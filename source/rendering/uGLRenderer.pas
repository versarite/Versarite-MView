unit uGLRenderer;

{
  Unit: uGLRenderer

  Purpose
  -------
  The GPU renderer (spec §8.5, the key feature). The image is uploaded
  to the graphics card once, as textures; zoom, pan and rotation then
  only change a transformation, so they stay smooth at any image size.

  Owns
  ----
  - The OpenGL textures of the image shown (FShown) and of the one
    being uploaded (FPending), each a TGLImageTextures.
  - Small textures for the text bars (info, diagnostics, mode label,
    placeholder, zone label, gesture text).
  - FDeleteQueue: textures waiting to be deleted in the next paint.

  Knows
  -----
  - The TOpenGLControl it draws into (for the context); owned by the
    view (uGLMediaView).
  - The current IDecodedImage (shared, read only; each
    TGLImageTextures holds a reference that keeps its bitmap alive).

  Responsibilities
  ----------------
  - Check at creation what the GPU can do; raise EGLUnsuitable if it
    is not good enough.
  - Plan tiles, upload them in steps, draw them with the view
    transformation, draw the edit-mode selection frame and the text
    bars, swap the buffers.
  - Start again from scratch when the context is lost (ContextLost).
  - Save a picture of the window (the frame just drawn) on request.

  Does NOT
  --------
  - Decode, cache, navigate or handle input.
  - Make GL calls outside Paint (and the constructor), nor in the
    destructor: the context may already be gone.

  Threads
  -------
  UI thread only: Paint is called by the view's paint handler with the
  context current. Further upload steps are asked for with
  Invalidate, not with a thread.

  Uses (MView units)
  ------------------
  interface:      uDecodedImage, uRenderer, uImageSaver, uStopwatch
  Libraries:      Classes, Types, SysUtils, Math, GL, OpenGLContext,
                  BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uGLMediaView, uMainForm

  How
  ---
  Tiles: a 12000 x 9000 image is larger than a GPU accepts as one
  texture, so it is cut into tiles of up to 1024 x 1024. Each tile
  carries a 1-pixel border from its neighbours, so linear filtering
  shows no seams between tiles.
  Mipmaps (glGenerateMipmap; GL_GENERATE_MIPMAP as the fallback): zoomed-out views stay sharp and free
  of aliasing. Above 400 % pixels are shown as sharp squares (nearest),
  so single pixels can be inspected.
  Pixels go straight from the BGRABitmap memory to the GPU
  (GL_UNPACK_ROW_LENGTH, GL_UNPACK_SKIP_PIXELS, GL_UNPACK_SKIP_ROWS),
  no copy; BGRABitmap's bottom-up row order on Windows is handled in
  the texture coordinates.
  Upload in steps: a large image is uploaded a few tiles per frame
  (about 12 ms each), so the window never stalls. Meanwhile the small
  version is shown: the screen copy of a new image, or the quick view
  when the full image arrives (spec §7.1). The full image's tiles are
  drawn over it as soon as each is on the GPU, the ones in the middle
  of the view first, so the part being looked at sharpens first.
  Mipmaps are made by the GPU (glGenerateMipmap) after each tile; the
  D line shows the time per tile for pixels and mipmaps.
  Text bars (info, diagnostics, mode label, placeholder) are drawn with
  BGRABitmap into small bitmaps and shown as textures; they are only
  redrawn when their text changes. Info, diagnostics and mode label
  are text with a thin dark outline straight over the image (no box),
  in the overlay colour ([View] OverlayColor: White, Yellow or Red);
  with [View] OverlaySolid=1 info and diagnostics sit on a solid
  black bar. The placeholder message stays on black.

  Notes
  -----
  All GL calls happen in Paint, with the context current. Textures
  that are no longer needed are queued and deleted in the next paint.
  Needs OpenGL 2.0 or later (for mipmaps of any texture size); the
  constructor raises EGLUnsuitable otherwise, and the form falls back
  to the CPU renderer.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  Types,
  SysUtils,
  Math,
  GL,
  OpenGLContext,
  BGRABitmap,
  BGRABitmapTypes,
  uDecodedImage,
  uRenderer,
  uImageSaver,
  uStopwatch;

type
  EGLUnsuitable = class(Exception);

  TGLTile = record
    Texture: GLuint;
    { Content rectangle in bitmap pixels (rows counted from the top). }
    CX0, CY0, CX1, CY1: Integer;
    { Texture coordinates of the content's corners. }
    U0, U1, VTop, VBottom: Single;
  end;

  { The textures of one bitmap. }
  TGLImageTextures = class(TObject)
  public
    Image: IDecodedImage;        { keeps the bitmap alive }
    Bitmap: TBGRACustomBitmap;   { what is uploaded: Bitmap or Preview }
    Tiles: array of TGLTile;
    Uploaded: Integer;           { tiles done }
    Failed: Boolean;             { e.g. out of video memory }
    UploadMs: Double;
    function Complete: Boolean;
  end;

  { glGenerateMipmap (OpenGL 3.0 / GL_EXT_framebuffer_object), loaded
    at run time. }
  TGLGenerateMipmapProc = procedure(target: GLenum); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}

  TGLTextBar = record
    Text: string;
    Texture: GLuint;
    Width, Height: Integer;
  end;

  { TGLRenderer }

  TGLRenderer = class(TRenderer)
  private
    FControl: TOpenGLControl;
    FShown: TGLImageTextures;    { drawn now }
    FPending: TGLImageTextures;  { being uploaded; replaces FShown when done }
    FDeleteQueue: array of GLuint;
    FTileSize: Integer;
    FUseMipMaps: Boolean;
    FGLName: string;
    FGLVersion: string;
    FLastUploadMs: Double;
    FGpuNote: string;            { e.g. "full image too large for the GPU" }
    FGenerateMipmap: TGLGenerateMipmapProc;   { nil: GL_GENERATE_MIPMAP }

    { Upload measurements (D line): per tile, pixels and mipmaps. }
    FTilesDone: Integer;
    FTexMs: Double;
    FMipMs: Double;

    { Pending tiles near this bitmap point go up first (the middle of
      the view), so the part being looked at gets sharp first. }
    FFocusX, FFocusY: Double;

    FInfoBar: TGLTextBar;
    FDiagBar: TGLTextBar;
    FModeBar: TGLTextBar;
    FCenterBar: TGLTextBar;
    FZoneBar: TGLTextBar;        { mouse language: the zone's name }
    FGestureBar: TGLTextBar;     { mouse language: what the gesture does }
    FPanelBar: TGLTextBar;       { the sort panel (Phase G) }
    FPanelUploaded: Cardinal;    { PanelVersion of the texture in FPanelBar }

    function MakeTextures(const AImage: IDecodedImage; ABitmap: TBGRACustomBitmap): TGLImageTextures;
    procedure DropTextures(var ATextures: TGLImageTextures);
    procedure DeleteQueued;
    function UploadTile(ATextures: TGLImageTextures; AIndex: Integer): Boolean;
    procedure UploadSome(ATextures: TGLImageTextures; ABudgetMs: Double);
    function NextTile(ATextures: TGLImageTextures): Integer;
    procedure UpdateFocus(ATextures: TGLImageTextures; AWidth, AHeight: Integer);
    procedure DrawTextures(ATextures: TGLImageTextures; AWidth, AHeight: Integer);
    procedure UpdateBar(var ABar: TGLTextBar; const AText: string; ACentered: Boolean);
    procedure UpdatePanel;
    { ASolidWidth > 0: a solid black bar that wide behind the text
      (OverlaySolid) instead of the outline. }
    procedure DrawBar(const ABar: TGLTextBar; AX, AY: Integer; AOverlay: Boolean = False;
      ASolidWidth: Integer = 0);
    procedure SetupScreenProjection(AWidth, AHeight: Integer);
    procedure PlanForCurrentImage;
    procedure CaptureFrame(AWidth, AHeight: Integer);
  protected
    procedure ImageChanged(AKeepView: Boolean); override;
  public
    { AControl must have its handle; the context is made current here
      to check what the GPU can do. }
    constructor Create(AControl: TOpenGLControl; AUseMipMaps: Boolean); reintroduce;
    destructor Destroy; override;

    { Draws a frame. Called by the view's paint handler with the
      context current; swaps the buffers itself. }
    procedure Paint(AWidth, AHeight: Integer);

    { The view's window (and with it the OpenGL context and all its
      textures) is about to be destroyed, e.g. when switching to
      fullscreen. Forgets every texture; the next paint uploads again. }
    procedure ContextLost;

    function Description: string; override;
    function IsUploading: Boolean; override;
    property GLName: string read FGLName;
  end;

implementation

const
  { Not in FPC's GL 1.1 unit. }
  MV_GL_BGRA = $80E1;
  MV_GL_CLAMP_TO_EDGE = $812F;
  MV_GL_GENERATE_MIPMAP = $8191;

  { Per frame, while a large image is being uploaded. }
  UploadBudgetMs = 12.0;

  { Tile size. 1024 (4 MB) rather than 2048: finer steps, so the view
    stays responsive and the visible part sharpens sooner. }
  PreferredTileSize = 1024;

  { From this scale on, pixels are shown as squares (no smoothing). }
  NearestFromScale = 4.0;

var
  PixelOrderIsBGRA: Boolean;

{$IFDEF WINDOWS}
function MViewWglGetProcAddress(AName: PAnsiChar): Pointer; stdcall;
  external 'opengl32.dll' name 'wglGetProcAddress';
{$ENDIF}

{ Errors left over from earlier calls must not be taken for an upload
  failure. }
procedure ClearGLErrors;
var
  I: Integer;
begin
  for I := 1 to 16 do
    if glGetError() = GL_NO_ERROR then
      Exit;
end;

function SplitLines(const AText: string): TStringArray;
var
  P, Start, N: Integer;
begin
  Result := nil;
  Start := 1;
  for P := 1 to Length(AText) + 1 do
    if (P > Length(AText)) or (AText[P] = #10) then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Copy(AText, Start, P - Start);
      Start := P + 1;
    end;
end;

function JoinLines(const ALines: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ALines) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + ALines[I];
  end;
end;

{ TGLImageTextures }

function TGLImageTextures.Complete: Boolean;
begin
  Result := Failed or (Uploaded >= Length(Tiles));
end;

{ TGLRenderer }

constructor TGLRenderer.Create(AControl: TOpenGLControl; AUseMipMaps: Boolean);
var
  MaxSize: GLint;
  P: PChar;
  Major: Integer;
begin
  inherited Create;
  FControl := AControl;
  FUseMipMaps := AUseMipMaps;

  if not FControl.MakeCurrent then
    raise EGLUnsuitable.Create('no OpenGL context');

  P := glGetString(GL_VERSION);
  if P <> nil then
    FGLVersion := string(P);
  P := glGetString(GL_RENDERER);
  if P <> nil then
    FGLName := string(P);

  { "4.6.0 NVIDIA 551.23" -> 4 }
  Major := StrToIntDef(Copy(FGLVersion, 1, Pos('.', FGLVersion + '.') - 1), 0);
  if Major < 2 then
    raise EGLUnsuitable.CreateFmt('OpenGL %s is too old (2.0 needed)', [FGLVersion]);
  if Pos('GDI Generic', FGLName) > 0 then
    raise EGLUnsuitable.Create('only the Windows software OpenGL is available');

  MaxSize := 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, @MaxSize);
  FTileSize := PreferredTileSize;
  if (MaxSize > 0) and (MaxSize < FTileSize) then
    FTileSize := MaxSize;
  if FTileSize < 256 then
    raise EGLUnsuitable.CreateFmt('maximum texture size %d is too small', [MaxSize]);

  { Mipmaps made by the GPU in one call after the upload. The old
    automatic GL_GENERATE_MIPMAP is only the fallback: with it, uploads
    measured about 35 MB/s on a GTX 960M (600 ms per 2048 x 2048 tile). }
  FGenerateMipmap := nil;
  {$IFDEF WINDOWS}
  Pointer(FGenerateMipmap) := MViewWglGetProcAddress('glGenerateMipmap');
  if PtrUInt(Pointer(FGenerateMipmap)) <= 3 then
    Pointer(FGenerateMipmap) := MViewWglGetProcAddress('glGenerateMipmapEXT');
  { Some drivers return 1, 2 or 3 instead of nil for "not there". }
  if PtrUInt(Pointer(FGenerateMipmap)) <= 3 then
    FGenerateMipmap := nil;
  {$ENDIF}
end;

destructor TGLRenderer.Destroy;
begin
  { No GL calls here: the context may already be gone. Its textures go
    with it. }
  FreeAndNil(FShown);
  FreeAndNil(FPending);
  inherited Destroy;
end;

function TGLRenderer.IsUploading: Boolean;
begin
  Result := (FPending <> nil) or ((FShown <> nil) and not FShown.Complete);
end;

function TGLRenderer.Description: string;
begin
  Result := 'GPU ' + FGLName;
  if FLastUploadMs > 0 then
    Result := Result + Format('   upload %d ms', [Round(FLastUploadMs)]);
  if (FShown <> nil) and (Length(FShown.Tiles) > 1) then
    Result := Result + Format('   %d tiles', [Length(FShown.Tiles)]);
  if FPending <> nil then
    Result := Result + Format('   sharpening %d / %d', [FPending.Uploaded, Length(FPending.Tiles)]);
  if FTilesDone > 0 then
    Result := Result + Format('   per tile: pixels %.1f + mipmaps %.1f ms',
      [FTexMs / FTilesDone, FMipMs / FTilesDone]);
  if not Assigned(FGenerateMipmap) then
    Result := Result + '   (old mipmaps)';
  if FGpuNote <> '' then
    Result := Result + '   (' + FGpuNote + ')';
end;

{ Plans the tiles; nothing is uploaded yet. }
function TGLRenderer.MakeTextures(const AImage: IDecodedImage;
  ABitmap: TBGRACustomBitmap): TGLImageTextures;
var
  Step, W, H, NX, NY, I, J, K: Integer;
begin
  Result := TGLImageTextures.Create;
  Result.Image := AImage;
  Result.Bitmap := ABitmap;
  W := ABitmap.Width;
  H := ABitmap.Height;

  { Content per tile; the texture adds up to 1 pixel on each side. }
  Step := FTileSize - 2;
  NX := (W + Step - 1) div Step;
  NY := (H + Step - 1) div Step;
  SetLength(Result.Tiles, NX * NY);
  K := 0;
  for J := 0 to NY - 1 do
    for I := 0 to NX - 1 do
    begin
      Result.Tiles[K].Texture := 0;
      Result.Tiles[K].CX0 := I * Step;
      Result.Tiles[K].CY0 := J * Step;
      Result.Tiles[K].CX1 := Min(W, (I + 1) * Step);
      Result.Tiles[K].CY1 := Min(H, (J + 1) * Step);
      Inc(K);
    end;
  Result.Uploaded := 0;
end;

{ Queues the textures for deletion (next paint) and frees the object. }
procedure TGLRenderer.DropTextures(var ATextures: TGLImageTextures);
var
  I, N: Integer;
begin
  if ATextures = nil then
    Exit;
  for I := 0 to High(ATextures.Tiles) do
    if ATextures.Tiles[I].Texture <> 0 then
    begin
      N := Length(FDeleteQueue);
      SetLength(FDeleteQueue, N + 1);
      FDeleteQueue[N] := ATextures.Tiles[I].Texture;
    end;
  FreeAndNil(ATextures);
end;

procedure TGLRenderer.DeleteQueued;
begin
  if Length(FDeleteQueue) > 0 then
  begin
    glDeleteTextures(Length(FDeleteQueue), @FDeleteQueue[0]);
    FDeleteQueue := nil;
  end;
end;

procedure TGLRenderer.ImageChanged(AKeepView: Boolean);
begin
  DropTextures(FPending);

  if (FImage = nil) or FImage.IsError then
  begin
    DropTextures(FShown);
    Exit;
  end;

  if AKeepView and (FShown <> nil) then
  begin
    { A better version of the image shown: keep drawing the old one
      until the new one is fully on the GPU. }
    FGpuNote := '';
    FPending := MakeTextures(FImage, FImage.Bitmap);
    Exit;
  end;

  FGpuNote := '';
  DropTextures(FShown);
  PlanForCurrentImage;
end;

{ A new image: show its screen copy at once (small, one tile), and
  upload the full bitmap in the background if there is more. }
procedure TGLRenderer.PlanForCurrentImage;
var
  Small: TBGRACustomBitmap;
begin
  if (FImage = nil) or FImage.IsError then
    Exit;
  Small := FImage.Preview;
  if Small <> nil then
  begin
    FShown := MakeTextures(FImage, Small);
    FPending := MakeTextures(FImage, FImage.Bitmap);
  end
  else
    FShown := MakeTextures(FImage, FImage.Bitmap);
end;

procedure TGLRenderer.ContextLost;

  procedure ForgetBar(var ABar: TGLTextBar);
  begin
    ABar.Text := '';
    ABar.Texture := 0;
    ABar.Width := 0;
    ABar.Height := 0;
  end;

begin
  { No GL calls: the textures die with the context. }
  FDeleteQueue := nil;
  FreeAndNil(FPending);
  FreeAndNil(FShown);
  ForgetBar(FPanelBar);
  FPanelUploaded := 0;
  ForgetBar(FInfoBar);
  ForgetBar(FDiagBar);
  ForgetBar(FModeBar);
  ForgetBar(FCenterBar);
  ForgetBar(FZoneBar);
  ForgetBar(FGestureBar);
  { Start again as for a new image: small version first. }
  PlanForCurrentImage;
end;

{ Uploads one tile. False if the GPU refused (e.g. out of memory). }
function TGLRenderer.UploadTile(ATextures: TGLImageTextures; AIndex: Integer): Boolean;
var
  Bmp: TBGRACustomBitmap;
  W, H, TX0, TY0, TX1, TY1, TW, TH, SkipRows: Integer;
  BottomUp: Boolean;
  Base: PBGRAPixel;
  Tex: GLuint;
  Format: GLenum;
  Err: GLenum;
  T0, T1: Double;
begin
  Result := False;
  Bmp := ATextures.Bitmap;
  W := Bmp.Width;
  H := Bmp.Height;

  with ATextures.Tiles[AIndex] do
  begin
    { The content plus a 1-pixel border where there is a neighbour. }
    TX0 := Max(0, CX0 - 1);
    TY0 := Max(0, CY0 - 1);
    TX1 := Min(W, CX1 + 1);
    TY1 := Min(H, CY1 + 1);
    TW := TX1 - TX0;
    TH := TY1 - TY0;

    { Rows in memory: bottom-up (BGRABitmap on Windows) or top-down.
      Base is the row at the lowest address. }
    if H > 1 then
      BottomUp := PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1])
    else
      BottomUp := False;
    if BottomUp then
    begin
      Base := Bmp.ScanLine[H - 1];
      SkipRows := H - TY1;       { memory row of the tile's bottom row }
    end
    else
    begin
      Base := Bmp.ScanLine[0];
      SkipRows := TY0;
    end;

    glGenTextures(1, @Tex);
    glBindTexture(GL_TEXTURE_2D, Tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    if FUseMipMaps then
    begin
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
      if not Assigned(FGenerateMipmap) then
        glTexParameteri(GL_TEXTURE_2D, MV_GL_GENERATE_MIPMAP, GL_TRUE);
    end
    else
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    ClearGLErrors;
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, W);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, TX0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, SkipRows);
    if PixelOrderIsBGRA then
      Format := MV_GL_BGRA
    else
      Format := GL_RGBA;
    T0 := NowMs;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TW, TH, 0, Format, GL_UNSIGNED_BYTE, Base);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    { glFinish: the GPU really is done, so the time per frame budget and
      the measurements are honest. }
    glFinish;
    T1 := NowMs;
    if FUseMipMaps and Assigned(FGenerateMipmap) then
    begin
      FGenerateMipmap(GL_TEXTURE_2D);
      glFinish;
    end;
    FTexMs := FTexMs + (T1 - T0);
    FMipMs := FMipMs + (NowMs - T1);
    Inc(FTilesDone);

    Err := glGetError();
    if Err <> GL_NO_ERROR then
    begin
      glDeleteTextures(1, @Tex);
      Exit;
    end;
    Texture := Tex;

    { Texture coordinates of the content edges. The first row uploaded
      is t = 0: the tile's bottom row if bottom-up, else its top row. }
    U0 := (CX0 - TX0) / TW;
    U1 := (CX1 - TX0) / TW;
    if BottomUp then
    begin
      VTop := (TY1 - CY0) / TH;
      VBottom := (TY1 - CY1) / TH;
    end
    else
    begin
      VTop := (CY0 - TY0) / TH;
      VBottom := (CY1 - TY0) / TH;
    end;
  end;
  Result := True;
end;

procedure TGLRenderer.UploadSome(ATextures: TGLImageTextures; ABudgetMs: Double);
var
  StartMs: Double;
begin
  StartMs := NowMs;
  while not ATextures.Complete do
  begin
    if not UploadTile(ATextures, NextTile(ATextures)) then
    begin
      ATextures.Failed := True;
      Break;
    end;
    Inc(ATextures.Uploaded);
    if (ABudgetMs > 0) and (NowMs - StartMs >= ABudgetMs) then
      Break;
  end;
  ATextures.UploadMs := ATextures.UploadMs + (NowMs - StartMs);
end;

{ The tile not yet uploaded that is closest to the focus point. }
function TGLRenderer.NextTile(ATextures: TGLImageTextures): Integer;
var
  I: Integer;
  D, BestD, MX, MY: Double;
begin
  Result := -1;
  BestD := 0;
  for I := 0 to High(ATextures.Tiles) do
    with ATextures.Tiles[I] do
      if Texture = 0 then
      begin
        MX := (CX0 + CX1) / 2 - FFocusX;
        MY := (CY0 + CY1) / 2 - FFocusY;
        D := MX * MX + MY * MY;
        if (Result < 0) or (D < BestD) then
        begin
          Result := I;
          BestD := D;
        end;
      end;
end;

{ The bitmap point shown in the middle of the window: the inverse of
  the transformation in DrawTextures. }
procedure TGLRenderer.UpdateFocus(ATextures: TGLImageTextures; AWidth, AHeight: Integer);
var
  LogW, LogH, BmpW, BmpH: Integer;
  Scale, SX, SY, VX, VY, Rad, C, S: Double;
begin
  BmpW := ATextures.Bitmap.Width;
  BmpH := ATextures.Bitmap.Height;
  FFocusX := BmpW / 2;
  FFocusY := BmpH / 2;
  LogicalSize(LogW, LogH);
  Scale := ScaleFor(AWidth, AHeight);
  if (Scale <= 0) or (LogW <= 0) or (LogH <= 0) then
    Exit;
  SX := Scale * LogW / BmpW;
  SY := Scale * LogH / BmpH;
  { Window centre relative to the image centre on screen, turned back. }
  VX := -FView.PanX;
  VY := -FView.PanY;
  Rad := DegToRad(-FView.Angle);
  C := Cos(Rad);
  S := Sin(Rad);
  FFocusX := BmpW / 2 + (VX * C - VY * S) / SX;
  FFocusY := BmpH / 2 + (VX * S + VY * C) / SY;
end;

procedure TGLRenderer.SetupScreenProjection(AWidth, AHeight: Integer);
begin
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  { Screen pixels, y pointing down. }
  glOrtho(0, AWidth, AHeight, 0, -1, 1);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
end;

procedure TGLRenderer.DrawTextures(ATextures: TGLImageTextures; AWidth, AHeight: Integer);
var
  LogW, LogH, BmpW, BmpH, I: Integer;
  Scale, SX, SY, CX, CY: Double;
  MagFilter: GLint;
begin
  BmpW := ATextures.Bitmap.Width;
  BmpH := ATextures.Bitmap.Height;
  LogicalSize(LogW, LogH);
  Scale := ScaleFor(AWidth, AHeight);
  if (Scale <= 0) or (LogW <= 0) or (BmpW <= 0) then
    Exit;
  FLastScale := Scale;

  { Bitmap pixels -> screen pixels. }
  SX := Scale * LogW / BmpW;
  SY := Scale * LogH / BmpH;
  CX := AWidth / 2 + FView.PanX;
  CY := AHeight / 2 + FView.PanY;

  { A bitmap made to fit exactly (quick view, screen copy): 1:1 on
    whole pixels, so it is as sharp as on the CPU. }
  if (FView.Angle = 0) and (Abs(BmpW * SX - BmpW) < 1.0) and (Abs(BmpH * SY - BmpH) < 1.0) then
  begin
    SX := 1.0;
    SY := 1.0;
    CX := Round(CX - BmpW / 2) + BmpW / 2;
    CY := Round(CY - BmpH / 2) + BmpH / 2;
  end;

  if SX >= NearestFromScale then
    MagFilter := GL_NEAREST
  else
    MagFilter := GL_LINEAR;

  SetupScreenProjection(AWidth, AHeight);
  glTranslatef(CX, CY, 0);
  glRotatef(FView.Angle, 0, 0, 1);
  glScalef(SX, SY, 1);
  glTranslatef(-BmpW / 2, -BmpH / 2, 0);

  glEnable(GL_TEXTURE_2D);
  glColor4f(1, 1, 1, 1);
  for I := 0 to High(ATextures.Tiles) do
    with ATextures.Tiles[I] do
    begin
      if Texture = 0 then
        Continue;
      glBindTexture(GL_TEXTURE_2D, Texture);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, MagFilter);
      glBegin(GL_QUADS);
      glTexCoord2f(U0, VTop);    glVertex2f(CX0, CY0);
      glTexCoord2f(U1, VTop);    glVertex2f(CX1, CY0);
      glTexCoord2f(U1, VBottom); glVertex2f(CX1, CY1);
      glTexCoord2f(U0, VBottom); glVertex2f(CX0, CY1);
      glEnd;
    end;
  glDisable(GL_TEXTURE_2D);
