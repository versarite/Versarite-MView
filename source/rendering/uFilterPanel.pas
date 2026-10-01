unit uFilterPanel;

{
  Unit: uFilterPanel

  Purpose
  -------
  The filter panel (Phase H, "Looking closer"; user, Day 22): a column
  at the left edge of the view with one row per display filter (black
  point, white point, brightness, contrast, gamma, saturation, hue,
  invert) and "Reset all". It opens when the mouse rests at the left
  edge (the sort panel's EdgeDelayMs / EdgeWidth), has a pin ([Filters]
  Pinned) and a lock ("Lock filters": the filters stay for the next
  images).

  Owns
  ----
  - FBitmap: the panel as a picture (with alpha), redrawn when something
    changes; FVersion counts the redraws (the GPU renderer uploads it
    again then).
  - A copy of the filter values, for drawing (TMView owns the real
    ones), the hover state, the drag in progress, the edge timer.

  Knows
  -----
  Nothing else (uFilters for names, ranges and bar positions).

  Responsibilities
  ----------------
  - Layout for the view's size: about 230 px wide (scaled for the
    screen's DPI), rows between 34 and 22 px high, as tall as its rows.
  - Step 2: a histogram under the header (of the image, or of the
    edit-mode selection) with the black / white points marked; an Auto
    button next to Reset all (lit while Auto is on for every image).
  - Draw: dark translucent background; per filter its name, its value
    and a bar with a mark at the neutral value, the part away from
    neutral lit; Invert as an on / off box; "Reset all"; the lock and
    the pin in the header; a hint line at the bottom.
  - Hit test; the drag along a row (relative: the value moves with the
    mouse, a click alone changes nothing; it snaps to neutral when
    passing it).
  - Edge opening and closing, as the sort panel (uSortPanel), at the
    left edge.

  Does NOT
  --------
  - Change the filters itself: TMView asks (HitTest, DragTo) and sets
    them (SetFilters).
  - Show itself: the renderers draw Bitmap at (Left, Top).

  Threads
  -------
  UI thread only.

  Uses (MView units)
  ------------------
  interface:      uFilters
  Libraries:      Classes, SysUtils, Math, Types, Graphics, BGRABitmap,
                  BGRABitmapTypes

  Used by
  -------
  uMView
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  Types,
  Graphics,
  BGRABitmap,
  BGRABitmapTypes,
  uFilters;

type

  TFilterPart = (fpNone, fpPanel, fpRow, fpAuto, fpReset, fpLock, fpPin);

  TFilterHit = record
    Part: TFilterPart;
    Kind: TFilterKind;    { fpRow: the filter }
  end;

  TFilterPanel = class(TObject)
  private
    FBitmap: TBGRABitmap;
    FVersion: Cardinal;
    FDirty: Boolean;
    FVisible: Boolean;
    FPinned: Boolean;
    FLocked: Boolean;
    FAvailable: Boolean;
    FScale: Double;
    FFilters: TFilterSettings;

    FViewW, FViewH: Integer;
    FWidth, FHeight: Integer;
    FHeaderH, FFooterH, FRowH: Integer;
    FHistH: Integer;             { the histogram below the header }
    FHist: THistogram;
    FHistValid: Boolean;
    FHistROI: Boolean;           { of the selection, not the whole image }
    FAutoOn: Boolean;            { Auto for every image (double-click) }
    FHover: TFilterHit;

    FDragging: Boolean;
    FDragKind: TFilterKind;
    FDragStartX: Integer;
    FDragStartPos: Double;

    FEdgeDelayMs: Integer;
    FEdgeWidth: Integer;         { px at 96 dpi }
    FEdgeSinceMs: Double;
    FAwaySinceMs: Double;
    FMouseX, FMouseY: Integer;
    FButtonDown: Boolean;
    FHold: Boolean;              { opened by a command: stays until the mouse has been on it }

    function RowRect(ARow: Integer): TRect;
    function BarRect(const ARow: TRect): TRect;
    function PinRect: TRect;
    function LockRect: TRect;
    function FooterRect: TRect;
    procedure Redraw;
    procedure DrawRow(AKind: TFilterKind; const R: TRect);
    procedure SetPinned(AValue: Boolean);
    procedure SetLocked(AValue: Boolean);
    procedure SetAvailable(AValue: Boolean);
    procedure SetAutoOn(AValue: Boolean);
    procedure DrawHistogram;
  public
    constructor Create;
    destructor Destroy; override;

    { The view's size and the screen's scale (PixelsPerInch / 96). }
    procedure SetViewSize(AWidth, AHeight: Integer; AScale: Double);
    { The values shown (TMView's). }
    procedure SetFilters(const AFilters: TFilterSettings);
    { The histogram of the image (unfiltered) or of the selection (AROI);
      AValid False: none (drawn empty). }
    procedure SetHistogram(const AHist: THistogram; AValid, AROI: Boolean);

    { AHold: opened by the menu, not at the edge: an unpinned panel stays
      until the mouse has been on it (and then left). }
    procedure Show(AHold: Boolean = False);
    procedure Hide;

    function HitTest(AX, AY: Integer): TFilterHit;
    function Contains(AX, AY: Integer): Boolean;
    { Every mouse move: hover and the edge timer. True if the picture
      changed. }
    function NoteMouse(AX, AY: Integer; AButtonDown: Boolean; ANowMs: Double): Boolean;
    { Edge opening and closing; True if the picture changed. }
    function Tick(ANowMs: Double): Boolean;
    { The mouse left the window (or the focus went). }
    procedure MouseGone(ANowMs: Double);

    { A drag along AKind's row starts at AX (screen x). DragTo: the value
      for the mouse at AX, into AFilters; True if it changed. }
    procedure BeginDrag(AKind: TFilterKind; AX: Integer);
    function DragTo(AX: Integer; var AFilters: TFilterSettings): Boolean;
    procedure EndDrag;
    property Dragging: Boolean read FDragging;

    { The picture, up to date; nil while hidden. }
    function Bitmap: TBGRABitmap;
    function Left: Integer;
    function Top: Integer;

    property Visible: Boolean read FVisible;
    property Pinned: Boolean read FPinned write SetPinned;
    { "Lock filters" is on: shown in the header. }
    property Locked: Boolean read FLocked write SetLocked;
    { False: the renderer can't show filters (said at the bottom). }
    property Available: Boolean read FAvailable write SetAvailable;
    { Auto for every image is on: the Auto button is lit. }
    property AutoOn: Boolean read FAutoOn write SetAutoOn;
    property Version: Cardinal read FVersion;
    property EdgeDelayMs: Integer read FEdgeDelayMs write FEdgeDelayMs;
    property EdgeWidth: Integer read FEdgeWidth write FEdgeWidth;
  end;

const
  { The rows, top to bottom: the order the filters work in. }
  FilterRowCount = Ord(High(TFilterKind)) + 1;

implementation

const
  CloseDelayMs = 600;      { unpinned: mouse away this long closes the panel }
  SnapPos = 0.006;         { drag: this close to neutral (of the bar) snaps;
                             less than a wheel step, so small values stay reachable }

function ScaleI(AValue: Integer; AScale: Double): Integer;
begin
  Result := Max(1, Round(AValue * AScale));
end;

{ TFilterPanel }

constructor TFilterPanel.Create;
begin
  inherited Create;
  FScale := 1;
  FEdgeDelayMs := 500;
  FEdgeWidth := 12;
  FAvailable := True;
  FFilters := NeutralFilters;
  FHover.Part := fpNone;
  FDirty := True;
end;

destructor TFilterPanel.Destroy;
begin
  FBitmap.Free;
  inherited Destroy;
end;

procedure TFilterPanel.SetViewSize(AWidth, AHeight: Integer; AScale: Double);
var
  Avail: Integer;
begin
  if AScale <= 0 then
    AScale := 1;
  FViewW := Max(0, AWidth);
  FViewH := Max(0, AHeight);
  FScale := AScale;
  FWidth := Min(ScaleI(230, FScale), Max(ScaleI(120, FScale), FViewW div 2));
  FHeaderH := ScaleI(26, FScale);
  FHistH := ScaleI(46, FScale);
  FFooterH := ScaleI(36, FScale);
  { The filters and the Auto / Reset all row. }
  Avail := Max(0, FViewH - FHeaderH - FHistH - FFooterH);
  FRowH := EnsureRange(Avail div (FilterRowCount + 1), ScaleI(22, FScale), ScaleI(34, FScale));
  FHeight := Min(FViewH, FHeaderH + FHistH + (FilterRowCount + 1) * FRowH + FFooterH);
  FDirty := True;
end;

procedure TFilterPanel.SetFilters(const AFilters: TFilterSettings);
begin
  if SameFilters(AFilters, FFilters) then
    Exit;
  FFilters := AFilters;
  FDirty := True;
end;

procedure TFilterPanel.SetHistogram(const AHist: THistogram; AValid, AROI: Boolean);
begin
  FHist := AHist;
  FHistValid := AValid;
  FHistROI := AROI;
  FDirty := True;
end;

procedure TFilterPanel.SetAutoOn(AValue: Boolean);
begin
  if FAutoOn = AValue then
    Exit;
  FAutoOn := AValue;
  FDirty := True;
end;

procedure TFilterPanel.Show(AHold: Boolean);
begin
  FHold := AHold;
  FAwaySinceMs := 0;
  if FVisible then
    Exit;
  FVisible := True;
  FDirty := True;
end;

procedure TFilterPanel.Hide;
begin
  if not FVisible then
    Exit;
  FVisible := False;
  FDirty := True;
  FEdgeSinceMs := 0;
  FHover.Part := fpNone;
  FDragging := False;
end;

procedure TFilterPanel.SetPinned(AValue: Boolean);
begin
  if FPinned = AValue then
    Exit;
  FPinned := AValue;
  FDirty := True;
end;

procedure TFilterPanel.SetLocked(AValue: Boolean);
begin
  if FLocked = AValue then
    Exit;
  FLocked := AValue;
  FDirty := True;
end;

procedure TFilterPanel.SetAvailable(AValue: Boolean);
begin
  if FAvailable = AValue then
    Exit;
  FAvailable := AValue;
  FDirty := True;
end;

function TFilterPanel.Left: Integer;
begin
  Result := 0;
end;

function TFilterPanel.Top: Integer;
begin
  Result := 0;
end;

{ Panel coordinates. Rows 0 .. FilterRowCount - 1: the filters;
  FilterRowCount: Auto (left half) and Reset all (right half). }
function TFilterPanel.RowRect(ARow: Integer): TRect;
var
  Y: Integer;
begin
  Y := FHeaderH + FHistH + ARow * FRowH;
  Result := Rect(0, Y, FWidth, Y + FRowH);
end;

{ The bar in a filter's row: its lower part. }
function TFilterPanel.BarRect(const ARow: TRect): TRect;
var
  Pad, Mid: Integer;
begin
  Pad := ScaleI(10, FScale);
  Mid := ARow.Top + ARow.Height * 72 div 100;
  Result := Rect(ARow.Left + Pad, Mid - ScaleI(4, FScale), ARow.Right - Pad,
    Mid + ScaleI(4, FScale));
end;

function TFilterPanel.PinRect: TRect;
begin
  { At the left border, where the mouse comes from (user, Day 22). }
  Result := Rect(0, 0, FHeaderH, FHeaderH);
end;

function TFilterPanel.LockRect: TRect;
begin
  Result := Rect(FHeaderH, 0, 2 * FHeaderH, FHeaderH);
end;

function TFilterPanel.FooterRect: TRect;
begin
  Result := Rect(0, FHeight - FFooterH, FWidth, FHeight);
end;

function TFilterPanel.Contains(AX, AY: Integer): Boolean;
begin
  Result := FVisible and (AX >= Left) and (AX < Left + FWidth) and (AY >= Top)
    and (AY < Top + FHeight);
end;

function TFilterPanel.HitTest(AX, AY: Integer): TFilterHit;
var
  PX, PY, Row: Integer;
  R: TRect;
begin
  Result.Part := fpNone;
  Result.Kind := fkBlack;
  if not Contains(AX, AY) then
    Exit;
  PX := AX - Left;
  PY := AY - Top;
  Result.Part := fpPanel;
  if PtInRect(PinRect, Point(PX, PY)) then
  begin
    Result.Part := fpPin;
    Exit;
  end;
  if PtInRect(LockRect, Point(PX, PY)) then
  begin
    Result.Part := fpLock;
    Exit;
  end;
  if (PY < FHeaderH + FHistH) or (FRowH <= 0) then
    Exit;
  Row := (PY - FHeaderH - FHistH) div FRowH;
  R := RowRect(Row);
  if R.Bottom > FHeight - FFooterH then
    Exit;
  if Row < FilterRowCount then
  begin
    Result.Part := fpRow;
    Result.Kind := TFilterKind(Row);
  end
  else if Row = FilterRowCount then
  begin
    if PX < FWidth div 2 then
      Result.Part := fpAuto
    else
      Result.Part := fpReset;
  end;
end;

function TFilterPanel.NoteMouse(AX, AY: Integer; AButtonDown: Boolean; ANowMs: Double): Boolean;
var
  Hit: TFilterHit;
begin
  Result := False;
  FMouseX := AX;
  FMouseY := AY;
  FButtonDown := AButtonDown;

  if FVisible then
  begin
    Hit := HitTest(AX, AY);
    { While dragging, the row being dragged stays lit. }
    if FDragging then
    begin
      Hit.Part := fpRow;
      Hit.Kind := FDragKind;
    end;
    if (Hit.Part <> FHover.Part) or (Hit.Kind <> FHover.Kind) then
    begin
      FHover := Hit;
      FDirty := True;
      Result := True;
    end;
    if Hit.Part <> fpNone then
      FHold := False;
    if (Hit.Part = fpNone) and not FHold then
    begin
      if FAwaySinceMs = 0 then
        FAwaySinceMs := ANowMs;
    end
    else
      FAwaySinceMs := 0;
  end
  else
  begin
    { The edge timer: resting at the left edge, no button down. }
    if (not AButtonDown) and (FEdgeDelayMs > 0) and (FViewW > 0)
      and (AX >= 0) and (AX < ScaleI(FEdgeWidth, FScale)) then
    begin
      if FEdgeSinceMs = 0 then
        FEdgeSinceMs := ANowMs;
    end
    else
      FEdgeSinceMs := 0;
  end;
end;

function TFilterPanel.Tick(ANowMs: Double): Boolean;
begin
  Result := False;
  if not FVisible then
  begin
    if (FEdgeSinceMs > 0) and (not FButtonDown) and (ANowMs - FEdgeSinceMs >= FEdgeDelayMs) then
    begin
      FEdgeSinceMs := 0;
      Show;
      FHover := HitTest(FMouseX, FMouseY);
      Result := True;
    end;
  end
  else if (not FPinned) and (not FDragging) and (FAwaySinceMs > 0)
    and (ANowMs - FAwaySinceMs >= CloseDelayMs) then
  begin
    Hide;
    Result := True;
  end;
end;

procedure TFilterPanel.MouseGone(ANowMs: Double);
begin
  FEdgeSinceMs := 0;
  if FVisible and (not FHold) and (FAwaySinceMs = 0) then
    FAwaySinceMs := ANowMs;
  if FVisible and (FHover.Part <> fpNone) and not FDragging then
  begin
    FHover.Part := fpNone;
    FDirty := True;
  end;
end;

procedure TFilterPanel.BeginDrag(AKind: TFilterKind; AX: Integer);
begin
  if IsToggleFilter(AKind) then
    Exit;
  FDragging := True;
  FDragKind := AKind;
  FDragStartX := AX;
  FDragStartPos := FilterBarPos(AKind, GetFilter(FFilters, AKind));
end;

function TFilterPanel.DragTo(AX: Integer; var AFilters: TFilterSettings): Boolean;
var
  Bar: TRect;
  Pos, NeutralPos: Double;
  Before: TFilterSettings;
begin
  Result := False;
  if not FDragging then
    Exit;
  Bar := BarRect(RowRect(Ord(FDragKind)));
  { Not moved (a click): the value stays exactly as it is. }
  if (Bar.Width <= 0) or (AX = FDragStartX) then
    Exit;
  Pos := EnsureRange(FDragStartPos + (AX - FDragStartX) / Bar.Width, 0, 1);
  NeutralPos := FilterBarPos(FDragKind, FilterNeutral(FDragKind));
  if Abs(Pos - NeutralPos) < SnapPos then
    Pos := NeutralPos;
  Before := AFilters;
  if Pos = NeutralPos then
    SetFilter(AFilters, FDragKind, FilterNeutral(FDragKind))
  else
    SetFilter(AFilters, FDragKind, FilterValueAt(FDragKind, Pos));
  Result := not SameFilters(Before, AFilters);
end;

procedure TFilterPanel.EndDrag;
begin
  if not FDragging then
    Exit;
  FDragging := False;
  FDirty := True;
end;

function TFilterPanel.Bitmap: TBGRABitmap;
begin
  if not FVisible then
    Exit(nil);
  if FDirty or (FBitmap = nil) then
    Redraw;
  Result := FBitmap;
end;

procedure TFilterPanel.DrawRow(AKind: TFilterKind; const R: TRect);
var
  Pad, TextY, X0, X1, XN, XV, BoxS: Integer;
  Bar, Box: TRect;
  Value, Neutral: Double;
  Changed, Hot: Boolean;
  Lit, Text, Dim, Track: TBGRAPixel;
  Line: string;
begin
  Pad := ScaleI(10, FScale);
  Text := BGRA(235, 235, 235, 255);
  Dim := BGRA(160, 160, 160, 255);
  Lit := BGRA(255, 190, 60, 255);
  Track := BGRA(255, 255, 255, 70);
  Value := GetFilter(FFilters, AKind);
  Neutral := FilterNeutral(AKind);
  Changed := Abs(Value - Neutral) > 1e-6;
  Hot := (FHover.Part = fpRow) and (FHover.Kind = AKind);
  if Hot then
    FBitmap.FillRect(R, BGRA(255, 255, 255, 30), dmDrawWithTransparency);

  FBitmap.FontHeight := Max(9, Min(ScaleI(13, FScale), R.Height * 2 div 5));
  if IsToggleFilter(AKind) then
  begin
    { A box, filled when on. }
    TextY := R.Top + (R.Height - FBitmap.TextSize('Xg').cy) div 2;
    FBitmap.TextOut(Pad, TextY, FilterName(AKind), Text);
    BoxS := Max(8, R.Height div 2);
    Box := Rect(R.Right - Pad - BoxS, R.Top + (R.Height - BoxS) div 2, R.Right - Pad,
      R.Top + (R.Height - BoxS) div 2 + BoxS);
    if Changed then
      FBitmap.FillRoundRectAntialias(Box.Left, Box.Top, Box.Right, Box.Bottom, 3, 3, Lit)
    else
      FBitmap.RoundRectAntialias(Box.Left + 0.5, Box.Top + 0.5, Box.Right - 0.5,
        Box.Bottom - 0.5, 3, 3, Dim, Max(1, FScale));
    Line := FilterText(FFilters, AKind);
    if Changed then
      FBitmap.TextOut(Box.Left - Pad div 2 - FBitmap.TextSize(Line).cx, TextY, Line, Lit)
    else
      FBitmap.TextOut(Box.Left - Pad div 2 - FBitmap.TextSize(Line).cx, TextY, Line, Dim);
    Exit;
  end;

  { Name left, value right, in the upper part. }
  TextY := R.Top + Max(1, R.Height * 6 div 100);
  FBitmap.TextOut(Pad, TextY, FilterName(AKind), Text);
  Line := FilterText(FFilters, AKind);
  if Changed then
    FBitmap.TextOut(R.Right - Pad - FBitmap.TextSize(Line).cx, TextY, Line, Lit)
  else
    FBitmap.TextOut(R.Right - Pad - FBitmap.TextSize(Line).cx, TextY, Line, Dim);

  { The bar: a track, a tick at neutral, lit from neutral to the value,
    a knob at the value. }
  Bar := BarRect(R);
  X0 := Bar.Left;
  X1 := Bar.Right;
  XN := X0 + Round(FilterBarPos(AKind, Neutral) * (X1 - X0));
  XV := X0 + Round(FilterBarPos(AKind, Value) * (X1 - X0));
  FBitmap.FillRect(X0, (Bar.Top + Bar.Bottom) div 2 - 1, X1, (Bar.Top + Bar.Bottom) div 2 + 1,
    Track, dmDrawWithTransparency);
  FBitmap.FillRect(XN, Bar.Top + 1, XN + 1, Bar.Bottom - 1, BGRA(255, 255, 255, 120),
    dmDrawWithTransparency);
  if Changed then
    FBitmap.FillRect(Min(XN, XV), (Bar.Top + Bar.Bottom) div 2 - 1, Max(XN, XV) + 1,
      (Bar.Top + Bar.Bottom) div 2 + 2, Lit, dmDrawWithTransparency);
  if Changed then
    FBitmap.FillEllipseAntialias(XV + 0.5, (Bar.Top + Bar.Bottom) / 2,
      Bar.Height / 2 + 0.5, Bar.Height / 2 + 0.5, Lit)
  else if Hot then
    FBitmap.FillEllipseAntialias(XV + 0.5, (Bar.Top + Bar.Bottom) / 2,
      Bar.Height / 2 + 0.5, Bar.Height / 2 + 0.5, Text);
end;

{ The histogram (luma, square-root scale so the small counts show), the
  range outside the black / white points shaded, the points marked. }
procedure TFilterPanel.DrawHistogram;
var
  Pad, X0, X1, Y0, Y1, I, X, XB, XW, H: Integer;
  MaxCount: Int64;
  Scale: Double;
  Lit: TBGRAPixel;
begin
  Pad := ScaleI(10, FScale);
  X0 := Pad;
  X1 := FWidth - Pad;
  Y0 := FHeaderH + ScaleI(3, FScale);
  Y1 := FHeaderH + FHistH - ScaleI(6, FScale);
  if (X1 - X0 < 16) or (Y1 - Y0 < 8) then
    Exit;
  Lit := BGRA(255, 190, 60, 255);
  FBitmap.FillRect(X0, Y0, X1, Y1, BGRA(0, 0, 0, 90), dmDrawWithTransparency);
  if FHistValid then
  begin
    { The largest bin, not counting pure black and pure white (often a
      huge background that would flatten everything else). }
    MaxCount := 1;
    for I := 1 to 254 do
      if FHist[I] > MaxCount then
        MaxCount := FHist[I];
    Scale := (Y1 - Y0 - 2) / Sqrt(MaxCount);
    for X := X0 to X1 - 1 do
    begin
      I := EnsureRange((X - X0) * 256 div (X1 - X0), 0, 255);
      H := Min(Y1 - Y0 - 2, Integer(Round(Sqrt(FHist[I]) * Scale)));
      if H > 0 then
        FBitmap.FillRect(X, Y1 - 1 - H, X + 1, Y1 - 1, BGRA(200, 200, 200, 200),
          dmDrawWithTransparency);
    end;
  end;
  XB := X0 + Round(FFilters.Black * (X1 - X0));
  XW := X0 + Round(FFilters.White * (X1 - X0));
  if XB > X0 then
    FBitmap.FillRect(X0, Y0, XB, Y1, BGRA(0, 0, 0, 120), dmDrawWithTransparency);
  if XW < X1 then
    FBitmap.FillRect(XW, Y0, X1, Y1, BGRA(0, 0, 0, 120), dmDrawWithTransparency);
  FBitmap.FillRect(Max(X0, XB - 1), Y0, Max(X0, XB - 1) + 2, Y1, Lit, dmDrawWithTransparency);
  FBitmap.FillRect(Min(X1, XW) - 1, Y0, Min(X1, XW) + 1, Y1, Lit, dmDrawWithTransparency);
  if FHistROI and FHistValid then
  begin
    FBitmap.FontHeight := ScaleI(10, FScale);
    FBitmap.TextOut(X0 + 3, Y0 + 1, 'selection', BGRA(255, 190, 60, 220));
  end;
end;

procedure TFilterPanel.Redraw;
var
  Pad, Row, CX, I, Y: Integer;
  R, P: TRect;
  Col, Text, Dim, Lit: TBGRAPixel;
  Line: string;
  Lines: TStringList;
begin
  FDirty := False;
  Inc(FVersion);
  if (FWidth <= 0) or (FHeight <= 0) then
    Exit;
  if FBitmap = nil then
    FBitmap := TBGRABitmap.Create(FWidth, FHeight)
  else
    FBitmap.SetSize(FWidth, FHeight);
  FBitmap.FontQuality := fqSystem;       { transparent background: no ClearType }
  FBitmap.Fill(BGRA(12, 12, 16, 205));
  { A thin line on the right: where the panel ends. }
  FBitmap.DrawLine(FWidth - 1, 0, FWidth - 1, FHeight - 1, BGRA(255, 255, 255, 60), False);
  FBitmap.DrawLine(0, FHeight - 1, FWidth - 1, FHeight - 1, BGRA(255, 255, 255, 60), False);

  Text := BGRA(235, 235, 235, 255);
  Dim := BGRA(160, 160, 160, 255);
  Lit := BGRA(255, 190, 60, 255);
  Pad := ScaleI(10, FScale);

  { Header: title (and "locked"), the lock, the pin. }
  FBitmap.FontHeight := ScaleI(15, FScale);
  { Pin and lock on the left, then the title. }
  CX := 2 * FHeaderH + Pad div 2;
  FBitmap.TextOut(CX, (FHeaderH - FBitmap.TextSize('Filters').cy) div 2, 'Filters', Dim);
  if FLocked then
  begin
    CX := CX + FBitmap.TextSize('Filters').cx + Pad;
    FBitmap.FontHeight := ScaleI(12, FScale);
    FBitmap.TextOut(CX, (FHeaderH - FBitmap.TextSize('locked').cy) div 2, 'locked', Lit);
  end;
  { The lock: a shackle and a body; lit when locked (drawn open when not). }
  P := LockRect;
  if FHover.Part = fpLock then
    FBitmap.FillRect(P, BGRA(255, 255, 255, 40), dmDrawWithTransparency);
  if FLocked then
    Col := Lit
  else
    Col := BGRA(150, 150, 150, 255);
  CX := (P.Left + P.Right) div 2;
  if FLocked then
    FBitmap.EllipseAntialias(CX, P.Top + P.Height * 0.42, P.Height * 0.16, P.Height * 0.18,
      Col, Max(1, FScale * 1.5))
  else
    FBitmap.EllipseAntialias(CX + P.Height * 0.12, P.Top + P.Height * 0.34, P.Height * 0.16,
      P.Height * 0.18, Col, Max(1, FScale * 1.5));
  FBitmap.FillRoundRectAntialias(CX - P.Height * 0.24, P.Top + P.Height * 0.46,
    CX + P.Height * 0.24, P.Top + P.Height * 0.8, 2, 2, Col);
  { The pin: a head and a needle; lit when pinned. }
  P := PinRect;
  if FHover.Part = fpPin then
    FBitmap.FillRect(P, BGRA(255, 255, 255, 40), dmDrawWithTransparency);
  if FPinned then
    Col := BGRA(255, 200, 60, 255)
  else
    Col := BGRA(150, 150, 150, 255);
  FBitmap.FillEllipseAntialias((P.Left + P.Right) / 2, P.Top + P.Height * 0.38,
    P.Height * 0.18, P.Height * 0.18, Col);
  FBitmap.DrawLineAntialias((P.Left + P.Right) / 2, P.Top + P.Height * 0.5,
    (P.Left + P.Right) / 2, P.Top + P.Height * 0.85, Col, Max(1, FScale * 1.5));

  { The filters. }
  for Row := 0 to FilterRowCount - 1 do
  begin
    R := RowRect(Row);
    if R.Bottom > FHeight - FFooterH then
      Break;
    DrawRow(TFilterKind(Row), R);
  end;

  { The histogram, under the header. }
  DrawHistogram;

  { Auto (left half; lit while it is on for every image) and Reset all. }
  R := RowRect(FilterRowCount);
  if R.Bottom <= FHeight - FFooterH then
  begin
    FBitmap.DrawLine(Pad, R.Top, FWidth - Pad, R.Top, BGRA(255, 255, 255, 40), False);
    FBitmap.DrawLine(FWidth div 2, R.Top + 4, FWidth div 2, R.Bottom - 4,
      BGRA(255, 255, 255, 40), False);
    FBitmap.FontHeight := Max(9, Min(ScaleI(13, FScale), R.Height * 2 div 5));
    P := Rect(0, R.Top, FWidth div 2, R.Bottom);
    if FAutoOn then
      FBitmap.FillRect(P.Left + 3, P.Top + 3, P.Right - 3, P.Bottom - 3, BGRA(255, 190, 60, 70),
        dmDrawWithTransparency);
    if FHover.Part = fpAuto then
      FBitmap.FillRect(P, BGRA(255, 255, 255, 38), dmDrawWithTransparency);
    if FAutoOn then
    begin
      Line := 'Auto  (on)';
      Col := Lit;
    end
    else
    begin
      Line := 'Auto';
      Col := Text;
    end;
    FBitmap.TextOut(P.Left + (P.Width - FBitmap.TextSize(Line).cx) div 2,
      R.Top + (R.Height - FBitmap.TextSize(Line).cy) div 2, Line, Col);
    P := Rect(FWidth div 2, R.Top, FWidth, R.Bottom);
    if FHover.Part = fpReset then
      FBitmap.FillRect(P, BGRA(255, 255, 255, 38), dmDrawWithTransparency);
    Line := 'Reset all';
    if FiltersNeutral(FFilters) then
      Col := BGRA(110, 110, 110, 255)
    else
      Col := Text;
    FBitmap.TextOut(P.Left + (P.Width - FBitmap.TextSize(Line).cx) div 2,
      R.Top + (R.Height - FBitmap.TextSize(Line).cy) div 2, Line, Col);
  end;

  { Footer: what the part under the mouse does. }
  R := FooterRect;
  FBitmap.DrawLine(0, R.Top, FWidth - 1, R.Top, BGRA(255, 255, 255, 50), False);
  if not FAvailable then
    Line := 'this graphics driver can''t' + LineEnding + 'show filters'
  else
    case FHover.Part of
      fpRow:
        if FHover.Kind = fkMirror then
          Line := 'click: on / off' + LineEnding + 'left and right swapped'
        else if FHover.Kind = fkInvert then
          Line := 'click: on / off'
        else
          Line := 'wheel: step    drag: adjust' + LineEnding + 'double-click: reset';
      fpReset:
        Line := 'all filters back to neutral';
      fpAuto:
        if FAutoOn then
          Line := 'on for every image' + LineEnding + 'click: again now   double-click: off'
        else
          Line := 'click: black / white point now' + LineEnding + 'double-click: for every image';
      fpLock:
        Line := 'lock: keep the filters' + LineEnding + 'for the next images';
      fpPin:
        Line := 'pin: stay open';
    else
      if (FHover.Part = fpPanel) and FHistValid then
      begin
        if FHistROI then
          Line := 'histogram of the selection'
        else
          Line := 'histogram of the image';
        Line := Line + LineEnding + 'marks: black / white point';
      end
      else if FLocked then
        Line := 'locked: kept for the next images'
      else
        Line := 'display only; the next image' + LineEnding + 'starts unfiltered (unless locked)';
    end;
  FBitmap.FontHeight := ScaleI(11, FScale);
  Lines := TStringList.Create;
  try
    Lines.Text := Line;
    Y := R.Top + 3;
    for I := 0 to Min(Lines.Count - 1, 1) do
    begin
      FBitmap.TextOut(Pad, Y, Lines[I], Dim);
      Inc(Y, FBitmap.TextSize('Xg').cy);
    end;
  finally
    Lines.Free;
  end;
end;

end.
