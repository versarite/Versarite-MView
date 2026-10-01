program TestMouse;

{
  Checks the mouse language (Phase F): the profile file (uMouseProfile:
  parsing, errors, fallbacks, saving) and the engine (uMouseEngine:
  zones, order per zone, clicks and double-clicks, wheel, tilt,
  gestures, modes, keys), with a simulated clock; and the Hamana
  homage profile (mouse\Hamana.mouse) as it is shipped.

  Build and run with build_test.bat.
}

{$mode ObjFPC}{$H+}

uses
  Classes,
  SysUtils,
  Math,
  uCommands,
  uMouseProfile,
  uMouseEngine;

var
  PassCount, FailCount: Integer;

procedure Check(const ALabel: string; ACondition: Boolean; const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(PassCount);
    WriteLn('  PASS  ', ALabel);
  end
  else
  begin
    Inc(FailCount);
    WriteLn('  FAIL  ', ALabel);
    if ADetail <> '' then
      WriteLn('         got: ', ADetail);
  end;
end;

function SameActions(const A: TActionList; const B: array of TMouseAction): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for I := 0 to High(A) do
      if A[I] <> B[I] then
        Exit(False);
end;

function ActionsText(const A: TActionList): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
    Result := Result + MouseActionName(A[I]) + ' ';
  if Result = '' then
    Result := '(none)';
end;

{ ---- profile ---- }

procedure TestProfile;
var
  P, Q: TMouseProfile;
  A, B: TStringList;
begin
  WriteLn;
  WriteLn('-- Profile --');
  P := TMouseProfile.Create;
  Q := TMouseProfile.Create;
  A := TStringList.Create;
  B := TStringList.Create;
  try
    P.LoadDefaults;
    Check('built-in profile: no errors', P.Errors.Count = 0, P.Errors.Text);
    Check('bottom left: wheel down = next image (from Anywhere)',
      SameActions(P.ActionsFor(mzBottomLeft, meWheelDown), [maNextImage]),
      ActionsText(P.ActionsFor(mzBottomLeft, meWheelDown)));
    Check('bottom right: wheel down = zoom in (its own)',
      SameActions(P.ActionsFor(mzBottomRight, meWheelDown), [maZoomIn]));
    Check('top left: wheel up = turn right',
      SameActions(P.ActionsFor(mzTopLeft, meWheelUp), [maTurnRight]));
    Check('keys: Space = next image; Esc is fixed, not in the profile',
      (Length(P.ActionsFor(mzTopLeft, meKeyEsc)) = 0)
      and SameActions(P.ActionsFor(mzBottomRight, meKeySpace), [maNextImage]));
    Check('zone names and orders',
      (P.ZoneTitle(mzBottomLeft) = 'Browse by date') and (P.ZoneOrder(mzBottomLeft) = zoDate)
      and (P.ZoneTitle(mzTopRight) = 'Browse by name') and (P.ZoneOrder(mzTopRight) = zoName)
      and (P.ZoneTitle(mzBottomRight) = 'Inspect') and (P.ZoneOrder(mzBottomRight) = zoNone));

    P.LoadFromText(
      '; comment' + LineEnding +
      '[Anywhere]' + LineEnding +
      'WheelDown = NextImage   # trailing comment' + LineEnding +
      'LeftClick = sortbyname, NEXTIMAGE, OriginalSize' + LineEnding +
      'RightClick = Menu, Fit, Info, Exit' + LineEnding +
      'X1 = Jump' + LineEnding +
      'Blink = Menu' + LineEnding +
      'Space = NextImage' + LineEnding +
      '[Zone BottomRight]' + LineEnding +
      'Name = Look' + LineEnding +
      'Order = Sideways' + LineEnding +
      'WheelDown = None' + LineEnding +
      'X2 =' + LineEnding +
      '[Zone Middle]' + LineEnding +
      'WheelUp = ZoomIn' + LineEnding +
      '[Keys]' + LineEnding +
      'Esc = Back' + LineEnding +
      'WheelUp = ZoomIn' + LineEnding);
    Check('three commands in a row, names not case sensitive',
      SameActions(P.ActionsFor(mzTopLeft, meLeftClick), [maSortByName, maNextImage, maOriginalSize]));
    Check('a fourth command is cut off (and reported)',
      SameActions(P.ActionsFor(mzTopLeft, meRightClick), [maMenu, maFit, maInfo]));
    Check('None in a zone switches the Anywhere entry off there',
      Length(P.ActionsFor(mzBottomRight, meWheelDown)) = 0);
    Check('  ...other zones still use it',
      SameActions(P.ActionsFor(mzTopRight, meWheelDown), [maNextImage]));
    Check('"X2 =" with nothing: off', Length(P.ActionsFor(mzBottomRight, meX2)) = 0);
    Check('zone name read', P.ZoneTitle(mzBottomRight) = 'Look');
    Check('an old "Esc = Back" line: accepted, ignored (Esc is fixed)',
      Length(P.ActionsFor(mzTopLeft, meKeyEsc)) = 0);
    { Errors: 4 commands (line 5), Jump (6), Blink (7), Space outside
      [Keys] (8), Order (11), [Zone Middle] (14), WheelUp in [Keys] (18). }
    Check('7 problems reported', P.Errors.Count = 7, P.Errors.Text);
    if P.Errors.Count > 0 then
      Check('  with line numbers', Pos('line 5:', P.Errors[0]) = 1, P.Errors[0]);

    { Saving and reading again gives the same profile. }
    P.LoadDefaults;
    P.SaveToStrings(A);
    Q.LoadFromStrings(A);
    Q.SaveToStrings(B);
    Check('save, read, save: identical', (A.Text = B.Text) and (Q.Errors.Count = 0), Q.Errors.Text);
    Check('  and it means the same',
      SameActions(Q.ActionsFor(mzBottomRight, meWheelDown), [maZoomIn])
      and (Q.ZoneOrder(mzTopRight) = zoName));

    Q.Assign(P);
    P.SetZoneBinding(mzTopLeft, meX1, nil);
    P.SetAnywhereBinding(meX1, nil);
    Check('Assign copies (later changes to the source don''t reach it)',
      SameActions(Q.ActionsFor(mzTopLeft, meX1), [maZoomMode]));
  finally
    B.Free;
    A.Free;
    Q.Free;
    P.Free;
  end;
end;

procedure TestZones;
begin
  WriteLn;
  WriteLn('-- Zones --');
  Check('corners', (ZoneAt(10, 10, 1000, 800, mzBottomLeft, False) = mzTopLeft)
    and (ZoneAt(990, 10, 1000, 800, mzBottomLeft, False) = mzTopRight)
    and (ZoneAt(10, 790, 1000, 800, mzTopLeft, False) = mzBottomLeft)
    and (ZoneAt(990, 790, 1000, 800, mzTopLeft, False) = mzBottomRight));
  Check('just right of the middle, coming from the left: still left',
    ZoneAt(510, 700, 1000, 800, mzBottomLeft, True) = mzBottomLeft);
  Check('  ...without a previous zone: right',
    ZoneAt(510, 700, 1000, 800, mzBottomLeft, False) = mzBottomRight);
  Check('  ...clearly right (beyond the band): right',
    ZoneAt(520, 700, 1000, 800, mzBottomLeft, True) = mzBottomRight);
  Check('just above the middle, coming from below: still bottom',
    ZoneAt(100, 395, 1000, 800, mzBottomLeft, True) = mzBottomLeft);
end;

{ ---- engine ---- }

type
  TRecorder = class
    Commands: array of TCommand;
    Args: array of TCommandArgs;
    procedure Handle(Sender: TObject; ACommand: TCommand; const AArgs: TCommandArgs);
    procedure Clear;
    function Count(ACommand: TCommand): Integer;
    function Has(ACommand: TCommand): Boolean;
    function IndexOf(ACommand: TCommand): Integer;
    { Everything except the zone feedback. }
    function Text: string;
  end;

procedure TRecorder.Handle(Sender: TObject; ACommand: TCommand; const AArgs: TCommandArgs);
var
  N: Integer;
begin
  N := Length(Commands);
  SetLength(Commands, N + 1);
  SetLength(Args, N + 1);
  Commands[N] := ACommand;
  Args[N] := AArgs;
end;

procedure TRecorder.Clear;
begin
  Commands := nil;
  Args := nil;
end;

function TRecorder.Count(ACommand: TCommand): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Commands) do
    if Commands[I] = ACommand then
      Inc(Result);
