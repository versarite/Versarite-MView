unit uMediaView;

{
  Unit: uMediaView

  Purpose
  -------
  TMediaView is the drawing surface of the CPU renderer (the fallback
  when OpenGL isn't usable; the GPU surface is TGLMediaView). It
  forwards paint requests to the renderer and passes raw input to the
  mouse engine (uMouseEngine, the mouse language), which turns it into
  commands.

  Owns
  ----
  - Its TMouseEngine (FInput).

  Knows
  -----
  - TCpuRenderer (to paint). The renderer is owned by TMView.
  - The OnCommand handler (the owner), which gets the commands.

  Responsibilities
  ----------------
  - Provide a drawing surface (black when there is no renderer).
  - Forward paint operations to the renderer.
  - Pass keys, mouse buttons, movement, the wheel and the tilt wheel
    to the mouse engine, which produces commands (spec §9.1).
  - Tell the engine when the view loses focus.
  - Suppress the LCL's automatic context menu (the menu is a command).

  Does NOT
  --------
  - Load media, navigate folders or change the view itself.
  - Decide what a command does.

  Threads
  -------
  UI thread only (an LCL control).

  Uses (MView units)
  ------------------
  interface:      uCommands, uMouseEngine, uRenderer
  Libraries:      Classes, SysUtils, Types, Controls, Graphics,
                  LCLType

  Used by
  -------
  uGLMediaView, uMainForm

  Revision History
  ----------------
  2026-07-18  Initial version.
  2026-09-25  Phase A: input produces commands (OnCommand).
  2026-09-26  Phase D: mouse control through TInputHandler.
  2026-09-27  Phase F: the mouse language (TMouseEngine).
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Types,
  Controls,
  Graphics,
  LCLType,
  uCommands,
  uMouseEngine,
  uRenderer;

type

  { TMediaView }

  TMediaView = class(TCustomControl)
  private
    FRenderer: TCpuRenderer;
    FInput: TMouseEngine;
    FOnCommand: TCommandEvent;

    procedure HandleInputCommand(Sender: TObject; ACommand: TCommand; const AArgs: TCommandArgs);
    function MousePosition: TPoint;
  protected
    procedure Paint; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    function DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure DoExit; override;
    procedure DoContextPopup(MousePos: TPoint; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure SetRenderer(ARenderer: TCpuRenderer);
    procedure RefreshView;

    property Input: TMouseEngine read FInput;
    property OnCommand: TCommandEvent read FOnCommand write FOnCommand;
  end;

{ LCL button -> mouse engine button; False for buttons it doesn't use. }
function EngineButton(AButton: TMouseButton; out AResult: TEngineButton): Boolean;

implementation

function EngineButton(AButton: TMouseButton; out AResult: TEngineButton): Boolean;
begin
  Result := True;
  AResult := ebLeft;
  case AButton of
    mbLeft:   AResult := ebLeft;
    mbRight:  AResult := ebRight;
    mbMiddle: AResult := ebMiddle;
    mbExtra1: AResult := ebX1;
    mbExtra2: AResult := ebX2;
  else
    Result := False;
  end;
end;

{ TMediaView }

constructor TMediaView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  DoubleBuffered := True;
  Color := clBlack;
  TabStop := True;
  FInput := TMouseEngine.Create(Self);
  FInput.OnCommand := @HandleInputCommand;
end;

destructor TMediaView.Destroy;
begin
  FRenderer := nil;
  FreeAndNil(FInput);
  inherited Destroy;
end;

procedure TMediaView.Paint;
begin
  { No inherited call: the renderer paints every pixel. }
  if Assigned(FRenderer) then
    FRenderer.Paint(Canvas, ClientWidth, ClientHeight)
  else
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
  end;
end;

procedure TMediaView.SetRenderer(ARenderer: TCpuRenderer);
begin
  FRenderer := ARenderer;
end;

procedure TMediaView.RefreshView;
begin
  Invalidate;
end;

procedure TMediaView.HandleInputCommand(Sender: TObject; ACommand: TCommand;
  const AArgs: TCommandArgs);
begin
  if (ACommand <> cmdNone) and Assigned(FOnCommand) then
    FOnCommand(Self, ACommand, AArgs);
end;

function TMediaView.MousePosition: TPoint;
begin
  Result := ScreenToClient(Mouse.CursorPos);
end;

procedure TMediaView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then
    Exit;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  if FInput.KeyDown(Key, ssCtrl in Shift, GetTickCount64) then
    Key := 0;   { handled }
end;

procedure TMediaView.KeyUp(var Key: Word; Shift: TShiftState);
begin
  inherited KeyUp(Key, Shift);
end;

procedure TMediaView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  B: TEngineButton;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus and not Focused then
    SetFocus;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  if EngineButton(Button, B) then
    FInput.MouseDown(B, X, Y, GetTickCount64);
end;

procedure TMediaView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  FInput.SetViewSize(ClientWidth, ClientHeight);
  FInput.MouseMove(X, Y, ssLeft in Shift, ssRight in Shift, GetTickCount64);
end;

procedure TMediaView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  B: TEngineButton;
begin
  inherited MouseUp(Button, Shift, X, Y);
  FInput.SetViewSize(ClientWidth, ClientHeight);
  if EngineButton(Button, B) then
    FInput.MouseUp(B, X, Y, GetTickCount64);
end;

function TMediaView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  P := MousePosition;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  FInput.Wheel(WheelDelta, P.X, P.Y, GetTickCount64);
  Result := True;
end;

function TMediaView.DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  P := MousePosition;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  FInput.WheelHorz(WheelDelta, P.X, P.Y, GetTickCount64);
  Result := True;
end;

{ The menu is a command of the mouse profile (Menu): never the LCL's
  automatic one. }
procedure TMediaView.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
begin
  Handled := True;
end;

procedure TMediaView.DoExit;
begin
  inherited DoExit;
  { Also called while the view is being freed (the focus leaves it in
    inherited Destroy, after the engine is gone: Esc to the settings
    screen, Day 19). }
  if Assigned(FInput) then
    FInput.FocusLost;
end;

end.
