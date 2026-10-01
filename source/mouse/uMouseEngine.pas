unit uMouseEngine;

{
  Unit: uMouseEngine

  Purpose
  -------
  The mouse language (spec §9.2, Phase F): turns raw mouse and key
  input into commands, following the mouse profile (uMouseProfile):
  which zone of the screen the mouse is in, and what each button does
  there. Replaces the fixed controls of uInputHandler.

  Both drawing surfaces (CPU and GPU) pass their raw input here; the
  engine emits TCommand values (spec §9.1) through OnCommand.

  Owns
  ----
  - FProfile: its own copy of the mouse profile (TMouseProfile),
    loaded with the built-in defaults at creation and replaced by
    SetProfile (Assign).
  - The input state: current zone, zoom / rotate mode, button and
    drag state, gesture start and preview, wheel remainder, tilt
    timing, and a click state per button (waiting single click,
    last press for the double-click).

  Knows
  -----
  - The owner object (passed to Create), handed back as Sender with
    every command and fired event.
  - OnCommand (TCommandEvent, uCommands): where the commands go.
  - OnFired: which zone / event / commands were recognised (for the
    settings editor's "Try it here" box, uMousePage).
  - The Windows double-click time (GetDoubleClickTime in user32.dll,
    Windows only; 500 ms if unknown or out of range).

  Responsibilities
  ----------------
  - Track the zone under the mouse and announce a new one
    (cmdShowZone); announce it again when a mouse event in it runs
    something.
  - Tell clicks, double-clicks, drags and gestures apart, and run what
    the profile binds to them; run the fixed controls below.
  - Keep the zoom / rotate mode (cmdInputMode) and give the wheel to
    it while one is on.
  - Before navigation from a zone with an order, emit the sort command
    for that order.
  - Report drags for edit-mode selections (cmdDragStart,
    cmdDragPoint) as well as panning (cmdPanBy), and gesture previews
    (cmdGesturePreview).
  - Keep the time of the last input (LastActivityMs, NoteActivity)
    for cursor hiding.
  - Forget held buttons and waiting clicks when the focus is lost.

  Does NOT
  --------
  - Use the LCL (tested by test\TestMouse.lpr). The surfaces translate
    LCL buttons and pass the time (GetTickCount64), and call Tick
    regularly for clicks that wait for a possible double-click.
  - Carry out commands (TMView) or show the menu (the main form).
  - Read or write the profile file (TMView, uMousePage).

  Threads
  -------
  UI thread only: called from the surfaces' LCL event handlers and
  from a UI timer (Tick). No locking.

  Uses (MView units)
  ------------------
  interface:      uCommands, uMouseProfile
  Libraries:      Classes, SysUtils, Math

  Used by
  -------
  uGLMediaView, uMainForm, uMediaView, uMousePage

  Fixed, not in the profile
  -------------------------
    Left button + drag   pan (in edit mode: select an area)
    Right button + drag  gesture (left / right / up / down, 40 px,
                         main direction 1.5 x the other); a gesture is
                         not a right click
    Arrow keys           next / previous image (down / up),
                         next / previous folder (right / left)
    Ctrl+V               paste an image from the clipboard
    Esc                  a zoom / rotate mode off; else Back (TMView:
                         edit mode off, else the settings editor)
  Programmable (profile): left / right click and double-click, wheel
  up / down / click, tilt left / right, X1, X2, the four gestures, and
  the keys Space, Enter, D.

  Rules
  -----
  - Zones: the quarters of the view, with a narrow band along the
    middle lines where the zone doesn't change (uMouseProfile.ZoneAt).
    The zone is fixed while a button is held (drag, gesture).
  - Click or double-click: a single click runs at once, unless the zone
    also has a double-click for that button; then it waits for the
    double-click time (Windows setting), and runs only if no second
    click came. A second press within that time, near the first, is
    the double-click (on the press, as Windows does).
  - Wheel: one event per notch (high-resolution wheels send parts of a
    notch, collected here). Zoom and turn commands follow the parts
    smoothly instead.
  - Tilt: one event per tilt. Holding the tilt wheel repeats the
    message; it fires again only after a pause (TiltGapMs).
  - X1 / X2 act on the press (LCL 4.6 never reports their release).
    Some mice send them as Browser Back / Forward keys; those count as
    X1 / X2, except right after a real side button (the driver's echo).
  - Navigation from a zone with an order (Date / Name) first switches
    to that order (TMView keeps the current image).
  - ZoomMode / RotateMode are switches: while one is on, the wheel
    zooms / turns everywhere; Back (Esc) or the same switch ends it.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  uCommands,
  uMouseProfile;

type

  TEngineButton = (ebLeft, ebRight, ebMiddle, ebX1, ebX2);

  { An event was recognised: which zone, which event, what it runs
    (possibly nothing). For the settings editor's "Try it here" box. }
  TMouseFiredEvent = procedure(Sender: TObject; AZone: TMouseZone; AEvent: TMouseEvent;
    const AActions: TActionList) of object;

  TClickButton = (cbLeft, cbRight);

  TClickState = record
    Pending: Boolean;          { a single click waiting for a second one }
    DueMs: QWord;
    X, Y: Integer;
    Zone: TMouseZone;
    LastPressMs: QWord;        { press that may start a double-click; 0 = none }
    LastX, LastY: Integer;
    LastZone: TMouseZone;      { ... and its zone: a double-click stays in one zone }
    SecondPress: Boolean;      { this press was a double-click: its release does nothing }
  end;

  { TMouseEngine }

  TMouseEngine = class(TObject)
  private
    FOwner: TObject;
    FProfile: TMouseProfile;   { own copy }
    FOnCommand: TCommandEvent;
    FOnFired: TMouseFiredEvent;
    FWidth, FHeight: Integer;
    FZone: TMouseZone;
    FHaveZone: Boolean;
    FZonesEnabled: Boolean;
    FMode: TInputMode;
    FDoubleClickMs: Integer;
    FLastActivityMs: QWord;
    FMouseX, FMouseY: Integer;
    FWheelAccum: Integer;
    FLastTiltMsgMs: QWord;
    FLastTiltDir: Integer;     { +1 right, -1 left, 0 none }
    FLastSideButtonMs: QWord;

    FLeftDown: Boolean;
    FDragging: Boolean;
    FDownX, FDownY: Integer;
    FLastX, FLastY: Integer;
    FLeftZone: TMouseZone;

    FRightDown: Boolean;
    FGestureMade: Boolean;
    FRightX, FRightY: Integer;
    FRightZone: TMouseZone;
    FGestureShown: Integer;    { Ord(event) + 1 of the preview; 0 = none }

    FClicks: array[TClickButton] of TClickState;

    procedure Emit(ACommand: TCommand; AX: Double = 0; AY: Double = 0; AValue: Double = 0);
    procedure Activity(ANowMs: QWord);
    procedure UpdateZone(AX, AY: Integer);
    procedure SetMode(AMode: TInputMode);
    procedure ApplyZoneOrder(AZone: TMouseZone);
    { What an event does: in AZone, or everywhere the Anywhere entry
      while the zones are switched off. }
    function ActionsFor(AZone: TMouseZone; AEvent: TMouseEvent): TActionList;
    procedure Perform(AAction: TMouseAction; AZone: TMouseZone; AX, AY: Integer; ANotches: Double);
    procedure Fire(AZone: TMouseZone; AEvent: TMouseEvent; AX, AY: Integer; ANotches: Double = 1);
    function HasDouble(AZone: TMouseZone; AButton: TClickButton): Boolean;
    procedure ClickPress(AButton: TClickButton; AZone: TMouseZone; AX, AY: Integer; ANowMs: QWord);
    procedure ClickRelease(AButton: TClickButton; AX, AY: Integer; ANowMs: QWord);
    function GestureEvent(ADX, ADY: Integer; out AEvent: TMouseEvent): Boolean;
    procedure ShowGesture(AValue: Integer);
  public
    constructor Create(AOwner: TObject);
    destructor Destroy; override;

    { Copies AProfile (the engine keeps its own). }
    procedure SetProfile(AProfile: TMouseProfile);
    { The view's size, for the zones. Call before passing an event. }
    procedure SetViewSize(AWidth, AHeight: Integer);

    procedure MouseDown(AButton: TEngineButton; AX, AY: Integer; ANowMs: QWord);
    procedure MouseMove(AX, AY: Integer; ALeftDown, ARightDown: Boolean; ANowMs: QWord);
    procedure MouseUp(AButton: TEngineButton; AX, AY: Integer; ANowMs: QWord);
    { WheelDelta as Windows reports it: 120 per notch, + = away. }
    procedure Wheel(AWheelDelta: Integer; AX, AY: Integer; ANowMs: QWord);
    { + = tilt right. }
    procedure WheelHorz(AWheelDelta: Integer; AX, AY: Integer; ANowMs: QWord);
    { Windows virtual key codes. True if the key was used. }
    function KeyDown(AKey: Word; ACtrl: Boolean; ANowMs: QWord): Boolean;
    { Runs single clicks whose double-click time is over. Call often
      (every 50 ms is enough). }
    procedure Tick(ANowMs: QWord);
    procedure FocusLost;

    property Profile: TMouseProfile read FProfile;
    property Zone: TMouseZone read FZone;
    { [Mouse] ZonesEnabled: off = only the Anywhere entries count, no
      zone orders, no zone names on screen. }
    property ZonesEnabled: Boolean read FZonesEnabled write FZonesEnabled;
    property Mode: TInputMode read FMode;
    property DoubleClickMs: Integer read FDoubleClickMs write FDoubleClickMs;
    { Counts as input (e.g. after the menu closed), for cursor hiding. }
    procedure NoteActivity(ANowMs: QWord);
    { Last input of any kind (cursor hiding). }
    property LastActivityMs: QWord read FLastActivityMs;
    property OnCommand: TCommandEvent read FOnCommand write FOnCommand;
    property OnFired: TMouseFiredEvent read FOnFired write FOnFired;
  end;

const
  { Movement before a press with the left button counts as a drag. }
  DragThreshold = 4;
  { A second click this near the first (pixels) can be a double-click. }
  DoubleClickDistance = 6;
  WheelNotch = 120;
  { A tilt message after this long a pause is a new tilt. }
  TiltGapMs = 300;
  SideKeyEchoMs = 700;
  GestureMinDistance = 40;
  GestureDominance = 1.5;
  TurnDegreesPerNotch = 5.0;

  { Windows virtual keys. }
  VKEY_RETURN = $0D;
  VKEY_ESCAPE = $1B;
  VKEY_SPACE = $20;
  VKEY_LEFT = $25;
  VKEY_UP = $26;
  VKEY_RIGHT = $27;
  VKEY_DOWN = $28;
  VKEY_D = $44;
  VKEY_V = $56;
  VKEY_BROWSER_BACK = $A6;
  VKEY_BROWSER_FORWARD = $A7;

{ The system's double-click time (500 ms if unknown). }
function SystemDoubleClickMs: Integer;

implementation

{$IFDEF WINDOWS}
function MViewGetDoubleClickTime: LongWord; stdcall;
  external 'user32.dll' name 'GetDoubleClickTime';
{$ENDIF}

function SystemDoubleClickMs: Integer;
begin
  Result := 500;
  {$IFDEF WINDOWS}
  Result := Integer(MViewGetDoubleClickTime);
  {$ENDIF}
  if (Result < 100) or (Result > 5000) then
    Result := 500;
end;

{ TMouseEngine }

constructor TMouseEngine.Create(AOwner: TObject);
begin
  inherited Create;
  FOwner := AOwner;
  FProfile := TMouseProfile.Create;
  FProfile.LoadDefaults;
  FMode := imBrowse;
  FDoubleClickMs := SystemDoubleClickMs;
  FZone := mzBottomLeft;
  FHaveZone := False;
  FZonesEnabled := True;
end;

destructor TMouseEngine.Destroy;
begin
  FProfile.Free;
  inherited Destroy;
end;

procedure TMouseEngine.SetProfile(AProfile: TMouseProfile);
begin
  if AProfile <> nil then
    FProfile.Assign(AProfile);
  { A click waiting for its double-click belongs to the old profile. }
  FClicks[cbLeft].Pending := False;
  FClicks[cbRight].Pending := False;
  FClicks[cbLeft].LastPressMs := 0;
  FClicks[cbRight].LastPressMs := 0;
end;

procedure TMouseEngine.SetViewSize(AWidth, AHeight: Integer);
begin
  FWidth := AWidth;
  FHeight := AHeight;
end;

procedure TMouseEngine.Emit(ACommand: TCommand; AX: Double; AY: Double; AValue: Double);
begin
  if Assigned(FOnCommand) then
    FOnCommand(FOwner, ACommand, CommandArgs(AX, AY, AValue));
end;

procedure TMouseEngine.Activity(ANowMs: QWord);
begin
  FLastActivityMs := ANowMs;
end;

procedure TMouseEngine.NoteActivity(ANowMs: QWord);
begin
  Activity(ANowMs);
end;

{ The zone under the mouse; not while a button is held. A new zone is
  announced (cmdShowZone), so its name appears. }
procedure TMouseEngine.UpdateZone(AX, AY: Integer);
var
  NewZone: TMouseZone;
begin
  FMouseX := AX;
  FMouseY := AY;
  if FLeftDown or FRightDown then
    Exit;
  if (FWidth <= 0) or (FHeight <= 0) then
    Exit;
  NewZone := ZoneAt(AX, AY, FWidth, FHeight, FZone, FHaveZone);
  if (not FHaveZone) or (NewZone <> FZone) then
  begin
    FZone := NewZone;
    FHaveZone := True;
    if FZonesEnabled then
      Emit(cmdShowZone, 0, 0, Ord(FZone));
  end;
end;

procedure TMouseEngine.SetMode(AMode: TInputMode);
begin
  if AMode = FMode then
    Exit;
  FMode := AMode;
  FWheelAccum := 0;
  Emit(cmdInputMode, 0, 0, Ord(AMode));
end;

function TMouseEngine.ActionsFor(AZone: TMouseZone; AEvent: TMouseEvent): TActionList;
begin
  if FZonesEnabled then
    Result := FProfile.ActionsFor(AZone, AEvent)
  else
    Result := FProfile.AnywhereActionsFor(AEvent);
end;

procedure TMouseEngine.ApplyZoneOrder(AZone: TMouseZone);
begin
  if not FZonesEnabled then
    Exit;
  case FProfile.ZoneOrder(AZone) of
    zoDate: Emit(cmdSortByDate);
    zoName: Emit(cmdSortByName);
  end;
end;

{ ANotches: for zoom and turn, how far (wheel parts); 1 otherwise. }
procedure TMouseEngine.Perform(AAction: TMouseAction; AZone: TMouseZone;
  AX, AY: Integer; ANotches: Double);
begin
  case AAction of
    maNextImage:
      begin
        ApplyZoneOrder(AZone);
        Emit(cmdNextImage);
      end;
    maPreviousImage:
      begin
        ApplyZoneOrder(AZone);
        Emit(cmdPreviousImage);
      end;
    maNextFolder:
      begin
        ApplyZoneOrder(AZone);
        Emit(cmdNextDirectory);
      end;
    maPreviousFolder:
      begin
        ApplyZoneOrder(AZone);
        Emit(cmdPreviousDirectory);
      end;
    maParentFolder:  Emit(cmdParentDirectory);
    { With zones on, the mouse sits in a corner zone: zooming there would
      pull the image towards that corner, so the middle of the view stays
      put (Day 22, user). Zones off: at the mouse. (Zoom mode, X1, always
      zooms at the mouse: see Wheel.) }
    maZoomIn:
      if FZonesEnabled and (FWidth > 0) and (FHeight > 0) then
        Emit(cmdZoomAt, FWidth / 2, FHeight / 2, ANotches)
      else
        Emit(cmdZoomAt, AX, AY, ANotches);
    maZoomOut:
      if FZonesEnabled and (FWidth > 0) and (FHeight > 0) then
        Emit(cmdZoomAt, FWidth / 2, FHeight / 2, -ANotches)
      else
        Emit(cmdZoomAt, AX, AY, -ANotches);
    maFit:           Emit(cmdFitToScreen);
    maOriginalSize:  Emit(cmdOriginalSizeAt, AX, AY);
    maFitOr100:      Emit(cmdToggleFit, AX, AY);
    maRotateLeft:    Emit(cmdRotateLeft);
    maRotateRight:   Emit(cmdRotateRight);
    maTurnLeft:      Emit(cmdRotateBy, 0, 0, -TurnDegreesPerNotch * ANotches);
    maTurnRight:     Emit(cmdRotateBy, 0, 0, TurnDegreesPerNotch * ANotches);
    maSortByDate:    Emit(cmdSortByDate);
    maSortByName:    Emit(cmdSortByName);
    maToggleSort:    Emit(cmdToggleSortMode);
    maZoomMode:
      if FMode = imZoom then
        SetMode(imBrowse)
      else
        SetMode(imZoom);
    maRotateMode:
      if FMode = imRotate then
        SetMode(imBrowse)
      else
        SetMode(imRotate);
    maFullscreen:    Emit(cmdToggleFullscreen);
    maInfo:          Emit(cmdToggleInfo);
    maDiagnostics:   Emit(cmdToggleDiagnostics);
    maMenu:          Emit(cmdShowMenu, AX, AY);
    maPaste:         Emit(cmdPaste);
    maSaveImage:     Emit(cmdSaveImage);
    maEditMode:      Emit(cmdEditMode);
    maEditOn:        Emit(cmdEditModeOn);
    maEditOff:       Emit(cmdEditModeOff);
    maCrop:          Emit(cmdCropSelection);
    maRescan:        Emit(cmdRescan);
    maSortPanel:     Emit(cmdSortPanel);
    maDeleteImage:   Emit(cmdDeleteImage);
    maUndo:          Emit(cmdUndo);
    maSideBySide:    Emit(cmdSideBySide);
    maFilterPanel:   Emit(cmdFilterPanel);
    maLockFilters:   Emit(cmdLockFilters);
    maResetFilters:  Emit(cmdResetFilters);
    maAutoLevels:    Emit(cmdAutoLevels);
    maAutoLevelsMode: Emit(cmdAutoLevelsMode);
    maApplyFilters:  Emit(cmdApplyFilters);
    maResizeToShown: Emit(cmdResizeToShown);
    maMagnifier:     Emit(cmdMagnifier);
    { A zoom / rotate mode is the engine's own; everything else (edit
      mode, exit) TMView decides. }
    maBack:
      if FMode <> imBrowse then
        SetMode(imBrowse)
      else
        Emit(cmdBack);
    maExit:          Emit(cmdExit);
  end;
end;

procedure TMouseEngine.Fire(AZone: TMouseZone; AEvent: TMouseEvent; AX, AY: Integer;
  ANotches: Double);
var
  Actions: TActionList;
  I: Integer;
begin
  Actions := ActionsFor(AZone, AEvent);
  if Assigned(FOnFired) then
    FOnFired(FOwner, AZone, AEvent, Actions);
  { The zone's name again, so it is clear where the command came from. }
  if FZonesEnabled and (AEvent in MouseEvents) and (Length(Actions) > 0) then
    Emit(cmdShowZone, 0, 0, Ord(AZone));
  for I := 0 to High(Actions) do
    Perform(Actions[I], AZone, AX, AY, ANotches);
end;

function TMouseEngine.HasDouble(AZone: TMouseZone; AButton: TClickButton): Boolean;
begin
  if AButton = cbLeft then
    Result := Length(ActionsFor(AZone, meLeftDouble)) > 0
  else
    Result := Length(ActionsFor(AZone, meRightDouble)) > 0;
end;

procedure TMouseEngine.ClickPress(AButton: TClickButton; AZone: TMouseZone;
  AX, AY: Integer; ANowMs: QWord);
var
  IsSecond: Boolean;
begin
  with FClicks[AButton] do
  begin
    IsSecond := (LastPressMs <> 0) and (ANowMs >= LastPressMs)
      and (ANowMs - LastPressMs <= QWord(FDoubleClickMs))
      and (Abs(AX - LastX) <= DoubleClickDistance) and (Abs(AY - LastY) <= DoubleClickDistance)
      and (LastZone = AZone) and HasDouble(AZone, AButton);
    if IsSecond then
    begin
      { The double-click: now, and the waiting single click is dropped. }
      Pending := False;
      LastPressMs := 0;
      SecondPress := True;
      if AButton = cbLeft then
        Fire(AZone, meLeftDouble, AX, AY)
      else
        Fire(AZone, meRightDouble, AX, AY);
    end
    else
    begin
      LastPressMs := ANowMs;
      LastX := AX;
      LastY := AY;
      LastZone := AZone;
      SecondPress := False;
    end;
  end;
end;

{ A release that was not a drag or gesture: a click, now or after the
  double-click time. }
procedure TMouseEngine.ClickRelease(AButton: TClickButton; AX, AY: Integer; ANowMs: QWord);
var
  PressZone: TMouseZone;
  Event: TMouseEvent;
begin
  if AButton = cbLeft then
  begin
    PressZone := FLeftZone;
    Event := meLeftClick;
  end
  else
  begin
    PressZone := FRightZone;
    Event := meRightClick;
  end;

  with FClicks[AButton] do
  begin
    if SecondPress then
    begin
      SecondPress := False;
      Exit;
    end;
    if HasDouble(PressZone, AButton) then
    begin
      { An earlier click still waiting: it runs now, this one waits. }
      if Pending then
      begin
        Pending := False;
        Fire(Zone, Event, X, Y);
      end;
      Pending := True;
      DueMs := LastPressMs + QWord(FDoubleClickMs);
      X := AX;
      Y := AY;
      Zone := PressZone;
    end
    else
      Fire(PressZone, Event, AX, AY);
  end;
end;

procedure TMouseEngine.Tick(ANowMs: QWord);
var
  B: TClickButton;
  Event: TMouseEvent;
begin
  for B := Low(TClickButton) to High(TClickButton) do
    if FClicks[B].Pending and (ANowMs >= FClicks[B].DueMs) then
    begin
      FClicks[B].Pending := False;
      if B = cbLeft then
        Event := meLeftClick
      else
        Event := meRightClick;
      Fire(FClicks[B].Zone, Event, FClicks[B].X, FClicks[B].Y);
    end;
end;

function TMouseEngine.GestureEvent(ADX, ADY: Integer; out AEvent: TMouseEvent): Boolean;
var
  LenX, LenY: Integer;
begin
  Result := False;
  AEvent := meGestureDown;
  LenX := Abs(ADX);
  LenY := Abs(ADY);
  if Max(LenX, LenY) < GestureMinDistance then
    Exit;
  if LenX >= GestureDominance * LenY then
  begin
    if ADX < 0 then
      AEvent := meGestureLeft
    else
      AEvent := meGestureRight;
    Result := True;
  end
  else if LenY >= GestureDominance * LenX then
  begin
    if ADY < 0 then
      AEvent := meGestureUp
    else
      AEvent := meGestureDown;
    Result := True;
  end;
end;

procedure TMouseEngine.ShowGesture(AValue: Integer);
begin
  if AValue = FGestureShown then
    Exit;
  FGestureShown := AValue;
  Emit(cmdGesturePreview, Ord(FRightZone), 0, AValue);
end;

procedure TMouseEngine.MouseDown(AButton: TEngineButton; AX, AY: Integer; ANowMs: QWord);
begin
  Activity(ANowMs);
  UpdateZone(AX, AY);
  case AButton of
    ebLeft:
      begin
        FLeftDown := True;
        FDragging := False;
        FDownX := AX;
        FDownY := AY;
        FLastX := AX;
        FLastY := AY;
        FLeftZone := FZone;
        ClickPress(cbLeft, FZone, AX, AY, ANowMs);
      end;
    ebRight:
      begin
        FRightDown := True;
        FGestureMade := False;
        FRightX := AX;
        FRightY := AY;
        FRightZone := FZone;
        ClickPress(cbRight, FZone, AX, AY, ANowMs);
      end;
    ebMiddle:
      Fire(FZone, meWheelClick, AX, AY);
    ebX1:
      begin
        FLastSideButtonMs := ANowMs;
        Fire(FZone, meX1, AX, AY);
      end;
    ebX2:
      begin
        FLastSideButtonMs := ANowMs;
        Fire(FZone, meX2, AX, AY);
      end;
  end;
end;

procedure TMouseEngine.MouseMove(AX, AY: Integer; ALeftDown, ARightDown: Boolean;
  ANowMs: QWord);
var
  Event: TMouseEvent;
begin
  Activity(ANowMs);

  { Released without us seeing it (e.g. outside the window). }
  if FRightDown and not ARightDown then
  begin
    FRightDown := False;
    FGestureMade := False;
    ShowGesture(0);
  end;
  if FLeftDown and not ALeftDown then
  begin
    FLeftDown := False;
    FDragging := False;
  end;

  UpdateZone(AX, AY);

  if FRightDown then
  begin
    { The same distance as GestureEvent asks for, so a press is always
      either a click or a gesture that can be recognised. }
    if (not FGestureMade)
      and (Max(Abs(AX - FRightX), Abs(AY - FRightY)) >= GestureMinDistance) then
    begin
      FGestureMade := True;
      { A gesture is no click, and doesn't start a double-click. }
      FClicks[cbRight].LastPressMs := 0;
      FClicks[cbRight].SecondPress := False;
    end;
    if FGestureMade then
    begin
      if GestureEvent(AX - FRightX, AY - FRightY, Event) then
        ShowGesture(Ord(Event) + 1)
      else
        ShowGesture(0);
    end;
  end;

  if not FLeftDown then
    Exit;
  if not FDragging then
  begin
    if Abs(AX - FDownX) + Abs(AY - FDownY) < DragThreshold then
      Exit;
    FDragging := True;
    FClicks[cbLeft].LastPressMs := 0;
    FClicks[cbLeft].SecondPress := False;
    { In edit mode TMView makes a selection from the drag instead of
      panning: it needs where the drag started and where it is. }
    Emit(cmdDragStart, FDownX, FDownY);
  end;
  if (AX <> FLastX) or (AY <> FLastY) then
  begin
    Emit(cmdPanBy, AX - FLastX, AY - FLastY);
    Emit(cmdDragPoint, AX, AY);
    FLastX := AX;
    FLastY := AY;
  end;
end;

procedure TMouseEngine.MouseUp(AButton: TEngineButton; AX, AY: Integer; ANowMs: QWord);
var
  Event: TMouseEvent;
begin
  Activity(ANowMs);
  case AButton of
    ebX1, ebX2:
      FLastSideButtonMs := ANowMs;   { the press did it }
    ebLeft:
      if FLeftDown then
      begin
        FLeftDown := False;
        if FDragging then
          FDragging := False
        else
          ClickRelease(cbLeft, AX, AY, ANowMs);
      end;
    ebRight:
      if FRightDown then
      begin
        FRightDown := False;
        if FGestureMade then
        begin
          FGestureMade := False;
          ShowGesture(0);
          if GestureEvent(AX - FRightX, AY - FRightY, Event) then
            Fire(FRightZone, Event, FRightX, FRightY);
          { else: went out and came back, or diagonal: nothing }
        end
        else
          ClickRelease(cbRight, AX, AY, ANowMs);
      end;
  end;
  UpdateZone(AX, AY);
end;

procedure TMouseEngine.Wheel(AWheelDelta: Integer; AX, AY: Integer; ANowMs: QWord);
var
  Event: TMouseEvent;
  Actions: TActionList;
  Notches: Double;
begin
  Activity(ANowMs);
  UpdateZone(AX, AY);
  if AWheelDelta = 0 then
    Exit;
  Notches := AWheelDelta / WheelNotch;

  { A switched-on mode takes the wheel everywhere. Towards you = in. }
  case FMode of
    imZoom:
      begin
        Emit(cmdZoomAt, AX, AY, -Notches);
        Exit;
      end;
    imRotate:
      begin
        Emit(cmdRotateBy, 0, 0, Notches * TurnDegreesPerNotch);
        Exit;
      end;
  end;

  if AWheelDelta > 0 then
    Event := meWheelUp
  else
    Event := meWheelDown;

  { Zoom and turn follow parts of a notch smoothly. }
  Actions := ActionsFor(FZone, Event);
  if (Length(Actions) = 1)
    and (Actions[0] in [maZoomIn, maZoomOut, maTurnLeft, maTurnRight]) then
  begin
    FWheelAccum := 0;
    Fire(FZone, Event, AX, AY, Abs(Notches));
    Exit;
  end;

  { Everything else: one event per whole notch. }
  if (FWheelAccum > 0) <> (AWheelDelta > 0) then
    FWheelAccum := 0;          { direction changed: start again }
  Inc(FWheelAccum, AWheelDelta);
  while FWheelAccum >= WheelNotch do
  begin
    Dec(FWheelAccum, WheelNotch);
    Fire(FZone, meWheelUp, AX, AY);
  end;
  while FWheelAccum <= -WheelNotch do
  begin
    Inc(FWheelAccum, WheelNotch);
    Fire(FZone, meWheelDown, AX, AY);
  end;
end;

procedure TMouseEngine.WheelHorz(AWheelDelta: Integer; AX, AY: Integer; ANowMs: QWord);
var
  NewTilt: Boolean;
begin
  Activity(ANowMs);
  UpdateZone(AX, AY);
  if AWheelDelta = 0 then
    Exit;
  { A new tilt: after a pause, or the other way. }
  NewTilt := (FLastTiltMsgMs = 0) or (ANowMs < FLastTiltMsgMs)
    or (ANowMs - FLastTiltMsgMs >= TiltGapMs) or (Sign(AWheelDelta) <> FLastTiltDir);
  FLastTiltMsgMs := ANowMs;
  FLastTiltDir := Sign(AWheelDelta);
  if not NewTilt then
    Exit;                      { the same tilt, held: repeats are ignored }
  if AWheelDelta > 0 then
    Fire(FZone, meTiltRight, AX, AY)
  else
    Fire(FZone, meTiltLeft, AX, AY);
end;

function TMouseEngine.KeyDown(AKey: Word; ACtrl: Boolean; ANowMs: QWord): Boolean;
begin
  Activity(ANowMs);
  Result := True;
  if ACtrl then
  begin
    if AKey = VKEY_V then
      Emit(cmdPaste)
    else
      Result := False;
    Exit;
  end;
  case AKey of
    { User's choice: up / down step through the images (like the wheel),
      left / right through the folders (like the gestures and tilt). }
    VKEY_DOWN:  Emit(cmdNextImage);
    VKEY_UP:    Emit(cmdPreviousImage);
    VKEY_RIGHT: Emit(cmdNextDirectory);
    VKEY_LEFT:  Emit(cmdPreviousDirectory);
    VKEY_SPACE:  Fire(FZone, meKeySpace, FMouseX, FMouseY);
    { Esc is fixed (user): a zoom / rotate mode ends; otherwise Back
      (TMView: edit mode off, else the settings editor). }
    VKEY_ESCAPE: Perform(maBack, FZone, FMouseX, FMouseY, 1);
    VKEY_RETURN: Fire(FZone, meKeyEnter, FMouseX, FMouseY);
    VKEY_D:      Fire(FZone, meKeyD, FMouseX, FMouseY);
    { Side buttons some mouse drivers send as keys; right after a real
      side button they are its echo. }
    VKEY_BROWSER_BACK:
      if (ANowMs < FLastSideButtonMs) or (ANowMs - FLastSideButtonMs > SideKeyEchoMs) then
        Fire(FZone, meX1, FMouseX, FMouseY);
    VKEY_BROWSER_FORWARD:
      if (ANowMs < FLastSideButtonMs) or (ANowMs - FLastSideButtonMs > SideKeyEchoMs) then
        Fire(FZone, meX2, FMouseX, FMouseY);
  else
    Result := False;
  end;
end;

procedure TMouseEngine.FocusLost;
begin
  FLeftDown := False;
  FDragging := False;
  FRightDown := False;
  FGestureMade := False;
  FClicks[cbLeft].Pending := False;
  FClicks[cbRight].Pending := False;
  FClicks[cbLeft].LastPressMs := 0;
  FClicks[cbRight].LastPressMs := 0;
  ShowGesture(0);
end;

end.
