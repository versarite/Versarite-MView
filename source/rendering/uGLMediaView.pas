unit uGLMediaView;

{
  Unit: uGLMediaView

  Purpose
  -------
  The OpenGL drawing surface: TMediaView's counterpart for the GPU
  renderer. It paints through TGLRenderer and passes all input to the
  same kind of TMouseEngine, so the controls are identical in both
  modes.

  Owns
  ----
  - Its TMouseEngine (FInput).
  - The OpenGL context, through TOpenGLControl.

  Knows
  -----
  - TGLRenderer (to paint). The renderer is owned by TMView.
  - OnCommand: where the mouse engine's commands go.

  Responsibilities
  ----------------
  - Paint: make the context current and let the renderer draw a
    frame.
  - Pass keys, mouse buttons, moves and both wheels to the mouse
    engine, with the view size and the time.
  - Tell the renderer before its window (and so the context and all
    textures) goes, e.g. when switching to fullscreen (ContextLost).
  - Suppress the LCL's automatic context menu: the menu is a command
    of the mouse profile (Menu).
  - Tell the engine when the focus leaves.

  Does NOT
  --------
  - Decide what input means (the mouse engine does).
  - Draw anything itself (uGLRenderer does).

  Threads
  -------
  UI thread only.

  Uses (MView units)
  ------------------
  interface:      uCommands, uMouseEngine, uMediaView, uGLRenderer
  Libraries:      Classes, SysUtils, Types, Controls, LCLType,
                  OpenGLContext

  Used by
  -------
  uMainForm

  Notes
  -----
  DoExit is also called while the view is being freed (the focus
  leaves it in inherited Destroy, after the engine is gone: Esc to the
  settings screen, Day 19), so it checks the engine first.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Types,
  Controls,
  LCLType,
  OpenGLContext,
  uCommands,
  uMouseEngine,
  uMediaView,
  uGLRenderer;

type

  { TGLMediaView }

  TGLMediaView = class(TOpenGLControl)
  private
    FRenderer: TGLRenderer;
    FInput: TMouseEngine;
    FOnCommand: TCommandEvent;
    procedure HandleInputCommand(Sender: TObject; ACommand: TCommand; const AArgs: TCommandArgs);
    function MousePosition: TPoint;
  protected
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
    procedure DestroyWnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure DoOnPaint; override;

    property Renderer: TGLRenderer read FRenderer write FRenderer;
    property Input: TMouseEngine read FInput;
    property OnCommand: TCommandEvent read FOnCommand write FOnCommand;
  end;

implementation

constructor TGLMediaView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  FInput := TMouseEngine.Create(Self);
  FInput.OnCommand := @HandleInputCommand;
end;

destructor TGLMediaView.Destroy;
begin
  FRenderer := nil;
  FreeAndNil(FInput);
  inherited Destroy;
end;

procedure TGLMediaView.DoOnPaint;
begin
  if Assigned(FRenderer) and MakeCurrent then
    FRenderer.Paint(ClientWidth, ClientHeight)
  else
    inherited DoOnPaint;
end;

procedure TGLMediaView.HandleInputCommand(Sender: TObject; ACommand: TCommand;
  const AArgs: TCommandArgs);
begin
  if (ACommand <> cmdNone) and Assigned(FOnCommand) then
    FOnCommand(Self, ACommand, AArgs);
end;

function TGLMediaView.MousePosition: TPoint;
begin
  Result := ScreenToClient(Mouse.CursorPos);
end;

procedure TGLMediaView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if Key = 0 then
    Exit;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  if FInput.KeyDown(Key, ssCtrl in Shift, GetTickCount64) then
    Key := 0;
end;

procedure TGLMediaView.KeyUp(var Key: Word; Shift: TShiftState);
begin
  inherited KeyUp(Key, Shift);
end;

procedure TGLMediaView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
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

procedure TGLMediaView.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  FInput.SetViewSize(ClientWidth, ClientHeight);
  FInput.MouseMove(X, Y, ssLeft in Shift, ssRight in Shift, GetTickCount64);
end;

procedure TGLMediaView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  B: TEngineButton;
begin
  inherited MouseUp(Button, Shift, X, Y);
  FInput.SetViewSize(ClientWidth, ClientHeight);
  if EngineButton(Button, B) then
    FInput.MouseUp(B, X, Y, GetTickCount64);
end;

function TGLMediaView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  P := MousePosition;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  FInput.Wheel(WheelDelta, P.X, P.Y, GetTickCount64);
  Result := True;
end;

function TGLMediaView.DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  P := MousePosition;
  FInput.SetViewSize(ClientWidth, ClientHeight);
  FInput.WheelHorz(WheelDelta, P.X, P.Y, GetTickCount64);
  Result := True;
end;

{ The window goes (e.g. fullscreen switch recreates it): so do the
  OpenGL context and its textures. }
procedure TGLMediaView.DestroyWnd;
begin
  if Assigned(FRenderer) then
    FRenderer.ContextLost;
  inherited DestroyWnd;
end;

{ The menu is a command of the mouse profile (Menu): never the LCL's
  automatic one. }
procedure TGLMediaView.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
begin
  Handled := True;
end;

procedure TGLMediaView.DoExit;
begin
  inherited DoExit;
  { Also called while the view is being freed (the focus leaves it in
    inherited Destroy, after the engine is gone: Esc to the settings
    screen, Day 19). }
  if Assigned(FInput) then
    FInput.FocusLost;
end;

end.