end;

{ Redraws a bar's bitmap and texture if its text changed. }
procedure TGLRenderer.UpdateBar(var ABar: TGLTextBar; const AText: string; ACentered: Boolean);
var
  Bmp: TBGRABitmap;
  Lines: TStringArray;
  I, LineH, W, H, Y, TW: Integer;
  Base: PBGRAPixel;
  Format: GLenum;
begin
  if (AText = ABar.Text) and ((ABar.Texture <> 0) or (AText = '')) then
    Exit;

  if ABar.Texture <> 0 then
  begin
    glDeleteTextures(1, @ABar.Texture);
    ABar.Texture := 0;
  end;
  ABar.Text := AText;
  ABar.Width := 0;
  ABar.Height := 0;
  if AText = '' then
    Exit;

  Lines := SplitLines(AText);
  Bmp := TBGRABitmap.Create(1, 1);
  try
    if ACentered then
    begin
      Bmp.FontHeight := 21;
      Bmp.FontQuality := fqSystemClearType;
    end
    else
    begin
      Bmp.FontHeight := 17;
      { Overlay text goes on a transparent background: ClearType needs
        an opaque one (coloured fringes otherwise). }
      Bmp.FontQuality := fqSystem;
    end;

    W := 0;
    LineH := 0;
    for I := 0 to High(Lines) do
    begin
      W := Max(W, Bmp.TextSize(Lines[I]).cx);
      LineH := Max(LineH, Bmp.TextSize(Lines[I] + 'Xg').cy);
    end;
    W := W + 16;
    H := LineH * Length(Lines) + 8;

    Bmp.SetSize(W, H);
    if ACentered then
      Bmp.Fill(BGRA(0, 0, 0, 255))
    else
      Bmp.Fill(BGRAPixelTransparent);   { white text only; DrawBar outlines it }
    Y := 4;
    for I := 0 to High(Lines) do
    begin
      if ACentered then
      begin
        TW := Bmp.TextSize(Lines[I]).cx;
        Bmp.TextOut((W - TW) div 2, Y, Lines[I], BGRA(192, 192, 192, 255));
      end
      else
        Bmp.TextOut(8, Y, Lines[I], BGRAWhite);
      Inc(Y, LineH);
    end;

    { One texture, no mipmaps; drawn 1:1. }
    if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
      Base := Bmp.ScanLine[H - 1]
    else
      Base := Bmp.ScanLine[0];
    if PixelOrderIsBGRA then
      Format := MV_GL_BGRA
    else
      Format := GL_RGBA;

    glGenTextures(1, @ABar.Texture);
    glBindTexture(GL_TEXTURE_2D, ABar.Texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    ClearGLErrors;
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, Format, GL_UNSIGNED_BYTE, Base);
    if glGetError() <> GL_NO_ERROR then
    begin
      glDeleteTextures(1, @ABar.Texture);
      ABar.Texture := 0;
      Exit;
    end;

    { Remember which way up the rows went in. }
    if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
      ABar.Height := -H          { bottom-up: flip when drawing }
    else
      ABar.Height := H;
    ABar.Width := W;
  finally
    Bmp.Free;
  end;
end;

{ The sort panel's picture as a texture, uploaded again only when it
  changed (PanelVersion). Drawn 1:1, no mipmaps. }
procedure TGLRenderer.UpdatePanel;
var
  Bmp: TBGRABitmap;
  W, H: Integer;
  Base: PBGRAPixel;
  Format: GLenum;
begin
  Bmp := Panel;
  if (Bmp = nil) or (Bmp.Width <= 0) or (Bmp.Height <= 0) then
    Exit;
  if (FPanelBar.Texture <> 0) and (FPanelUploaded = PanelVersion) then
    Exit;
  if FPanelBar.Texture <> 0 then
  begin
    glDeleteTextures(1, @FPanelBar.Texture);
    FPanelBar.Texture := 0;
  end;
  W := Bmp.Width;
  H := Bmp.Height;
  if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
    Base := Bmp.ScanLine[H - 1]
  else
    Base := Bmp.ScanLine[0];
  if PixelOrderIsBGRA then
    Format := MV_GL_BGRA
  else
    Format := GL_RGBA;
  glGenTextures(1, @FPanelBar.Texture);
  glBindTexture(GL_TEXTURE_2D, FPanelBar.Texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, MV_GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, MV_GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  ClearGLErrors;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, Format, GL_UNSIGNED_BYTE, Base);
  if glGetError() <> GL_NO_ERROR then
  begin
    glDeleteTextures(1, @FPanelBar.Texture);
    FPanelBar.Texture := 0;
    Exit;
  end;
  if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
    FPanelBar.Height := -H
  else
    FPanelBar.Height := H;
  FPanelBar.Width := W;
  FPanelUploaded := PanelVersion;
end;

{ AX, AY: top-left corner on screen. The screen projection is set.
  AOverlay: the texture is white text on transparent; it is drawn over
  the image with a thin dark outline (the same texture tinted black,
  shifted by one pixel in 8 directions, plus a soft shadow), so it
  reads on dark and bright images alike without a box behind it. The
  text is rasterised once; the extra quads cost nothing. }
procedure TGLRenderer.DrawBar(const ABar: TGLTextBar; AX, AY: Integer; AOverlay: Boolean;
  ASolidWidth: Integer);
var
  H, DX, DY: Integer;
  VTop, VBottom: Single;

  procedure Quad(X, Y: Integer);
  begin
    glBegin(GL_QUADS);
    glTexCoord2f(0, VTop);    glVertex2f(X, Y);
    glTexCoord2f(1, VTop);    glVertex2f(X + ABar.Width, Y);
    glTexCoord2f(1, VBottom); glVertex2f(X + ABar.Width, Y + H);
    glTexCoord2f(0, VBottom); glVertex2f(X, Y + H);
    glEnd;
  end;

begin
  if ABar.Texture = 0 then
    Exit;
  H := Abs(ABar.Height);
  if ABar.Height < 0 then
  begin
    VTop := 1;
    VBottom := 0;
  end
  else
  begin
    VTop := 0;
    VBottom := 1;
  end;

  { Solid: a black bar behind the text, no outline needed. }
  if AOverlay and (ASolidWidth > 0) then
  begin
    glDisable(GL_TEXTURE_2D);
    glColor4f(0, 0, 0, 1);
    glBegin(GL_QUADS);
    glVertex2f(AX, AY);
    glVertex2f(AX + ASolidWidth, AY);
    glVertex2f(AX + ASolidWidth, AY + H);
    glVertex2f(AX, AY + H);
    glEnd;
  end;

  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, ABar.Texture);
  if AOverlay and (ASolidWidth > 0) then
  begin
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  end
  else if AOverlay then
  begin
    { Texture colour x glColor (GL_MODULATE): black with the text's
      alpha. BGRABitmap alpha is not premultiplied. }
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glColor4f(0, 0, 0, 0.45);
    Quad(AX + 2, AY + 2);
    glColor4f(0, 0, 0, 0.9);
    for DY := -1 to 1 do
      for DX := -1 to 1 do
        if (DX <> 0) or (DY <> 0) then
          Quad(AX + DX, AY + DY);
  end;
  { The text: white in the texture, tinted to the overlay colour
    (GL_MODULATE). }
  if AOverlay then
    glColor4f(OverlayRed / 255, OverlayGreen / 255, OverlayBlue / 255, 1)
  else
    glColor4f(1, 1, 1, 1);
  Quad(AX, AY);
  glColor4f(1, 1, 1, 1);
  if AOverlay then
    glDisable(GL_BLEND);
  glDisable(GL_TEXTURE_2D);