end;

function TRecorder.Has(ACommand: TCommand): Boolean;
begin
  Result := Count(ACommand) > 0;
end;

function TRecorder.IndexOf(ACommand: TCommand): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Commands) do
    if Commands[I] = ACommand then
      Exit(I);
  Result := -1;
end;

function TRecorder.Text: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Commands) do
    if Commands[I] <> cmdShowZone then
      Result := Result + IntToStr(Ord(Commands[I])) + ' ';
  if Result = '' then
    Result := '(nothing)';
end;

procedure TestEngine;
const
  W = 1000;
  H = 800;
  { Points in the zones. }
  BLX = 100; BLY = 700;   { bottom left: browse by date }
  BRX = 900; BRY = 700;   { bottom right: inspect }
  TRPX = 900; TRPY = 100;   { top right: browse by name }
  TLX = 100; TLY = 100;   { top left: edit }
var
  E: TMouseEngine;
  R: TRecorder;
  P: TMouseProfile;
  T: QWord;
  I, Idx: Integer;
begin
  WriteLn;
  WriteLn('-- Engine --');
  R := TRecorder.Create;
  E := TMouseEngine.Create(nil);
  P := TMouseProfile.Create;
  try
    E.OnCommand := @R.Handle;
    E.SetViewSize(W, H);
    E.DoubleClickMs := 500;
    T := 10000;

    { Entering zones. }
    E.MouseMove(BLX, BLY, False, False, T);
    Check('entering a zone shows its name', R.Has(cmdShowZone)
      and (Round(R.Args[R.IndexOf(cmdShowZone)].Value) = Ord(mzBottomLeft)));
    R.Clear;
    E.MouseMove(BLX + 20, BLY - 20, False, False, T);
    Check('moving inside it: nothing', Length(R.Commands) = 0, R.Text);

    { Wheel: browse by date. }
    R.Clear;
    E.Wheel(-120, BLX, BLY, T);
    Idx := R.IndexOf(cmdNextImage);
    Check('bottom left, wheel towards you: sort by date, then next image',
      (Idx > 0) and (R.IndexOf(cmdSortByDate) >= 0) and (R.IndexOf(cmdSortByDate) < Idx), R.Text);
    R.Clear;
    E.Wheel(120, TRPX, TRPY, T);
    Check('top right, wheel away: sort by name, then previous image',
      (R.IndexOf(cmdSortByName) >= 0) and (R.IndexOf(cmdPreviousImage) > R.IndexOf(cmdSortByName)),
      R.Text);

    { High-resolution wheel: parts of a notch. }
    R.Clear;
    E.Wheel(-40, BLX, BLY, T);
    E.Wheel(-40, BLX, BLY, T);
    Check('two thirds of a notch: no step yet', not R.Has(cmdNextImage), R.Text);
    E.Wheel(-40, BLX, BLY, T);
    Check('  the third part: one step', R.Count(cmdNextImage) = 1, R.Text);

    { Inspect: zoom, smoothly. }
    R.Clear;
    E.Wheel(-120, BRX, BRY, T);
    Idx := R.IndexOf(cmdZoomAt);
    Check('bottom right, wheel towards you: zoom in at the middle of the view (zones on)',
      (Idx >= 0) and SameValue(R.Args[Idx].Value, 1.0) and (Round(R.Args[Idx].X) = W div 2)
      and (Round(R.Args[Idx].Y) = H div 2), R.Text);
    R.Clear;
    E.Wheel(40, BRX, BRY, T);
    Idx := R.IndexOf(cmdZoomAt);
    Check('  a third of a notch away: zoom out by a third at once',
      (Idx >= 0) and SameValue(R.Args[Idx].Value, -1 / 3, 1e-9), R.Text);

    { Edit zone: turn 5 degrees. }
    R.Clear;
    E.Wheel(120, TLX, TLY, T);
    Idx := R.IndexOf(cmdRotateBy);
    Check('top left, wheel away: turn right 5 degrees',
      (Idx >= 0) and SameValue(R.Args[Idx].Value, 5.0), R.Text);

    { Zones switched off ([Mouse] ZonesEnabled=0): the Inspect zone's
      wheel zooms no more, the Anywhere entry (next image) counts, no
      zone order and no zone name. }
    E.ZonesEnabled := False;
    R.Clear;
    E.MouseMove(BRX, BRY, False, False, T);
    E.Wheel(-120, BRX, BRY, T);
    Check('zones off: bottom right wheel = next image, no zoom, no sort, no zone name',
      R.Has(cmdNextImage) and not R.Has(cmdZoomAt) and not R.Has(cmdSortByDate)
      and not R.Has(cmdSortByName) and not R.Has(cmdShowZone), R.Text);
    R.Clear;
    E.MouseMove(BLX, BLY, False, False, T + 100);
    E.Wheel(-120, BLX, BLY, T + 100);
    Check('  bottom left (by date): next image, but no sort by date',
      R.Has(cmdNextImage) and not R.Has(cmdSortByDate), R.Text);
    E.ZonesEnabled := True;
    T := T + 5000;

    { Edit zone (top left): a click switches edit mode on (after the
      double-click time), a double-click switches it off. }
    R.Clear;
    E.MouseMove(TLX, TLY, False, False, T);
    E.MouseDown(ebLeft, TLX, TLY, T);
    E.MouseUp(ebLeft, TLX, TLY, T + 80);
    E.Tick(T + 2000);
    Check('edit zone: click = edit mode on', R.Has(cmdEditModeOn) and not R.Has(cmdEditModeOff), R.Text);
    T := T + 5000;
    R.Clear;
    E.MouseDown(ebLeft, TLX, TLY, T);
    E.MouseUp(ebLeft, TLX, TLY, T + 80);
    E.MouseDown(ebLeft, TLX, TLY, T + 200);
    E.MouseUp(ebLeft, TLX, TLY, T + 260);
    E.Tick(T + 2000);
    Check('  double-click = edit mode off (and not on)',
      R.Has(cmdEditModeOff) and not R.Has(cmdEditModeOn), R.Text);
    T := T + 5000;
    E.MouseMove(BLX, BLY, False, False, T);

    { Double-click (Anywhere: fit <-> 100 %); a plain left click does
      nothing in the built-in profile. }
    R.Clear;
    E.MouseDown(ebLeft, BLX, BLY, T);
    E.MouseUp(ebLeft, BLX, BLY, T + 80);
    E.MouseDown(ebLeft, BLX + 2, BLY, T + 200);
    Idx := R.IndexOf(cmdToggleFit);
    Check('double-click: fit <-> 100 % at the mouse, on the second press',
      (Idx >= 0) and (Round(R.Args[Idx].X) = BLX + 2), R.Text);
    E.MouseUp(ebLeft, BLX + 2, BLY, T + 260);
    E.Tick(T + 2000);
    Check('  ...once', R.Count(cmdToggleFit) = 1, R.Text);
    T := T + 5000;

    { Single click with a double-click in the same zone: waits. }
    P.LoadFromText('[Anywhere]' + LineEnding + 'LeftClick = NextImage' + LineEnding +
      'LeftDouble = Fit' + LineEnding + 'RightClick = Menu' + LineEnding +
      'TiltRight = NextFolder' + LineEnding + 'TiltLeft = PreviousFolder' + LineEnding +
      'X1 = ZoomMode' + LineEnding + 'GestureRight = NextFolder' + LineEnding +
      '[Zone TopLeft]' + LineEnding + 'LeftDouble = None' + LineEnding +
      '[Keys]' + LineEnding + 'Esc = Back' + LineEnding + 'Space = NextImage' + LineEnding +
      'Enter = Fullscreen' + LineEnding + 'D = Diagnostics' + LineEnding);
    E.SetProfile(P);
    R.Clear;
    E.MouseDown(ebLeft, BRX, BRY, T);
    E.MouseUp(ebLeft, BRX, BRY, T + 80);
    Check('click, with a double-click there: waits', not R.Has(cmdNextImage), R.Text);
    E.Tick(T + 300);
    Check('  still waiting at 300 ms', not R.Has(cmdNextImage), R.Text);
    E.Tick(T + 520);
    Check('  runs after the double-click time', R.Count(cmdNextImage) = 1, R.Text);
    T := T + 5000;
    R.Clear;
    E.MouseDown(ebLeft, BRX, BRY, T);
    E.MouseUp(ebLeft, BRX, BRY, T + 80);
    E.MouseDown(ebLeft, BRX, BRY, T + 150);
    E.MouseUp(ebLeft, BRX, BRY, T + 220);
    E.Tick(T + 2000);
    Check('double-click: only the double-click runs',
      R.Has(cmdFitToScreen) and not R.Has(cmdNextImage), R.Text);
    T := T + 5000;
    R.Clear;
    E.MouseMove(TLX, TLY, False, False, T);
    E.MouseDown(ebLeft, TLX, TLY, T);
    E.MouseUp(ebLeft, TLX, TLY, T + 80);
    Check('no double-click in that zone: the click runs at once', R.Count(cmdNextImage) = 1, R.Text);
    T := T + 5000;
    R.Clear;
    E.MouseDown(ebLeft, TLX, TLY, T);
    E.MouseMove(TLX + 30, TLY + 10, True, False, T + 20);
    E.MouseUp(ebLeft, TLX + 30, TLY + 10, T + 40);
    Check('drag: pan, no click', R.Has(cmdPanBy) and not R.Has(cmdNextImage), R.Text);
    Idx := R.IndexOf(cmdDragStart);
    Check('  drag start reported where the button went down (for a selection)',
      (Idx >= 0) and (Round(R.Args[Idx].X) = TLX) and (Round(R.Args[Idx].Y) = TLY), R.Text);
    Idx := R.IndexOf(cmdDragPoint);
    Check('  and where the drag is', (Idx >= 0) and (Round(R.Args[Idx].X) = TLX + 30), R.Text);

    { Right: menu, gestures. }
    T := T + 5000;
    R.Clear;
    E.MouseMove(BLX, BLY, False, False, T);
    E.MouseDown(ebRight, BLX, BLY, T);
    E.MouseUp(ebRight, BLX, BLY, T + 60);
    Idx := R.IndexOf(cmdShowMenu);
    Check('right click: the menu, where the mouse is',
      (Idx >= 0) and (Round(R.Args[Idx].X) = BLX), R.Text);
    R.Clear;
    E.MouseDown(ebRight, 300, 700, T + 1000);
    E.MouseMove(360, 704, False, True, T + 1050);
    Idx := R.IndexOf(cmdGesturePreview);
    Check('gesture to the right: shown while it is made',
      (Idx >= 0) and (Round(R.Args[Idx].Value) = Ord(meGestureRight) + 1), R.Text);
    E.MouseUp(ebRight, 360, 704, T + 1100);
    Check('  on release: next folder, no menu',
      R.Has(cmdNextDirectory) and not R.Has(cmdShowMenu), R.Text);
    Idx := -1;
    for I := 0 to High(R.Commands) do
      if R.Commands[I] = cmdGesturePreview then
        Idx := I;
    Check('  and the preview is cleared', (Idx >= 0) and (Round(R.Args[Idx].Value) = 0), R.Text);
    R.Clear;
    E.MouseDown(ebRight, 300, 700, T + 2000);
    E.MouseMove(350, 650, False, True, T + 2050);
    E.MouseUp(ebRight, 350, 650, T + 2100);
    Check('diagonal stroke: nothing (no menu either)',
      not R.Has(cmdNextDirectory) and not R.Has(cmdShowMenu), R.Text);

    { Tilt: one folder per tilt. }
    T := T + 5000;
    R.Clear;
    E.WheelHorz(120, BLX, BLY, T);
    E.WheelHorz(120, BLX, BLY, T + 50);
    E.WheelHorz(120, BLX, BLY, T + 100);
    Check('tilt right, held: one next folder', R.Count(cmdNextDirectory) = 1, R.Text);
    E.WheelHorz(-120, BLX, BLY, T + 600);
    Check('  after a pause, tilt left: previous folder', R.Has(cmdPreviousDirectory), R.Text);
    R.Clear;
    E.WheelHorz(120, BLX, BLY, T + 650);
    Check('  tilt right again at once (other way): next folder', R.Count(cmdNextDirectory) = 1, R.Text);

    { Modes and Back. }
    R.Clear;
    E.MouseDown(ebX1, TLX, TLY, T + 1000);
    Idx := R.IndexOf(cmdInputMode);
    Check('X1: zoom mode on', (Idx >= 0) and (Round(R.Args[Idx].Value) = Ord(imZoom)), R.Text);
    R.Clear;
    E.Wheel(-120, TLX, TLY, T + 1100);
    Check('  the wheel zooms everywhere', R.Has(cmdZoomAt) and not R.Has(cmdRotateBy), R.Text);
    Check('  ...at the mouse (zoom mode), not at the middle',
      R.Has(cmdZoomAt) and (Round(R.Args[R.IndexOf(cmdZoomAt)].X) = TLX), R.Text);
    R.Clear;
    E.KeyDown(VKEY_BROWSER_BACK, False, T + 1200);
    Check('  a Browser Back key right after X1 is its echo: ignored', not R.Has(cmdInputMode), R.Text);
    E.KeyDown(VKEY_ESCAPE, False, T + 3000);
    Idx := R.IndexOf(cmdInputMode);
    Check('Esc (Back): leaves the mode', (Idx >= 0) and (Round(R.Args[Idx].Value) = Ord(imBrowse))
      and not R.Has(cmdExit), R.Text);
    R.Clear;
    E.KeyDown(VKEY_ESCAPE, False, T + 3100);
    Check('Esc again: Back for TMView (edit mode off, else the settings editor)',
      R.Has(cmdBack) and not R.Has(cmdExit), R.Text);

    { Keys. }
    R.Clear;
    E.KeyDown(VKEY_DOWN, False, T);
    Check('arrow down: next image', R.Has(cmdNextImage) and (R.Count(cmdNextImage) = 1), R.Text);
    R.Clear;
    E.KeyDown(VKEY_UP, False, T);
    Check('arrow up: previous image', R.Has(cmdPreviousImage), R.Text);
    R.Clear;
    E.KeyDown(VKEY_RIGHT, False, T);
    Check('arrow right: next folder', R.Has(cmdNextDirectory) and not R.Has(cmdNextImage), R.Text);
    R.Clear;
    E.KeyDown(VKEY_LEFT, False, T);
    Check('arrow left: previous folder', R.Has(cmdPreviousDirectory), R.Text);
    R.Clear;
    Check('Ctrl+V: paste', E.KeyDown(VKEY_V, True, T) and R.Has(cmdPaste), R.Text);
    R.Clear;
    E.KeyDown(VKEY_SPACE, False, T);
    E.KeyDown(VKEY_RETURN, False, T);
    E.KeyDown(VKEY_D, False, T);
    Check('Space, Enter, D from [Keys]',
      R.Has(cmdNextImage) and R.Has(cmdToggleFullscreen) and R.Has(cmdToggleDiagnostics), R.Text);
    Check('other keys are not used', not E.KeyDown(Ord('Q'), False, T));

    { Focus lost: a waiting click is dropped. }
    T := T + 5000;
    R.Clear;
    E.MouseDown(ebLeft, BRX, BRY, T);
    E.MouseUp(ebLeft, BRX, BRY, T + 50);
    E.FocusLost;
    for I := 1 to 3 do
      E.Tick(T + 1000 * QWord(I));
    Check('focus lost: the waiting click is dropped', not R.Has(cmdNextImage), R.Text);
  finally
    P.Free;
    E.Free;
    R.Free;
  end;
