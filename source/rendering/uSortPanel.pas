unit uSortPanel;

{
  Unit: uSortPanel

  Purpose
  -------
  The sort panel (Phase G, G1): a slim column at the right edge of the
  view with one button per sort folder. Left click on a button = copy
  the image there, right click = move it. It opens when the mouse rests
  at the right edge (EdgeDelayMs), has a pin, a "+" to add a folder, a
  small "..." corner per button (the folder menu), and a bottom line
  with the last action (click = undo) or, while the mouse rests on a
  button, that button's full folder.

  Owns
  ----
  - FBitmap: the panel as a picture (BGRABitmap, with alpha), redrawn
    when something changes (FDirty); FVersion counts the redraws so the
    GPU renderer knows when to upload it again.
  - The layout (FRows: one rectangle per visible row), the hover state,
    the scroll offset, the edge timer.

  Knows
  -----
  - TSortFolders (the slots), handed in; read only here.

  Responsibilities
  ----------------
  - Layout for the view's size (elastic): as tall as the view, about
    160 px wide (scaled for the screen's DPI); each button between 36 and
    20 px high (scaled), as many as fit; more slots than fit at the
    minimum: the column scrolls with the wheel.
  - Draw: dark translucent background, per button a folder shape in the
    slot's colour with its number, the name (cut with "..." if long), the
    "..." corner; hover highlight; the pin (lit when pinned); the bottom
    line.
  - Confirmation (Day 21): a button with a copy / move under way has a
    frame in its colour; when the job is done the button lights up in
    its colour with a check mark and fades (0.9 s); red with a cross if
    it failed. Delete and undo flash the bottom line. Unpinned, the
    panel closes only after the flash (at most 3 s after the click);
    if it is closed already, a strip at the right edge flashes instead.
  - Icons (stage 2): a button shows its icon (OnSlotIcon, scaled to
    the button by the owner) with the number small in a corner, else the
    coloured folder; a folder that was not found (OnSlotMissing) is
    drawn grey and its bottom line says so.
  - Hit test: which part is at a point (button, its "..." corner, "+",
    pin, bottom line, empty panel, outside).
  - Edge opening: NoteMouse (every mouse move) and Tick (the viewer's
    50 ms timer) open the panel after the mouse has rested EdgeDelayMs at
    the right edge with no button down; unpinned, it closes again when
    the mouse has been away from it for CloseDelayMs.

  Does NOT
  --------
  - Copy, move or delete files, or change the slots (TMView does, from
    the hit test).
  - Show itself: the renderers draw Bitmap at (Left, Top) on top of
    everything (uRenderer, uGLRenderer).
  - Read the disk (no folder checks, no icon files yet: Stage 2).

  Threads
  -------
  UI thread only.

  Uses (MView units)
  ------------------
  interface:      uSortFolders
  Libraries:      Classes, SysUtils, Math, Types, Graphics, BGRABitmap,
                  BGRABitmapTypes, LazUTF8

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
  LazUTF8,
  uSortFolders;

type

  TPanelPart = (ppNone, ppPanel, ppSlot, ppSlotMenu, ppAdd, ppPin, ppFooter);

  TPanelHit = record
    Part: TPanelPart;
    Slot: Integer;      { ppSlot / ppSlotMenu: the slot; else -1 }
  end;

  { The icon of slot ASlot as an ASize x ASize picture; nil = draw the
    coloured folder. The picture stays the owner's. }
  TSlotIconEvent = function(ASlot, ASize: Integer): TBGRABitmap of object;
  { Slot ASlot's folder was not found (drawn greyed). }
  TSlotMissingEvent = function(ASlot: Integer): Boolean of object;

  TSortPanel = class(TObject)
  private
    FFolders: TSortFolders;
    FBitmap: TBGRABitmap;
    FVersion: Cardinal;
    FDirty: Boolean;
    FVisible: Boolean;
    FPinned: Boolean;
    FScale: Double;

    FViewW, FViewH: Integer;
    FWidth: Integer;
    FHeaderH, FFooterH, FRowH: Integer;
    FFirstRow: Integer;          { scroll: index of the first row shown }
    FRowsShown: Integer;
    FHover: TPanelHit;
    FFooterText: string;
    FBusy: Boolean;

    FEdgeDelayMs: Integer;
    FEdgeWidth: Integer;         { px at 96 dpi }
    FEdgeSinceMs: Double;        { mouse at the edge since; 0 = not }
    FAwaySinceMs: Double;        { mouse away from the open panel since; 0 = on it }
    FMouseX, FMouseY: Integer;
    FButtonDown: Boolean;
    FHold: Boolean;              { opened by a command: stays until the mouse has been on it }
    { Confirmation (Day 21, user: "a flash in the folder icon color"):
      the button of a finished copy / move lights up in its colour and
      fades (red with a cross if it failed); the bottom line for delete
      and undo. A button with a job under way has a frame. }
    FFlashSlot: Integer;         { -1 = the bottom line }
    FFlashOK: Boolean;
    FFlashStartMs: Double;       { 0 = no flash }
    FFlashLevel: Double;         { 1 .. 0 while it fades }
    FPending: array of Integer;  { per slot: jobs under way }
    FCloseWhenDone: Boolean;     { unpinned: close once the flash is over }
    FCloseDeadlineMs: Double;    { ... or at the latest then }
    FStrip: TBGRABitmap;         { the flash as a strip at the edge, panel closed }
    FOnSlotIcon: TSlotIconEvent;
    FOnSlotMissing: TSlotMissingEvent;
    function SlotMissing(ASlot: Integer): Boolean;
    procedure DrawBadge(X, Y, W, H: Integer; const ANumber: string);
    function FlashColor: TBGRAPixel;
    function StripMode: Boolean;
    procedure RedrawStrip;
    procedure DrawMark(const R: TRect; AOK: Boolean; AAlpha: Byte);

    function RowCount: Integer;  { slots + the "+" row }
    function RowRect(ARow: Integer): TRect;
    function MenuRect(const ARow: TRect): TRect;
    function PinRect: TRect;
    function FooterRect: TRect;
    procedure Redraw;
    procedure DrawFolder(X, Y, W, H: Integer; AColor: TBGRAPixel; const ANumber: string);
    procedure SetPinned(AValue: Boolean);
    procedure SetFooterText(const AValue: string);
    procedure SetBusy(AValue: Boolean);
  public
    constructor Create(AFolders: TSortFolders);
    destructor Destroy; override;

    { The view's size in pixels and the screen's scale (PixelsPerInch /
      96). Call when the view is resized; the layout follows. }
    procedure SetViewSize(AWidth, AHeight: Integer; AScale: Double);
    { The slots changed (a folder, colour or order): redraw. }
    procedure Changed;

    { AHold: opened by the menu or a key, not at the edge: an unpinned
      panel stays open until the mouse has been on it (and then left). }
    procedure Show(AHold: Boolean = False);
    procedure Hide;

    function HitTest(AX, AY: Integer): TPanelHit;
    function Contains(AX, AY: Integer): Boolean;
    { Mouse position (every move), for hover and the edge timer. True
      if the picture changed (hover). }
    function NoteMouse(AX, AY: Integer; AButtonDown: Boolean; ANowMs: Double): Boolean;
    { The wheel over the panel: scroll. True if it scrolled. }
    function Scroll(ANotches: Integer): Boolean;
    { Edge opening and closing, the flash's fading; True if the picture
      changed (call Bitmap again). }
    function Tick(ANowMs: Double): Boolean;

    { A copy / move into ASlot was queued (-1: delete, undo): the button
      gets a frame until it is done. }
    procedure JobStarted(ASlot: Integer);
    { It is done: the button flashes (in its colour, or red if AOK is
      False). With the panel closed, a strip at the right edge flashes. }
    procedure JobDone(ASlot: Integer; AOK: Boolean; ANowMs: Double);
    { Just the flash (e.g. red for "already in that folder"). }
    procedure Flash(ASlot: Integer; AOK: Boolean; ANowMs: Double);
    { Unpinned: close after this action, once its flash has been seen
      (at most CloseWaitMs). Pinned: nothing. }
    procedure CloseAfterAction(ANowMs: Double);
    { The mouse left the window, or the window lost the focus: an
      unpinned panel closes as when the mouse leaves it. }
    procedure MouseGone(ANowMs: Double);

    { The picture, up to date; nil while hidden (except while a flash
      shows as a strip at the edge: then that, at Left / Top). }
    function Bitmap: TBGRABitmap;
    function Left: Integer;
    function Top: Integer;

    property Visible: Boolean read FVisible;
    property Pinned: Boolean read FPinned write SetPinned;
    property Version: Cardinal read FVersion;
    property EdgeDelayMs: Integer read FEdgeDelayMs write FEdgeDelayMs;
    { How close to the right edge counts as "at the edge" (px at 96 dpi,
      scaled). }
    property EdgeWidth: Integer read FEdgeWidth write FEdgeWidth;
    { The bottom line when no button is hovered: the last action. }
    property FooterText: string read FFooterText write SetFooterText;
    { A copy / move is running: shown in the header. }
    property Busy: Boolean read FBusy write SetBusy;
    { Stage 2: icons and missing folders, asked for while drawing. }
    property OnSlotIcon: TSlotIconEvent read FOnSlotIcon write FOnSlotIcon;
    property OnSlotMissing: TSlotMissingEvent read FOnSlotMissing write FOnSlotMissing;
  end;

implementation

const
  CloseDelayMs = 600;      { unpinned: mouse away this long closes the panel }
  FlashMs = 900;           { the confirmation flash: full for FlashHoldMs, then fading }
  FlashHoldMs = 200;
  CloseWaitMs = 3000;      { unpinned: closes at the latest this long after an action }
  StripPx = 8;             { the flash strip with the panel closed (scaled) }

function ScaleI(AValue: Integer; AScale: Double): Integer;
begin
  Result := Max(1, Round(AValue * AScale));
end;

{ TSortPanel }

constructor TSortPanel.Create(AFolders: TSortFolders);
begin
  inherited Create;
  FFolders := AFolders;
  FScale := 1;
  FEdgeDelayMs := 500;
  FEdgeWidth := 12;
  FHover.Part := ppNone;
  FHover.Slot := -1;
  FFlashSlot := -1;
  FDirty := True;
end;

destructor TSortPanel.Destroy;
begin
  FStrip.Free;
  FBitmap.Free;
  inherited Destroy;
end;

function TSortPanel.RowCount: Integer;
begin
  Result := FFolders.Count + 1;
end;

procedure TSortPanel.SetViewSize(AWidth, AHeight: Integer; AScale: Double);
var
  Avail, MinH, MaxH: Integer;
begin
  if AScale <= 0 then
    AScale := 1;
  FViewW := Max(0, AWidth);
  FViewH := Max(0, AHeight);
  FScale := AScale;
  FWidth := Min(ScaleI(160, FScale), Max(ScaleI(60, FScale), FViewW div 2));
  FHeaderH := ScaleI(26, FScale);
  FFooterH := ScaleI(52, FScale);   { three short lines }
  MinH := ScaleI(20, FScale);
  MaxH := ScaleI(36, FScale);
  Avail := Max(0, FViewH - FHeaderH - FFooterH);
  { Elastic: as large as fits, within the limits. }
  if RowCount > 0 then
    FRowH := Avail div RowCount
  else
    FRowH := MaxH;
  FRowH := EnsureRange(FRowH, MinH, MaxH);
  FRowsShown := Max(1, Avail div FRowH);
  { More than fit: a line for the "1-12 of 20 (wheel)" hint. }
  if RowCount > FRowsShown then
    FRowsShown := Max(1, (Avail - ScaleI(16, FScale)) div FRowH);
  FFirstRow := EnsureRange(FFirstRow, 0, Max(0, RowCount - FRowsShown));
  FDirty := True;
end;

procedure TSortPanel.Changed;
begin
  { The row count may have changed: the same layout rules again. }
  SetViewSize(FViewW, FViewH, FScale);
end;

procedure TSortPanel.Show(AHold: Boolean);
begin
  FHold := AHold;
  if AHold then
    FCloseWhenDone := False;   { asked for: stays }
  FAwaySinceMs := 0;
  if FVisible then
    Exit;
  FVisible := True;
  FDirty := True;
end;

procedure TSortPanel.Hide;
begin
  FCloseWhenDone := False;
  if not FVisible then
    Exit;
  FVisible := False;
  FDirty := True;      { a new picture (the strip, or none): a new version }
  FEdgeSinceMs := 0;
  FHover.Part := ppNone;
  FHover.Slot := -1;
end;

procedure TSortPanel.SetPinned(AValue: Boolean);
begin
  if FPinned = AValue then
    Exit;
  FPinned := AValue;
  FDirty := True;
end;

procedure TSortPanel.SetFooterText(const AValue: string);
begin
  if FFooterText = AValue then
    Exit;
  FFooterText := AValue;
  FDirty := True;
end;

procedure TSortPanel.SetBusy(AValue: Boolean);
begin
  if FBusy = AValue then
    Exit;
  FBusy := AValue;
  FDirty := True;
end;

function TSortPanel.Left: Integer;
begin
  if StripMode then
    Result := FViewW - ScaleI(StripPx, FScale)
  else
    Result := FViewW - FWidth;
end;

function TSortPanel.Top: Integer;
begin
  Result := 0;
end;

{ Panel coordinates (0,0 = the panel's top left). }
function TSortPanel.RowRect(ARow: Integer): TRect;
var
  Y: Integer;
begin
  Y := FHeaderH + (ARow - FFirstRow) * FRowH;
  Result := Rect(0, Y, FWidth, Y + FRowH);
end;

function TSortPanel.MenuRect(const ARow: TRect): TRect;
var
  W: Integer;
begin
  W := Min(ScaleI(22, FScale), ARow.Height);
  Result := Rect(ARow.Right - W, ARow.Top, ARow.Right, ARow.Bottom);
end;

function TSortPanel.PinRect: TRect;
begin
  Result := Rect(FWidth - FHeaderH, 0, FWidth, FHeaderH);
end;

function TSortPanel.FooterRect: TRect;
begin
  Result := Rect(0, FViewH - FFooterH, FWidth, FViewH);
end;

function TSortPanel.Contains(AX, AY: Integer): Boolean;
begin
  Result := FVisible and (AX >= Left) and (AX < Left + FWidth) and (AY >= 0) and (AY < FViewH);
end;

function TSortPanel.HitTest(AX, AY: Integer): TPanelHit;
var
  PX, PY, Row: Integer;
  R: TRect;
begin
  Result.Part := ppNone;
  Result.Slot := -1;
  if not Contains(AX, AY) then
    Exit;
  PX := AX - Left;
  PY := AY - Top;
  Result.Part := ppPanel;
  if PtInRect(PinRect, Point(PX, PY)) then
  begin
    Result.Part := ppPin;
    Exit;
  end;
  if PtInRect(FooterRect, Point(PX, PY)) then
  begin
    Result.Part := ppFooter;
    Exit;
  end;
  if (PY < FHeaderH) or (FRowH <= 0) then
    Exit;
  Row := FFirstRow + (PY - FHeaderH) div FRowH;
  if (Row - FFirstRow >= FRowsShown) or (Row >= RowCount) then
    Exit;
  R := RowRect(Row);
  if R.Bottom > FViewH - FFooterH then
    Exit;
  if Row = FFolders.Count then
    Result.Part := ppAdd
  else
  begin
    Result.Slot := Row;
    if PtInRect(MenuRect(R), Point(PX, PY)) then
      Result.Part := ppSlotMenu
    else
      Result.Part := ppSlot;
  end;
end;

function TSortPanel.NoteMouse(AX, AY: Integer; AButtonDown: Boolean; ANowMs: Double): Boolean;
var
  Hit: TPanelHit;
begin
  Result := False;
  FMouseX := AX;
  FMouseY := AY;
  FButtonDown := AButtonDown;

  if FVisible then
  begin
    Hit := HitTest(AX, AY);
    if (Hit.Part <> FHover.Part) or (Hit.Slot <> FHover.Slot) then
    begin
      FHover := Hit;
      FDirty := True;
      Result := True;
    end;
    if Hit.Part <> ppNone then
      FHold := False;
    if (Hit.Part = ppNone) and not FHold then
    begin
      if FAwaySinceMs = 0 then
        FAwaySinceMs := ANowMs;
    end
    else
      FAwaySinceMs := 0;
  end
  else
  begin
    { The edge timer: only while resting there with no button down (a
      right-drag gesture ending at the edge doesn't open it). }
    if (not AButtonDown) and (FEdgeDelayMs > 0) and (FViewW > 0)
      and (AX >= FViewW - ScaleI(FEdgeWidth, FScale)) then
    begin
      if FEdgeSinceMs = 0 then
        FEdgeSinceMs := ANowMs;
    end
    else
      FEdgeSinceMs := 0;
  end;
end;

function TSortPanel.Tick(ANowMs: Double): Boolean;
var
  T: Double;
  AnyPending: Boolean;
  I: Integer;
begin
  Result := False;

  { The flash fades. }
  if FFlashStartMs > 0 then
  begin
    T := ANowMs - FFlashStartMs;
    if T >= FlashMs then
    begin
      FFlashStartMs := 0;
      FFlashLevel := 0;
    end
    else if T <= FlashHoldMs then
      FFlashLevel := 1
    else
      FFlashLevel := 1 - (T - FlashHoldMs) / (FlashMs - FlashHoldMs);
    FDirty := True;
    Result := True;
  end;

  { Unpinned, after an action: closes once its job is done and the
    flash has been seen (or after CloseWaitMs, a slow copy). }
  if FCloseWhenDone then
  begin
    AnyPending := False;
    for I := 0 to High(FPending) do
      if FPending[I] > 0 then
        AnyPending := True;
    if FPinned or not FVisible then
      FCloseWhenDone := False
    else if ((not AnyPending) and (FFlashStartMs = 0)) or (ANowMs >= FCloseDeadlineMs) then
    begin
      Hide;
      Exit(True);
    end
    else
      Exit;   { not closed by the mouse leaving meanwhile }
  end;

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
  else if (not FPinned) and (FAwaySinceMs > 0) and (ANowMs - FAwaySinceMs >= CloseDelayMs) then
  begin
    Hide;
    Result := True;
  end;
end;

procedure TSortPanel.JobStarted(ASlot: Integer);
begin
  if ASlot < 0 then
    Exit;
  if ASlot > High(FPending) then
    SetLength(FPending, ASlot + 1);
  Inc(FPending[ASlot]);
  FDirty := True;
end;

procedure TSortPanel.JobDone(ASlot: Integer; AOK: Boolean; ANowMs: Double);
begin
  if (ASlot >= 0) and (ASlot <= High(FPending)) and (FPending[ASlot] > 0) then
    Dec(FPending[ASlot]);
  Flash(ASlot, AOK, ANowMs);
end;

procedure TSortPanel.Flash(ASlot: Integer; AOK: Boolean; ANowMs: Double);
begin
  if ASlot >= FFolders.Count then
    ASlot := -1;
  FFlashSlot := ASlot;
  FFlashOK := AOK;
  FFlashStartMs := Max(1.0, ANowMs);
  FFlashLevel := 1;
  FDirty := True;
end;

procedure TSortPanel.CloseAfterAction(ANowMs: Double);
begin
  if FPinned or not FVisible then
    Exit;
  FCloseWhenDone := True;
  FCloseDeadlineMs := ANowMs + CloseWaitMs;
end;

function TSortPanel.FlashColor: TBGRAPixel;
var
  C: LongWord;
begin
  if not FFlashOK then
    Result := BGRA(230, 40, 40, 255)
  else if (FFlashSlot >= 0) and (FFlashSlot < FFolders.Count) then
  begin
    C := SlotColorValue(FFolders.Slot(FFlashSlot).Color);
    Result := BGRA(C and $FF, (C shr 8) and $FF, (C shr 16) and $FF, 255);
  end
  else
    Result := BGRA(220, 220, 220, 255);   { delete / undo: neutral }
end;

{ The panel is closed but a flash is still to be seen: a strip. }
function TSortPanel.StripMode: Boolean;
begin
  Result := (not FVisible) and (FFlashStartMs > 0) and (FViewW > 0) and (FViewH > 0);
end;

procedure TSortPanel.RedrawStrip;
var
  W: Integer;
  C: TBGRAPixel;
begin
  FDirty := False;
  Inc(FVersion);
  W := ScaleI(StripPx, FScale);
  if FStrip = nil then
    FStrip := TBGRABitmap.Create(W, FViewH)
  else
    FStrip.SetSize(W, FViewH);
  C := FlashColor;
  C.alpha := Round(230 * FFlashLevel);
  FStrip.Fill(C);
end;

{ A check mark (done) or a cross (failed) in R. }
procedure TSortPanel.DrawMark(const R: TRect; AOK: Boolean; AAlpha: Byte);
var
  X, Y, S, W: Single;
  C: TBGRAPixel;
begin
  C := BGRA(255, 255, 255, AAlpha);
  S := Min(R.Width, R.Height) * 0.30;
  X := R.Left + R.Width / 2;
  Y := R.Top + R.Height / 2;
  W := Max(2.0, FScale * 2.5);
  if AOK then
    FBitmap.DrawPolyLineAntialias([PointF(X - S, Y), PointF(X - S * 0.3, Y + S * 0.7),
      PointF(X + S, Y - S * 0.7)], C, W)
  else
  begin
    FBitmap.DrawLineAntialias(X - S * 0.7, Y - S * 0.7, X + S * 0.7, Y + S * 0.7, C, W);
    FBitmap.DrawLineAntialias(X - S * 0.7, Y + S * 0.7, X + S * 0.7, Y - S * 0.7, C, W);
  end;
end;

procedure TSortPanel.MouseGone(ANowMs: Double);
begin
  FEdgeSinceMs := 0;
  if FVisible and (not FHold) and (FAwaySinceMs = 0) then
    FAwaySinceMs := ANowMs;
  if FVisible and (FHover.Part <> ppNone) then
  begin
    FHover.Part := ppNone;
    FHover.Slot := -1;
    FDirty := True;
  end;
end;

function TSortPanel.Scroll(ANotches: Integer): Boolean;
var
  Old: Integer;
begin
  Old := FFirstRow;
  FFirstRow := EnsureRange(FFirstRow - ANotches, 0, Max(0, RowCount - FRowsShown));
  Result := FFirstRow <> Old;
  if Result then
    FDirty := True;
end;

function TSortPanel.Bitmap: TBGRABitmap;
begin
  if StripMode then
  begin
    if FDirty or (FStrip = nil) then
      RedrawStrip;
    Exit(FStrip);
  end;
  if not FVisible then
    Exit(nil);
  if FDirty or (FBitmap = nil) then
    Redraw;
  Result := FBitmap;
end;

function TSortPanel.SlotMissing(ASlot: Integer): Boolean;
begin
  Result := Assigned(FOnSlotMissing) and FOnSlotMissing(ASlot);
end;

{ The slot's number, small, in the lower right corner of an icon. }
procedure TSortPanel.DrawBadge(X, Y, W, H: Integer; const ANumber: string);
var
  TS: TSize;
  BW, BH: Integer;
begin
  FBitmap.FontHeight := Max(8, H * 9 div 20);
  FBitmap.FontStyle := [fsBold];
  TS := FBitmap.TextSize(ANumber);
  BW := TS.cx + 4;
  BH := TS.cy;
  FBitmap.FillRoundRectAntialias(X + W - BW, Y + H - BH, X + W, Y + H, 3, 3,
    BGRA(0, 0, 0, 170));
  FBitmap.TextOut(X + W - BW + 2, Y + H - BH, ANumber, BGRA(255, 255, 255, 235));
  FBitmap.FontStyle := [];
end;

{ A folder: a tab and a body in AColor, the number on it. }
procedure TSortPanel.DrawFolder(X, Y, W, H: Integer; AColor: TBGRAPixel; const ANumber: string);
var
  TabW, TabH: Integer;
  Dark: TBGRAPixel;
  TS: TSize;
begin
  TabW := W * 2 div 5;
  TabH := Max(2, H div 6);
  Dark := BGRA(AColor.red * 3 div 4, AColor.green * 3 div 4, AColor.blue * 3 div 4, 255);
  FBitmap.FillRoundRectAntialias(X, Y, X + TabW, Y + TabH * 2, 2, 2, Dark);
  FBitmap.FillRoundRectAntialias(X, Y + TabH, X + W, Y + H, 3, 3, AColor);
  if ANumber <> '' then
  begin
    FBitmap.FontHeight := Max(8, (H - TabH) * 3 div 4);
    FBitmap.FontStyle := [fsBold];
    TS := FBitmap.TextSize(ANumber);
    FBitmap.TextOut(X + (W - TS.cx) div 2, Y + TabH + (H - TabH - TS.cy) div 2,
      ANumber, BGRA(255, 255, 255, 235));
    FBitmap.FontStyle := [];
  end;
end;

{ The lines of AText (split at line endings). }
function TextLines(const AText: string): TStringArray;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Text := AText;
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      Result[I] := L[I];
  finally
    L.Free;
  end;
end;

{ Cuts AText to AWidth pixels, with "..." at the end. }
function FitText(ABitmap: TBGRABitmap; const AText: string; AWidth: Integer): string;
var
  N: Integer;
begin
  Result := AText;
  if ABitmap.TextSize(Result).cx <= AWidth then
    Exit;
  { In characters, not bytes: "Präparate" must not be cut inside the ä. }
  N := UTF8Length(AText);
  while (N > 0) and (ABitmap.TextSize(UTF8Copy(AText, 1, N) + '...').cx > AWidth) do
    Dec(N);
  Result := UTF8Copy(AText, 1, N) + '...';
end;

procedure TSortPanel.Redraw;
var
  Row, Pad, IconW, TextX, TextW, Y2: Integer;
  R, M, P: TRect;
  Slot: TSortSlot;
  C: LongWord;
  Col, Text, Dim: TBGRAPixel;
  Line: string;
  Lines: TStringArray;
  I, IconS, IconX: Integer;
  Icon: TBGRABitmap;
  Missing: Boolean;
begin
  FDirty := False;
  Inc(FVersion);
  if (FWidth <= 0) or (FViewH <= 0) then
    Exit;
  if FBitmap = nil then
    FBitmap := TBGRABitmap.Create(FWidth, FViewH)
  else
    FBitmap.SetSize(FWidth, FViewH);
  FBitmap.FontQuality := fqSystem;       { transparent background: no ClearType }
  FBitmap.Fill(BGRA(12, 12, 16, 205));
  { A thin line on the left: where the panel starts. }
  FBitmap.DrawLine(0, 0, 0, FViewH - 1, BGRA(255, 255, 255, 60), False);

  Text := BGRA(235, 235, 235, 255);
  Dim := BGRA(160, 160, 160, 255);
  Pad := ScaleI(6, FScale);

  { Header: title and the pin. }
  FBitmap.FontHeight := ScaleI(15, FScale);
  if FBusy then
    Line := 'Sort   (working ...)'
  else
    Line := 'Sort';
  FBitmap.TextOut(Pad, (FHeaderH - FBitmap.TextSize(Line).cy) div 2, Line, Dim);
  P := PinRect;
  if (FHover.Part = ppPin) then
    FBitmap.FillRect(P, BGRA(255, 255, 255, 40), dmDrawWithTransparency);
  { The pin: a head and a needle; lit when pinned. }
  if FPinned then
    Col := BGRA(255, 200, 60, 255)
  else
    Col := BGRA(150, 150, 150, 255);
  FBitmap.FillEllipseAntialias((P.Left + P.Right) / 2, P.Top + P.Height * 0.38,
    P.Height * 0.18, P.Height * 0.18, Col);
  FBitmap.DrawLineAntialias((P.Left + P.Right) / 2, P.Top + P.Height * 0.5,
    (P.Left + P.Right) / 2, P.Top + P.Height * 0.85, Col, Max(1, FScale * 1.5));

  { Rows. }
  for Row := FFirstRow to Min(RowCount - 1, FFirstRow + FRowsShown - 1) do
  begin
    R := RowRect(Row);
    if R.Bottom > FViewH - FFooterH then
      Break;
    if (FHover.Part in [ppSlot, ppSlotMenu]) and (FHover.Slot = Row) then
      FBitmap.FillRect(R, BGRA(255, 255, 255, 38), dmDrawWithTransparency);
    { The confirmation flash, and the frame of a job under way. }
    if (FFlashStartMs > 0) and (FFlashSlot = Row) then
    begin
      Col := FlashColor;
      Col.alpha := Round(200 * FFlashLevel);
      FBitmap.FillRect(R, Col, dmDrawWithTransparency);
    end;
    if (Row < FFolders.Count) and (Row <= High(FPending)) and (FPending[Row] > 0) then
    begin
      C := SlotColorValue(FFolders.Slot(Row).Color);
      FBitmap.RectangleAntialias(R.Left + 1.5, R.Top + 1.5, R.Right - 2.5, R.Bottom - 2.5,
        BGRA(C and $FF, (C shr 8) and $FF, (C shr 16) and $FF, 230), Max(1.5, FScale * 1.5));
    end;
    IconW := Round((R.Height - 2 * Pad div 2) * 1.25);
    if Row = FFolders.Count then
    begin
      { "+": add a folder (or drop one here). }
      if FHover.Part = ppAdd then
        FBitmap.FillRect(R, BGRA(255, 255, 255, 38), dmDrawWithTransparency);
      FBitmap.FontHeight := Max(10, R.Height * 2 div 3);
      FBitmap.TextOut(Pad + IconW div 4, R.Top + (R.Height - FBitmap.TextSize('+').cy) div 2, '+', Dim);
      FBitmap.FontHeight := Max(9, Min(ScaleI(13, FScale), R.Height * 11 div 20));
      Line := 'add folder';
      FBitmap.TextOut(Pad + IconW + Pad, R.Top + (R.Height - FBitmap.TextSize(Line).cy) div 2, Line, Dim);
      Continue;
    end;
    Slot := FFolders.Slot(Row);
    Missing := SlotMissing(Row);
    C := SlotColorValue(Slot.Color);
    if Missing then
      Col := BGRA(90, 90, 90, 255)
    else
      Col := BGRA(C and $FF, (C shr 8) and $FF, (C shr 16) and $FF, 255);
    { Its icon (stage 2), scaled to the button, else the coloured folder. }
    IconS := R.Height - Pad;
    Icon := nil;
    if Assigned(FOnSlotIcon) and (IconS >= 8) then
      Icon := FOnSlotIcon(Row, IconS);
    if Icon <> nil then
    begin
      IconX := Pad + (IconW - IconS) div 2;
      if Missing then
        FBitmap.PutImage(IconX, R.Top + Pad div 2, Icon, dmDrawWithTransparency, 90)
      else
        FBitmap.PutImage(IconX, R.Top + Pad div 2, Icon, dmDrawWithTransparency);
      DrawBadge(IconX, R.Top + Pad div 2, IconS, IconS, IntToStr(Row + 1));
    end
    else
      DrawFolder(Pad, R.Top + Pad div 2, IconW, R.Height - Pad, Col, IntToStr(Row + 1));
    M := MenuRect(R);
    TextX := Pad + IconW + Pad;
    TextW := M.Left - TextX - 2;
    FBitmap.FontHeight := Max(9, Min(ScaleI(14, FScale), R.Height * 11 div 20));
    Line := FitText(FBitmap, Slot.Name, TextW);
    if Missing then
      FBitmap.TextOut(TextX, R.Top + (R.Height - FBitmap.TextSize(Line).cy) div 2, Line,
        BGRA(110, 110, 110, 255))
    else
      FBitmap.TextOut(TextX, R.Top + (R.Height - FBitmap.TextSize(Line).cy) div 2, Line, Text);
    { While it flashes: a check mark (or a cross) instead of "...". }
    if (FFlashStartMs > 0) and (FFlashSlot = Row) then
    begin
      DrawMark(M, FFlashOK, Round(255 * FFlashLevel));
      Continue;
    end;
    { The "..." corner. }
    if (FHover.Part = ppSlotMenu) and (FHover.Slot = Row) then
      FBitmap.FillRect(M, BGRA(255, 255, 255, 60), dmDrawWithTransparency);
    FBitmap.FontHeight := Max(9, R.Height div 2);
    FBitmap.TextOut(M.Left + (M.Width - FBitmap.TextSize('...').cx) div 2,
      M.Top + (M.Height - FBitmap.TextSize('...').cy) div 2 - 2, '...', Dim);
  end;

  { More rows than fit: a hint that the wheel scrolls. }
  if RowCount > FRowsShown then
  begin
    FBitmap.FontHeight := ScaleI(11, FScale);
    Line := Format('%d-%d of %d  (wheel)', [FFirstRow + 1,
      Min(RowCount, FFirstRow + FRowsShown), RowCount]);
    FBitmap.TextOut(Pad, FViewH - FFooterH - FBitmap.TextSize(Line).cy - 2, Line, Dim);
  end;

  { Footer: the hovered folder, or the last action (click = undo). }
  R := FooterRect;
  FBitmap.DrawLine(0, R.Top, FWidth - 1, R.Top, BGRA(255, 255, 255, 50), False);
  if (FHover.Part in [ppSlot, ppSlotMenu]) and (FHover.Slot >= 0) and (FHover.Slot < FFolders.Count) then
    if SlotMissing(FHover.Slot) then
      Line := 'folder not found:' + LineEnding + FFolders.Slot(FHover.Slot).Folder
    else
      Line := FFolders.Slot(FHover.Slot).Folder
        + LineEnding + 'double-click  left: copy  right: move'
        + LineEnding + 'swipe right: open the folder'
  else if FHover.Part = ppAdd then
    Line := 'click: choose a folder' + LineEnding + 'or drop folders here'
  else if FHover.Part = ppPin then
    Line := 'pin: stay open'
  else
    Line := FFooterText;
  if FHover.Part = ppFooter then
    FBitmap.FillRect(R, BGRA(255, 255, 255, 38), dmDrawWithTransparency);
  { Delete / undo: the bottom line flashes. }
  if (FFlashStartMs > 0) and (FFlashSlot < 0) then
  begin
    Col := FlashColor;
    Col.alpha := Round(110 * FFlashLevel);
    FBitmap.FillRect(R, Col, dmDrawWithTransparency);
  end;
  FBitmap.FontHeight := ScaleI(11, FScale);
  Lines := TextLines(Line);
  Y2 := R.Top + 3;
  for I := 0 to Min(High(Lines), 2) do
  begin
    FBitmap.TextOut(Pad, Y2, FitText(FBitmap, Lines[I], FWidth - 2 * Pad), Dim);
    Inc(Y2, FBitmap.TextSize('Xg').cy);
  end;
end;

end.
