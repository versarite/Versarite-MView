unit uTotalCommander;

{
  Unit: uTotalCommander

  Purpose
  -------
  "Side by side with Total Commander" (Phase G, G1, user): finds Total
  Commander (its window, or the program to start), tells it to open a
  folder, and puts windows exactly into a half of the screen.

  Owns
  ----
  Nothing (plain functions over the Windows API).

  Knows
  -----
  - Total Commander's main window class (TTOTAL_CMD), its documented
    command line (/O = use the running one, /S = the paths are
    source / target, /L= the source panel's folder) and its registry
    entry (HKCU / HKLM \Software\Ghisler\Total Commander, InstallDir).

  Responsibilities
  ----------------
  - FindTotalCommanderWindow: the running Total Commander's window, 0 if
    none.
  - TotalCommanderExe: the program: the configured path if it exists,
    else the running one's, else from the registry (TOTALCMD64.EXE, or
    TOTALCMD.EXE), else a few usual folders; '' if not found.
  - OpenInTotalCommander: starts it (or passes to the running one) with
    the folder in its active panel.
  - PlaceWindow: a window, restored if minimised or maximised, placed so
    that its visible frame fills the rectangle (Windows 10 / 11 windows
    have invisible borders a few pixels wide: corrected, so two halves
    meet exactly).

  Does NOT
  --------
  - Decide the halves or keep any state (the main form does).
  - Work on other systems: there every function says "not found" /
    False.

  Threads
  -------
  UI thread (window functions). Reads the registry and checks a few
  files: small, only when the user asks for it.

  Uses (MView units)
  ------------------
  (none)
  Libraries:      Classes, SysUtils, Types; Windows, ShellApi, Registry
                  (Windows only)

  Used by
  -------
  uMainForm
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Types;

function FindTotalCommanderWindow: THandle;
{ AConfigured: [Sort] TotalCommander ('' = look for it); AWindow: the
  running one's window (0 = none). }
function TotalCommanderExe(const AConfigured: string; AWindow: THandle): string;
{ AFolder '' = just bring it up. True if it could be started. }
function OpenInTotalCommander(const AExe, AFolder: string): Boolean;
{ True if the window was placed (False: e.g. it runs as administrator
  and MView doesn't). }
function PlaceWindow(AWindow: THandle; const ARect: Types.TRect): Boolean;

implementation

{$IFDEF WINDOWS}
uses
  Windows,
  ShellApi,
  Registry;

const
  DWMWA_EXTENDED_FRAME_BOUNDS_ID = 9;
  PROCESS_QUERY_LIMITED_INFORMATION_ID = $1000;
  KEY_WOW64_64KEY_ID = $0100;
  KEY_WOW64_32KEY_ID = $0200;

type
  { A Windows RECT, declared here so no unit's TRect is mixed up. }
  TWinRect = record
    Left, Top, Right, Bottom: LongInt;
  end;

function MViewDwmGetWindowAttribute(AWnd: HWND; AAttribute: DWORD; AValue: Pointer;
  ASize: DWORD): HRESULT; stdcall; external 'dwmapi.dll' name 'DwmGetWindowAttribute';
function MViewGetWindowRect(AWnd: HWND; ARect: Pointer): BOOL; stdcall;
  external 'user32.dll' name 'GetWindowRect';
function MViewGetWindowThreadProcessId(AWnd: HWND; AProcessId: Pointer): DWORD; stdcall;
  external 'user32.dll' name 'GetWindowThreadProcessId';
function MViewQueryFullProcessImageNameW(AProcess: THandle; AFlags: DWORD;
  AName: PWideChar; var ASize: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryFullProcessImageNameW';

function FindTotalCommanderWindow: THandle;
begin
  Result := FindWindowW('TTOTAL_CMD', nil);
end;

{ The program file of the process that owns AWindow. }
function ExeOfWindow(AWindow: THandle): string;
var
  Pid, Size: DWORD;
  Process: THandle;
  Buffer: array[0..MAX_PATH * 2] of WideChar;
  Name: WideString;
begin
  Result := '';
  if AWindow = 0 then
    Exit;
  Pid := 0;
  MViewGetWindowThreadProcessId(AWindow, @Pid);
  if Pid = 0 then
    Exit;
  Process := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_ID, False, Pid);
  if Process = 0 then
    Exit;
  try
    Size := Length(Buffer);
    if MViewQueryFullProcessImageNameW(Process, 0, @Buffer[0], Size) then
    begin
      SetString(Name, PWideChar(@Buffer[0]), Size);
      Result := UTF8Encode(Name);
    end;
  finally
    CloseHandle(Process);
  end;
end;

function ExeInFolder(const AFolder: string): string;
var
  Dir: string;
begin
  Result := '';
  if Trim(AFolder) = '' then
    Exit;
  Dir := IncludeTrailingPathDelimiter(Trim(AFolder));
  if FileExists(Dir + 'TOTALCMD64.EXE') then
    Result := Dir + 'TOTALCMD64.EXE'
  else if FileExists(Dir + 'TOTALCMD.EXE') then
    Result := Dir + 'TOTALCMD.EXE';
end;

function InstallDirFromRegistry(ARoot: HKEY; AAccess: LongWord): string;
var
  Reg: TRegistry;
begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ or AAccess);
  try
    Reg.RootKey := ARoot;
    { OpenKey with the access given at Create (it keeps the WOW64 view). }
    if Reg.OpenKey('Software\Ghisler\Total Commander', False) then
    begin
      if Reg.ValueExists('InstallDir') then
        Result := Reg.ReadString('InstallDir');
      Reg.CloseKey;
    end;
  except
    Result := '';
  end;
  Reg.Free;
end;

function TotalCommanderExe(const AConfigured: string; AWindow: THandle): string;
begin
  { 1. The configured path (the program, or its folder). }
  Result := Trim(AConfigured);
  if Result <> '' then
  begin
    if FileExists(Result) then
      Exit;
    Result := ExeInFolder(Result);
    if Result <> '' then
      Exit;
  end;
  { 2. The running one. }
  Result := ExeOfWindow(AWindow);
  if (Result <> '') and FileExists(Result) then
    Exit;
  { 3. Its registry entry (user, then machine, both registry views). }
  Result := ExeInFolder(InstallDirFromRegistry(HKEY_CURRENT_USER, 0));
  if Result = '' then
    Result := ExeInFolder(InstallDirFromRegistry(HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY_ID));
  if Result = '' then
    Result := ExeInFolder(InstallDirFromRegistry(HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY_ID));
  { 4. The usual folders. }
  if Result = '' then
    Result := ExeInFolder('C:\totalcmd');
  if Result = '' then
    Result := ExeInFolder('C:\Program Files\totalcmd');
  if Result = '' then
    Result := ExeInFolder('C:\Program Files (x86)\totalcmd');
end;

function OpenInTotalCommander(const AExe, AFolder: string): Boolean;
var
  Params, Folder: string;
begin
  Result := False;
  if (AExe = '') or not FileExists(AExe) then
    Exit;
  Params := '/O /S';
  Folder := Trim(AFolder);
  if Folder <> '' then
  begin
    { A drive's root keeps its backslash; "D:\" in quotes would end in \"
      (read as an escaped quote), so no quotes where no space needs them. }
    if Length(ExcludeTrailingPathDelimiter(Folder)) <= 2 then
      Folder := IncludeTrailingPathDelimiter(ExcludeTrailingPathDelimiter(Folder))
    else
      Folder := ExcludeTrailingPathDelimiter(Folder);
    if Pos(' ', Folder) > 0 then
      Params := Params + ' /L="' + Folder + '"'
    else
      Params := Params + ' /L=' + Folder;
  end;
  Result := ShellExecuteW(0, 'open', PWideChar(UTF8Decode(AExe)), PWideChar(UTF8Decode(Params)),
    nil, SW_SHOWNORMAL) > 32;
end;

function PlaceWindow(AWindow: THandle; const ARect: Types.TRect): Boolean;
var
  Outer, Frame: TWinRect;
  L, T, R, B: Integer;
begin
  Result := False;
  if (AWindow = 0) or not IsWindow(AWindow) then
    Exit;
  if IsIconic(AWindow) or IsZoomed(AWindow) then
    ShowWindow(AWindow, SW_RESTORE);
  { The invisible borders: the window rectangle minus the visible frame. }
  L := 0;
  T := 0;
  R := 0;
  B := 0;
  if MViewGetWindowRect(AWindow, @Outer)
    and (MViewDwmGetWindowAttribute(AWindow, DWMWA_EXTENDED_FRAME_BOUNDS_ID, @Frame,
      SizeOf(Frame)) = S_OK) then
  begin
    L := Frame.Left - Outer.Left;
    T := Frame.Top - Outer.Top;
    R := Outer.Right - Frame.Right;
    B := Outer.Bottom - Frame.Bottom;
  end;
  Result := SetWindowPos(AWindow, 0, ARect.Left - L, ARect.Top - T,
    (ARect.Right - ARect.Left) + L + R, (ARect.Bottom - ARect.Top) + T + B,
    SWP_NOZORDER or SWP_NOACTIVATE);
end;

{$ELSE}

function FindTotalCommanderWindow: THandle;
begin
  Result := 0;
end;

function TotalCommanderExe(const AConfigured: string; AWindow: THandle): string;
begin
  Result := '';
end;

function OpenInTotalCommander(const AExe, AFolder: string): Boolean;
begin
  Result := False;
end;

function PlaceWindow(AWindow: THandle; const ARect: Types.TRect): Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
