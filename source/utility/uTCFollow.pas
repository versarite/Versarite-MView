unit uTCFollow;

{
  Unit: uTCFollow

  Purpose
  -------
  "Follow Total Commander" (user, Day 23: "it would be cool to see if
  mview could be a power viewer for tc"): asks the running Total
  Commander which folder its active panel shows, and which file its
  cursor is on, so MView can show the same.

  Total Commander tells nobody when its folder changes, but it answers
  questions; MView asks a few times a second (TMView's timer).

  Owns
  ----
  - A hidden message-only window: Total Commander sends its answers to
    it (WM_COPYDATA, while MView waits for the question to return).

  Knows
  -----
  - Total Commander's window (uTotalCommander.FindTotalCommanderWindow).
  - Its two interfaces:
      1. WM_COPYDATA with dwData 'G' + 256 * 'W' and a two-letter
         question ("SP" = the active (source) panel's path, "SN" = the
         name under its cursor; "SC" answers a number, Day 23 test), the reply window in wParam; the answer
         comes back as WM_COPYDATA, dwData 'R' + 256 * 'W', UTF-16.
         (As used by community scripts; not in the wiki pages MView's
         author could read: if no answer comes, method 2.)
      2. WM_USER + 50 (TC wiki "WM_USER"): wParam 1000 = which panel is
         active (1 left, 2 right); 9 / 10 = the handle of the left /
         right path line, whose text is the folder plus a mask
         ("C:\Images\*.*"). Folder only.

  Responsibilities
  ----------------
  - Poll: the active panel's folder (with a trailing backslash) and, if
    asked, the full name of the file under the cursor ('' when it is on
    ".." or a folder name can't be told apart: the caller checks the
    extension). False when Total Commander isn't running or answers
    nothing.
  - CursorSupported: False once the cursor question went unanswered
    (then only the folder is followed, and the caller can say so).
  - Paths that aren't folders on a disk (archives, FTP, plugins:
    "\\\", "::", no drive or share) give ''.

  Does NOT
  --------
  - Read the disk or open anything (TMView does: the scanner checks).

  Threads
  -------
  UI thread only (the answers arrive on it, during the question).

  Uses (MView units)
  ------------------
  implementation: uTotalCommander
  Libraries:      SysUtils; Windows (Windows only)

  Used by
  -------
  uMView
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type

  { A question's outcome: answered; returned without an answer (this
    Total Commander doesn't know it); or no reply in time (busy). }
  TTCAsk = (taAnswered, taNoAnswer, taTimeout);

  TTCFollower = class(TObject)
  private
    FReplyWindow: THandle;
    FCursorSupported: Boolean;
    FAskCursor: Boolean;         { the cursor question is worth asking }
    FCursorTried: Boolean;       { the cursor question was answered once }
    FInfo: string;
    function Ask(ATC: THandle; const AQuestion: AnsiString; out AAnswer: string): TTCAsk;
    function PathFromPathLine(ATC: THandle): string;
    function NameFromFileList(ATC: THandle; out AName: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { AWantFile: also the file under the cursor. }
    function Poll(AWantFile: Boolean; out AFolder, AFile: string): Boolean;
    property CursorSupported: Boolean read FCursorSupported;
    { For the D line: how the last answers came ("folder: question,
      cursor: list 'x.jpg'"). }
    property Info: string read FInfo;
  end;

implementation

{$IFDEF WINDOWS}
uses
  Windows,
  uTotalCommander;

type
  {$PUSH}{$PACKRECORDS C}
  TTCCopyData = record
    dwData: PtrUInt;
    cbData: DWORD;
    lpData: Pointer;
  end;
  TTCWndClass = record
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
  PTCCopyData = ^TTCCopyData;
  PTCWndClass = ^TTCWndClass;

function TCRegisterClassW(AClass: PTCWndClass): Word; stdcall;
  external 'user32.dll' name 'RegisterClassW';
function TCCreateWindowExW(AExStyle: DWORD; AClassName, AWindowName: PWideChar;
  AStyle: DWORD; AX, AY, AWidth, AHeight: Integer; AParent: HWND; AMenu: THandle;
  AInstance: THandle; AParam: Pointer): HWND; stdcall;
  external 'user32.dll' name 'CreateWindowExW';
function TCDefWindowProcW(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT;
  stdcall; external 'user32.dll' name 'DefWindowProcW';
function TCSendMessageTimeoutW(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM;
  AFlags, ATimeout: UINT; AResult: PPtrUInt): LRESULT; stdcall;
  external 'user32.dll' name 'SendMessageTimeoutW';
function TCDestroyWindow(AWnd: HWND): BOOL; stdcall;
  external 'user32.dll' name 'DestroyWindow';

const
  WmCopyData = $004A;
  WmGetText = $000D;
  WmUser50 = $0400 + 50;
  AskTag = Ord('G') + 256 * Ord('W');      { a question, answer in UTF-16 }
  AnswerTag = Ord('R') + 256 * Ord('W');   { the answer }
  AnswerTagAnsi = Ord('R') + 256 * Ord('A');
  ReplyClassName: WideString = 'VersariteMViewTCReply';
  HwndMessage = HWND(High(PtrUInt) - 2);   { HWND_MESSAGE (-3) }
  TimeoutMs = 300;

var
  { The answer to the question being asked (one at a time, UI thread). }
  Answer: string = '';
  Answered: Boolean = False;

function ReplyProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
var
  Data: PTCCopyData;
  W: UnicodeString;
  A: AnsiString;
begin
  if AMsg = WmCopyData then
  begin
    Data := PTCCopyData(ALParam);
    if (Data <> nil) and ((Data^.dwData = AnswerTag) or (Data^.dwData = AnswerTagAnsi)) then
    begin
      Result := 1;
      try
        if (Data^.lpData = nil) or (Data^.cbData = 0) then
          Answer := ''
        else if Data^.dwData = AnswerTag then
        begin
          SetString(W, PWideChar(Data^.lpData), Data^.cbData div 2);
          Answer := UTF8Encode(W);
        end
        else
        begin
          SetString(A, PAnsiChar(Data^.lpData), Data^.cbData);
          Answer := string(A);
        end;
        { Up to the first #0 (the length may count it). }
        if Pos(#0, Answer) > 0 then
          SetLength(Answer, Pos(#0, Answer) - 1);
        Answered := True;
      except
        { Nothing reaches Windows. }
      end;
      Exit;
    end;
  end;
  Result := TCDefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

constructor TTCFollower.Create;
var
  WndClass: TTCWndClass;
begin
  inherited Create;
  FCursorSupported := True;
  FAskCursor := True;
  FillChar(WndClass, SizeOf(WndClass), 0);
  WndClass.lpfnWndProc := @ReplyProc;
  WndClass.hInstance := System.HInstance;
  WndClass.lpszClassName := PWideChar(ReplyClassName);
  TCRegisterClassW(@WndClass);    { 0 if registered already: fine }
  FReplyWindow := TCCreateWindowExW(0, PWideChar(ReplyClassName), nil, 0, 0, 0, 0, 0,
    HwndMessage, 0, System.HInstance, nil);
end;

destructor TTCFollower.Destroy;
begin
  if FReplyWindow <> 0 then
    TCDestroyWindow(FReplyWindow);
  inherited Destroy;
end;

function TTCFollower.Ask(ATC: THandle; const AQuestion: AnsiString; out AAnswer: string): TTCAsk;
var
  Data: TTCCopyData;
  Question: AnsiString;
  Dummy: PtrUInt;
begin
  AAnswer := '';
  Result := taNoAnswer;
  if FReplyWindow = 0 then
    Exit;
  Question := AQuestion + #0;
  Data.dwData := AskTag;
  Data.cbData := Length(Question);
  Data.lpData := PAnsiChar(Question);
  Answer := '';
  Answered := False;
  Dummy := 0;
  { Total Commander answers to FReplyWindow before this returns. }
  if TCSendMessageTimeoutW(ATC, WmCopyData, WPARAM(FReplyWindow), LPARAM(@Data),
    SMTO_ABORTIFHUNG, TimeoutMs, @Dummy) = 0 then
  begin
    Result := taTimeout;
    Exit;
  end;
  if Answered then
  begin
    AAnswer := Answer;
    Result := taAnswered;
  end;
end;

{ Method 2: the active panel's path line ("C:\Images\*.*"). }
function TTCFollower.PathFromPathLine(ATC: THandle): string;
var
  Active, Line: PtrUInt;
  Buffer: array[0..1023] of WideChar;
  Len: PtrUInt;
  W: UnicodeString;
  Slash: Integer;
begin
  Result := '';
  Active := 0;
  if TCSendMessageTimeoutW(ATC, WmUser50, 1000, 0, SMTO_ABORTIFHUNG, TimeoutMs, @Active) = 0 then
    Exit;
  Line := 0;
  if Active = 2 then
    TCSendMessageTimeoutW(ATC, WmUser50, 10, 0, SMTO_ABORTIFHUNG, TimeoutMs, @Line)
  else
    TCSendMessageTimeoutW(ATC, WmUser50, 9, 0, SMTO_ABORTIFHUNG, TimeoutMs, @Line);
  if Line = 0 then
    Exit;
  FillChar(Buffer, SizeOf(Buffer), 0);
  Len := 0;
  if TCSendMessageTimeoutW(HWND(Line), WmGetText, Length(Buffer) - 1, LPARAM(@Buffer[0]),
    SMTO_ABORTIFHUNG, TimeoutMs, @Len) = 0 then
    Exit;
  W := PWideChar(@Buffer[0]);
  Result := UTF8Encode(W);
  { The mask after the last backslash goes. }
  Slash := LastDelimiter('\', Result);
  if (Slash > 0) and ((Pos('*', Copy(Result, Slash + 1, MaxInt)) > 0)
    or (Pos('?', Copy(Result, Slash + 1, MaxInt)) > 0)) then
    SetLength(Result, Slash);
end;

{ Method 2 for the cursor (WM_USER + 50, documented): the active file
  list's handle (3), the index of the item under the cursor (1007 left,
  1008 right) and that list line's text (LB_GETTEXT; Windows copies the
  text across for list boxes). The line may hold more than the name,
  separated by tabs: the name comes first; "show the extension apart"
  gives "name<tab>ext". Folders come as "[name]". }
function TTCFollower.NameFromFileList(ATC: THandle; out AName: string): Boolean;
const
  LbGetText = $0189;
  LbGetTextLen = $018A;
  LbErr = PtrUInt(High(PtrUInt));   { LB_ERR (-1) }
var
  Active, List, Index, Len, Got: PtrUInt;
  Buffer: array of WideChar;
  W: UnicodeString;
  Line, Ext: string;
  Tab, I: Integer;
begin
  AName := '';
  Result := False;
  Active := 0;
  if TCSendMessageTimeoutW(ATC, WmUser50, 1000, 0, SMTO_ABORTIFHUNG, TimeoutMs, @Active) = 0 then
    Exit;
  List := 0;
  TCSendMessageTimeoutW(ATC, WmUser50, 3, 0, SMTO_ABORTIFHUNG, TimeoutMs, @List);
  Index := LbErr;
  if Active = 2 then
    TCSendMessageTimeoutW(ATC, WmUser50, 1008, 0, SMTO_ABORTIFHUNG, TimeoutMs, @Index)
  else
    TCSendMessageTimeoutW(ATC, WmUser50, 1007, 0, SMTO_ABORTIFHUNG, TimeoutMs, @Index);
  if (List = 0) or (Index = LbErr) or (Index > 10000000) then
    Exit;
  Len := LbErr;
  if TCSendMessageTimeoutW(HWND(List), LbGetTextLen, Index, 0, SMTO_ABORTIFHUNG, TimeoutMs,
    @Len) = 0 then
    Exit;
  if (Len = LbErr) or (Len = 0) or (Len > 4000) then
    Exit;
  SetLength(Buffer, Len + 2);
  FillChar(Buffer[0], Length(Buffer) * SizeOf(WideChar), 0);
  Got := LbErr;
  if TCSendMessageTimeoutW(HWND(List), LbGetText, Index, LPARAM(@Buffer[0]), SMTO_ABORTIFHUNG,
    TimeoutMs, @Got) = 0 then
    Exit;
  if (Got = LbErr) or (Got = 0) then
    Exit;
  W := PWideChar(@Buffer[0]);
  Line := UTF8Encode(W);
  Tab := Pos(#9, Line);
  if Tab = 0 then
    AName := Line
  else
  begin
    AName := Copy(Line, 1, Tab - 1);
    { "name<tab>ext<tab>...": the extension shown apart. }
    Ext := Copy(Line, Tab + 1, MaxInt);
    if Pos(#9, Ext) > 0 then
      SetLength(Ext, Pos(#9, Ext) - 1);
    Ext := Trim(Ext);
    if (ExtractFileExt(AName) = '') and (Ext <> '') and (Length(Ext) <= 5) then
    begin
      for I := 1 to Length(Ext) do
        if not (Ext[I] in ['a'..'z', 'A'..'Z', '0'..'9']) then
        begin
          Ext := '';
          Break;
        end;
      if Ext <> '' then
        AName := AName + '.' + Ext;
    end;
  end;
  AName := Trim(AName);
  { A folder: not a file. }
  if (AName <> '') and (AName[1] = '[') then
    AName := '';
  Result := True;
end;

function IsNumber(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := AText <> '';
  for I := 1 to Length(AText) do
    if not (AText[I] in ['0'..'9']) then
      Exit(False);
end;

{ A folder on a disk or share ("C:\...", "\\server\share\..."), not an
  archive ("C:\x.zip\sub\": Total Commander shows archives as folders),
  FTP or plugin path. Decided from the text only (no disk access on the
  window thread). }
function IsDiskFolder(const APath: string): Boolean;
const
  Archives: array[0..15] of string = ('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2',
    '.xz', '.cab', '.iso', '.arj', '.lzh', '.jar', '.zst', '.lha', '.wim');
var
  I, J, Start: Integer;
  Ext: string;
begin
  Result := False;
  if Length(APath) < 3 then
    Exit;
  if (Pos('::', APath) > 0) or (Copy(APath, 1, 3) = '\\\') then
    Exit;
  if not (((APath[2] = ':') and (APath[3] = '\'))
    or ((APath[1] = '\') and (APath[2] = '\'))) then
    Exit;
  { Each part between backslashes. }
  Start := 1;
  for I := 1 to Length(APath) + 1 do
    if (I > Length(APath)) or (APath[I] = '\') then
    begin
      Ext := LowerCase(ExtractFileExt(Copy(APath, Start, I - Start)));
      if Ext <> '' then
        for J := Low(Archives) to High(Archives) do
          if Ext = Archives[J] then
            Exit;
      Start := I + 1;
    end;
  Result := True;
end;

function TTCFollower.Poll(AWantFile: Boolean; out AFolder, AFile: string): Boolean;
var
  TC: THandle;
  Name, Via: string;
  Got: Boolean;
begin
  AFolder := '';
  AFile := '';
  Result := False;
  TC := FindTotalCommanderWindow;
  if TC = 0 then
    Exit;

  { The folder: the question, else the path line. (A Total Commander
    that doesn't know the question returns at once, without an answer;
    a busy one: nothing more this time.) }
  FInfo := 'folder: question';
  case Ask(TC, 'SP', AFolder) of
    taTimeout:
      begin
        FInfo := 'busy';
        Exit;
      end;
    taNoAnswer:
      begin
        AFolder := PathFromPathLine(TC);
        FInfo := 'folder: path line';
      end;
  else
    if AFolder = '' then
    begin
      AFolder := PathFromPathLine(TC);
      FInfo := 'folder: path line';
    end;
  end;
  if AFolder = '' then
    Exit;
  AFolder := IncludeTrailingPathDelimiter(AFolder);
  if not IsDiskFolder(AFolder) then
  begin
    AFolder := '';
    Exit;
  end;
  Result := True;

  if not AWantFile then
    Exit;

  { The file under the cursor: the question, else the file list. }
  Got := False;
  Via := '';
  if FAskCursor then
    case Ask(TC, 'SN', Name) of
      taAnswered:
        { A bare number is not a name (user's test, Day 23: "SC" gave the
          same number on every line): the list then. }
        if IsNumber(Name) then
          FAskCursor := False
        else
        begin
          FCursorTried := True;
          Got := True;
          Via := 'question';
        end;
      taNoAnswer:
        { Returned at once without an answer: this Total Commander
          doesn't know the question; the list from now on. }
        if not FCursorTried then
          FAskCursor := False;
      taTimeout:
        Exit;
    end;
  if not Got then
  begin
    Got := NameFromFileList(TC, Name);
    if Got then
      Via := 'list';
  end;
  FCursorSupported := Got or FCursorTried;
  if not Got then
  begin
    FInfo := FInfo + ', cursor: no answer';
    Exit;
  end;
  FInfo := FInfo + ', cursor: ' + Via + ' "' + Name + '"';
  if (Name = '') or (Name = '..') then
    Exit;
  { A full path, or a name in the folder. }
  if ((Length(Name) > 2) and (Name[2] = ':')) or (Copy(Name, 1, 2) = '\\') then
    AFile := Name
  else if Pos('\', Name) = 0 then
    AFile := AFolder + Name;
end;

{$ELSE}

constructor TTCFollower.Create;
begin
  inherited Create;
end;

destructor TTCFollower.Destroy;
begin
  inherited Destroy;
end;

function TTCFollower.Ask(ATC: THandle; const AQuestion: AnsiString; out AAnswer: string): TTCAsk;
begin
  AAnswer := '';
  Result := taNoAnswer;
end;

function TTCFollower.PathFromPathLine(ATC: THandle): string;
begin
  Result := '';
end;

function TTCFollower.NameFromFileList(ATC: THandle; out AName: string): Boolean;
begin
  AName := '';
  Result := False;
end;

function TTCFollower.Poll(AWantFile: Boolean; out AFolder, AFile: string): Boolean;
begin
  AFolder := '';
  AFile := '';
  Result := False;
end;

{$ENDIF}

end.
