unit uInputHandler;

{
  Unit: uInputHandler

  Purpose
  -------
  The built-in mouse and keyboard profile, until the mouse language
  (Phase F) arrives. Both drawing surfaces (CPU and GPU) pass their raw
  input here; it turns it into commands (spec §9.1: input sources only
  produce commands). The plan was for the mouse language to take it
  over as its default profile; in the end it replaced it (see Status).

  Status: retired. The mouse language (uMouseEngine + uMouseProfile)
  replaced it after all; no unit uses it any more. Kept for reference
  only. It is still listed in MView.lpr's uses and in MView.lpi, so it
  is compiled; it can be removed from MView.lpr and the project.

  Owns
  ----
  - Nothing but its own state: the switched-on and held mode, the
    button and key states, the gesture start point, the wheel
    remainder. No objects, timers or files.

  Knows
  -----
  - The owner object (passed to Create), handed back as Sender with
    every command.
  - OnCommand (TCommandEvent, uCommands): where the commands go.

  Responsibilities
  ----------------
  - Turn key presses (Z, R, Esc, Browser Back / Forward), wheel turns,
    button presses, drags and double-clicks into TCommand values
    (uCommands), per the Controls table below.
  - Keep the input mode (browse / zoom / rotate): switched by X1 / X2
    or a tap on Z, or held while Z / R is down; report changes as
    cmdInputMode.
  - Collect parts of a wheel notch in browse mode (one image per
    whole notch); zoom and rotation follow the parts smoothly.
  - Recognise right-button gestures and tell the surface when the
    context menu must not be shown (SuppressContextMenu).
  - End holds and drags when the window loses the focus (FocusLost).

  Does NOT
  --------
  - Change the view itself (TMView does, through the renderer).
  - Know the renderer or the image.

  Threads
  -------
  UI thread only (called from the surfaces' LCL event handlers, when
  it was still used). No locking.

  Uses (MView units)
  ------------------
  interface:      uCommands
  Libraries:      Classes, SysUtils, Math, Controls, LCLType

  Used by
  -------
  none (only listed in MView.lpr)

  Controls
  --------
    Wheel                 next / previous image         (browse mode)
    X1 (rear side button) zoom mode on / off: wheel zooms around
                          the mouse (towards you = in)
    X2 (front side button) rotate mode on / off: wheel turns the
                          image, 5 degrees per notch, 1 with Shift
    Left button + drag    pan (in every mode)
    Double-click          fit <-> 100 %, keeping the point clicked
    Wheel press (middle)  fullscreen on / off
    Right button + drag   gesture (spec §9.2, as in Hamana):
                            left  = previous folder
                            right = next folder
                            down  = exit
                            up    = not used yet (parent folder, later)
    Right click           context menu (not after a gesture)
    Z                     like X1          R  like X2 (tap = turn 90)
    Esc                   leave a switched-on mode (otherwise: exit)

  X1 and X2 are plain switches: each press switches the mode on, or
  off again (pressing the other button switches over). Only the press
  is used, never the release: the LCL (4.6, TControl.WMXButtonUp)
  finds the released button from the "buttons down" flags, where
  Windows no longer lists it, so MouseUp never comes for X1 / X2.
  A quick second press arrives as a double-click press (ssDouble)
  and switches like any other.
  Mouse movement plays no part at all.
  Gestures: the right button must move GestureMinDistance pixels
  before it counts as a gesture; from then on the context menu is not
  shown for that press (the surface asks SuppressContextMenu). The
  direction is decided at the release, by the larger of the two
  movements, and only if it is clearly larger (GestureDominance), so
  a diagonal stroke does nothing rather than the wrong thing.
  Z works two ways: tap = switch, hold + wheel = zoom only while held
  (key releases are reported reliably). R likewise, except that a
  tap keeps its old meaning, 90 degrees.
  Some mice report the side buttons as Browser Back / Forward keys;
  those switch the modes too (but not when they only echo a side
  button that was just seen).

  Safety
  ------
  Key auto-repeat doesn't start anything twice. When the window loses
  the focus, holds end, so no mode stays on by accident. (The shift
  state of mouse moves is not used for the side buttons: not every
  LCL version reports them there, and a tap with a slightly moving
  mouse then looked like a release.)
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  Controls,
  LCLType,
  uCommands;

type

  THoldSource = (hsNone, hsZ, hsR);

  TInputHandler = class(TObject)
  private
    FOnCommand: TCommandEvent;
    FOwner: TObject;

    FToggled: TInputMode;        { switched on by a tap }
    FHeld: TInputMode;           { while a button or key is held }
    FHoldSource: THoldSource;
    FWheelDuringHold: Boolean;
    FHoldStartMs: QWord;
    FLastSideButtonMs: QWord;    { last X1 / X2 press or release }
    FWheelAccum: Integer;        { browse mode: parts of a notch }
    FShownMode: TInputMode;      { last mode reported (cmdInputMode) }

    FZDown: Boolean;
    FRDown: Boolean;

    FLeftDown: Boolean;
    FDragging: Boolean;
    FDownX, FDownY: Integer;
    FLastX, FLastY: Integer;

    FRightDown: Boolean;
    FGestureMade: Boolean;       { this right press moved far enough }
    FSuppressMenu: Boolean;      { ... so no context menu for it }
    FRightX, FRightY: Integer;

    procedure Emit(ACommand: TCommand; AX: Double = 0; AY: Double = 0; AValue: Double = 0);
    function EffectiveMode: TInputMode;
    procedure ReportMode;
    procedure BeginHold(ASource: THoldSource; AMode: TInputMode);
    function EndHold(ASource: THoldSource): Boolean;
    procedure ToggleMode(AMode: TInputMode);
    procedure FinishGesture(ADX, ADY: Integer);
  public
    constructor Create(AOwner: TObject);

    { Each returns True if it used the input (the caller then does
      nothing else with it). }
    function KeyDown(AKey: Word; AShift: TShiftState): Boolean;
    function KeyUp(AKey: Word; AShift: TShiftState): Boolean;
    function MouseWheel(AShift: TShiftState; AWheelDelta: Integer; AX, AY: Integer): Boolean;

    procedure MouseDown(AButton: TMouseButton; AShift: TShiftState; AX, AY: Integer);
    procedure MouseMove(AShift: TShiftState; AX, AY: Integer);
    procedure MouseUp(AButton: TMouseButton; AShift: TShiftState; AX, AY: Integer);
    procedure DoubleClick(AX, AY: Integer);
    procedure FocusLost;

    { True if the last right-button press was a gesture: the surface
      then doesn't show the context menu. }
    function SuppressContextMenu: Boolean;

    property Mode: TInputMode read FShownMode;
    property OnCommand: TCommandEvent read FOnCommand write FOnCommand;
  end;

implementation

const
  { Movement before a press with the left button counts as a drag, so
    a plain click stays a click (the mouse language needs clicks). }
  DragThreshold = 4;

  WheelNotch = 120;

  { A press longer than this without the wheel is not a tap. }
  TapMaxMs = 500;

  { Browser Back / Forward keys this soon after a side button are the
    driver's echo of it. }
  SideKeyEchoMs = 700;
  RotateDegreesPerNotch = 5.0;
  RotateDegreesPerNotchFine = 1.0;

  { Windows virtual keys some mice send for the side buttons. }
  VK_BROWSER_BACK_KEY = $A6;
  VK_BROWSER_FORWARD_KEY = $A7;

  { Right-button movement that makes a gesture, in pixels. }
  GestureMinDistance = 40;
  { The main direction must be this many times the other one. }
  GestureDominance = 1.5;

constructor TInputHandler.Create(AOwner: TObject);
begin
  inherited Create;
  FOwner := AOwner;
  FToggled := imBrowse;
  FHeld := imBrowse;
  FHoldSource := hsNone;
  FShownMode := imBrowse;
end;

procedure TInputHandler.Emit(ACommand: TCommand; AX: Double; AY: Double; AValue: Double);
begin
  if Assigned(FOnCommand) then
    FOnCommand(FOwner, ACommand, CommandArgs(AX, AY, AValue));
end;

function TInputHandler.EffectiveMode: TInputMode;
begin
  if FHoldSource <> hsNone then
    Result := FHeld
  else
    Result := FToggled;
end;

procedure TInputHandler.ReportMode;
var
  M: TInputMode;
begin
  M := EffectiveMode;
  if M <> FShownMode then
  begin
    FShownMode := M;
    FWheelAccum := 0;
    Emit(cmdInputMode, 0, 0, Ord(M));
  end;
end;

procedure TInputHandler.BeginHold(ASource: THoldSource; AMode: TInputMode);
begin
  if FHoldSource <> hsNone then
    Exit;   { one hold at a time }
  FHoldSource := ASource;
  FHeld := AMode;
  FWheelDuringHold := False;
  FHoldStartMs := GetTickCount64;
  ReportMode;
end;

{ True if ASource was holding and the wheel wasn't turned: a tap. }
function TInputHandler.EndHold(ASource: THoldSource): Boolean;
begin
  Result := False;
  if FHoldSource <> ASource then
    Exit;
  Result := (not FWheelDuringHold) and (GetTickCount64 - FHoldStartMs < TapMaxMs);
  FHoldSource := hsNone;
  FHeld := imBrowse;
  ReportMode;
end;

procedure TInputHandler.ToggleMode(AMode: TInputMode);
begin
  if FToggled = AMode then
    FToggled := imBrowse
  else
    FToggled := AMode;
  ReportMode;
end;

function TInputHandler.KeyDown(AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := True;
  case AKey of
    VK_Z:
      if not FZDown then
      begin
        FZDown := True;   { auto-repeat sends more KeyDowns: ignored }
        BeginHold(hsZ, imZoom);
      end;
    VK_R:
      if not FRDown then
      begin
        FRDown := True;
        BeginHold(hsR, imRotate);
      end;
    { Some mouse drivers send these keys instead of the side buttons,
      others send them in addition. Right after a real side button
      they are the same click again: ignored, or the mode would be
      switched on and straight off again. }
    VK_BROWSER_BACK_KEY:
      if GetTickCount64 - FLastSideButtonMs > SideKeyEchoMs then
        ToggleMode(imZoom);
    VK_BROWSER_FORWARD_KEY:
      if GetTickCount64 - FLastSideButtonMs > SideKeyEchoMs then
        ToggleMode(imRotate);
    VK_ESCAPE:
      if FToggled <> imBrowse then
      begin
        FToggled := imBrowse;
        ReportMode;
      end
      else
        Result := False;   { Esc in browse mode: the normal key map (exit) }
  else
    Result := False;
  end;
end;

function TInputHandler.KeyUp(AKey: Word; AShift: TShiftState): Boolean;
begin
  Result := True;
  case AKey of
    VK_Z:
      begin
        FZDown := False;
        if EndHold(hsZ) then
          ToggleMode(imZoom);
      end;
    VK_R:
      begin
        FRDown := False;
        if EndHold(hsR) then
          Emit(cmdRotateRight);   { a tap on R: 90 degrees, as before }
      end;
  else
    Result := False;
  end;
end;

function TInputHandler.MouseWheel(AShift: TShiftState; AWheelDelta: Integer; AX, AY: Integer): Boolean;
var
  Notches, Degrees: Double;
begin
  Result := True;
  if AWheelDelta = 0 then
    Exit;
  if FHoldSource <> hsNone then
    FWheelDuringHold := True;

  { High-resolution wheels send parts of a notch; zoom and rotation
    follow them smoothly. }
  Notches := AWheelDelta / WheelNotch;

  case EffectiveMode of
    imBrowse:
      begin
        { One image per whole notch; high-resolution wheels and
          touchpads send parts of a notch. }
        Inc(FWheelAccum, AWheelDelta);
        while FWheelAccum >= WheelNotch do
        begin
          Dec(FWheelAccum, WheelNotch);
          Emit(cmdPreviousImage);
        end;
        while FWheelAccum <= -WheelNotch do
        begin
          Inc(FWheelAccum, WheelNotch);
          Emit(cmdNextImage);
        end;
      end;
    imZoom:
      { Wheel towards you = zoom in (cmdZoomAt: + = in). }
      Emit(cmdZoomAt, AX, AY, -Notches);
    imRotate:
      begin
        if ssShift in AShift then
          Degrees := Notches * RotateDegreesPerNotchFine
        else
          Degrees := Notches * RotateDegreesPerNotch;
        Emit(cmdRotateBy, 0, 0, Degrees);      { wheel up = clockwise }
      end;
  end;
end;

procedure TInputHandler.MouseDown(AButton: TMouseButton; AShift: TShiftState; AX, AY: Integer);
begin
  case AButton of
    mbExtra1:
      begin
        FLastSideButtonMs := GetTickCount64;
        ToggleMode(imZoom);
      end;
    mbExtra2:
      begin
        FLastSideButtonMs := GetTickCount64;
        ToggleMode(imRotate);
      end;
    mbMiddle:
      { On the press, like the side buttons: movement plays no part. }
      Emit(cmdToggleFullscreen);
    mbLeft:
      begin
        FLeftDown := True;
        FDragging := False;
        FDownX := AX;
        FDownY := AY;
        FLastX := AX;
        FLastY := AY;
      end;
    mbRight:
      begin
        FRightDown := True;
        FGestureMade := False;
        FSuppressMenu := False;
        FRightX := AX;
        FRightY := AY;
      end;
  end;
end;

procedure TInputHandler.MouseMove(AShift: TShiftState; AX, AY: Integer);
begin
  if FRightDown then
  begin
    if not (ssRight in AShift) then
      FRightDown := False   { released without us seeing it }
    else if Abs(AX - FRightX) + Abs(AY - FRightY) >= GestureMinDistance then
    begin
      FGestureMade := True;
      FSuppressMenu := True;
    end;
  end;

  if not FLeftDown then
    Exit;
  if not (ssLeft in AShift) then
  begin
    { Released without us seeing it (e.g. outside the window). }
    FLeftDown := False;
    FDragging := False;
    Exit;
  end;

  if not FDragging then
  begin
    if Abs(AX - FDownX) + Abs(AY - FDownY) < DragThreshold then
      Exit;
    FDragging := True;
  end;

  if (AX <> FLastX) or (AY <> FLastY) then
  begin
    Emit(cmdPanBy, AX - FLastX, AY - FLastY);
    FLastX := AX;
    FLastY := AY;
  end;
end;

procedure TInputHandler.MouseUp(AButton: TMouseButton; AShift: TShiftState; AX, AY: Integer);
begin
  case AButton of
    mbExtra1, mbExtra2:
      { Nothing: the press did it (see the header). }
      FLastSideButtonMs := GetTickCount64;
    mbLeft:
      begin
        { Not dragged: a click. Reserved for the mouse language
          (screen quadrants, Phase F). }
        FLeftDown := False;
        FDragging := False;
      end;
    mbRight:
      if FRightDown then
      begin
        FRightDown := False;
        if FGestureMade then
          FinishGesture(AX - FRightX, AY - FRightY);
      end;
  end;
end;

procedure TInputHandler.FinishGesture(ADX, ADY: Integer);
var
  LenX, LenY: Integer;
begin
  LenX := Abs(ADX);
  LenY := Abs(ADY);
  if Max(LenX, LenY) < GestureMinDistance then
    Exit;   { went out and came back: nothing }
  if LenX >= GestureDominance * LenY then
  begin
    if ADX < 0 then
      Emit(cmdPreviousDirectory)
    else
      Emit(cmdNextDirectory);
  end
  else if LenY >= GestureDominance * LenX then
  begin
    if ADY > 0 then
      Emit(cmdExit);
    { Up: reserved (parent folder, Phase F). }
  end;
end;

{ Asked once per context menu (WM_CONTEXTMENU): used up, so a menu
  opened later with the keyboard isn't blocked. }
function TInputHandler.SuppressContextMenu: Boolean;
begin
  Result := FSuppressMenu;
  FSuppressMenu := False;
end;

procedure TInputHandler.DoubleClick(AX, AY: Integer);
begin
  Emit(cmdToggleFit, AX, AY);
end;

procedure TInputHandler.FocusLost;
begin
  FZDown := False;
  FRDown := False;
  FLeftDown := False;
  FDragging := False;
  FRightDown := False;
  if FHoldSource <> hsNone then
  begin
    FHoldSource := hsNone;
    FHeld := imBrowse;
  end;
  ReportMode;
end;

end.
