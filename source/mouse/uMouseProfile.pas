unit uMouseProfile;

{
  Unit: uMouseProfile

  Purpose
  -------
  The mouse language (spec §9.2, Phase F): which button does what,
  depending on where the mouse is. Read from and written to a small
  text file (Default.mouse, next to MView.ini).

  Owns
  ----
  - TMouseProfile: the four zone setups (name, order, binding table),
    the [Anywhere] table (which also holds the [Keys] entries) and
    the Errors list (TStringList) of the last load.
  - The built-in profile text (DefaultProfileText) and the name and
    caption tables for zones, events, commands and orders.

  Knows
  -----
  - Nothing else. The file name comes from the caller (TMView,
    uMousePage).

  Responsibilities
  ----------------
  - Parse a profile (file, text or string list); lines it does not
    understand are skipped and listed in Errors ("line 12: unknown
    command 'Foo'"). A UTF-8 byte order mark on line 1 is skipped.
  - Write a profile back (SaveToStrings / SaveToFile), and copy one
    (Assign).
  - Answer what an event does in a zone (ActionsFor: the zone's own
    entry, or the Anywhere one; maNone left out), or with the zones
    switched off (AnywhereActionsFor).
  - Get and set single bindings, zone names and zone orders (for the
    settings editor).
  - Name every zone, event and command, as written in the file and as
    shown to the user, and parse those names back.
  - Find the zone of a point (ZoneAt), keeping the previous zone
    inside a dead band along the middle lines (ZoneDeadBandPercent,
    3 %) so the zone doesn't flicker there.

  Does NOT
  --------
  - Read the mouse, or carry out commands (uMouseEngine, TMView).
  - Use the LCL: this unit is tested by test\TestMouse.lpr with plain
    fpc.
  - Keep comments of a file it loaded: saving writes the profile anew.

  Threads
  -------
  UI thread only (TMView, the mouse engines, the settings page). No
  locking.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      Classes, SysUtils

  Used by
  -------
  uMView, uMouseEngine, uMousePage

  File format
  -----------
  The screen has four zones (the quarters). Each zone has a name (shown
  on screen when the mouse enters it, while the diagnostics line D is
  on), an optional browsing order
  (Date / Name: navigation from that zone uses that order), and its own
  table "event -> commands". A table [Anywhere] holds what a zone
  doesn't set itself. [Keys] holds the three programmable keys (Esc
  is fixed).

    [Anywhere]
    RightClick   = Menu
    GestureDown  = Exit

    [Zone BottomLeft]
    Name      = Browse by date
    Order     = Date
    WheelDown = NextImage
    WheelUp   = PreviousImage

    [Keys]
    Space = NextImage

  One event can run up to three commands in a row, separated by
  commas ("WheelDown = SortByName, NextImage"). In a zone, "None"
  switches an event off there (instead of using the Anywhere entry).
  Names are not case sensitive; ; and # start a comment.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils;

type

  TMouseZone = (mzTopLeft, mzTopRight, mzBottomLeft, mzBottomRight);

  TMouseEvent = (
    meLeftClick, meLeftDouble, meRightClick, meRightDouble,
    meWheelUp, meWheelDown, meWheelClick, meTiltLeft, meTiltRight,
    meX1, meX2,
    meGestureLeft, meGestureRight, meGestureUp, meGestureDown,
    meKeySpace, meKeyEsc, meKeyEnter, meKeyD
  );

  TMouseAction = (
    maNone,
    maNextImage, maPreviousImage, maNextFolder, maPreviousFolder, maParentFolder,
    maZoomIn, maZoomOut, maFit, maOriginalSize, maFitOr100,
    maRotateLeft, maRotateRight, maTurnLeft, maTurnRight,
    maSortByDate, maSortByName, maToggleSort,
    maZoomMode, maRotateMode,
    maFullscreen, maInfo, maDiagnostics, maMenu,
    maPaste, maSaveImage, maEditMode, maEditOn, maEditOff, maCrop, maRescan,
    maBack, maExit
  );

  TZoneOrder = (zoNone, zoDate, zoName);

  { Up to MaxActionsPerEvent commands. nil = not set (a zone then uses
    the Anywhere entry); [maNone] = switched off. }
  TActionList = array of TMouseAction;

  TBindingTable = array[TMouseEvent] of TActionList;

  TZoneSetup = record
    Title: string;
    Order: TZoneOrder;
    Bindings: TBindingTable;
  end;

  { TMouseProfile }

  TMouseProfile = class(TObject)
  private
    FZones: array[TMouseZone] of TZoneSetup;
    FAnywhere: TBindingTable;
    FErrors: TStringList;
    procedure ParseLine(const ALine: string; ALineNo: Integer; var ASection: string);
  public
    constructor Create;
    destructor Destroy; override;

    { Nothing set, no errors. }
    procedure Clear;
    { The built-in profile (DefaultProfileText). }
    procedure LoadDefaults;
    { Parses the text; lines it doesn't understand are skipped and
      listed in Errors ("line 12: unknown command 'Foo'"). }
    procedure LoadFromStrings(ALines: TStrings);
    procedure LoadFromText(const AText: string);
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToStrings(ALines: TStrings);
    procedure SaveToFile(const AFileName: string);
    procedure Assign(ASource: TMouseProfile);

    { What AEvent does in AZone: the zone's own entry, or the Anywhere
      one. Keys: always the [Keys] entry. maNone is left out, so the
      result may be empty. }
    function ActionsFor(AZone: TMouseZone; AEvent: TMouseEvent): TActionList;
    { The Anywhere entry alone (zones switched off), without None. }
    function AnywhereActionsFor(AEvent: TMouseEvent): TActionList;

    function ZoneBinding(AZone: TMouseZone; AEvent: TMouseEvent): TActionList;
    procedure SetZoneBinding(AZone: TMouseZone; AEvent: TMouseEvent; const AActions: TActionList);
    function AnywhereBinding(AEvent: TMouseEvent): TActionList;
    procedure SetAnywhereBinding(AEvent: TMouseEvent; const AActions: TActionList);
    function ZoneTitle(AZone: TMouseZone): string;
    procedure SetZoneTitle(AZone: TMouseZone; const ATitle: string);
    function ZoneOrder(AZone: TMouseZone): TZoneOrder;
    procedure SetZoneOrder(AZone: TMouseZone; AOrder: TZoneOrder);

    property Errors: TStringList read FErrors;
  end;

const
  MaxActionsPerEvent = 3;

  KeyEvents = [meKeySpace, meKeyEsc, meKeyEnter, meKeyD];
  { Esc is fixed in the engine (Back); an "Esc =" line is ignored. }
  ProgrammableKeys = [meKeySpace, meKeyEnter, meKeyD];
  MouseEvents = [meLeftClick .. meGestureDown];

  { Width of the band along the middle lines in which the zone doesn't
    change (percent of the window's width / height, in all). }
  ZoneDeadBandPercent = 3;

  DefaultProfileText =
    '; MView mouse profile (spec 9.2). Edit it here or on the "Mouse & keys"' + LineEnding +
    '; page of the settings editor. One event can run up to three commands,' + LineEnding +
    '; separated by commas. In a zone, None switches an event off there.' + LineEnding +
    '' + LineEnding +
    '[Anywhere]' + LineEnding +
    'RightClick   = Menu' + LineEnding +
    'WheelClick   = Fullscreen' + LineEnding +
    'LeftDouble   = FitOr100' + LineEnding +
    'TiltLeft     = PreviousFolder' + LineEnding +
    'TiltRight    = NextFolder' + LineEnding +
    'X1           = ZoomMode' + LineEnding +
    'X2           = RotateMode' + LineEnding +
    'GestureLeft  = PreviousFolder' + LineEnding +
    'GestureRight = NextFolder' + LineEnding +
    'GestureUp    = ParentFolder' + LineEnding +
    'GestureDown  = Exit' + LineEnding +
    'WheelDown    = NextImage' + LineEnding +
    'WheelUp      = PreviousImage' + LineEnding +
    '' + LineEnding +
    '[Zone TopLeft]' + LineEnding +
    'Name       = Edit' + LineEnding +
    'Order      = None' + LineEnding +
    'LeftClick  = EditModeOn' + LineEnding +
    'LeftDouble = EditModeOff' + LineEnding +
    'WheelUp    = TurnRight' + LineEnding +
    'WheelDown  = TurnLeft' + LineEnding +
    '' + LineEnding +
    '[Zone TopRight]' + LineEnding +
    'Name       = Browse by name' + LineEnding +
    'Order      = Name' + LineEnding +
    '' + LineEnding +
    '[Zone BottomLeft]' + LineEnding +
    'Name       = Browse by date' + LineEnding +
    'Order      = Date' + LineEnding +
    '' + LineEnding +
    '[Zone BottomRight]' + LineEnding +
    'Name       = Inspect' + LineEnding +
    'Order      = None' + LineEnding +
    'WheelDown  = ZoomIn' + LineEnding +
    'WheelUp    = ZoomOut' + LineEnding +
    'LeftDouble = FitOr100' + LineEnding +
    '' + LineEnding +
    '[Keys]' + LineEnding +
    'Space = NextImage' + LineEnding +
    'Enter = Fullscreen' + LineEnding +
    'D     = Diagnostics' + LineEnding;

{ Names as written in the file. }
function MouseZoneName(AZone: TMouseZone): string;
function MouseEventName(AEvent: TMouseEvent): string;
function MouseActionName(AAction: TMouseAction): string;
function ZoneOrderName(AOrder: TZoneOrder): string;

{ Names as shown to the user. }
function MouseZoneCaption(AZone: TMouseZone): string;
function MouseEventCaption(AEvent: TMouseEvent): string;
function MouseActionCaption(AAction: TMouseAction): string;
{ "Next image, Original size" }
function ActionListCaption(const AActions: TActionList): string;

function ParseMouseZone(const AText: string; out AZone: TMouseZone): Boolean;
function ParseMouseEvent(const AText: string; out AEvent: TMouseEvent): Boolean;
function ParseMouseAction(const AText: string; out AAction: TMouseAction): Boolean;
function ParseZoneOrder(const AText: string; out AOrder: TZoneOrder): Boolean;

{ The zone of point AX, AY in a AWidth x AHeight window. Along the
  middle lines (ZoneDeadBandPercent) the side of APrevious is kept, if
  AHavePrevious, so the zone doesn't flicker there. }
function ZoneAt(AX, AY, AWidth, AHeight: Integer; APrevious: TMouseZone;
  AHavePrevious: Boolean): TMouseZone;

function IsLeftZone(AZone: TMouseZone): Boolean;
function IsTopZone(AZone: TMouseZone): Boolean;

implementation

const
  ZoneNames: array[TMouseZone] of string = (
    'TopLeft', 'TopRight', 'BottomLeft', 'BottomRight');
  ZoneCaptions: array[TMouseZone] of string = (
    'Top left', 'Top right', 'Bottom left', 'Bottom right');

  EventNames: array[TMouseEvent] of string = (
    'LeftClick', 'LeftDouble', 'RightClick', 'RightDouble',
    'WheelUp', 'WheelDown', 'WheelClick', 'TiltLeft', 'TiltRight',
    'X1', 'X2',
    'GestureLeft', 'GestureRight', 'GestureUp', 'GestureDown',
    'Space', 'Esc', 'Enter', 'D');
  EventCaptions: array[TMouseEvent] of string = (
    'Left click', 'Left double-click', 'Right click', 'Right double-click',
    'Wheel up (away)', 'Wheel down (towards you)', 'Wheel click', 'Tilt left', 'Tilt right',
    'X1 (rear side button)', 'X2 (front side button)',
    'Gesture left', 'Gesture right', 'Gesture up', 'Gesture down',
    'Space', 'Esc', 'Enter', 'D');

  ActionNames: array[TMouseAction] of string = (
    'None',
    'NextImage', 'PreviousImage', 'NextFolder', 'PreviousFolder', 'ParentFolder',
    'ZoomIn', 'ZoomOut', 'Fit', 'OriginalSize', 'FitOr100',
    'RotateLeft', 'RotateRight', 'TurnLeft', 'TurnRight',
    'SortByDate', 'SortByName', 'ToggleSort',
    'ZoomMode', 'RotateMode',
    'Fullscreen', 'Info', 'Diagnostics', 'Menu',
    'Paste', 'SaveImage', 'EditMode', 'EditModeOn', 'EditModeOff', 'CropSelection', 'Rescan',
    'Back', 'Exit');
  ActionCaptions: array[TMouseAction] of string = (
    '(nothing)',
    'Next image', 'Previous image', 'Next folder', 'Previous folder', 'Parent folder',
    'Zoom in (at the mouse)', 'Zoom out (at the mouse)', 'Fit to window',
    'Original size (100 %)', 'Fit <-> 100 % (at the mouse)',
    'Rotate left 90°', 'Rotate right 90°', 'Turn left 5° (per wheel notch)',
    'Turn right 5° (per wheel notch)',
    'Sort by date', 'Sort by name', 'Sort: date <-> name',
    'Zoom mode on / off', 'Rotate mode on / off',
    'Fullscreen on / off', 'Info line on / off', 'Diagnostics line on / off', 'Menu',
    'Paste image from the clipboard', 'Save image', 'Edit mode on / off', 'Edit mode on',
    'Edit mode off', 'Crop the selection', 'Read the folders again',
    'Back (leave a mode, else the settings screen)', 'Exit');

  OrderNames: array[TZoneOrder] of string = ('None', 'Date', 'Name');

function MouseZoneName(AZone: TMouseZone): string;
begin
  Result := ZoneNames[AZone];
end;

function MouseEventName(AEvent: TMouseEvent): string;
begin
  Result := EventNames[AEvent];
end;

function MouseActionName(AAction: TMouseAction): string;
begin
  Result := ActionNames[AAction];
end;

function ZoneOrderName(AOrder: TZoneOrder): string;
begin
  Result := OrderNames[AOrder];
end;

function MouseZoneCaption(AZone: TMouseZone): string;
begin
  Result := ZoneCaptions[AZone];
end;

function MouseEventCaption(AEvent: TMouseEvent): string;
begin
  Result := EventCaptions[AEvent];
end;

function MouseActionCaption(AAction: TMouseAction): string;
begin
  Result := ActionCaptions[AAction];
end;

function ActionListCaption(const AActions: TActionList): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AActions) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ActionCaptions[AActions[I]];
  end;
  if Result = '' then
    Result := ActionCaptions[maNone];
end;

function ParseMouseZone(const AText: string; out AZone: TMouseZone): Boolean;
var
  Z: TMouseZone;
begin
  for Z := Low(TMouseZone) to High(TMouseZone) do
    if SameText(Trim(AText), ZoneNames[Z]) then
    begin
      AZone := Z;
      Exit(True);
    end;
  AZone := mzBottomLeft;
  Result := False;
end;

function ParseMouseEvent(const AText: string; out AEvent: TMouseEvent): Boolean;
var
  E: TMouseEvent;
begin
  for E := Low(TMouseEvent) to High(TMouseEvent) do
    if SameText(Trim(AText), EventNames[E]) then
    begin
      AEvent := E;
      Exit(True);
    end;
  AEvent := meLeftClick;
  Result := False;
end;

function ParseMouseAction(const AText: string; out AAction: TMouseAction): Boolean;
var
  A: TMouseAction;
begin
  for A := Low(TMouseAction) to High(TMouseAction) do
    if SameText(Trim(AText), ActionNames[A]) then
    begin
      AAction := A;
      Exit(True);
    end;
  AAction := maNone;
  Result := False;
end;

function ParseZoneOrder(const AText: string; out AOrder: TZoneOrder): Boolean;
var
  O: TZoneOrder;
begin
  if Trim(AText) = '' then
  begin
    AOrder := zoNone;
    Exit(True);
  end;
  for O := Low(TZoneOrder) to High(TZoneOrder) do
    if SameText(Trim(AText), OrderNames[O]) then
    begin
      AOrder := O;
      Exit(True);
    end;
  AOrder := zoNone;
  Result := False;
end;

function IsLeftZone(AZone: TMouseZone): Boolean;
begin
  Result := AZone in [mzTopLeft, mzBottomLeft];
end;

function IsTopZone(AZone: TMouseZone): Boolean;
begin
  Result := AZone in [mzTopLeft, mzTopRight];
end;

function ZoneAt(AX, AY, AWidth, AHeight: Integer; APrevious: TMouseZone;
  AHavePrevious: Boolean): TMouseZone;
var
  Left, Top: Boolean;
  HalfBandX, HalfBandY: Double;
begin
  HalfBandX := AWidth * ZoneDeadBandPercent / 200.0;
  HalfBandY := AHeight * ZoneDeadBandPercent / 200.0;

  if AHavePrevious and (Abs(AX - AWidth / 2.0) < HalfBandX) then
    Left := IsLeftZone(APrevious)
  else
    Left := AX < AWidth / 2.0;

  if AHavePrevious and (Abs(AY - AHeight / 2.0) < HalfBandY) then
    Top := IsTopZone(APrevious)
  else
    Top := AY < AHeight / 2.0;

  if Top then
  begin
    if Left then
      Result := mzTopLeft
    else
      Result := mzTopRight;
  end
  else if Left then
    Result := mzBottomLeft
  else
    Result := mzBottomRight;
end;

{ TMouseProfile }

constructor TMouseProfile.Create;
begin
  inherited Create;
  FErrors := TStringList.Create;
  Clear;
end;

destructor TMouseProfile.Destroy;
begin
  FErrors.Free;
  inherited Destroy;
end;

procedure TMouseProfile.Clear;
var
  Z: TMouseZone;
  E: TMouseEvent;
begin
  for Z := Low(TMouseZone) to High(TMouseZone) do
  begin
    FZones[Z].Title := ZoneCaptions[Z];
    FZones[Z].Order := zoNone;
    for E := Low(TMouseEvent) to High(TMouseEvent) do
      FZones[Z].Bindings[E] := nil;
  end;
  for E := Low(TMouseEvent) to High(TMouseEvent) do
    FAnywhere[E] := nil;
  FErrors.Clear;
end;

procedure TMouseProfile.LoadDefaults;
begin
  LoadFromText(DefaultProfileText);
end;

procedure TMouseProfile.LoadFromText(const AText: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    LoadFromStrings(Lines);
  finally
    Lines.Free;
  end;
end;

procedure TMouseProfile.LoadFromFile(const AFileName: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    LoadFromStrings(Lines);
  finally
    Lines.Free;
  end;
end;

procedure TMouseProfile.LoadFromStrings(ALines: TStrings);
var
  I: Integer;
  Section: string;
begin
  Clear;
  Section := '';
  for I := 0 to ALines.Count - 1 do
    ParseLine(ALines[I], I + 1, Section);
end;

{ ASection: the current section as written, e.g. 'Anywhere', 'Keys',
  'Zone BottomLeft'; '?' after an unknown one (its lines are skipped). }
procedure TMouseProfile.ParseLine(const ALine: string; ALineNo: Integer; var ASection: string);
var
  S, Key, Value, Part, Rest: string;
  P, Count: Integer;
  Zone: TMouseZone;
  IsZone: Boolean;
  Event: TMouseEvent;
  Action: TMouseAction;
  Order: TZoneOrder;
  Actions: TActionList;

  procedure Error(const AMessage: string);
  begin
    FErrors.Add(Format('line %d: %s', [ALineNo, AMessage]));
  end;

begin
  S := ALine;
  { A UTF-8 byte order mark (an editor may add one). }
  if (ALineNo = 1) and (Copy(S, 1, 3) = #$EF#$BB#$BF) then
    Delete(S, 1, 3);
  { Comments: ; or # at the start of the line, or after a blank (so a
    zone may be called "C# files"). }
  for P := 1 to Length(S) do
    if (S[P] in [';', '#']) and ((Trim(Copy(S, 1, P - 1)) = '') or (S[P - 1] in [' ', #9])) then
    begin
      S := Copy(S, 1, P - 1);
      Break;
    end;
  S := Trim(S);
  if S = '' then
    Exit;

  if S[1] = '[' then
  begin
    P := Pos(']', S);
    if P = 0 then
    begin
      Error('section without ]');
      ASection := '?';
      Exit;
    end;
    ASection := Trim(Copy(S, 2, P - 2));
    if SameText(ASection, 'Anywhere') or SameText(ASection, 'Keys') then
      Exit;
    if SameText(Copy(ASection, 1, 5), 'Zone ')
      and ParseMouseZone(Copy(ASection, 6, MaxInt), Zone) then
      Exit;
    Error('unknown section [' + ASection + ']');
    ASection := '?';
    Exit;
  end;

  if ASection = '?' then
    Exit;
  if ASection = '' then
  begin
    Error('entry before any section: ' + S);
    Exit;
  end;

  P := Pos('=', S);
  if P <= 1 then
  begin
    Error('expected Event = Command: ' + S);
    Exit;
  end;
  Key := Trim(Copy(S, 1, P - 1));
  Value := Trim(Copy(S, P + 1, MaxInt));

  IsZone := SameText(Copy(ASection, 1, 5), 'Zone ');
  Zone := mzBottomLeft;
  if IsZone then
    ParseMouseZone(Copy(ASection, 6, MaxInt), Zone);

  if IsZone and SameText(Key, 'Name') then
  begin
    FZones[Zone].Title := Value;
    Exit;
  end;
  if IsZone and SameText(Key, 'Order') then
  begin
    if ParseZoneOrder(Value, Order) then
      FZones[Zone].Order := Order
    else
      Error('Order must be Date, Name or None: ' + Value);
    Exit;
  end;

  if not ParseMouseEvent(Key, Event) then
  begin
    Error('unknown event ''' + Key + '''');
    Exit;
  end;
  { Esc is fixed (Back): older files have it, not an error. }
  if Event = meKeyEsc then
    Exit;
  if SameText(ASection, 'Keys') <> (Event in KeyEvents) then
  begin
    if Event in KeyEvents then
      Error('the key ' + Key + ' belongs in [Keys]')
    else
      Error(Key + ' is a mouse event: not in [Keys]');
    Exit;
  end;

  { The commands, comma separated. }
  Actions := nil;
  Count := 0;
  Rest := Value;
  while Rest <> '' do
  begin
    P := Pos(',', Rest);
    if P > 0 then
    begin
      Part := Trim(Copy(Rest, 1, P - 1));
      Rest := Trim(Copy(Rest, P + 1, MaxInt));
    end
    else
    begin
      Part := Trim(Rest);
      Rest := '';
    end;
    if Part = '' then
      Continue;
    if not ParseMouseAction(Part, Action) then
    begin
      Error('unknown command ''' + Part + '''');
      Continue;
    end;
    if Count >= MaxActionsPerEvent then
    begin
      Error(Format('more than %d commands for %s: the rest is ignored', [MaxActionsPerEvent, Key]));
      Break;
    end;
    SetLength(Actions, Count + 1);
    Actions[Count] := Action;
    Inc(Count);
  end;
  { "Event =" with nothing: switched off, like None. }
  if Count = 0 then
  begin
    SetLength(Actions, 1);
    Actions[0] := maNone;
  end;

  if IsZone then
    FZones[Zone].Bindings[Event] := Actions
  else
    FAnywhere[Event] := Actions;
end;

procedure TMouseProfile.SaveToStrings(ALines: TStrings);

  function ListText(const AActions: TActionList): string;
  var
    I: Integer;
  begin
    Result := '';
    for I := 0 to High(AActions) do
    begin
      if I > 0 then
        Result := Result + ', ';
      Result := Result + ActionNames[AActions[I]];
    end;
  end;

var
  Z: TMouseZone;
  E: TMouseEvent;
begin
  ALines.Clear;
  ALines.Add('; MView mouse profile (spec 9.2), written by the settings editor.');
  ALines.Add('; One event can run up to three commands, separated by commas.');
  ALines.Add('; In a zone, None switches an event off there.');
  ALines.Add('');
  ALines.Add('[Anywhere]');
  for E := Low(TMouseEvent) to High(TMouseEvent) do
    if (E in MouseEvents) and (Length(FAnywhere[E]) > 0) then
      ALines.Add(EventNames[E] + ' = ' + ListText(FAnywhere[E]));
  for Z := Low(TMouseZone) to High(TMouseZone) do
  begin
    ALines.Add('');
    ALines.Add('[Zone ' + ZoneNames[Z] + ']');
    ALines.Add('Name = ' + FZones[Z].Title);
    ALines.Add('Order = ' + OrderNames[FZones[Z].Order]);
    for E := Low(TMouseEvent) to High(TMouseEvent) do
      if (E in MouseEvents) and (Length(FZones[Z].Bindings[E]) > 0) then
        ALines.Add(EventNames[E] + ' = ' + ListText(FZones[Z].Bindings[E]));
  end;
  ALines.Add('');
  ALines.Add('[Keys]');
  for E := Low(TMouseEvent) to High(TMouseEvent) do
    if (E in ProgrammableKeys) and (Length(FAnywhere[E]) > 0) then
      ALines.Add(EventNames[E] + ' = ' + ListText(FAnywhere[E]));
end;

procedure TMouseProfile.SaveToFile(const AFileName: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    SaveToStrings(Lines);
    Lines.SaveToFile(AFileName);
  finally
    Lines.Free;
  end;
end;

procedure TMouseProfile.Assign(ASource: TMouseProfile);
var
  Z: TMouseZone;
  E: TMouseEvent;
begin
  for Z := Low(TMouseZone) to High(TMouseZone) do
  begin
    FZones[Z].Title := ASource.FZones[Z].Title;
    FZones[Z].Order := ASource.FZones[Z].Order;
    for E := Low(TMouseEvent) to High(TMouseEvent) do
      FZones[Z].Bindings[E] := Copy(ASource.FZones[Z].Bindings[E], 0, Length(ASource.FZones[Z].Bindings[E]));
  end;
  for E := Low(TMouseEvent) to High(TMouseEvent) do
    FAnywhere[E] := Copy(ASource.FAnywhere[E], 0, Length(ASource.FAnywhere[E]));
  FErrors.Assign(ASource.FErrors);
end;

function TMouseProfile.ActionsFor(AZone: TMouseZone; AEvent: TMouseEvent): TActionList;
var
  Source: TActionList;
  I, N: Integer;
begin
  if (AEvent in MouseEvents) and (Length(FZones[AZone].Bindings[AEvent]) > 0) then
    Source := FZones[AZone].Bindings[AEvent]
  else
    Source := FAnywhere[AEvent];
  Result := nil;
  N := 0;
  for I := 0 to High(Source) do
    if Source[I] <> maNone then
    begin
      SetLength(Result, N + 1);
      Result[N] := Source[I];
      Inc(N);
    end;
end;

function TMouseProfile.AnywhereActionsFor(AEvent: TMouseEvent): TActionList;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(FAnywhere[AEvent]) do
    if FAnywhere[AEvent][I] <> maNone then
    begin
      SetLength(Result, N + 1);
      Result[N] := FAnywhere[AEvent][I];
      Inc(N);
    end;
end;

function TMouseProfile.ZoneBinding(AZone: TMouseZone; AEvent: TMouseEvent): TActionList;
begin
  Result := Copy(FZones[AZone].Bindings[AEvent], 0, Length(FZones[AZone].Bindings[AEvent]));
end;

procedure TMouseProfile.SetZoneBinding(AZone: TMouseZone; AEvent: TMouseEvent;
  const AActions: TActionList);
begin
  FZones[AZone].Bindings[AEvent] := Copy(AActions, 0, Length(AActions));
end;

function TMouseProfile.AnywhereBinding(AEvent: TMouseEvent): TActionList;
begin
  Result := Copy(FAnywhere[AEvent], 0, Length(FAnywhere[AEvent]));
end;

procedure TMouseProfile.SetAnywhereBinding(AEvent: TMouseEvent; const AActions: TActionList);
begin
  FAnywhere[AEvent] := Copy(AActions, 0, Length(AActions));
end;

function TMouseProfile.ZoneTitle(AZone: TMouseZone): string;
begin
  Result := FZones[AZone].Title;
end;

procedure TMouseProfile.SetZoneTitle(AZone: TMouseZone; const ATitle: string);
begin
  FZones[AZone].Title := ATitle;
end;

function TMouseProfile.ZoneOrder(AZone: TMouseZone): TZoneOrder;
begin
  Result := FZones[AZone].Order;
end;

procedure TMouseProfile.SetZoneOrder(AZone: TMouseZone; AOrder: TZoneOrder);
begin
  FZones[AZone].Order := AOrder;
end;

end.