end;

{ ---- the Hamana homage profile (mouse\Hamana.mouse) ---- }

procedure TestHamanaProfile;
const
  W = 1000;
  H = 800;
var
  P: TMouseProfile;
  E: TMouseEngine;
  R: TRecorder;
  FileName: string;
  T: QWord;
begin
  WriteLn;
  WriteLn('-- Hamana profile --');
  FileName := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim
    + 'mouse' + PathDelim + 'Hamana.mouse');
  if not FileExists(FileName) then
  begin
    Check('mouse\Hamana.mouse found', False, FileName);
    Exit;
  end;
  P := TMouseProfile.Create;
  R := TRecorder.Create;
  E := TMouseEngine.Create(nil);
  try
    P.LoadFromFile(FileName);
    Check('Hamana.mouse: no errors', P.Errors.Count = 0, P.Errors.Text);
    Check('top right: wheel steps images by name',
      SameActions(P.ActionsFor(mzTopRight, meWheelDown), [maNextImage])
      and SameActions(P.ActionsFor(mzTopRight, meWheelUp), [maPreviousImage])
      and (P.ZoneOrder(mzTopRight) = zoName));
    Check('bottom left: wheel steps images by date',
      SameActions(P.ActionsFor(mzBottomLeft, meWheelDown), [maNextImage])
      and (P.ZoneOrder(mzBottomLeft) = zoDate));
    Check('elsewhere the wheel zooms (down = in, up = out)',
      SameActions(P.ActionsFor(mzBottomRight, meWheelDown), [maZoomIn])
      and SameActions(P.ActionsFor(mzTopLeft, meWheelUp), [maZoomOut]));
    Check('gestures as in Hamana: folders, parent, exit',
      SameActions(P.ActionsFor(mzBottomLeft, meGestureLeft), [maPreviousFolder])
      and SameActions(P.ActionsFor(mzBottomLeft, meGestureRight), [maNextFolder])
      and SameActions(P.ActionsFor(mzBottomLeft, meGestureUp), [maParentFolder])
      and SameActions(P.ActionsFor(mzBottomLeft, meGestureDown), [maExit]));
    Check('right click = original size, X2 = menu, X1 = zoom mode',
      SameActions(P.ActionsFor(mzTopRight, meRightClick), [maOriginalSize])
      and (Length(P.ActionsFor(mzTopRight, meRightDouble)) = 0)
      and SameActions(P.ActionsFor(mzTopRight, meX2), [maMenu])
      and SameActions(P.ActionsFor(mzTopRight, meX1), [maZoomMode]));
    Check('top left: click = edit mode on, double-click = off',
      SameActions(P.ActionsFor(mzTopLeft, meLeftClick), [maEditOn])
      and SameActions(P.ActionsFor(mzTopLeft, meLeftDouble), [maEditOff]));
    Check('wheel click and Enter = fullscreen, Space = next image',
      SameActions(P.ActionsFor(mzTopLeft, meWheelClick), [maFullscreen])
      and SameActions(P.ActionsFor(mzTopLeft, meKeyEnter), [maFullscreen])
      and SameActions(P.ActionsFor(mzTopLeft, meKeySpace), [maNextImage]));

    { The engine with this profile. }
    E.OnCommand := @R.Handle;
    E.SetViewSize(W, H);
    E.DoubleClickMs := 500;
    E.SetProfile(P);
    T := 10000;
    E.MouseMove(900, 100, False, False, T);
    R.Clear;
    E.Wheel(-120, 900, 100, T);
    Check('engine, top right: sort by name, then next image',
      (R.IndexOf(cmdSortByName) >= 0) and (R.IndexOf(cmdNextImage) > R.IndexOf(cmdSortByName)),
      R.Text);
    E.MouseMove(900, 700, False, False, T);
    R.Clear;
    E.Wheel(-120, 900, 700, T);
    Check('engine, bottom right: zoom in (towards you), no image step',
      R.Has(cmdZoomAt) and (R.Args[R.IndexOf(cmdZoomAt)].Value > 0)
      and not R.Has(cmdNextImage), R.Text);
    T := T + 5000;
    R.Clear;
    E.MouseDown(ebRight, 900, 700, T);
    E.MouseUp(ebRight, 900, 700, T + 60);
    Check('engine: right click = original size at once (no double-click wait)',
      R.Has(cmdOriginalSizeAt), R.Text);
    T := T + 5000;
    R.Clear;
    E.MouseDown(ebX2, 900, 700, T);
    E.MouseUp(ebX2, 900, 700, T + 60);
    Check('engine: X2 = the menu', R.Has(cmdShowMenu), R.Text);
  finally
    E.Free;
    R.Free;
    P.Free;
  end;
end;

begin
  PassCount := 0;
  FailCount := 0;
  WriteLn('MView mouse language test');
  WriteLn('=========================');
  TestProfile;
  TestZones;
  TestEngine;
  TestHamanaProfile;
  WriteLn;
  WriteLn('=========================');
  WriteLn(PassCount, ' passed, ', FailCount, ' failed');
  if FailCount > 0 then
    ExitCode := 1;
end.