end;

procedure TGLRenderer.Paint(AWidth, AHeight: Integer);
var
  StartMs: Double;
  NewImagePainted, MoreToUpload: Boolean;
  Lines: TStringArray;
  Bottom: Integer;
  Corners: array[0..3] of TPoint;
  Pass, I, SolidWidth: Integer;
begin
  StartMs := BeginPaint(AWidth, AHeight);
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;

  glViewport(0, 0, AWidth, AHeight);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glDisable(GL_BLEND);

  DeleteQueued;

  { The small version must be complete before it is drawn (one tile,
    a few ms). The large one goes up in steps. }
  if (FShown <> nil) and not FShown.Complete then
  begin
    UploadSome(FShown, 0);
    FLastUploadMs := FShown.UploadMs;
  end;

  MoreToUpload := False;
  if FPending <> nil then
  begin
    UpdateFocus(FPending, AWidth, AHeight);
    UploadSome(FPending, UploadBudgetMs);
    if FPending.Complete then
    begin
      if FPending.Failed then
      begin
        { Keep showing the small version. }
        FGpuNote := 'full image too large for the GPU memory';
        DropTextures(FPending);
      end
      else
      begin
        FLastUploadMs := FPending.UploadMs;
        DropTextures(FShown);
        FShown := FPending;
        FPending := nil;
      end;
      DeleteQueued;
    end
    else
      MoreToUpload := True;
  end;

  if (FImage = nil) or FImage.IsError then
  begin
    PlaceholderLines(Lines);
    SetupScreenProjection(AWidth, AHeight);
    UpdateBar(FCenterBar, JoinLines(Lines), True);
    DrawBar(FCenterBar, (AWidth - FCenterBar.Width) div 2,
      (AHeight - Abs(FCenterBar.Height)) div 2);
  end
  else if FShown <> nil then
  begin
    DrawTextures(FShown, AWidth, AHeight);
    { The full image's tiles that are already on the GPU, over the
      small version: the view sharpens tile by tile. }
    if FPending <> nil then
      DrawTextures(FPending, AWidth, AHeight);
  end;

  { Edit mode: the selection as a frame, dark under light so it shows
    on any image. }
  if SelectionCorners(Corners) then
  begin
    SetupScreenProjection(AWidth, AHeight);
    glDisable(GL_TEXTURE_2D);
    for Pass := 0 to 1 do
    begin
      if Pass = 0 then
      begin
        glLineWidth(3);
        glColor4f(0, 0, 0, 1);
      end
      else
      begin
        glLineWidth(1);
        glColor4f(1, 1, 1, 1);
      end;
      glBegin(GL_LINE_LOOP);
      for I := 0 to 3 do
        glVertex2f(Corners[I].X + 0.5, Corners[I].Y + 0.5);
      glEnd;
    end;
    glLineWidth(1);
    glColor4f(1, 1, 1, 1);
  end;

  NewImagePainted := EndImagePart(StartMs);

  { Overlays, in screen pixels. Info and diagnostics on a solid bar
    across the window, if wanted. }
  if OverlaySolid then
    SolidWidth := AWidth
  else
    SolidWidth := 0;
  SetupScreenProjection(AWidth, AHeight);
  Bottom := AHeight;
  UpdateBar(FInfoBar, InfoLine, False);
  if FInfoBar.Texture <> 0 then
  begin
    Dec(Bottom, Abs(FInfoBar.Height));
    DrawBar(FInfoBar, 0, Bottom, True, SolidWidth);
  end;
  UpdateBar(FDiagBar, DiagnosticsLine, False);
  if FDiagBar.Texture <> 0 then
  begin
    Dec(Bottom, Abs(FDiagBar.Height));
    DrawBar(FDiagBar, 0, Bottom, True, SolidWidth);
  end;
  UpdateBar(FModeBar, ModeLine, False);
  DrawBar(FModeBar, 0, 0, True);

  { Mouse language: the zone's name in its corner (top left: below the
    mode label; bottom: above the info and diagnostics lines). }
  UpdateBar(FZoneBar, ZoneLabel, False);
  if FZoneBar.Texture <> 0 then
    case ZoneCorner of
      0: DrawBar(FZoneBar, 0, Abs(FModeBar.Height), True);
      1: DrawBar(FZoneBar, AWidth - FZoneBar.Width, 0, True);
      2: DrawBar(FZoneBar, 0, Bottom - Abs(FZoneBar.Height), True);
    else
      DrawBar(FZoneBar, AWidth - FZoneBar.Width, Bottom - Abs(FZoneBar.Height), True);
    end;
  { A gesture being made: what it will do, in the middle. }
  UpdateBar(FGestureBar, GestureText, False);
  if FGestureBar.Texture <> 0 then
    DrawBar(FGestureBar, (AWidth - FGestureBar.Width) div 2,
      (AHeight - Abs(FGestureBar.Height)) div 2, True);

  { The sort panel, on top, with its transparency. }
  if Assigned(Panel) then
  begin
    UpdatePanel;
    if FPanelBar.Texture <> 0 then
    begin
      glEnable(GL_BLEND);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      DrawBar(FPanelBar, PanelX, PanelY);
      glDisable(GL_BLEND);
    end;
  end;

  { Debugging: a picture of this frame, before it is shown. }
  if FScreenshotFile <> '' then
    CaptureFrame(AWidth, AHeight);

  FControl.SwapBuffers;

  if NewImagePainted then
    ReportPainted;

  { Continue the upload in the next frame. }
  if MoreToUpload then
    FControl.Invalidate;
