unit uRenderer;

{
  Unit: uRenderer

  Purpose
  -------
  TRenderer: what every renderer has in common - the current image,
  the view (fit / 100 %, zoom, pan, rotation), the texts drawn over the
  image, and the measurements (spec §8, §12).
  TCpuRenderer: draws with BGRABitmap onto a canvas. It is the
  fallback when OpenGL isn't usable (spec §8.5, §8.6); the GPU
  renderer is TGLRenderer (uGLRenderer).

  Owns
  ----
  - TCpuRenderer: FRotated (a rotated copy, only while rotated),
    FDisplay (the scaled part of the image last drawn, a cache; freed
    only when FDisplayOwned, since it may be the image's own bitmap)
    and FFiltered (FDisplay with the display filters, while any are
    set).
  - The bitmap of a picture of the window, while it is saved.

  Knows
  -----
  - The current IDecodedImage (shared, read only).
  - OnImagePainted: called with latency and paint time (TMView).
  - The texts and settings TMView sets: info and diagnostics text,
    input mode, zone label, gesture text, edit mode and selection,
    overlay colour and solid bar.

  Responsibilities
  ----------------
  - The view model, identical for both renderers:
      scale on screen = BaseScale x Zoom, where BaseScale is the fit
      scale (or 1 at 100 %);
      the image centre sits at the window centre + (PanX, PanY);
      the image is turned by Angle degrees (clockwise) around it.
    ZoomAt keeps the point under the mouse where it is. RotateBy
    turns around the window centre (the pan turns with it). Zoom is
    kept between 1/64 and 256.
  - Converting between screen pixels and pixels of the original image.
  - Placeholder texts, the info line, the diagnostics line and the
    mode label ("ZOOM" / "ROTATE") as text; each renderer draws them.
  - Latency and paint time (spec §12).
  - The display filters (Phase H, uFilters) and the pictures of the two
    slide-out panels (sort panel right, filter panel left).
  - TCpuRenderer: paint image, edit-mode selection frame and overlays
    onto a canvas; save a picture of the window as PNG on request. The
    filters are applied to the screen-sized part only.

  Does NOT
  --------
  - Load or decode files, navigate or handle input.
  - Own the image or decide which image is shown (TMView does).

  Threads
  -------
  UI thread only: TMView sets the image and view, and TMediaView's
  paint handler calls TCpuRenderer.Paint. The CPU renderer saves a
  picture of the window at once, on the UI thread.

  Uses (MView units)
  ------------------
  interface:      uCommands, uDecodedImage, uFilters, uFilterImage, uImageSaver,
                  uStopwatch
  Libraries:      Classes, Types, SysUtils, Math, Graphics,
                  BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uGLRenderer, uMView, uMainForm, uMediaView

  Quality levels
  --------------
  All geometry is in pixels of the original image (FullWidth /
  FullHeight), whatever the size of the bitmap actually drawn. So
  "100 %" means one original pixel per screen pixel even while only
  the quick view is there; it is just blurrier until Full arrives.

  CPU renderer limits
  -------------------
  It turns in 90-degree steps only: a free angle is shown rounded to
  the nearest quarter turn (the GPU renderer shows it exactly).
  Downscaling uses the fine resampler; at 100 % and above, plain
  pixel stretching, so single pixels can be inspected without blur.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  Types,
  SysUtils,
  Math,
  Graphics,
  BGRABitmap,
  BGRABitmapTypes,
  uCommands,
  uDecodedImage,
  uFilters,
  uFilterImage,
  uImageSaver,
  uStopwatch;

const
  { In InfoText: where the zoom ("52 % = 1997 x 1331", the angle) goes;
    none = no zoom in the line (user, Day 24: [InfoLine] Zoom=0). }
  InfoZoomMarker = #1;

type

  TViewMode = (vmFit, vmOriginal);

  TViewState = record
    Mode: TViewMode;
    Zoom: Double;
    PanX: Double;
    PanY: Double;
    Angle: Double;       { degrees clockwise, 0 <= Angle < 360 }
  end;

  { A rectangle in pixels of the original image (edit mode selection);
    X0 <= X1, Y0 <= Y1. }
  TImageRect = record
    Active: Boolean;
    X0, Y0, X1, Y1: Double;
  end;

  { The magnifier (Phase H, G6): a round lens at (X, Y) on screen,
    showing what is under it Mag times larger than on screen (user:
    "relative to screen"), Radius px; Sharpen 0 off, 1 low, 2 high;
    Locked: it stays where it is (the mouse is free). }
  TLensState = record
    Active: Boolean;
    Locked: Boolean;
    X, Y: Double;
    Radius: Double;
    Mag: Double;
    Sharpen: Integer;
  end;

  { ALatencyMs: from the command to the end of this paint.
    APaintMs: how long drawing the image took in this paint. }
  TImagePaintedEvent = procedure(ALatencyMs, APaintMs: Double) of object;

  { TRenderer }

  TRenderer = class(TObject)
  private
    FZoomStepPercent: Double;
    FMessage: string;
    FInfoText: string;
    FInfoFontName: string;       { '' = the standard font }
    FInfoFontSize: Integer;      { points; 0 = the standard size }
    FShowInfo: Boolean;
    FShowDiagnostics: Boolean;
    FDiagnosticsText: string;
    FInputMode: TInputMode;
    FOnImagePainted: TImagePaintedEvent;
    FZoneLabel: string;
    FZoneCorner: Integer;
    FGestureText: string;
    { The sort panel (Phase G): drawn on top of everything. }
    FPanel: TBGRABitmap;
    FPanelX, FPanelY: Integer;
    FPanelVersion: Cardinal;
    { The filter panel (Phase H), at the left edge. }
    FFilterPanel: TBGRABitmap;
    FFilterPanelX, FFilterPanelY: Integer;
    FFilterPanelVersion: Cardinal;
    { The display filters (Phase H); FFilterVersion changes with them. }
    FFilters: TFilterSettings;
    FFilterVersion: Cardinal;
    FLens: TLensState;
    { A mode badge in the bottom right corner (user, Day 23: "TC" bold and
      blinking while MView follows Total Commander); BadgeOn: the blink's
      phase. The picture is made once per text. }
    FBadgeText: string;
    FBadgeStyle: Integer;        { 0 see-through (off), 1 light blue, 2 amber }
    FBadgeOn: Boolean;
    FBadgeBmp: TBGRABitmap;
    FBadgeVersion: Cardinal;
    { A short notice in the middle of the view (user, Day 24: "TC
      connection, directory change disabled!"), in the badge's colours;
      NoticeOn: the flash's phase. TMView times it. }
    FNoticeText: string;
    FNoticeStyle: Integer;
    FNoticeOn: Boolean;
    FNoticeBmp: TBGRABitmap;
    FNoticeVersion: Cardinal;
    FEditMode: Boolean;
    FSelection: TImageRect;
    FOverlaySolid: Boolean;
    FOverlayRGB: array[0..2] of Byte;
  protected
    FImage: IDecodedImage;
    FView: TViewState;
    FSurfaceWidth: Integer;      { size of the last paint }
    FSurfaceHeight: Integer;
    FLastScale: Double;          { original pixels -> screen, last paint }

    FScreenshotFile: string;     { requested picture of the window }
    FScreenshotResult: string;   { "saved: ..." / "... failed: ..." }

    FLatencyStart: Double;       { NowMs of the command; 0 = nothing pending }
    FLastLatencyMs: Double;
    FLastPaintMs: Double;

    { Size of the original image; and as it stands after the quarter
      turns (width and height swapped for 90 / 270 degrees). }
    procedure LogicalSize(out AWidth, AHeight: Integer);
    procedure TurnedLogicalSize(out AWidth, AHeight: Integer);
    function QuarterTurns: Integer;
    { Original pixels -> screen pixels, for a surface of this size. }
    function ScaleFor(AWidth, AHeight: Integer): Double;

    { Called at the start of every paint, and after drawing the image
      (before the overlays). EndImagePart returns True if this was the
      first paint of a new image (latency measured). }
    function BeginPaint(AWidth, AHeight: Integer): Double;
    function EndImagePart(AStartMs: Double): Boolean;
    procedure ReportPainted;

    { Hooks for the subclasses. }
    procedure ImageChanged(AKeepView: Boolean); virtual;
    procedure TurnsChanged; virtual;
    { Filters' Mirror switched (the CPU renderer remakes its copy). }
    procedure MirrorChanged; virtual;
    { The angle the image is drawn at (the CPU renderer: quarter turns
      only). }
    function DrawAngle: Double; virtual;
    { The selection's corners on screen (a turned rectangle); False if
      there is none. }
    function SelectionCorners(out APoints: array of TPoint): Boolean;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { nil = no image; the message set with SetMessage is shown.
      AKeepView: the same image in better quality; keep the view. }
    procedure SetImage(const AImage: IDecodedImage; AKeepView: Boolean = False);
    procedure SetMessage(const AText: string);

    procedure ResetView;
    procedure ZoomIn;
    procedure ZoomOut;
    { Multiplies the zoom by AFactor, keeping screen point AX, AY. }
    procedure ZoomAt(AFactor, AX, AY: Double);
    procedure PanBy(ADX, ADY: Double);
    { Degrees, + = clockwise, around the window centre. }
    procedure RotateBy(ADegrees: Double);
    { +1 = 90 degrees clockwise, -1 = counter-clockwise }
    procedure Rotate(AQuarterTurns: Integer);
    procedure FitToScreen;
    procedure OriginalSize;
    { 100 %, keeping screen point AX, AY where it is. }
    procedure OriginalSizeAt(AX, AY: Double);
    function IsFitView: Boolean;

    { Call right after SetImage with the NowMs of the user's command.
      The next paint then measures the latency. }
    procedure StartLatency(ACommandMs: Double);

    { Texts for the overlays (both renderers draw these). }
    function InfoLine: string;
    function DiagnosticsLine: string;
    function ModeLine: string;
    { The centre text when there is no image or it failed. }
    procedure PlaceholderLines(out ALines: TStringArray);

    { A short description for the diagnostics line ("CPU", "GPU ..."). }
    function Description: string; virtual;

    { Screen pixels (of the last paint) <-> pixels of the original
      image. ScreenToImage is False while nothing has been drawn. }
    function ScreenToImage(AX, AY: Double; out AImgX, AImgY: Double): Boolean;
    procedure ImageToScreen(AImgX, AImgY: Double; out AX, AY: Double);

    { True while the image last set is still being put on screen (GPU
      upload in steps). Animation playback waits for it instead of
      piling up frames. }
    function IsUploading: Boolean; virtual;

    { The image's size on screen, in pixels (original size x the scale
      of the last paint); False while nothing has been drawn. }
    function ShownSize(out AWidth, AHeight: Integer): Boolean;

    { Debugging: save a PNG of what the window shows (image, zoom,
      rotation, text bars). The CPU renderer does it at once, the GPU
      renderer at the end of the next frame. TakeScreenshotResult
      returns the outcome once (empty while pending). }
    procedure RequestScreenshot(const AFileName: string); virtual;
    function TakeScreenshotResult: string;

    property Image: IDecodedImage read FImage;
    property ZoomStepPercent: Double read FZoomStepPercent write FZoomStepPercent;
    property InfoText: string read FInfoText write FInfoText;
    { The info line's font ([InfoLine] Font / FontSize, Day 24). }
    property InfoFontName: string read FInfoFontName write FInfoFontName;
    property InfoFontSize: Integer read FInfoFontSize write FInfoFontSize;
    property ShowInfo: Boolean read FShowInfo write FShowInfo;
    property ShowDiagnostics: Boolean read FShowDiagnostics write FShowDiagnostics;
    { The part of the diagnostics line that TMView knows (decode,
      cache). The renderer adds its own part, latency and paint time. }
    property DiagnosticsText: string read FDiagnosticsText write FDiagnosticsText;
    property InputMode: TInputMode read FInputMode write FInputMode;
    { Mouse language feedback (Phase F): the name of the zone the mouse
      is in, drawn in that zone's corner (0 top left, 1 top right,
      2 bottom left, 3 bottom right); '' = none. And what a gesture
      will do, in the middle of the window, while it is being made. }
    { Edit mode (shown in the mode label) and its selection, drawn over
      the image as a frame. }
    property EditMode: Boolean read FEditMode write FEditMode;
    { Info and diagnostics lines on a solid black bar ([View]
      OverlaySolid), and the colour of the texts over the image
      ([View] OverlayColor: White, Yellow, Red). }
    property OverlaySolid: Boolean read FOverlaySolid write FOverlaySolid;
    procedure SetOverlayColorName(const AName: string);
    function OverlayRed: Byte;
    function OverlayGreen: Byte;
    function OverlayBlue: Byte;
    function OverlayTColor: TColor;
    property Selection: TImageRect read FSelection write FSelection;
    property ZoneLabel: string read FZoneLabel write FZoneLabel;
    property ZoneCorner: Integer read FZoneCorner write FZoneCorner;
    property GestureText: string read FGestureText write FGestureText;
    { The sort panel's picture (not owned; nil = none), where it goes,
      and a number that changes whenever the picture does (the GPU
      renderer uploads it again then). }
    procedure SetPanel(ABitmap: TBGRABitmap; AX, AY: Integer; AVersion: Cardinal);
    property Panel: TBGRABitmap read FPanel;
    property PanelX: Integer read FPanelX;
    property PanelY: Integer read FPanelY;
    property PanelVersion: Cardinal read FPanelVersion;
    { The filter panel's picture, the same way (left edge). }
    procedure SetFilterPanel(ABitmap: TBGRABitmap; AX, AY: Integer; AVersion: Cardinal);
    property FilterPanel: TBGRABitmap read FFilterPanel;
    property FilterPanelX: Integer read FFilterPanelX;
    property FilterPanelY: Integer read FFilterPanelY;
    property FilterPanelVersion: Cardinal read FFilterPanelVersion;
    { The display filters (uFilters); only the picture on screen changes,
      never the image. }
    procedure SetFilters(const AFilters: TFilterSettings);
    property Filters: TFilterSettings read FFilters;
    property FilterVersion: Cardinal read FFilterVersion;
    { False if this renderer can't show the filters (a GPU without
      shaders); TMView says so instead of pretending. }
    function FiltersAvailable: Boolean; virtual;
    { The mode badge ('' = none) and its blink (shown while BadgeOn). }
    { AStyle: 0 see-through (an outline: the mode is off), 1 light blue,
      2 amber. }
    procedure SetBadge(const AText: string; AStyle: Integer = 2);
    property BadgeStyle: Integer read FBadgeStyle;
    { Room the info line leaves for the badge at its right end (px). }
    function BadgeRoom: Integer;
    { The badge is under this point of the view (the last paint's size). }
    function BadgeHit(AX, AY: Integer): Boolean;
    property BadgeText: string read FBadgeText;
    property BadgeOn: Boolean read FBadgeOn write FBadgeOn;
    { Its picture (nil = none); BadgeVersion changes with it. }
    function BadgeBitmap: TBGRABitmap;
    property BadgeVersion: Cardinal read FBadgeVersion;
    { The notice in the middle ('' = none); AStyle as for the badge (1
      light blue, 2 amber). Shown while NoticeOn. }
    procedure SetNotice(const AText: string; AStyle: Integer = 2);
    property NoticeText: string read FNoticeText;
    property NoticeOn: Boolean read FNoticeOn write FNoticeOn;
    function NoticeBitmap: TBGRABitmap;
    property NoticeVersion: Cardinal read FNoticeVersion;
    { The magnifier: drawn over the image (under the texts and panels). }
    property Lens: TLensState read FLens write FLens;
    property OnImagePainted: TImagePaintedEvent read FOnImagePainted write FOnImagePainted;
    property View: TViewState read FView;
  end;

  { TCpuRenderer }

  TCpuRenderer = class(TRenderer)
  private
    FRotated: TBGRACustomBitmap;
    FRotatedTurns: Integer;      { quarter turns FRotated was made for }
    FRotatedMirror: Boolean;     { ... and whether mirrored }
    FDisplay: TBGRACustomBitmap;
    FDisplayOwned: Boolean;      { False if FDisplay is FImage's own bitmap }
    FDisplayKey: string;         { what FDisplay currently shows }
    FFiltered: TBGRACustomBitmap; { FDisplay with the filters (owned) }
    FFilteredKey: string;
    FNote: string;               { e.g. why the GPU isn't used }

    function SourceBitmap: TBGRACustomBitmap;
    procedure ClearDisplay;
    procedure ClearRotated;
    procedure RebuildRotated;
    procedure DrawImage(ACanvas: TCanvas; AWidth, AHeight: Integer);
    procedure DrawLens(ACanvas: TCanvas; AWidth, AHeight: Integer);
    procedure DrawCenteredText(ACanvas: TCanvas; AWidth, AHeight: Integer; const ALines: array of string);
    function DrawBar(ACanvas: TCanvas; AWidth, ABottom: Integer; const AText: string;
      ASolid: Boolean = False): Integer;
    procedure DrawOverlays(ACanvas: TCanvas; AWidth, AHeight: Integer);
  protected
    procedure ImageChanged(AKeepView: Boolean); override;
    procedure TurnsChanged; override;
    procedure MirrorChanged; override;
    function DrawAngle: Double; override;
  public
    destructor Destroy; override;
    procedure Paint(ACanvas: TCanvas; AWidth, AHeight: Integer);
    function Description: string; override;
    procedure RequestScreenshot(const AFileName: string); override;
    { Shown in the diagnostics line, e.g. why the GPU isn't used. }
    property Note: string read FNote write FNote;
  end;

{ The magnifier's sharpening per level (0 off, 1 low, 2 high): the
  amount of the unsharp mask (both renderers). }
function LensSharpenAmount(ALevel: Integer): Single;

const
  { Typed, so Min/Max pick the Double overload without ambiguity. }
  MinZoom: Double = 1 / 64;
  MaxZoom: Double = 256;

implementation

const
  ZeroD: Double = 0;

function LensSharpenAmount(ALevel: Integer): Single;
begin
  case ALevel of
    1: Result := 0.6;
    2: Result := 1.4;
  else
    Result := 0;
  end;
end;

function LensSharpenName(ALevel: Integer): string;
begin
  case ALevel of
    1: Result := 'low';
    2: Result := 'high';
  else
    Result := 'off';
  end;
end;

{ The lines of AText (CR LF or LF). }
function SplitAtLineBreaks(const AText: string): TStringArray;
var
  I, Start, N: Integer;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = #10) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(AText, Start, I - Start);
      if (Result[N] <> '') and (Result[N][Length(Result[N])] = #13) then
        SetLength(Result[N], Length(Result[N]) - 1);
      Inc(N);
      Start := I + 1;
    end;
end;

function NormalizeAngle(A: Double): Double;
begin
  Result := A - 360.0 * Floor(A / 360.0);
  if Result >= 360.0 then
    Result := 0;
end;

{ TRenderer }

constructor TRenderer.Create;
begin
  inherited Create;
  FZoomStepPercent := 20.0;
  FShowInfo := True;
  FLastScale := 0;
  FInputMode := imBrowse;
  FView.Mode := vmFit;
  FView.Zoom := 1.0;
  FView.PanX := 0;
  FView.PanY := 0;
  FView.Angle := 0;
  FFilters := NeutralFilters;
  SetOverlayColorName('White');
end;

destructor TRenderer.Destroy;
begin
  FImage := nil;
  FBadgeBmp.Free;
  FNoticeBmp.Free;
  inherited Destroy;
end;

procedure TRenderer.SetBadge(const AText: string; AStyle: Integer);
begin
  if (AText = FBadgeText) and (AStyle = FBadgeStyle) then
    Exit;
  FBadgeText := AText;
  FBadgeStyle := AStyle;
  FreeAndNil(FBadgeBmp);
  Inc(FBadgeVersion);
end;

function TRenderer.BadgeRoom: Integer;
begin
  Result := 0;
  if FBadgeOn and (BadgeBitmap <> nil) then
    Result := BadgeBitmap.Width + 16;
end;

function TRenderer.BadgeHit(AX, AY: Integer): Boolean;
var
  Bmp: TBGRABitmap;
  X0, Y0: Integer;
begin
  Result := False;
  if not FBadgeOn then
    Exit;
  Bmp := BadgeBitmap;
  if (Bmp = nil) or (FSurfaceWidth <= 0) or (FSurfaceHeight <= 0) then
    Exit;
  { As drawn: 8 px from the right, 6 px from the bottom (a little room
    around it, so it is easy to hit). }
  X0 := FSurfaceWidth - Bmp.Width - 8;
  Y0 := FSurfaceHeight - Bmp.Height - 6;
  Result := (AX >= X0 - 3) and (AX < X0 + Bmp.Width + 3)
    and (AY >= Y0 - 3) and (AY < Y0 + Bmp.Height + 3);
end;

{ Bold dark text on a rounded label: light blue or amber; see-through
  (a light outline and faint text) when the mode is off. }
function TRenderer.BadgeBitmap: TBGRABitmap;
var
  TS: TSize;
begin
  Result := nil;
  if FBadgeText = '' then
    Exit;
  if FBadgeBmp = nil then
  begin
    FBadgeBmp := TBGRABitmap.Create(1, 1);
    FBadgeBmp.FontHeight := 18;
    FBadgeBmp.FontStyle := [fsBold];
    FBadgeBmp.FontQuality := fqSystemClearType;
    TS := FBadgeBmp.TextSize(FBadgeText);
    FBadgeBmp.SetSize(TS.cx + 16, TS.cy + 6);
    FBadgeBmp.Fill(BGRAPixelTransparent);
    case FBadgeStyle of
      1:
        begin
          FBadgeBmp.FillRoundRectAntialias(0, 0, FBadgeBmp.Width - 1, FBadgeBmp.Height - 1, 5, 5,
            BGRA(140, 200, 255, 240));
          FBadgeBmp.TextOut(8, 3, FBadgeText, BGRA(20, 20, 20, 255));
        end;
      2:
        begin
          FBadgeBmp.FillRoundRectAntialias(0, 0, FBadgeBmp.Width - 1, FBadgeBmp.Height - 1, 5, 5,
            BGRA(255, 190, 60, 240));
          FBadgeBmp.TextOut(8, 3, FBadgeText, BGRA(20, 20, 20, 255));
        end;
    else
      { Off: an outline, the text faint (no ClearType on transparent). }
      FBadgeBmp.FontQuality := fqSystem;
      FBadgeBmp.RoundRectAntialias(0.5, 0.5, FBadgeBmp.Width - 1.5, FBadgeBmp.Height - 1.5, 5, 5,
        BGRA(220, 220, 220, 110), 1);
      FBadgeBmp.TextOut(8, 3, FBadgeText, BGRA(220, 220, 220, 110));
    end;
    Inc(FBadgeVersion);
  end;
  Result := FBadgeBmp;
end;

procedure TRenderer.SetNotice(const AText: string; AStyle: Integer);
begin
  if (AText = FNoticeText) and (AStyle = FNoticeStyle) then
    Exit;
  FNoticeText := AText;
  FNoticeStyle := AStyle;
  FreeAndNil(FNoticeBmp);
  Inc(FNoticeVersion);
end;

{ Large bold dark text on a rounded label in the badge's colour. }
function TRenderer.NoticeBitmap: TBGRABitmap;
var
  TS: TSize;
  Fill: TBGRAPixel;
begin
  Result := nil;
  if FNoticeText = '' then
    Exit;
  if FNoticeBmp = nil then
  begin
    FNoticeBmp := TBGRABitmap.Create(1, 1);
    FNoticeBmp.FontHeight := 24;
    FNoticeBmp.FontStyle := [fsBold];
    FNoticeBmp.FontQuality := fqSystemClearType;
    TS := FNoticeBmp.TextSize(FNoticeText);
    FNoticeBmp.SetSize(TS.cx + 40, TS.cy + 20);
    FNoticeBmp.Fill(BGRAPixelTransparent);
    if FNoticeStyle = 1 then
      Fill := BGRA(140, 200, 255, 245)
    else
      Fill := BGRA(255, 190, 60, 245);
    FNoticeBmp.FillRoundRectAntialias(0, 0, FNoticeBmp.Width - 1, FNoticeBmp.Height - 1, 9, 9, Fill);
    FNoticeBmp.TextOut(20, 10, FNoticeText, BGRA(20, 20, 20, 255));
    Inc(FNoticeVersion);
  end;
  Result := FNoticeBmp;
end;

procedure TRenderer.ImageChanged(AKeepView: Boolean);
begin
end;

procedure TRenderer.TurnsChanged;
begin
end;

procedure TRenderer.MirrorChanged;
begin
end;

procedure TRenderer.LogicalSize(out AWidth, AHeight: Integer);
begin
  AWidth := 0;
  AHeight := 0;
  if (FImage = nil) or FImage.IsError then
    Exit;
  AWidth := FImage.FullWidth;
  AHeight := FImage.FullHeight;
  if (AWidth <= 0) or (AHeight <= 0) then
  begin
    AWidth := FImage.Width;
    AHeight := FImage.Height;
  end;
end;

function TRenderer.QuarterTurns: Integer;
begin
  Result := Round(FView.Angle / 90.0) mod 4;
  if Result < 0 then
    Inc(Result, 4);
end;

procedure TRenderer.TurnedLogicalSize(out AWidth, AHeight: Integer);
var
  Tmp: Integer;
begin
  LogicalSize(AWidth, AHeight);
  if Odd(QuarterTurns) then
  begin
    Tmp := AWidth;
    AWidth := AHeight;
    AHeight := Tmp;
  end;
end;

function TRenderer.ScaleFor(AWidth, AHeight: Integer): Double;
var
  LogW, LogH: Integer;
  Rad, BoxW, BoxH: Double;
begin
  Result := 0;
  LogicalSize(LogW, LogH);
  if (LogW <= 0) or (LogH <= 0) or (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  if FView.Mode = vmFit then
  begin
    { Fit the turned image's bounding box, so it shrinks and grows
      smoothly while turning (no jump at 45 degrees). At quarter turns
      this is simply width and height, swapped for 90 / 270. }
    Rad := DegToRad(FView.Angle);
    BoxW := LogW * Abs(Cos(Rad)) + LogH * Abs(Sin(Rad));
    BoxH := LogW * Abs(Sin(Rad)) + LogH * Abs(Cos(Rad));
    Result := Min(AWidth / BoxW, AHeight / BoxH) * FView.Zoom;
  end
  else
    Result := FView.Zoom;
end;

procedure TRenderer.SetImage(const AImage: IDecodedImage; AKeepView: Boolean);
begin
  FImage := AImage;
  if not AKeepView then
  begin
    FView.Mode := vmFit;
    FView.Zoom := 1.0;
    FView.PanX := 0;
    FView.PanY := 0;
    FView.Angle := 0;
  end;
  ImageChanged(AKeepView);
end;

procedure TRenderer.SetMessage(const AText: string);
begin
  FMessage := AText;
end;

procedure TRenderer.ResetView;
var
  OldTurns: Integer;
begin
  OldTurns := QuarterTurns;
  FView.Mode := vmFit;
  FView.Zoom := 1.0;
  FView.PanX := 0;
  FView.PanY := 0;
  FView.Angle := 0;
  if OldTurns <> 0 then
    TurnsChanged;
end;

procedure TRenderer.ZoomAt(AFactor, AX, AY: Double);
var
  OldZoom, NewZoom, Ratio, CX, CY: Double;
begin
  if AFactor <= 0 then
    Exit;
  OldZoom := FView.Zoom;
  NewZoom := EnsureRange(OldZoom * AFactor, MinZoom, MaxZoom);
  if NewZoom = OldZoom then
    Exit;
  Ratio := NewZoom / OldZoom;

  { The image point under (AX, AY) stays where it is: everything
    around it scales by Ratio. }
  CX := FSurfaceWidth / 2;
  CY := FSurfaceHeight / 2;
  FView.PanX := AX - CX - Ratio * (AX - CX - FView.PanX);
  FView.PanY := AY - CY - Ratio * (AY - CY - FView.PanY);
  FView.Zoom := NewZoom;
end;

procedure TRenderer.ZoomIn;
begin
  ZoomAt(1.0 + FZoomStepPercent / 100.0, FSurfaceWidth / 2, FSurfaceHeight / 2);
end;

procedure TRenderer.ZoomOut;
begin
  ZoomAt(1.0 / (1.0 + FZoomStepPercent / 100.0), FSurfaceWidth / 2, FSurfaceHeight / 2);
end;

procedure TRenderer.PanBy(ADX, ADY: Double);
begin
  FView.PanX := FView.PanX + ADX;
  FView.PanY := FView.PanY + ADY;
end;

procedure TRenderer.RotateBy(ADegrees: Double);
var
  OldTurns: Integer;
  Rad, C, S, PX, PY: Double;
begin
  if ADegrees = 0 then
    Exit;
  OldTurns := QuarterTurns;

  { Around the window centre: the image centre (at centre + pan)
    turns around it too. Screen y points down, so this matrix turns
    clockwise on screen, like the image. }
  Rad := DegToRad(ADegrees);
  C := Cos(Rad);
  S := Sin(Rad);
  PX := FView.PanX;
  PY := FView.PanY;
  FView.PanX := PX * C - PY * S;
  FView.PanY := PX * S + PY * C;
  FView.Angle := NormalizeAngle(FView.Angle + ADegrees);

  { Snap tiny rounding leftovers, so 18 x 5 degrees is exactly 90. }
  if Abs(FView.Angle - Round(FView.Angle)) < 1e-6 then
    FView.Angle := NormalizeAngle(Round(FView.Angle));

  if QuarterTurns <> OldTurns then
    TurnsChanged;
end;

procedure TRenderer.Rotate(AQuarterTurns: Integer);
begin
  RotateBy(90.0 * AQuarterTurns);
end;

procedure TRenderer.FitToScreen;
begin
  FView.Mode := vmFit;
  FView.Zoom := 1.0;
  FView.PanX := 0;
  FView.PanY := 0;
end;

procedure TRenderer.OriginalSize;
begin
  FView.Mode := vmOriginal;
  FView.Zoom := 1.0;
  FView.PanX := 0;
  FView.PanY := 0;
end;

procedure TRenderer.OriginalSizeAt(AX, AY: Double);
var
  OldScale, Ratio, CX, CY: Double;
begin
  OldScale := ScaleFor(FSurfaceWidth, FSurfaceHeight);
  if OldScale <= 0 then
  begin
    OriginalSize;
    Exit;
  end;
  Ratio := 1.0 / OldScale;
  CX := FSurfaceWidth / 2;
  CY := FSurfaceHeight / 2;
  FView.PanX := AX - CX - Ratio * (AX - CX - FView.PanX);
  FView.PanY := AY - CY - Ratio * (AY - CY - FView.PanY);
  FView.Mode := vmOriginal;
  FView.Zoom := 1.0;
end;

function TRenderer.IsFitView: Boolean;
begin
  Result := (FView.Mode = vmFit) and SameValue(FView.Zoom, 1.0)
    and (Abs(FView.PanX) < 0.5) and (Abs(FView.PanY) < 0.5);
end;

procedure TRenderer.StartLatency(ACommandMs: Double);
begin
  FLatencyStart := ACommandMs;
end;

function TRenderer.BeginPaint(AWidth, AHeight: Integer): Double;
begin
  Result := NowMs;
  FSurfaceWidth := AWidth;
  FSurfaceHeight := AHeight;
  FLastScale := 0;
end;

function TRenderer.EndImagePart(AStartMs: Double): Boolean;
begin
  FLastPaintMs := NowMs - AStartMs;
  Result := (FLatencyStart > 0) and (FImage <> nil);
  if Result then
  begin
    FLastLatencyMs := NowMs - FLatencyStart;
    FLatencyStart := 0;
  end;
end;

procedure TRenderer.ReportPainted;
begin
  if Assigned(FOnImagePainted) then
    FOnImagePainted(FLastLatencyMs, FLastPaintMs);
end;

function TRenderer.InfoLine: string;
var
  W, H, P: Integer;
  Zoom: string;
begin
  Result := '';
  if not FShowInfo then
    Exit;
  Result := FInfoText;
  P := Pos(InfoZoomMarker, Result);
  if P = 0 then
    Exit;
  { The scale, and the size on screen in pixels (user, Day 22: "it
    replaces a resize function"; Resize to the size shown makes it),
    where the marker is. }
  Zoom := '';
  if FLastScale > 0 then
  begin
    Zoom := Format('%d %%', [Round(FLastScale * 100)]);
    if ShownSize(W, H) then
      Zoom := Zoom + Format(' = %d x %d', [W, H]);
  end;
  if (FImage <> nil) and (FView.Angle <> 0) then
    Zoom := Trim(Zoom + Format('   %.0f°', [FView.Angle]));
  Delete(Result, P, Length(InfoZoomMarker));
  if Zoom <> '' then
    Insert(Zoom, Result, P)
  else if Copy(Result, P, 5) = '     ' then
    Delete(Result, P, 5)                 { no zoom yet: no gap either }
  else if (P > 5) and (Copy(Result, P - 5, 5) = '     ') then
    Delete(Result, P - 5, 5);
end;

function TRenderer.DiagnosticsLine: string;
begin
  Result := '';
  if not FShowDiagnostics then
    Exit;
  { Two lines: TMView's part, then the renderer's (a single line ran
    past the right edge on a full-HD screen). }
  Result := FDiagnosticsText;
  if Result <> '' then
    Result := Result + #10;
  Result := Result + Description + '     '
    + Format('latency %d ms     paint %.1f ms', [Round(FLastLatencyMs), FLastPaintMs]);
end;

function TRenderer.ModeLine: string;
begin
  case FInputMode of
    imZoom:
      Result := Format('ZOOM   %d %%      wheel = zoom at the mouse,   X1 / Esc = back',
        [Round(FLastScale * 100)]);
    imRotate:
      Result := Format('ROTATE   %.0f°      wheel = turn,   X2 / Esc = back',
        [FView.Angle]);
  else
    if FLens.Active then
    begin
      Result := Format('LENS   %.1f x  = %d %%   %d px   sharpen %s',
        [FLens.Mag, Round(FLastScale * FLens.Mag * 100), Round(2 * FLens.Radius),
         LensSharpenName(FLens.Sharpen)]);
      if FLens.Locked then
        Result := Result + '   LOCKED      wheel click = free'
      else
        Result := Result + '      left drag: <-> magnification, up / down size,   wheel: sharpen,   '
          + 'wheel click: lock,   Esc: off';
      if FEditMode then
        Result := 'EDIT ON   |   ' + Result;
    end
    else if FEditMode then
      Result := 'EDIT ON      left drag = select an area,   right click: Crop selection,   '
        + 'double-click in the Edit zone / Esc = end'
    else
      Result := '';
  end;
  { Edit mode stays on while zooming or turning (user, Day 23): said at
    the start of the zoom / rotate line, which takes the same place. }
  if FEditMode and (FInputMode in [imZoom, imRotate]) then
    Result := 'EDIT ON   |   ' + Result;
end;

procedure TRenderer.PlaceholderLines(out ALines: TStringArray);
begin
  if FImage = nil then
  begin
    SetLength(ALines, 1);
    ALines[0] := FMessage;
  end
  else
  begin
    SetLength(ALines, 3);
    ALines[0] := 'Cannot display this image';
    ALines[1] := ExtractFileName(FImage.Key.FileName);
    ALines[2] := FImage.ErrorMessage;
  end;
end;

procedure TRenderer.SetOverlayColorName(const AName: string);
begin
  FOverlayRGB[0] := 255;
  FOverlayRGB[1] := 255;
  FOverlayRGB[2] := 255;
  if SameText(Trim(AName), 'Yellow') then
    FOverlayRGB[2] := 0
  else if SameText(Trim(AName), 'Red') then
  begin
    FOverlayRGB[1] := 64;
    FOverlayRGB[2] := 64;
  end;
end;

function TRenderer.OverlayRed: Byte;
begin
  Result := FOverlayRGB[0];
end;

function TRenderer.OverlayGreen: Byte;
begin
  Result := FOverlayRGB[1];
end;

function TRenderer.OverlayBlue: Byte;
begin
  Result := FOverlayRGB[2];
end;

function TRenderer.OverlayTColor: TColor;
begin
  Result := RGBToColor(FOverlayRGB[0], FOverlayRGB[1], FOverlayRGB[2]);
end;

function TRenderer.DrawAngle: Double;
begin
  Result := FView.Angle;
end;

function TRenderer.ScreenToImage(AX, AY: Double; out AImgX, AImgY: Double): Boolean;
var
  LogW, LogH: Integer;
  Scale, DX, DY, Rad, C, S: Double;
begin
  AImgX := 0;
  AImgY := 0;
  LogicalSize(LogW, LogH);
  Scale := ScaleFor(FSurfaceWidth, FSurfaceHeight);
  if (Scale <= 0) or (LogW <= 0) or (LogH <= 0) then
    Exit(False);
  { Undo: shift to the image centre, turn back, scale back. }
  DX := AX - (FSurfaceWidth / 2 + FView.PanX);
  DY := AY - (FSurfaceHeight / 2 + FView.PanY);
  Rad := DegToRad(DrawAngle);
  C := Cos(Rad);
  S := Sin(Rad);
  { Mirrored: the image's x runs the other way (before the turn). }
  if FFilters.Mirror then
    AImgX := -(DX * C + DY * S) / Scale + LogW / 2
  else
    AImgX := (DX * C + DY * S) / Scale + LogW / 2;
  AImgY := (-DX * S + DY * C) / Scale + LogH / 2;
  Result := True;
end;

procedure TRenderer.ImageToScreen(AImgX, AImgY: Double; out AX, AY: Double);
var
  LogW, LogH: Integer;
  Scale, DX, DY, Rad, C, S: Double;
begin
  LogicalSize(LogW, LogH);
  Scale := ScaleFor(FSurfaceWidth, FSurfaceHeight);
  DX := (AImgX - LogW / 2) * Scale;
  DY := (AImgY - LogH / 2) * Scale;
  if FFilters.Mirror then
    DX := -DX;
  Rad := DegToRad(DrawAngle);
  C := Cos(Rad);
  S := Sin(Rad);
  { Screen y points down: this turns clockwise, like the image. }
  AX := FSurfaceWidth / 2 + FView.PanX + DX * C - DY * S;
  AY := FSurfaceHeight / 2 + FView.PanY + DX * S + DY * C;
end;

function TRenderer.SelectionCorners(out APoints: array of TPoint): Boolean;
var
  SX, SY: Double;

  procedure Corner(AIndex: Integer; AImgX, AImgY: Double);
  begin
    ImageToScreen(AImgX, AImgY, SX, SY);
    APoints[AIndex] := Point(Round(SX), Round(SY));
  end;

begin
  Result := FSelection.Active and (FImage <> nil) and not FImage.IsError
    and (Length(APoints) >= 4);
  if not Result then
    Exit;
  Corner(0, FSelection.X0, FSelection.Y0);
  Corner(1, FSelection.X1, FSelection.Y0);
  Corner(2, FSelection.X1, FSelection.Y1);
  Corner(3, FSelection.X0, FSelection.Y1);
end;

function TRenderer.IsUploading: Boolean;
begin
  Result := False;
end;

function TRenderer.ShownSize(out AWidth, AHeight: Integer): Boolean;
var
  LogW, LogH: Integer;
begin
  AWidth := 0;
  AHeight := 0;
  LogicalSize(LogW, LogH);
  Result := (FLastScale > 0) and (LogW > 0) and (LogH > 0);
  if not Result then
    Exit;
  AWidth := Max(1, Round(LogW * FLastScale));
  AHeight := Max(1, Round(LogH * FLastScale));
end;

function TRenderer.Description: string;
begin
  Result := '';
end;

procedure TRenderer.RequestScreenshot(const AFileName: string);
begin
  FScreenshotFile := AFileName;
  FScreenshotResult := '';
end;

function TRenderer.TakeScreenshotResult: string;
begin
  Result := FScreenshotResult;
  FScreenshotResult := '';
end;

{ TCpuRenderer }

destructor TCpuRenderer.Destroy;
begin
  ClearDisplay;
  ClearRotated;
  inherited Destroy;
end;

{ Paints one frame into a bitmap of the window's size and saves it. }
procedure TCpuRenderer.RequestScreenshot(const AFileName: string);
var
  Bmp: TBGRABitmap;
  W, H: Integer;
  SavedLatency: Double;
begin
  FScreenshotFile := '';
  W := FSurfaceWidth;
  H := FSurfaceHeight;
  if (W <= 0) or (H <= 0) then
  begin
    FScreenshotResult := 'view not saved: nothing painted yet';
    Exit;
  end;
  { This extra paint must not count as the first paint of an image. }
  SavedLatency := FLatencyStart;
  FLatencyStart := 0;
  Bmp := TBGRABitmap.Create(W, H);
  try
    try
      Paint(Bmp.Canvas, W, H);
      SaveBitmapAsPng(Bmp, AFileName);
      FScreenshotResult := 'view saved: ' + AFileName;
    except
      on E: Exception do
        FScreenshotResult := 'view not saved: ' + E.Message;
    end;
  finally
    Bmp.Free;
    FLatencyStart := SavedLatency;
  end;
end;

function TCpuRenderer.DrawAngle: Double;
begin
  Result := 90.0 * QuarterTurns;
end;

function TCpuRenderer.Description: string;
begin
  Result := 'CPU renderer';
  if FNote <> '' then
    Result := Result + ' (' + FNote + ')';
end;

procedure TCpuRenderer.ClearDisplay;
begin
  if FDisplayOwned then
    FDisplay.Free;
  FDisplay := nil;
  FDisplayOwned := False;
  FDisplayKey := '';
  FreeAndNil(FFiltered);
  FFilteredKey := '';
end;

procedure TCpuRenderer.ClearRotated;
begin
  FreeAndNil(FRotated);
  FRotatedTurns := 0;
  FRotatedMirror := False;
end;

function TCpuRenderer.SourceBitmap: TBGRACustomBitmap;
begin
  if Assigned(FRotated) then
    Result := FRotated
  else if Assigned(FImage) and not FImage.IsError then
    Result := FImage.Bitmap
  else
    Result := nil;
end;

procedure TCpuRenderer.ImageChanged(AKeepView: Boolean);
begin
  ClearDisplay;
  ClearRotated;
  if (QuarterTurns <> 0) or Filters.Mirror then
    RebuildRotated;
end;

procedure TCpuRenderer.TurnsChanged;
begin
  RebuildRotated;
end;

procedure TCpuRenderer.MirrorChanged;
begin
  RebuildRotated;
end;

procedure TCpuRenderer.RebuildRotated;
var
  Src, Mirrored: TBGRABitmap;
begin
  ClearDisplay;
  ClearRotated;
  if (FImage = nil) or FImage.IsError then
    Exit;

  { Mirrored first (in the image), then turned: as ImageToScreen. }
  Src := FImage.Bitmap;
  Mirrored := nil;
  try
    if Filters.Mirror then
    begin
      Mirrored := Src.Duplicate as TBGRABitmap;
      Mirrored.HorizontalFlip;
      Src := Mirrored;
    end;
    case QuarterTurns of
      1: FRotated := Src.RotateCW as TBGRACustomBitmap;
      2: if Mirrored <> nil then
         begin
           { Mirrored and turned 180 degrees: upside down, one copy. }
           Mirrored.HorizontalFlip;
           Mirrored.VerticalFlip;
           FRotated := Mirrored;
           Mirrored := nil;
         end
         else
         begin
           FRotated := Src.Duplicate as TBGRACustomBitmap;
           FRotated.HorizontalFlip;
           FRotated.VerticalFlip;
         end;
      3: FRotated := Src.RotateCCW as TBGRACustomBitmap;
    else
      if Mirrored <> nil then
      begin
        FRotated := Mirrored;     { handed over }
        Mirrored := nil;
      end;
    end;
  finally
    Mirrored.Free;
  end;
  FRotatedTurns := QuarterTurns;
  FRotatedMirror := Filters.Mirror;
end;

procedure TRenderer.SetPanel(ABitmap: TBGRABitmap; AX, AY: Integer; AVersion: Cardinal);
begin
  FPanel := ABitmap;
  FPanelX := AX;
  FPanelY := AY;
  FPanelVersion := AVersion;
end;

procedure TRenderer.SetFilterPanel(ABitmap: TBGRABitmap; AX, AY: Integer; AVersion: Cardinal);
begin
  FFilterPanel := ABitmap;
  FFilterPanelX := AX;
  FFilterPanelY := AY;
  FFilterPanelVersion := AVersion;
end;

procedure TRenderer.SetFilters(const AFilters: TFilterSettings);
var
  OldMirror: Boolean;
begin
  if SameFilters(AFilters, FFilters) then
    Exit;
  OldMirror := FFilters.Mirror;
  FFilters := AFilters;
  Inc(FFilterVersion);
  if OldMirror <> FFilters.Mirror then
    MirrorChanged;
end;

function TRenderer.FiltersAvailable: Boolean;
begin
  Result := True;
end;

procedure TCpuRenderer.Paint(ACanvas: TCanvas; AWidth, AHeight: Integer);
var
  StartMs: Double;
  NewImagePainted: Boolean;
  Lines: TStringArray;
  Corners: array[0..3] of TPoint;
begin
  StartMs := BeginPaint(AWidth, AHeight);

  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBlack;
  ACanvas.FillRect(0, 0, AWidth, AHeight);

  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;

  if (FImage = nil) or FImage.IsError then
  begin
    PlaceholderLines(Lines);
    DrawCenteredText(ACanvas, AWidth, AHeight, Lines);
  end
  else
  begin
    DrawImage(ACanvas, AWidth, AHeight);
    { The magnifier, over the image (the frame stays on top, as on the
      GPU). }
    DrawLens(ACanvas, AWidth, AHeight);
    { Edit mode: the selection, dark and light so it shows on any image. }
    if SelectionCorners(Corners) then
    begin
      ACanvas.Brush.Style := bsClear;
      ACanvas.Pen.Style := psSolid;
      ACanvas.Pen.Color := clBlack;
      ACanvas.Pen.Width := 3;
      ACanvas.Polygon(Corners);
      ACanvas.Pen.Color := clWhite;
      ACanvas.Pen.Width := 1;
      ACanvas.Polygon(Corners);
      ACanvas.Brush.Style := bsSolid;
    end;
  end;

  { Measured before the overlays, so the numbers can be shown in this
    same paint. }
  NewImagePainted := EndImagePart(StartMs);

  DrawOverlays(ACanvas, AWidth, AHeight);
  { The mode badge, bottom right (blinking: drawn while BadgeOn). }
  if FBadgeOn and (BadgeBitmap <> nil) then
    BadgeBitmap.Draw(ACanvas, AWidth - BadgeBitmap.Width - 8,
      AHeight - BadgeBitmap.Height - 6, False);
  { A notice, in the middle (flashing: drawn while NoticeOn). }
  if FNoticeOn and (NoticeBitmap <> nil) then
    NoticeBitmap.Draw(ACanvas, (AWidth - NoticeBitmap.Width) div 2,
      (AHeight - NoticeBitmap.Height) div 2, False);
  { The sort panel, on top (with its transparency). }
  if Assigned(Panel) then
    Panel.Draw(ACanvas, PanelX, PanelY, False);
  if Assigned(FilterPanel) then
    FilterPanel.Draw(ACanvas, FilterPanelX, FilterPanelY, False);

  if NewImagePainted then
    ReportPainted;
end;

{ Draws only the visible part of the image. The source rectangle that
  maps onto the window is cut out and scaled to its size on screen.
  The result is cached, so a repaint without a view change costs only
  one blit. }
procedure TCpuRenderer.DrawImage(ACanvas: TCanvas; AWidth, AHeight: Integer);
var
  Src, Part: TBGRACustomBitmap;
  ImgW, ImgH, LogW, LogH: Integer;
  Scale, X0, Y0: Double;
  UsePreview: Boolean;
  DX0, DY0, DX1, DY1: Double;            { visible area on screen }
  SX0, SY0, SX1, SY1: Integer;           { matching source pixels }
  RX0, RY0, RW, RH: Integer;             { where they go on screen }
  Key: string;
  Mode: TResampleMode;
begin
  if (FRotatedTurns <> QuarterTurns) or (FRotatedMirror <> Filters.Mirror) then
    RebuildRotated;
  Src := SourceBitmap;
  if (Src = nil) or (Src.Width <= 0) or (Src.Height <= 0) then
    Exit;

  { Geometry in original pixels (see "Quality levels" above), after
    the quarter turns. }
  TurnedLogicalSize(LogW, LogH);
  Scale := ScaleFor(AWidth, AHeight);
  if (Scale <= 0) or (LogW <= 0) then
    Exit;
  FLastScale := Scale;   { the info overlay reports the real scale }

  { Shown no larger than the screen-size copy? Then draw from the copy.
    Only without rotation: the rotated bitmap is made from the main
    bitmap. The size on screen stays exactly the same. }
  UsePreview := (FRotated = nil) and Assigned(FImage.Preview)
    and (LogW * Scale <= FImage.Preview.Width + 0.5);
  if UsePreview then
    Src := FImage.Preview;

  { From here on: pixels of the bitmap actually drawn. }
  Scale := Scale * LogW / Src.Width;
  ImgW := Src.Width;
  ImgH := Src.Height;

  { A quick view or screen copy made on the worker for exactly this
    fit (uImageScaling.FitSize) comes out within a pixel of its own
    size: draw it 1:1, so the UI thread does no resampling at all. }
  if (Abs(ImgW * Scale - ImgW) < 1.0) and (Abs(ImgH * Scale - ImgH) < 1.0) then
    Scale := 1.0;

  { Top-left corner of the whole scaled image on screen. At exactly
    100 % it is placed on whole pixels, so 1:1 really is 1:1. }
  X0 := (AWidth - ImgW * Scale) / 2 + FView.PanX;
  Y0 := (AHeight - ImgH * Scale) / 2 + FView.PanY;
  if SameValue(Scale, 1.0) then
  begin
    X0 := Round(X0);
    Y0 := Round(Y0);
  end;

  { Visible part of the scaled image. }
  DX0 := Max(ZeroD, X0);
  DY0 := Max(ZeroD, Y0);
  DX1 := Min(Double(AWidth), X0 + ImgW * Scale);
  DY1 := Min(Double(AHeight), Y0 + ImgH * Scale);
  if (DX1 <= DX0) or (DY1 <= DY0) then
    Exit;

  { Source pixels covering it, widened to whole pixels. }
  SX0 := EnsureRange(Floor((DX0 - X0) / Scale), 0, ImgW - 1);
  SY0 := EnsureRange(Floor((DY0 - Y0) / Scale), 0, ImgH - 1);
  SX1 := EnsureRange(Ceil((DX1 - X0) / Scale), SX0 + 1, ImgW);
  SY1 := EnsureRange(Ceil((DY1 - Y0) / Scale), SY0 + 1, ImgH);

  { Where those whole source pixels land on screen. }
  RX0 := Round(X0 + SX0 * Scale);
  RY0 := Round(Y0 + SY0 * Scale);
  RW := Max(1, Round(X0 + SX1 * Scale) - RX0);
  RH := Max(1, Round(Y0 + SY1 * Scale) - RY0);

  Key := Format('%d,%d,%d,%d>%d,%d|%d|%s|%s',
    [SX0, SY0, SX1, SY1, RW, RH, FRotatedTurns, BoolToStr(UsePreview, 'P', 'F'),
     BoolToStr(FRotatedMirror, 'M', '-')]);
  if (FDisplay = nil) or (Key <> FDisplayKey) then
  begin
    ClearDisplay;

    if Scale < 1.0 then
      Mode := rmFineResample
    else
      Mode := rmSimpleStretch;

    if (SX0 = 0) and (SY0 = 0) and (SX1 = ImgW) and (SY1 = ImgH) then
    begin
      { The whole image is visible: scale it directly, no copy. }
      if (RW = ImgW) and (RH = ImgH) then
      begin
        FDisplay := Src;          { 1:1 and fully visible: draw as is }
        FDisplayOwned := False;
      end
      else
      begin
        FDisplay := Src.Resample(RW, RH, Mode) as TBGRACustomBitmap;
        FDisplayOwned := True;
      end;
    end
    else
    begin
      Part := Src.GetPart(Rect(SX0, SY0, SX1, SY1)) as TBGRACustomBitmap;
      try
        if (RW = Part.Width) and (RH = Part.Height) then
        begin
          FDisplay := Part;
          Part := nil;           { handed over, don't free }
        end
        else
          FDisplay := Part.Resample(RW, RH, Mode) as TBGRACustomBitmap;
      finally
        Part.Free;
      end;
      FDisplayOwned := True;
    end;

    FDisplayKey := Key;
  end;

  { The filters: on a copy of the screen-sized part only (a few million
    pixels at most), made again when the part or the filters change. }
  if not ColourNeutral(Filters) then
  begin
    Key := FDisplayKey + '#' + IntToStr(FilterVersion);
    if (FFiltered = nil) or (Key <> FFilteredKey) then
    begin
      FreeAndNil(FFiltered);
      FFiltered := FDisplay.Duplicate as TBGRACustomBitmap;
      ApplyFiltersToBitmap(FFiltered, Filters);
      FFilteredKey := Key;
    end;
    FFiltered.Draw(ACanvas, RX0, RY0, True);
  end
  else
  begin
    if Assigned(FFiltered) then
    begin
      FreeAndNil(FFiltered);    { back to neutral: the copy isn't needed }
      FFilteredKey := '';
    end;
    FDisplay.Draw(ACanvas, RX0, RY0, True);
  end;
end;

{ The magnifier: what lies under the lens, Mag times larger than on
  screen, from the full image (not the screen-sized copy: the point is
  to see its real pixels), sharpened, filtered, cut round, with a dark
  and a light rim. Small (the lens' size), made again every paint. }
procedure TCpuRenderer.DrawLens(ACanvas: TCanvas; AWidth, AHeight: Integer);
const
  NearestFrom = 4.0;       { as the GPU: from 4 x on, pixels are squares }
  MaxPartPixels = 4000000; { more source pixels than this: sampled, not resampled }
var
  L: TLensState;
  Src: TBGRACustomBitmap;
  Part, Scaled, LensBmp: TBGRABitmap;
  LogW, LogH, D, SX0, SY0, SX1, SY1, RX, RY, RW, RH, X, Y, SXI, SYI: Integer;
  Scale, S2, X0, Y0, LX0, LY0, R, DX, DY: Double;
  P, SrcRow: PBGRAPixel;
begin
  L := Lens;
  if (not L.Active) or (FImage = nil) or FImage.IsError or (L.Radius < 4) or (L.Mag <= 0) then
    Exit;
  if (FRotatedTurns <> QuarterTurns) or (FRotatedMirror <> Filters.Mirror) then
    RebuildRotated;
  Src := SourceBitmap;
  if (Src = nil) or (Src.Width <= 0) or (Src.Height <= 0) then
    Exit;
  TurnedLogicalSize(LogW, LogH);
  Scale := ScaleFor(AWidth, AHeight);
  if (Scale <= 0) or (LogW <= 0) then
    Exit;
  { Less than the real pixels in the lens (a large image, zoomed out):
    the screen-size copy is enough and far smaller (as DrawImage, only
    without turns or mirror). }
  if (FRotated = nil) and Assigned(FImage.Preview)
    and (LogW * Scale * L.Mag <= FImage.Preview.Width + 0.5) then
    Src := FImage.Preview;
  { Bitmap pixels -> screen, as in DrawImage; then around the lens'
    centre, Mag times. }
  Scale := Scale * LogW / Src.Width;
  X0 := (AWidth - Src.Width * Scale) / 2 + FView.PanX;
  Y0 := (AHeight - Src.Height * Scale) / 2 + FView.PanY;
  S2 := Scale * L.Mag;
  LX0 := L.X + (X0 - L.X) * L.Mag;
  LY0 := L.Y + (Y0 - L.Y) * L.Mag;
  R := L.Radius;
  D := Max(8, Round(2 * R));

  { The source pixels under the lens, one more on each side (for the
    sharpening). }
  SX0 := Max(0, Floor((L.X - R - LX0) / S2) - 1);
  SY0 := Max(0, Floor((L.Y - R - LY0) / S2) - 1);
  SX1 := Min(Src.Width, Ceil((L.X + R - LX0) / S2) + 1);
  SY1 := Min(Src.Height, Ceil((L.Y + R - LY0) / S2) + 1);

  LensBmp := TBGRABitmap.Create(D, D, BGRA(0, 0, 0, 255));
  try
    if (SX1 > SX0) and (SY1 > SY0) then
    begin
      if Int64(SX1 - SX0) * (SY1 - SY0) <= MaxPartPixels then
      begin
        { Sharpened at the image's own pixels (as the GPU, per texel),
          then made larger. }
        Part := Src.GetPart(Rect(SX0, SY0, SX1, SY1)) as TBGRABitmap;
        try
          SharpenBitmap(Part, LensSharpenAmount(L.Sharpen));
          if S2 >= NearestFrom then
          begin
            { Each lens pixel takes its source pixel (squares). }
            for Y := 0 to D - 1 do
            begin
              SYI := Floor((L.Y - R + Y + 0.5 - LY0) / S2) - SY0;
              if (SYI < 0) or (SYI >= Part.Height) then
                Continue;
              SrcRow := Part.ScanLine[SYI];
              P := LensBmp.ScanLine[Y];
              for X := 0 to D - 1 do
              begin
                SXI := Floor((L.X - R + X + 0.5 - LX0) / S2) - SX0;
                if (SXI >= 0) and (SXI < Part.Width) then
                  P[X] := SrcRow[SXI];
              end;
            end;
            LensBmp.InvalidateBitmap;
          end
          else
          begin
            RX := Round(LX0 + SX0 * S2 - (L.X - R));
            RY := Round(LY0 + SY0 * S2 - (L.Y - R));
            RW := Max(1, Round(LX0 + SX1 * S2) - Round(LX0 + SX0 * S2));
            RH := Max(1, Round(LY0 + SY1 * S2) - Round(LY0 + SY0 * S2));
            Scaled := Part.Resample(RW, RH, rmFineResample) as TBGRABitmap;
            try
              LensBmp.PutImage(RX, RY, Scaled, dmSet);
            finally
              Scaled.Free;
            end;
          end;
        finally
          Part.Free;
        end;
      end
      else
      begin
        { Very many source pixels (a huge image far out, no screen copy):
          sampled, each lens pixel one source pixel; fast, a little rough. }
        for Y := 0 to D - 1 do
        begin
          SYI := Floor((L.Y - R + Y + 0.5 - LY0) / S2);
          if (SYI < 0) or (SYI >= Src.Height) then
            Continue;
          SrcRow := Src.ScanLine[SYI];
          P := LensBmp.ScanLine[Y];
          for X := 0 to D - 1 do
          begin
            SXI := Floor((L.X - R + X + 0.5 - LX0) / S2);
            if (SXI >= 0) and (SXI < Src.Width) then
              P[X] := SrcRow[SXI];
          end;
        end;
        LensBmp.InvalidateBitmap;
      end;
    end;

    if not ColourNeutral(Filters) then
      ApplyFiltersToBitmap(LensBmp, Filters);

    { Round: outside the circle transparent. }
    for Y := 0 to D - 1 do
    begin
      P := LensBmp.ScanLine[Y];
      DY := Y + 0.5 - D / 2;
      for X := 0 to D - 1 do
      begin
        DX := X + 0.5 - D / 2;
        if DX * DX + DY * DY > (D / 2) * (D / 2) then
          P[X].alpha := 0;
      end;
    end;
    LensBmp.InvalidateBitmap;
    LensBmp.Draw(ACanvas, Round(L.X - D / 2), Round(L.Y - D / 2), False);
  finally
    LensBmp.Free;
  end;

  { The rim: dark under light, so it shows on any image. }
  ACanvas.Brush.Style := bsClear;
  ACanvas.Pen.Style := psSolid;
  ACanvas.Pen.Color := clBlack;
  ACanvas.Pen.Width := 3;
  ACanvas.Ellipse(Round(L.X - D / 2), Round(L.Y - D / 2), Round(L.X + D / 2), Round(L.Y + D / 2));
  if L.Locked then
    ACanvas.Pen.Color := RGBToColor(255, 190, 60)
  else
    ACanvas.Pen.Color := clWhite;
  ACanvas.Pen.Width := 1;
  ACanvas.Ellipse(Round(L.X - D / 2), Round(L.Y - D / 2), Round(L.X + D / 2), Round(L.Y + D / 2));
  ACanvas.Brush.Style := bsSolid;
end;

procedure TCpuRenderer.DrawCenteredText(ACanvas: TCanvas; AWidth, AHeight: Integer;
  const ALines: array of string);
var
  I, LineHeight, Y: Integer;
begin
  ACanvas.Font.Color := clSilver;
  ACanvas.Font.Height := -16;
  ACanvas.Brush.Style := bsClear;

  LineHeight := ACanvas.TextHeight('Xg') + 6;
  Y := (AHeight - LineHeight * Length(ALines)) div 2;
  for I := Low(ALines) to High(ALines) do
  begin
    ACanvas.TextOut((AWidth - ACanvas.TextWidth(ALines[I])) div 2, Y, ALines[I]);
    Inc(Y, LineHeight);
  end;

  ACanvas.Brush.Style := bsSolid;
end;

{ Draws one line of white text straight over the image, with a thin
  black outline so it reads on bright images too (no box behind it).
  Its bottom edge is at ABottom. Returns the top edge, where the next
  line can sit. }
{ AText cut with "..." to AMaxWidth px (0: as it is). }
function FitCanvasText(ACanvas: TCanvas; const AText: string; AMaxWidth: Integer): string;
var
  N: Integer;
begin
  Result := AText;
  if (AMaxWidth <= 0) or (ACanvas.TextWidth(Result) <= AMaxWidth) then
    Exit;
  N := Length(AText);
  while (N > 0) and (ACanvas.TextWidth(Copy(AText, 1, N) + '...') > AMaxWidth) do
    Dec(N);
  { Not inside a UTF-8 character. }
  while (N > 0) and ((Ord(AText[N + 1]) and $C0) = $80) do
    Dec(N);
  Result := Copy(AText, 1, N) + '...';
end;

function TCpuRenderer.DrawBar(ACanvas: TCanvas; AWidth, ABottom: Integer; const AText: string;
  ASolid: Boolean): Integer;
var
  TextH, DX, DY: Integer;
begin
  { The font is the caller's (the info line has its own). }
  TextH := ACanvas.TextHeight(AText);
  Result := ABottom - TextH - 8;

  if ASolid then
  begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := clBlack;
    ACanvas.FillRect(0, Result, AWidth, ABottom);
  end;
  ACanvas.Brush.Style := bsClear;
  if not ASolid then
  begin
    ACanvas.Font.Color := clBlack;
    for DY := -1 to 1 do
      for DX := -1 to 1 do
        if (DX <> 0) or (DY <> 0) then
          ACanvas.TextOut(8 + DX, Result + 4 + DY, AText);
  end;
  ACanvas.Font.Color := OverlayTColor;
  ACanvas.TextOut(8, Result + 4, AText);
  ACanvas.Brush.Style := bsSolid;
end;

{ Bottom: file info, above it the diagnostics. Top: the mode label. }
procedure TCpuRenderer.DrawOverlays(ACanvas: TCanvas; AWidth, AHeight: Integer);
var
  Bottom, TextH, TopUsed, I: Integer;
  Text, OldFontName: string;
  Lines: TStringArray;

  { White text with a dark outline at AX, AY. }
  procedure TextAt(AX, AY: Integer; const AText: string);
  var
    DX, DY: Integer;
  begin
    ACanvas.Brush.Style := bsClear;
    ACanvas.Font.Color := clBlack;
    for DY := -1 to 1 do
      for DX := -1 to 1 do
        if (DX <> 0) or (DY <> 0) then
          ACanvas.TextOut(AX + DX, AY + DY, AText);
    ACanvas.Font.Color := OverlayTColor;
    ACanvas.TextOut(AX, AY, AText);
    ACanvas.Brush.Style := bsSolid;
  end;

begin
  Bottom := AHeight;
  ACanvas.Font.Height := -13;

  Text := InfoLine;
  if Text <> '' then
  begin
    { Its own font ([InfoLine] Font / FontSize, Day 24). }
    OldFontName := ACanvas.Font.Name;
    if InfoFontName <> '' then
      ACanvas.Font.Name := InfoFontName;
    if InfoFontSize > 0 then
      ACanvas.Font.Size := InfoFontSize
    else
      ACanvas.Font.Height := -13;
    { It ends before the mode badge (bottom right). }
    Text := FitCanvasText(ACanvas, Text, AWidth - 16 - BadgeRoom);
    Bottom := DrawBar(ACanvas, AWidth, Bottom, Text, OverlaySolid);
    ACanvas.Font.Name := OldFontName;
    ACanvas.Font.Height := -13;
  end;

  { The diagnostics may have several lines: the last at the bottom. }
  Text := DiagnosticsLine;
  if Text <> '' then
  begin
    Lines := SplitAtLineBreaks(Text);
    for I := High(Lines) downto 0 do
      if Lines[I] <> '' then
        Bottom := DrawBar(ACanvas, AWidth, Bottom, Lines[I], OverlaySolid);
  end;

  TopUsed := 0;
  Text := ModeLine;
  if Text <> '' then
  begin
    ACanvas.Font.Height := -13;
    TextH := ACanvas.TextHeight(Text);
    DrawBar(ACanvas, AWidth, TextH + 8, Text);
    TopUsed := TextH + 8;
  end;

  ACanvas.Font.Height := -13;
  if ZoneLabel <> '' then
  begin
    TextH := ACanvas.TextHeight(ZoneLabel) + 8;
    case ZoneCorner of
      0: TextAt(8, TopUsed + 4, ZoneLabel);
      1: TextAt(AWidth - ACanvas.TextWidth(ZoneLabel) - 8, 4, ZoneLabel);
      2: TextAt(8, Bottom - TextH + 4, ZoneLabel);
    else
      TextAt(AWidth - ACanvas.TextWidth(ZoneLabel) - 8, Bottom - TextH + 4, ZoneLabel);
    end;
  end;

  if GestureText <> '' then
  begin
    ACanvas.Font.Height := -20;
    TextAt((AWidth - ACanvas.TextWidth(GestureText)) div 2,
      (AHeight - ACanvas.TextHeight(GestureText)) div 2, GestureText);
    ACanvas.Font.Height := -13;
  end;
end;

end.
