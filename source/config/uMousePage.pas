unit uMousePage;

{
  Unit: uMousePage

  Purpose
  -------
  The "Mouse & keys" page of the settings editor (spec §9.2, §11,
  Phase F): the mouse profile (Default.mouse) shown and edited without
  writing the text file by hand.

  Owns
  ----
  The profile being edited, the try-it engine and a timer (clicks that
  wait for a possible double-click). In detail:
  - FProfile (TMouseProfile): the profile being edited; the built-in
    one until LoadFile.
  - FEngine (TMouseEngine): the try-it engine, fed with a copy of
    FProfile after every change.
  - FTimer (TTimer, 50 ms): calls FEngine.Tick.
  - The page's controls (zone picture, zones on / off button,
    "Use the built-in profile" button, name edit, order group, the
    event rows of up to three combo boxes, the try-it area TTryArea).
    They belong to the page as LCL owner.

  Knows
  -----
  - The file name given to LoadFile (the editor passes the viewer's
    mouse profile file).
  - OnChange and OnZonesToggle: the editor's handlers.
  - TTryArea knows the engine and the profile of the page (not owned).

  Responsibilities
  ----------------
  - Load the profile file (the built-in profile if it isn't there or
    can't be read) and save it (SaveFile; False and a note on the page
    if it couldn't be written).
  - Show the zones, Anywhere and Keys; show and edit the selection's
    name, browsing order and commands; mark the page changed.
  - Show the file name, "changed, not saved", the problems found in
    the file, and the fixed controls.
  - Switch the zones on / off on the page and tell the editor
    (OnZonesToggle), which keeps [Mouse] ZonesEnabled in MView.ini.
  - Run the "Try it here" area through a real TMouseEngine and say
    what arrived and what it would run; its commands are not carried
    out, only the zoom / rotate mode and Back are described.

  Does NOT
  --------
  - Keep comments of a hand-edited Default.mouse: saving writes the
    profile afresh (only when something was changed on this page).
  - Tell the viewer: the viewer reads the file when it starts.
  - Write MView.ini (uIniEditor does).

  Threads
  -------
  UI thread only (LCL events and a TTimer). No locking.

  Uses (MView units)
  ------------------
  interface:      uCommands, uMouseProfile, uMouseEngine
  Libraries:      Classes, SysUtils, Types, Math, Controls, Forms,
                  Graphics, StdCtrls, ExtCtrls, LCLType

  Used by
  -------
  uIniEditor, uMainForm

  Layout
  ------
  Left: a picture of the screen, its four zones, and below them
  "Anywhere" (what every zone uses unless it sets it itself) and
  "Keys". A click selects one of them.
  Right: for the selection, its name and browsing order (zones only)
  and one row per event (mouse events, or the three
  programmable keys; Esc is fixed and has no row) with up to
  three commands in a row.
  Bottom: "Try it here", a small area with the same four zones. Mouse
  buttons, the wheel, tilt, side buttons and the keys pressed over it
  go through a real TMouseEngine with the profile being edited, and
  the area says what arrived and what it would run. That also shows at
  once whether a mouse really sends X1, X2 and tilt.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Types,
  Math,
  Controls,
  Forms,
  Graphics,
  StdCtrls,
  ExtCtrls,
  LCLType,
  uCommands,
  uMouseProfile,
  uMouseEngine;

type

  { The try-it area: a small screen with the four zones. }
  TTryArea = class(TCustomControl)
  private
    FEngine: TMouseEngine;
    FProfile: TMouseProfile;     { for the zone names; not owned }
    FText: string;
    function CursorPos: TPoint;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    function DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoContextPopup(MousePos: TPoint; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure ShowText(const AText: string);
    property Engine: TMouseEngine read FEngine write FEngine;
    property Profile: TMouseProfile read FProfile write FProfile;
  end;

  TEventRow = record
    Caption: TLabel;
    Combos: array[0..MaxActionsPerEvent - 1] of TComboBox;
  end;

  { TMouseProfilePage }

  TMouseProfilePage = class(TPanel)
  private
    FProfile: TMouseProfile;
    FFileName: string;
    FModified: Boolean;
    FSelection: Integer;         { 0..3 = TMouseZone, SelAnywhere, SelKeys }
    FUpdating: Boolean;

    FLeft: TPanel;
    FZonesButton: TPanel;        { green = zones on, red = off }
    FZonesEnabled: Boolean;
    FOnZonesToggle: TNotifyEvent;
    FZoneBox: TPaintBox;
    FDefaultsButton: TButton;
    FInfo: TLabel;
    FRight: TScrollBox;
    FIntro: TLabel;
    FTitleLabel: TLabel;
    FTitleEdit: TEdit;
    FOrderGroup: TRadioGroup;
    FRows: array[TMouseEvent] of TEventRow;
    FActions: array of TMouseAction;   { the choosable commands, list order }

    FTryPanel: TPanel;
    FTryHeader: TLabel;
    FTry: TTryArea;
    FEngine: TMouseEngine;
    FTimer: TTimer;

    FOnChange: TNotifyEvent;

    function IsZoneSelected: Boolean;
    function SelectedZone: TMouseZone;
    procedure CellRects(out AZones: array of TRect; out AAnywhere, AKeys: TRect);
    procedure PaintZones(Sender: TObject);
    procedure ZoneBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure SelectCell(ASelection: Integer);
    procedure ShowSelection;
    procedure FillCombo(ACombo: TComboBox; AFirst: Boolean; AEvent: TMouseEvent);
    function FirstBase: Integer;
    procedure ShowRow(AEvent: TMouseEvent);
    procedure WriteRow(AEvent: TMouseEvent);
    procedure HandleComboChange(Sender: TObject);
    procedure HandleTitleChange(Sender: TObject);
    procedure HandleOrderClick(Sender: TObject);
    procedure HandleFired(Sender: TObject; AZone: TMouseZone; AEvent: TMouseEvent;
      const AActions: TActionList);
    procedure HandleTryCommand(Sender: TObject; ACommand: TCommand; const AArgs: TCommandArgs);
    procedure HandleTimer(Sender: TObject);
    procedure HandleDefaultsClick(Sender: TObject);
    procedure HandleZonesClick(Sender: TObject);
    procedure SetZonesEnabled(AValue: Boolean);
    procedure MarkChanged;
    procedure ShowInfo;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Reads the profile (the built-in one if the file isn't there). }
    procedure LoadFile(const AFileName: string);
    { False and a note on the page if it couldn't be written. }
    function SaveFile: Boolean;

    property Modified: Boolean read FModified;
    { [Mouse] ZonesEnabled of MView.ini (the editor keeps it there):
      off = only Anywhere counts. Setting it only changes the page. }
    property ZonesEnabled: Boolean read FZonesEnabled write SetZonesEnabled;
    { The green / red button was pressed (ZonesEnabled is the new
      state): the editor writes it into MView.ini's text. }
    property OnZonesToggle: TNotifyEvent read FOnZonesToggle write FOnZonesToggle;
    property FileName: string read FFileName;
    { Something was changed on the page. }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

const
  SelAnywhere = 4;
  SelKeys = 5;

  RowHeight = 30;
  LabelWidth = 200;
  ComboWidth = 250;
  ComboGap = 8;
  StripHeight = 34;
  { The column headings, then the event rows. }
  HeadingTop = 116;
  FirstRowTop = 140;
  ColumnHeadings: array[0..MaxActionsPerEvent - 1] of string = (
    'Command', 'then (optional)', 'and then (optional)');

{ TTryArea }

constructor TTryArea.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Color := $00303030;
  FText := 'Point here and press buttons, turn or tilt the wheel, press Space / Esc / Enter / D.';
end;

function TTryArea.CursorPos: TPoint;
begin
  Result := ScreenToClient(Mouse.CursorPos);
end;

procedure TTryArea.ShowText(const AText: string);
begin
  FText := AText;
  Invalidate;
end;

procedure TTryArea.Paint;
var
  Z: TMouseZone;
  R: TRect;
  HalfW, HalfH, TH: Integer;
  S: string;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(0, 0, ClientWidth, ClientHeight);
  HalfW := ClientWidth div 2;
  HalfH := ClientHeight div 2;
  Canvas.Font.Height := -12;
  TH := Canvas.TextHeight('Xg');
  for Z := Low(TMouseZone) to High(TMouseZone) do
  begin
    if IsLeftZone(Z) then
    begin
      R.Left := 0;
      R.Right := HalfW;
    end
    else
    begin
      R.Left := HalfW;
      R.Right := ClientWidth;
    end;
    if IsTopZone(Z) then
    begin
      R.Top := 0;
      R.Bottom := HalfH;
    end
    else
    begin
      R.Top := HalfH;
      R.Bottom := ClientHeight;
    end;
    if Assigned(FEngine) and (FEngine.Zone = Z) and MouseInClient then
    begin
      Canvas.Brush.Color := $00504838;
      Canvas.FillRect(R);
    end;
    Canvas.Pen.Color := $00606060;
    Canvas.Brush.Style := bsClear;
    Canvas.Rectangle(R);
    if Assigned(FProfile) then
      S := FProfile.ZoneTitle(Z)
    else
      S := MouseZoneCaption(Z);
    Canvas.Font.Color := $00A0A0A0;
    Canvas.TextOut(R.Left + 6, R.Top + 4, S);
    Canvas.Brush.Style := bsSolid;
  end;
  { What arrived, in the middle. }
  Canvas.Font.Height := -15;
  Canvas.Font.Color := clWhite;
  Canvas.Brush.Style := bsClear;
  TH := Canvas.TextHeight('Xg');
  Canvas.TextOut(Max(6, (ClientWidth - Canvas.TextWidth(FText)) div 2),
    (ClientHeight - TH) div 2, FText);
  Canvas.Brush.Style := bsSolid;
end;

procedure TTryArea.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus and not Focused then
    SetFocus;
  if FEngine = nil then
    Exit;
  FEngine.SetViewSize(ClientWidth, ClientHeight);
  case Button of
    mbLeft:   FEngine.MouseDown(ebLeft, X, Y, GetTickCount64);
    mbRight:  FEngine.MouseDown(ebRight, X, Y, GetTickCount64);
    mbMiddle: FEngine.MouseDown(ebMiddle, X, Y, GetTickCount64);
    mbExtra1: FEngine.MouseDown(ebX1, X, Y, GetTickCount64);
    mbExtra2: FEngine.MouseDown(ebX2, X, Y, GetTickCount64);
  end;
end;

procedure TTryArea.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Before: TMouseZone;
begin
  inherited MouseMove(Shift, X, Y);
  if FEngine = nil then
    Exit;
  Before := FEngine.Zone;
  FEngine.SetViewSize(ClientWidth, ClientHeight);
  FEngine.MouseMove(X, Y, ssLeft in Shift, ssRight in Shift, GetTickCount64);
  if FEngine.Zone <> Before then
    Invalidate;
end;

procedure TTryArea.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FEngine = nil then
    Exit;
  FEngine.SetViewSize(ClientWidth, ClientHeight);
  case Button of
    mbLeft:   FEngine.MouseUp(ebLeft, X, Y, GetTickCount64);
    mbRight:  FEngine.MouseUp(ebRight, X, Y, GetTickCount64);
    mbMiddle: FEngine.MouseUp(ebMiddle, X, Y, GetTickCount64);
    mbExtra1: FEngine.MouseUp(ebX1, X, Y, GetTickCount64);
    mbExtra2: FEngine.MouseUp(ebX2, X, Y, GetTickCount64);
  end;
end;

function TTryArea.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  Result := True;
  if FEngine = nil then
    Exit;
  P := CursorPos;
  FEngine.SetViewSize(ClientWidth, ClientHeight);
  FEngine.Wheel(WheelDelta, P.X, P.Y, GetTickCount64);
end;

function TTryArea.DoMouseWheelHorz(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  P: TPoint;
begin
  Result := True;
  if FEngine = nil then
    Exit;
  P := CursorPos;
  FEngine.SetViewSize(ClientWidth, ClientHeight);
  FEngine.WheelHorz(WheelDelta, P.X, P.Y, GetTickCount64);
end;

procedure TTryArea.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (Key = 0) or (FEngine = nil) then
    Exit;
  FEngine.SetViewSize(ClientWidth, ClientHeight);
  if FEngine.KeyDown(Key, ssCtrl in Shift, GetTickCount64) then
    Key := 0;
end;

procedure TTryArea.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
begin
  Handled := True;
end;

{ TMouseProfilePage }

constructor TMouseProfilePage.Create(AOwner: TComponent);
var
  E: TMouseEvent;
  A: TMouseAction;
  K, N, Y: Integer;
  Heading: TLabel;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption := '';
  FProfile := TMouseProfile.Create;
  FProfile.LoadDefaults;
  FSelection := Ord(mzBottomLeft);

  { The choosable commands: all but "None". }
  N := 0;
  for A := Low(TMouseAction) to High(TMouseAction) do
    if A <> maNone then
    begin
      SetLength(FActions, N + 1);
      FActions[N] := A;
      Inc(N);
    end;

  { Bottom: try it here. }
  FTryPanel := TPanel.Create(Self);
  FTryPanel.Parent := Self;
  FTryPanel.Align := alBottom;
  FTryPanel.Height := 150;
  FTryPanel.BevelOuter := bvNone;
  FTryPanel.Caption := '';
  FTryHeader := TLabel.Create(Self);
  FTryHeader.Parent := FTryPanel;
  FTryHeader.Align := alTop;
  FTryHeader.BorderSpacing.Around := 6;
  FTryHeader.Font.Style := [fsBold];
  FTryHeader.Caption := 'Try it here (the profile as edited above, not yet saved)';
  FTry := TTryArea.Create(Self);
  FTry.Parent := FTryPanel;
  FTry.Align := alClient;
  FTry.BorderSpacing.Around := 6;

  FEngine := TMouseEngine.Create(Self);
  FEngine.OnFired := @HandleFired;
  FEngine.OnCommand := @HandleTryCommand;
  FEngine.SetProfile(FProfile);
  FTry.Engine := FEngine;
  FTry.Profile := FProfile;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 50;
  FTimer.OnTimer := @HandleTimer;
  FTimer.Enabled := True;

  { Left: the zones. }
  FLeft := TPanel.Create(Self);
  FLeft.Parent := Self;
  FLeft.Align := alLeft;
  FLeft.Width := 320;
  FLeft.BevelOuter := bvNone;
  FLeft.Caption := '';
  FZonesEnabled := True;
  FZonesButton := TPanel.Create(Self);
  FZonesButton.Parent := FLeft;
  FZonesButton.Align := alTop;
  FZonesButton.Top := 0;
  FZonesButton.Height := 34;
  FZonesButton.BorderSpacing.Left := 8;
  FZonesButton.BorderSpacing.Right := 8;
  FZonesButton.BorderSpacing.Top := 8;
  FZonesButton.BevelOuter := bvRaised;
  FZonesButton.ParentBackground := False;
  FZonesButton.Font.Color := clWhite;
  FZonesButton.Font.Style := [fsBold];
  FZonesButton.Cursor := crHandPoint;
  FZonesButton.OnClick := @HandleZonesClick;
  FZonesButton.Hint := 'Click to switch the zones on or off ([Mouse] ZonesEnabled in MView.ini).';
  FZonesButton.ShowHint := True;
  FZoneBox := TPaintBox.Create(Self);
  FZoneBox.Parent := FLeft;
  FZoneBox.Top := 100;
  FZoneBox.Align := alTop;
  FZoneBox.Height := 300;
  FZoneBox.BorderSpacing.Around := 8;
  FZoneBox.OnPaint := @PaintZones;
  FZoneBox.OnMouseDown := @ZoneBoxMouseDown;
  FDefaultsButton := TButton.Create(Self);
  FDefaultsButton.Parent := FLeft;
  FDefaultsButton.Align := alTop;
  FDefaultsButton.Top := 1000;          { below the zone picture }
  FDefaultsButton.BorderSpacing.Left := 8;
  FDefaultsButton.BorderSpacing.Right := 8;
  FDefaultsButton.Caption := 'Use the built-in profile';
  FDefaultsButton.Hint := 'All zones, Anywhere and Keys as MView comes (Save to keep it).';
  FDefaultsButton.ShowHint := True;
  FDefaultsButton.OnClick := @HandleDefaultsClick;
  FInfo := TLabel.Create(Self);
  FInfo.Parent := FLeft;
  FInfo.Align := alClient;
  FInfo.BorderSpacing.Around := 8;
  FInfo.WordWrap := True;
  FInfo.AutoSize := False;
  FInfo.Caption := '';

  { Right: the selection's table. }
  FRight := TScrollBox.Create(Self);
  FRight.Parent := Self;
  FRight.Align := alClient;
  FRight.BorderStyle := bsNone;
  FRight.HorzScrollBar.Visible := True;
  FRight.VertScrollBar.Tracking := True;

  FIntro := TLabel.Create(Self);
  FIntro.Parent := FRight;
  FIntro.SetBounds(8, 8, LabelWidth + 3 * (ComboWidth + ComboGap), 50);
  FIntro.AutoSize := False;
  FIntro.WordWrap := True;

  { Column headings above the boxes. }
  for K := 0 to MaxActionsPerEvent - 1 do
  begin
    Heading := TLabel.Create(Self);
    Heading.Parent := FRight;
    Heading.SetBounds(LabelWidth + K * (ComboWidth + ComboGap) + 2, HeadingTop, ComboWidth, 20);
    Heading.Font.Style := [fsBold];
    Heading.Caption := ColumnHeadings[K];
  end;
  Heading := TLabel.Create(Self);
  Heading.Parent := FRight;
  Heading.SetBounds(8, HeadingTop, LabelWidth - 12, 20);
  Heading.Font.Style := [fsBold];
  Heading.Caption := 'Button / key';

  FTitleLabel := TLabel.Create(Self);
  FTitleLabel.Parent := FRight;
  FTitleLabel.SetBounds(8, 74, LabelWidth - 8, 24);
  FTitleLabel.Caption := 'Name (shown on screen)';
  FTitleEdit := TEdit.Create(Self);
  FTitleEdit.Parent := FRight;
  FTitleEdit.SetBounds(LabelWidth, 70, ComboWidth, 26);
  FTitleEdit.OnChange := @HandleTitleChange;

  FOrderGroup := TRadioGroup.Create(Self);
  FOrderGroup.Parent := FRight;
  FOrderGroup.SetBounds(LabelWidth + ComboWidth + ComboGap, 60, 2 * ComboWidth, 46);
  FOrderGroup.Caption := 'Browsing from this zone';
  FOrderGroup.Columns := 3;
  FOrderGroup.Items.Add('any order');
  FOrderGroup.Items.Add('by date');
  FOrderGroup.Items.Add('by name');
  FOrderGroup.OnClick := @HandleOrderClick;

  { One row per event; the keys use the rows' places too (only one set
    is visible at a time). }
  for E := Low(TMouseEvent) to High(TMouseEvent) do
  begin
    { Keys: Space, Enter, D one below the other (Esc is fixed, no row
      shown). }
    if E in KeyEvents then
    begin
      Y := FirstRowTop + (Ord(E) - Ord(meKeySpace)) * RowHeight;
      if E > meKeyEsc then
        Dec(Y, RowHeight);
    end
    else
      Y := FirstRowTop + Ord(E) * RowHeight;
    FRows[E].Caption := TLabel.Create(Self);
    FRows[E].Caption.Parent := FRight;
    FRows[E].Caption.SetBounds(8, Y + 4, LabelWidth - 12, 22);
    FRows[E].Caption.Caption := MouseEventCaption(E);
    for K := 0 to MaxActionsPerEvent - 1 do
    begin
      FRows[E].Combos[K] := TComboBox.Create(Self);
      FRows[E].Combos[K].Parent := FRight;
      FRows[E].Combos[K].Style := csDropDownList;
      FRows[E].Combos[K].DropDownCount := 24;
      FRows[E].Combos[K].SetBounds(LabelWidth + K * (ComboWidth + ComboGap), Y,
        ComboWidth, 26);
      FRows[E].Combos[K].Tag := Ord(E) * 10 + K;
      FRows[E].Combos[K].OnChange := @HandleComboChange;
    end;
  end;

  ShowSelection;
  SetZonesEnabled(True);
end;

destructor TMouseProfilePage.Destroy;
begin
  FTimer.Enabled := False;
  FTry.Engine := nil;
  FTry.Profile := nil;
  FEngine.Free;
  FProfile.Free;
  inherited Destroy;
end;

procedure TMouseProfilePage.LoadFile(const AFileName: string);
begin
  FFileName := AFileName;
  try
    if FileExists(AFileName) then
      FProfile.LoadFromFile(AFileName)
    else
      FProfile.LoadDefaults;
  except
    on E: Exception do
    begin
      FProfile.LoadDefaults;
      FProfile.Errors.Add('could not read the file: ' + E.Message);
    end;
  end;
  FModified := False;
  FEngine.SetProfile(FProfile);
  ShowSelection;
  ShowInfo;
end;

function TMouseProfilePage.SaveFile: Boolean;
begin
  Result := False;
  try
    FProfile.SaveToFile(FFileName);
    FModified := False;
    FProfile.Errors.Clear;
    Result := True;
  except
    on E: Exception do
      FProfile.Errors.Add('could not save: ' + E.Message);
  end;
  ShowInfo;
end;

procedure TMouseProfilePage.ShowInfo;
var
  S: string;
begin
  S := 'File: ' + FFileName;
  if not FileExists(FFileName) then
    S := S + LineEnding + '(not there yet: the built-in profile is shown; Save writes it)';
  if FModified then
    S := S + LineEnding + LineEnding + 'Changed, not saved.';
  if FProfile.Errors.Count > 0 then
    S := S + LineEnding + LineEnding + 'Problems in the file (those lines are ignored):'
      + LineEnding + FProfile.Errors.Text;
  S := S + LineEnding + LineEnding
    + 'Fixed, not in the profile: left button + drag = pan; right button + drag = '
    + 'gesture; arrow keys = next / previous image (down / up) and folder '
    + '(right / left); Ctrl+V = paste; Esc = a mode or edit mode off, else back to the '
    + 'settings (here: ends MView).';
  FInfo.Caption := S;
end;

procedure TMouseProfilePage.MarkChanged;
begin
  FModified := True;
  FEngine.SetProfile(FProfile);
  FTry.Invalidate;
  ShowInfo;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TMouseProfilePage.IsZoneSelected: Boolean;
begin
  Result := (FSelection >= Ord(Low(TMouseZone))) and (FSelection <= Ord(High(TMouseZone)));
end;

function TMouseProfilePage.SelectedZone: TMouseZone;
begin
  if IsZoneSelected then
    Result := TMouseZone(FSelection)
  else
    Result := mzBottomLeft;
end;

{ The cells of the zone picture: the four zones on top, then two strips
  (Anywhere, Keys). }
procedure TMouseProfilePage.CellRects(out AZones: array of TRect; out AAnywhere, AKeys: TRect);
var
  W, H, GridH, HalfW, HalfH: Integer;
  Z: TMouseZone;
begin
  W := FZoneBox.Width - 1;
  H := FZoneBox.Height - 1;
  GridH := Max(40, H - 2 * (StripHeight + 8));
  HalfW := W div 2;
  HalfH := GridH div 2;
  for Z := Low(TMouseZone) to High(TMouseZone) do
  begin
    if IsLeftZone(Z) then
    begin
      AZones[Ord(Z)].Left := 0;
      AZones[Ord(Z)].Right := HalfW;
    end
    else
    begin
      AZones[Ord(Z)].Left := HalfW;
      AZones[Ord(Z)].Right := W;
    end;
    if IsTopZone(Z) then
    begin
      AZones[Ord(Z)].Top := 0;
      AZones[Ord(Z)].Bottom := HalfH;
    end
    else
    begin
      AZones[Ord(Z)].Top := HalfH;
      AZones[Ord(Z)].Bottom := GridH;
    end;
  end;
  AAnywhere := Rect(0, GridH + 8, W, GridH + 8 + StripHeight);
  AKeys := Rect(0, AAnywhere.Bottom + 8, W, AAnywhere.Bottom + 8 + StripHeight);
end;

procedure TMouseProfilePage.PaintZones(Sender: TObject);
var
  C: TCanvas;
  Zones: array[0..3] of TRect;
  AnyRect, KeyRect: TRect;
  Z: TMouseZone;
  OrderText: string;

  { Up to three lines, centred; the first bold. Lines too wide for the
    cell are cut at the cell's edges. }
  procedure Cell(const R: TRect; ASelected: Boolean; const ALine1, ALine2, ALine3: string);
  var
    TH, Y, Lines: Integer;

    procedure Line(const AText: string);
    var
      TR: TRect;
    begin
      TR := Rect(R.Left + 2, Y, R.Right - 2, Y + TH);
      C.TextRect(TR, Max(TR.Left, (R.Left + R.Right - C.TextWidth(AText)) div 2), Y, AText);
      Inc(Y, TH);
    end;

  begin
    C.Brush.Style := bsSolid;
    if ASelected then
    begin
      C.Brush.Color := clHighlight;
      C.Font.Color := clHighlightText;
    end
    else
    begin
      C.Brush.Color := clWindow;
      C.Font.Color := clWindowText;
    end;
    C.Pen.Color := clGrayText;
    C.Rectangle(R);
    C.Brush.Style := bsClear;
    TH := C.TextHeight('Xg');
    Lines := 1;
    if ALine2 <> '' then
      Inc(Lines);
    if ALine3 <> '' then
      Inc(Lines);
    Y := (R.Top + R.Bottom - Lines * TH) div 2;
    C.Font.Style := [fsBold];
    Line(ALine1);
    C.Font.Style := [];
    if ALine2 <> '' then
      Line(ALine2);
    if ALine3 <> '' then
      Line(ALine3);
    C.Brush.Style := bsSolid;
  end;

begin
  C := FZoneBox.Canvas;
  C.Brush.Color := clBtnFace;
  C.FillRect(0, 0, FZoneBox.Width, FZoneBox.Height);
  CellRects(Zones, AnyRect, KeyRect);
  for Z := Low(TMouseZone) to High(TMouseZone) do
  begin
    case FProfile.ZoneOrder(Z) of
      zoDate: OrderText := '(by date)';
      zoName: OrderText := '(by name)';
    else
      OrderText := '';
    end;
    if not FZonesEnabled then
      OrderText := '(zones off)';
    Cell(Zones[Ord(Z)], FSelection = Ord(Z), MouseZoneCaption(Z), FProfile.ZoneTitle(Z),
      OrderText);
  end;
  Cell(AnyRect, FSelection = SelAnywhere, 'Anywhere (all zones)', '', '');
  Cell(KeyRect, FSelection = SelKeys, 'Keys', '', '');
end;

procedure TMouseProfilePage.ZoneBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Zones: array[0..3] of TRect;
  AnyRect, KeyRect: TRect;
  I: Integer;
  P: TPoint;
begin
  CellRects(Zones, AnyRect, KeyRect);
  P := Point(X, Y);
  for I := 0 to 3 do
    if PtInRect(Zones[I], P) then
    begin
      SelectCell(I);
      Exit;
    end;
  if PtInRect(AnyRect, P) then
    SelectCell(SelAnywhere)
  else if PtInRect(KeyRect, P) then
    SelectCell(SelKeys);
end;

procedure TMouseProfilePage.SelectCell(ASelection: Integer);
begin
  if ASelection = FSelection then
    Exit;
  FSelection := ASelection;
  ShowSelection;
end;

{ Index of the first real command in the first combo box. }
function TMouseProfilePage.FirstBase: Integer;
begin
  if IsZoneSelected then
    Result := 2     { (as in Anywhere), (nothing here) }
  else
    Result := 1;    { (nothing) }
end;

procedure TMouseProfilePage.FillCombo(ACombo: TComboBox; AFirst: Boolean; AEvent: TMouseEvent);
var
  I: Integer;
begin
  ACombo.Items.BeginUpdate;
  try
    ACombo.Items.Clear;
    if AFirst then
    begin
      if IsZoneSelected then
      begin
        ACombo.Items.Add('(as in Anywhere: '
          + ActionListCaption(FProfile.AnywhereBinding(AEvent)) + ')');
        ACombo.Items.Add('(nothing here)');
      end
      else
        ACombo.Items.Add('(nothing)');
    end
    else
      ACombo.Items.Add('-');
    for I := 0 to High(FActions) do
      ACombo.Items.Add(MouseActionCaption(FActions[I]));
  finally
    ACombo.Items.EndUpdate;
  end;
end;

function IndexOfAction(const AActions: array of TMouseAction; AAction: TMouseAction): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AActions) do
    if AActions[I] = AAction then
      Exit(I);
  Result := -1;
end;

procedure TMouseProfilePage.ShowRow(AEvent: TMouseEvent);
var
  List: TActionList;
  K, Idx, Base: Integer;
begin
  for K := 0 to MaxActionsPerEvent - 1 do
    FillCombo(FRows[AEvent].Combos[K], K = 0, AEvent);
  Base := FirstBase;

  if IsZoneSelected then
    List := FProfile.ZoneBinding(SelectedZone, AEvent)
  else
    List := FProfile.AnywhereBinding(AEvent);

  { First box. }
  if Length(List) = 0 then
    FRows[AEvent].Combos[0].ItemIndex := 0             { as in Anywhere / nothing }
  else if (Length(List) = 1) and (List[0] = maNone) then
  begin
    if IsZoneSelected then
      FRows[AEvent].Combos[0].ItemIndex := 1           { nothing here }
    else
      FRows[AEvent].Combos[0].ItemIndex := 0;
  end
  else
  begin
    Idx := IndexOfAction(FActions, List[0]);
    if Idx >= 0 then
      FRows[AEvent].Combos[0].ItemIndex := Base + Idx
    else
      FRows[AEvent].Combos[0].ItemIndex := 0;
  end;

  { The commands after it. }
  for K := 1 to MaxActionsPerEvent - 1 do
  begin
    Idx := -1;
    if (K < Length(List)) and (List[K] <> maNone) then
      Idx := IndexOfAction(FActions, List[K]);
    if Idx >= 0 then
      FRows[AEvent].Combos[K].ItemIndex := 1 + Idx
    else
      FRows[AEvent].Combos[K].ItemIndex := 0;
    FRows[AEvent].Combos[K].Enabled := FRows[AEvent].Combos[0].ItemIndex >= Base;
  end;
end;

{ The row's boxes -> the profile. }
procedure TMouseProfilePage.WriteRow(AEvent: TMouseEvent);
var
  List: TActionList;
  K, Idx, Base, N: Integer;
begin
  Base := FirstBase;
  List := nil;
  Idx := FRows[AEvent].Combos[0].ItemIndex;
  if Idx >= Base then
  begin
    N := 1;
    SetLength(List, 1);
    List[0] := FActions[Idx - Base];
    for K := 1 to MaxActionsPerEvent - 1 do
    begin
      Idx := FRows[AEvent].Combos[K].ItemIndex;
      if Idx >= 1 then
      begin
        SetLength(List, N + 1);
        List[N] := FActions[Idx - 1];
        Inc(N);
      end;
    end;
  end
  else if IsZoneSelected and (Idx = 1) then
  begin
    SetLength(List, 1);
    List[0] := maNone;                 { switched off in this zone }
  end;
  { else: nil = as in Anywhere (zones), nothing (Anywhere, keys) }

  if IsZoneSelected then
    FProfile.SetZoneBinding(SelectedZone, AEvent, List)
  else
    FProfile.SetAnywhereBinding(AEvent, List);

  for K := 1 to MaxActionsPerEvent - 1 do
    FRows[AEvent].Combos[K].Enabled := FRows[AEvent].Combos[0].ItemIndex >= Base;
end;

procedure TMouseProfilePage.ShowSelection;
var
  E: TMouseEvent;
  K: Integer;
  ShowKeys, Vis: Boolean;
begin
  FUpdating := True;
  try
    ShowKeys := FSelection = SelKeys;
    if IsZoneSelected then
      FIntro.Caption := Format('Zone "%s" (%s): what each button does while the mouse is in '
        + 'this quarter of the screen. "(as in Anywhere ...)" uses the Anywhere setting; '
        + '"(nothing here)" switches it off in this zone. One press runs the commands of '
        + 'its row from left to right.',
        [FProfile.ZoneTitle(SelectedZone), LowerCase(MouseZoneCaption(SelectedZone))])
    else if ShowKeys then
      FIntro.Caption := 'Keys: the three keys that can be set. One press runs the commands of '
        + 'its row from left to right. Fixed: Esc (a mode or edit mode off, else back to this '
        + 'settings screen; here it ends MView), arrow keys (images and folders), Ctrl+V (paste).'
    else
      FIntro.Caption := 'Anywhere: what each button does in every zone that doesn''t set it '
        + 'itself. One press runs the commands of its row from left to right.';

    FTitleLabel.Visible := IsZoneSelected;
    FTitleEdit.Visible := IsZoneSelected;
    FOrderGroup.Visible := IsZoneSelected;
    if IsZoneSelected then
    begin
      FTitleEdit.Text := FProfile.ZoneTitle(SelectedZone);
      FOrderGroup.ItemIndex := Ord(FProfile.ZoneOrder(SelectedZone));
    end;

    for E := Low(TMouseEvent) to High(TMouseEvent) do
    begin
      Vis := ((E in KeyEvents) = ShowKeys) and (E <> meKeyEsc);
      FRows[E].Caption.Visible := Vis;
      for K := 0 to MaxActionsPerEvent - 1 do
        FRows[E].Combos[K].Visible := Vis;
      if Vis then
        ShowRow(E);
    end;
  finally
    FUpdating := False;
  end;
  FZoneBox.Invalidate;
end;

procedure TMouseProfilePage.HandleComboChange(Sender: TObject);
var
  E: TMouseEvent;
begin
  if FUpdating then
    Exit;
  E := TMouseEvent(TComboBox(Sender).Tag div 10);
  WriteRow(E);
  MarkChanged;
end;

procedure TMouseProfilePage.HandleTitleChange(Sender: TObject);
begin
  if FUpdating or not IsZoneSelected
    or (FTitleEdit.Text = FProfile.ZoneTitle(SelectedZone)) then
    Exit;
  FProfile.SetZoneTitle(SelectedZone, FTitleEdit.Text);
  FZoneBox.Invalidate;
  MarkChanged;
end;

procedure TMouseProfilePage.HandleOrderClick(Sender: TObject);
begin
  if FUpdating or not IsZoneSelected or (FOrderGroup.ItemIndex < 0)
    or (TZoneOrder(FOrderGroup.ItemIndex) = FProfile.ZoneOrder(SelectedZone)) then
    Exit;
  FProfile.SetZoneOrder(SelectedZone, TZoneOrder(FOrderGroup.ItemIndex));
  FZoneBox.Invalidate;
  MarkChanged;
end;

procedure TMouseProfilePage.HandleFired(Sender: TObject; AZone: TMouseZone;
  AEvent: TMouseEvent; const AActions: TActionList);
var
  Where: string;
begin
  if AEvent in KeyEvents then
    Where := 'Key'
  else if not FZonesEnabled then
    Where := 'Anywhere (zones off)'
  else
    Where := FProfile.ZoneTitle(AZone) + ' (' + LowerCase(MouseZoneCaption(AZone)) + ')';
  FTry.ShowText(Format('%s   ·   %s   ->   %s',
    [Where, MouseEventCaption(AEvent), ActionListCaption(AActions)]));
end;

{ The try-it engine's commands are not carried out; only the modes are
  worth telling (they change what the wheel does). }
procedure TMouseProfilePage.HandleTryCommand(Sender: TObject; ACommand: TCommand;
  const AArgs: TCommandArgs);
begin
  if ACommand = cmdInputMode then
    case TInputMode(Round(AArgs.Value)) of
      imZoom:   FTry.ShowText('Zoom mode on: the wheel zooms in every zone (the same button or Esc = off)');
      imRotate: FTry.ShowText('Rotate mode on: the wheel turns in every zone (the same button or Esc = off)');
    else
      FTry.ShowText('Mode off: the wheel follows the zones again');
    end
  else if ACommand = cmdBack then
    { Esc (fixed) or a Back entry: no mode was on. }
    FTry.ShowText('Back: in the viewer edit mode off, else the settings screen (Esc is fixed to this)')
  else if ACommand = cmdShowZone then
    FTry.Invalidate;
end;

procedure TMouseProfilePage.SetZonesEnabled(AValue: Boolean);
begin
  FZonesEnabled := AValue;
  if AValue then
  begin
    FZonesButton.Color := $00308030;           { green }
    FZonesButton.Caption := 'Zones ON  (click to switch off)';
  end
  else
  begin
    FZonesButton.Color := $003030B0;           { red }
    FZonesButton.Caption := 'Zones OFF: only Anywhere counts';
  end;
  if Assigned(FEngine) then
    FEngine.ZonesEnabled := AValue;
  FZoneBox.Invalidate;
  if Assigned(FTry) then
    FTry.Invalidate;
end;

procedure TMouseProfilePage.HandleZonesClick(Sender: TObject);
begin
  SetZonesEnabled(not FZonesEnabled);
  if Assigned(FOnZonesToggle) then
    FOnZonesToggle(Self);
end;

{ Back to MView's own profile (e.g. to get new default commands after
  an update); not saved until Save. }
procedure TMouseProfilePage.HandleDefaultsClick(Sender: TObject);
begin
  FProfile.LoadDefaults;
  ShowSelection;
  MarkChanged;
end;

procedure TMouseProfilePage.HandleTimer(Sender: TObject);
begin
  if Assigned(FEngine) then
    FEngine.Tick(GetTickCount64);
end;

end.
