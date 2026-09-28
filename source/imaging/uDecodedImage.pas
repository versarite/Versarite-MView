unit uDecodedImage;

{
  Unit: uDecodedImage

  Purpose
  -------
  IDecodedImage (spec §7.2): a decoded image, immutable once created,
  shared by reference counting between loader, cache, renderer and
  pending deliveries.

  Owns
  ----
  - TDecodedImage owns its TBGRABitmap and, if present, its preview
    (TBGRACustomBitmap) and its animation (TAnimation). All three are
    freed when the last reference goes.

  Knows
  -----
  - Nothing else.

  Responsibilities
  ----------------
  - Hold decoded 32-bit BGRA pixels and the key of the file they came
    from.
  - MakeImageKey: the key of a file from its name, size and
    modification time (size and time 0 if the file can't be read).
  - Represent a file that could not be decoded (an "error entry",
    spec §7.4), so the renderer can show a placeholder. Bitmap is nil,
    Quality is qlNone, the message is never empty.
  - Optionally carry a screen-size copy (Preview), made on the worker,
    so fitting a huge image on screen costs the UI thread almost
    nothing (spec §7.1, "Screen" level).
  - Optionally carry the frames of an animation (TAnimation, Day 19).
    Bitmap is then the first frame; the frames are played by TMView.
  - Carry the measurements taken by the loader (spec §12: DecodeMs,
    PreviewMs), the original size in the file (FullWidth/FullHeight)
    and the memory it holds (SizeInBytes: bitmap, preview and
    animation, for the cache budget).

  Does NOT
  --------
  - Decode files. That is TMediaLoader's job.
  - Draw anything.

  Threads
  -------
  Created on a decode worker (uMediaLoader), then read from any
  thread: cache, job queue, scheduler, renderer and TMView on the UI
  thread. No lock: nothing changes after creation, and the reference
  count (TInterfacedObject, interlocked) decides when it is freed.
  MakeImageKey may be called on any thread.

  Uses (MView units)
  ------------------
  interface:      uTypes, uAnimation
  Libraries:      SysUtils, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uGLRenderer, uImageCache, uImageSaver, uJobQueue, uJobScheduler,
  uMView, uMediaLoader, uRenderer

  Rules
  -----
  Nobody changes the pixels after creation. The renderer may read the
  bitmap and make its own copies (rotation, scaling), but never writes
  to it. This is what makes sharing between threads safe later on.

  Pixels points to the bitmap's first pixel. BGRABitmap stores rows
  bottom-up on Windows (LineOrder = riloBottomToTop); the GPU upload
  in Phase D must take that into account.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  BGRABitmap,
  BGRABitmapTypes,
  uTypes,
  uAnimation;

type

  IDecodedImage = interface
    ['{7B0E3F52-5C1B-4E3A-9B3E-2E6F0C4B8A12}']
    function Key: TImageKey;
    function Quality: TQualityLevel;
    function Width: Integer;
    function Height: Integer;
    function Pixels: PBGRAPixel;
    function SizeInBytes: Int64;
    function FrameCount: Integer;
    function FrameDelayMs(AIndex: Integer): Integer;

    { The decoded bitmap, read only. nil for an error entry. }
    function Bitmap: TBGRABitmap;
    { A copy scaled down to about screen size, or nil if the image is
      not larger than the screen. Read only. }
    function Preview: TBGRACustomBitmap;
    function IsError: Boolean;
    function ErrorMessage: string;

    { Measurements (spec §12), taken by the loader on the worker:
      reading + decoding, and making the screen-size copy. }
    function DecodeMs: Double;
    function PreviewMs: Double;

    { Size of the original image in the file. Width/Height are the size
      of Bitmap, which is smaller for Screen quality (a JPEG decoded at
      1/2 .. 1/8 size). The renderer does all its geometry in original
      pixels, so zoom and 100 % mean the same whatever the quality. }
    function FullWidth: Integer;
    function FullHeight: Integer;

    { The frames of an animated image, or nil for a still one. Read
      only; lives as long as this image. }
    function Animation: TAnimation;
  end;

  TDecodedImage = class(TInterfacedObject, IDecodedImage)
  private
    FKey: TImageKey;
    FQuality: TQualityLevel;
    FBitmap: TBGRABitmap;
    FPreview: TBGRACustomBitmap;
    FErrorMessage: string;
    FDecodeMs: Double;
    FPreviewMs: Double;
    FFullWidth: Integer;
    FFullHeight: Integer;
    FAnimation: TAnimation;
  public
    { Takes ownership of ABitmap, APreview and AAnimation (the last two
      may be nil). AFullWidth/AFullHeight: original size; 0 = the
      bitmap's size. }
    constructor Create(const AKey: TImageKey; AQuality: TQualityLevel;
      ABitmap: TBGRABitmap; APreview: TBGRACustomBitmap = nil;
      ADecodeMs: Double = 0; APreviewMs: Double = 0;
      AFullWidth: Integer = 0; AFullHeight: Integer = 0;
      AAnimation: TAnimation = nil);
    constructor CreateError(const AKey: TImageKey; const AMessage: string;
      ADecodeMs: Double = 0);
    destructor Destroy; override;

    function Key: TImageKey;
    function Quality: TQualityLevel;
    function Width: Integer;
    function Height: Integer;
    function Pixels: PBGRAPixel;
    function SizeInBytes: Int64;
    function FrameCount: Integer;
    function FrameDelayMs(AIndex: Integer): Integer;
    function Bitmap: TBGRABitmap;
    function Preview: TBGRACustomBitmap;
    function IsError: Boolean;
    function ErrorMessage: string;
    function DecodeMs: Double;
    function PreviewMs: Double;
    function FullWidth: Integer;
    function FullHeight: Integer;
    function Animation: TAnimation;
  end;

{ Builds the key for a file from its name, size and modification time.
  Size and time are 0 if the file can't be read. }
function MakeImageKey(const AFileName: string): TImageKey;

implementation

function MakeImageKey(const AFileName: string): TImageKey;
var
  SearchRec: TSearchRec;
begin
  Result.FileName := AFileName;
  Result.FileSize := 0;
  Result.FileTime := 0;
  if FindFirst(AFileName, faAnyFile, SearchRec) = 0 then
  begin
    Result.FileSize := SearchRec.Size;
    Result.FileTime := FileDateToDateTime(SearchRec.Time);
    FindClose(SearchRec);
  end;
end;

{ TDecodedImage }

constructor TDecodedImage.Create(const AKey: TImageKey; AQuality: TQualityLevel;
  ABitmap: TBGRABitmap; APreview: TBGRACustomBitmap;
  ADecodeMs: Double; APreviewMs: Double; AFullWidth: Integer; AFullHeight: Integer;
  AAnimation: TAnimation);
begin
  inherited Create;
  FAnimation := AAnimation;
  FKey := AKey;
  FQuality := AQuality;
  FBitmap := ABitmap;
  FPreview := APreview;
  FErrorMessage := '';
  FDecodeMs := ADecodeMs;
  FPreviewMs := APreviewMs;
  if (AFullWidth > 0) and (AFullHeight > 0) then
  begin
    FFullWidth := AFullWidth;
    FFullHeight := AFullHeight;
  end
  else if Assigned(ABitmap) then
  begin
    FFullWidth := ABitmap.Width;
    FFullHeight := ABitmap.Height;
  end;
end;

constructor TDecodedImage.CreateError(const AKey: TImageKey; const AMessage: string;
  ADecodeMs: Double);
begin
  inherited Create;
  FDecodeMs := ADecodeMs;
  FPreviewMs := 0;
  FKey := AKey;
  FQuality := qlNone;
  FBitmap := nil;
  FPreview := nil;
  FFullWidth := 0;
  FFullHeight := 0;
  FErrorMessage := AMessage;
  if FErrorMessage = '' then
    FErrorMessage := 'Unknown error';
end;

destructor TDecodedImage.Destroy;
begin
  FAnimation.Free;
  FPreview.Free;
  FBitmap.Free;
  inherited Destroy;
end;

function TDecodedImage.Key: TImageKey;
begin
  Result := FKey;
end;

function TDecodedImage.Quality: TQualityLevel;
begin
  Result := FQuality;
end;

function TDecodedImage.Width: Integer;
begin
  if Assigned(FBitmap) then
    Result := FBitmap.Width
  else
    Result := 0;
end;

function TDecodedImage.Height: Integer;
begin
  if Assigned(FBitmap) then
    Result := FBitmap.Height
  else
    Result := 0;
end;

function TDecodedImage.Pixels: PBGRAPixel;
begin
  if Assigned(FBitmap) then
    Result := FBitmap.Data
  else
    Result := nil;
end;

function TDecodedImage.SizeInBytes: Int64;
begin
  Result := Int64(Width) * Int64(Height) * SizeOf(TBGRAPixel);
  if Assigned(FPreview) then
    Inc(Result, Int64(FPreview.Width) * Int64(FPreview.Height) * SizeOf(TBGRAPixel));
  if Assigned(FAnimation) then
    Inc(Result, FAnimation.SizeInBytes);
end;

function TDecodedImage.FrameCount: Integer;
begin
  if FBitmap = nil then
    Result := 0
  else if Assigned(FAnimation) then
    Result := FAnimation.FrameCount
  else
    Result := 1;
end;

function TDecodedImage.FrameDelayMs(AIndex: Integer): Integer;
begin
  if Assigned(FAnimation) then
    Result := FAnimation.FrameDelayMs(AIndex)
  else
    Result := 0;
end;

function TDecodedImage.Animation: TAnimation;
begin
  Result := FAnimation;
end;

function TDecodedImage.Bitmap: TBGRABitmap;
begin
  Result := FBitmap;
end;

function TDecodedImage.Preview: TBGRACustomBitmap;
begin
  Result := FPreview;
end;

function TDecodedImage.IsError: Boolean;
begin
  Result := FBitmap = nil;
end;

function TDecodedImage.ErrorMessage: string;
begin
  Result := FErrorMessage;
end;

function TDecodedImage.DecodeMs: Double;
begin
  Result := FDecodeMs;
end;

function TDecodedImage.PreviewMs: Double;
begin
  Result := FPreviewMs;
end;

function TDecodedImage.FullWidth: Integer;
begin
  Result := FFullWidth;
end;

function TDecodedImage.FullHeight: Integer;
begin
  Result := FFullHeight;
end;

end.
