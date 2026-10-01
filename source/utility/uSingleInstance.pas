unit uSingleInstance;

{
  Unit: uSingleInstance

  Purpose
  -------
  "Only one instance" ([Startup] OnlyOneInstance, user, Day 23): opening
  images from Total Commander one after another must not start a new
  MView each time. A second MView hands its file or folder to the one
  already running (which opens it and comes to the front) and ends.

  Owns
  ----
  - A named mutex (held while MView runs): "is one running?".
  - A hidden message-only window that receives the path (its own window
    procedure: the LCL doesn't pass WM_COPYDATA on to a form, and the
    form's window is made again when going fullscreen; this one stays).
  - A small named shared memory block with that window's handle: "where
    do I send it?".

  Knows
  -----
  Nothing else.

  Responsibilities
  ----------------
  - HandOverToRunningInstance (the second MView, before its window is
    made): if another MView holds the mutex, send it the path with
    WM_COPYDATA (tagged MViewCopyDataTag), bring its window to the front
    and return True: the caller ends. The running one may still be
    starting (no window yet): it is asked again for up to 3 s; if there
    is still no window, False (this one runs after all).
  - StartInstanceListener (the first MView, once the main form exists):
    makes the message window, publishes its handle, and calls AOnPath
    (on the UI thread) for every path that arrives.

  Does NOT
  --------
  - Open anything (the main form does, as for a drop) or bring a window
    to the front (the sender allows it, the main form does it).
  - Work on other systems: there every MView runs on its own.

  Threads
  -------
  UI thread, at start-up and in the main form's message handler.

  Uses (MView units)
  ------------------
  (none)
  Libraries:      SysUtils; Windows (Windows only)

  Used by
  -------
  MView.lpr
}

{$mode ObjFPC}{$H+}

interface

type
  { APath '' = started without a file: just come to the front. }
  TInstancePathEvent = procedure(const APath: string) of object;

const
  { WM_COPYDATA, and the tag that says "a path for MView". }
  MViewWmCopyData = $004A;
  MViewCopyDataTag = $4D564F50;   { 'MVOP' }

{ True: another MView took APath ('' = just come to the front); end now. }
function HandOverToRunningInstance(const APath: string): Boolean;
{ This MView receives the next ones' paths (UI thread). }
procedure StartInstanceListener(AOnPath: TInstancePathEvent);

implementation

{$IFDEF WINDOWS}
uses
  Windows;

const
  MutexName = 'Local\VersariteMView.Instance';
  MappingName = 'Local\VersariteMView.Window';

type
  TSharedWindow = record
    Window: UInt64;
  end;
  PSharedWindow = ^TSharedWindow;

  { COPYDATASTRUCT, declared here (the C layout), so no unit's version
    matters. }
  {$PUSH}{$PACKRECORDS C}
  TMViewCopyData = record
    dwData: PtrUInt;
    cbData: DWORD;
    lpData: Pointer;
  end;
  {$POP}
  PMViewCopyData = ^TMViewCopyData;

  { WNDCLASSW, likewise. }
  {$PUSH}{$PACKRECORDS C}
  TMViewWndClass = record
    style: UINT;
    lpfnWndProc: Pointer;
    cbClsExtra: Integer;
    cbWndExtra: Integer;
    hInstance: THandle;
    hIcon: THandle;
    hCursor: THandle;
    hbrBackground: THandle;
    lpszMenuName: PWideChar;
    lpszClassName: PWideChar;
  end;
  {$POP}
  PMViewWndClass = ^TMViewWndClass;

function MViewRegisterClassW(AClass: PMViewWndClass): Word; stdcall;
  external 'user32.dll' name 'RegisterClassW';
function MViewCreateWindowExW(AExStyle: DWORD; AClassName, AWindowName: PWideChar;
  AStyle: DWORD; AX, AY, AWidth, AHeight: Integer; AParent: HWND; AMenu: THandle;
  AInstance: THandle; AParam: Pointer): HWND; stdcall;
  external 'user32.dll' name 'CreateWindowExW';
function MViewDefWindowProcW(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT;
  stdcall; external 'user32.dll' name 'DefWindowProcW';
function MViewAllowSetForegroundWindow(AProcessId: DWORD): BOOL; stdcall;
  external 'user32.dll' name 'AllowSetForegroundWindow';

function MViewSendMessageTimeoutW(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM;
  AFlags, ATimeout: UINT; AResult: PPtrUInt): LRESULT; stdcall;
  external 'user32.dll' name 'SendMessageTimeoutW';

const
  ListenerClassName: WideString = 'VersariteMViewInstanceListener';
  HwndMessage = HWND(High(PtrUInt) - 2);   { HWND_MESSAGE (-3): a message-only window }
  AsfwAny = DWORD($FFFFFFFF);       { ASFW_ANY }

var
  InstanceMutex: THandle = 0;
  Mapping: THandle = 0;
  ListenerWindow: HWND = 0;
  OnPath: TInstancePathEvent = nil;

function ReadPublishedWindow: HWND;
var
  Map: THandle;
  View: PSharedWindow;
begin
  Result := 0;
  Map := OpenFileMappingW(FILE_MAP_READ, False, PWideChar(WideString(MappingName)));
  if Map = 0 then
    Exit;
  try
    View := MapViewOfFile(Map, FILE_MAP_READ, 0, 0, SizeOf(TSharedWindow));
    if View <> nil then
    try
      Result := HWND(View^.Window);
    finally
      UnmapViewOfFile(View);
    end;
  finally
    CloseHandle(Map);
  end;
  if (Result <> 0) and not IsWindow(Result) then
    Result := 0;
end;

function HandOverToRunningInstance(const APath: string): Boolean;
var
  Wnd: HWND;
  Data: TMViewCopyData;
  Bytes: UTF8String;
  Tries: Integer;
  Answer: PtrUInt;
begin
  Result := False;
  InstanceMutex := CreateMutexW(nil, False, PWideChar(WideString(MutexName)));
  if (InstanceMutex = 0) or (GetLastError <> ERROR_ALREADY_EXISTS) then
    Exit;   { the first one (or no mutex at all): run }

  { Another MView runs. Its window may not be there yet (just started):
    ask again for up to 3 s. }
  Wnd := 0;
  for Tries := 1 to 30 do
  begin
    Wnd := ReadPublishedWindow;
    if Wnd <> 0 then
      Break;
    Sleep(100);
  end;
  if Wnd = 0 then
    Exit;   { no answer: run on our own }

  { This process was just started by the user, so it may hand the right
    to come to the front on: the running MView brings itself up. }
  MViewAllowSetForegroundWindow(AsfwAny);
  Bytes := UTF8String(APath);
  Data.dwData := MViewCopyDataTag;
  Data.cbData := Length(Bytes);
  if Length(Bytes) > 0 then
    Data.lpData := PAnsiChar(Bytes)
  else
    Data.lpData := nil;
  { Not SendMessage: a running MView that hangs must not hang this one. }
  Answer := 0;
  if MViewSendMessageTimeoutW(Wnd, MViewWmCopyData, 0, LPARAM(@Data), SMTO_ABORTIFHUNG, 5000,
    @Answer) = 0 then
    Exit;   { it didn't take it: run on our own }

  Result := True;
end;

procedure PublishWindow(AWindow: THandle);
var
  View: PSharedWindow;
begin
  if Mapping = 0 then
    Mapping := CreateFileMappingW(INVALID_HANDLE_VALUE, nil, PAGE_READWRITE, 0,
      SizeOf(TSharedWindow), PWideChar(WideString(MappingName)));
  if Mapping = 0 then
    Exit;
  View := MapViewOfFile(Mapping, FILE_MAP_WRITE, 0, 0, SizeOf(TSharedWindow));
  if View = nil then
    Exit;
  View^.Window := UInt64(AWindow);
  UnmapViewOfFile(View);
end;

{ The message window's procedure: a path from another MView. Never lets
  an exception out (it is called by Windows). }
function ListenerProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT;
  stdcall;
var
  Data: PMViewCopyData;
  Bytes: UTF8String;
begin
  if AMsg = MViewWmCopyData then
  begin
    Data := PMViewCopyData(ALParam);
    if (Data <> nil) and (Data^.dwData = MViewCopyDataTag) then
    begin
      Result := 1;
      try
        Bytes := '';
        if (Data^.cbData > 0) and (Data^.lpData <> nil) then
          SetString(Bytes, PAnsiChar(Data^.lpData), Data^.cbData);
        if Assigned(OnPath) then
          OnPath(string(Bytes));
      except
        { Nothing reaches Windows. }
      end;
      Exit;
    end;
  end;
  Result := MViewDefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

procedure StartInstanceListener(AOnPath: TInstancePathEvent);
var
  WndClass: TMViewWndClass;
begin
  OnPath := AOnPath;
  if ListenerWindow <> 0 then
    Exit;
  FillChar(WndClass, SizeOf(WndClass), 0);
  WndClass.lpfnWndProc := @ListenerProc;
  WndClass.hInstance := HInstance;
  WndClass.lpszClassName := PWideChar(ListenerClassName);
  MViewRegisterClassW(@WndClass);   { 0 if registered already: fine }
  ListenerWindow := MViewCreateWindowExW(0, PWideChar(ListenerClassName), nil, 0, 0, 0, 0, 0,
    HwndMessage, 0, HInstance, nil);
  if ListenerWindow <> 0 then
    PublishWindow(ListenerWindow);
end;

{$ELSE}

function HandOverToRunningInstance(const APath: string): Boolean;
begin
  Result := False;
end;

procedure StartInstanceListener(AOnPath: TInstancePathEvent);
begin
end;

{$ENDIF}

end.