end;

{ Reads the frame just drawn (back buffer) and saves it as PNG. GL rows
  come bottom row first. }
procedure TGLRenderer.CaptureFrame(AWidth, AHeight: Integer);
var
  Bmp: TBGRABitmap;
  Buffer: PByte;
  Y: Integer;
  Format: GLenum;
  FileName: string;
begin
  FileName := FScreenshotFile;
  FScreenshotFile := '';
  Buffer := nil;
  Bmp := TBGRABitmap.Create(AWidth, AHeight);
  try
    try
      GetMem(Buffer, PtrUInt(AWidth) * PtrUInt(AHeight) * 4);
      if PixelOrderIsBGRA then
        Format := MV_GL_BGRA
      else
        Format := GL_RGBA;
      glPixelStorei(GL_PACK_ALIGNMENT, 4);
      glReadPixels(0, 0, AWidth, AHeight, Format, GL_UNSIGNED_BYTE, Buffer);
      for Y := 0 to AHeight - 1 do
        Move((Buffer + PtrUInt(Y) * PtrUInt(AWidth) * 4)^,
          Bmp.ScanLine[AHeight - 1 - Y]^, AWidth * 4);
      Bmp.InvalidateBitmap;
      SaveBitmapAsPng(Bmp, FileName);
      FScreenshotResult := 'view saved: ' + FileName;
    except
      on E: Exception do
        FScreenshotResult := 'view not saved: ' + E.Message;
    end;
  finally
    if Buffer <> nil then
      FreeMem(Buffer);
    Bmp.Free;
  end;
end;

procedure DetectPixelOrder;
var
  P: TBGRAPixel;
  B: PByte;
begin
  P := BGRA(1, 2, 3, 4);   { red 1, green 2, blue 3, alpha 4 }
  B := PByte(@P);
  PixelOrderIsBGRA := (B[0] = 3) and (B[1] = 2) and (B[2] = 1) and (B[3] = 4);
end;

initialization
  DetectPixelOrder;

end.
