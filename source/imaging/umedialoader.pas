unit uMediaLoader;

{
  Unit: uMediaLoader

  Purpose
  -------
  Decodes image files into IDecodedImage (spec §4.2, §7).

  Owns
  ----
  - Nothing. It keeps no state between calls, so the decode workers
    can call it from their own threads (spec §4.2: "stateless").
  - Its only fields are three settings (AutoRotate, UseWic,
    UseWicQuickView; all True by default), set by TMView before the
    workers start.
  - Per call, temporaries it frees itself: the file data
    (TMemoryStream or TBytes), a TProgressAdapter for BGRABitmap's
    reader, intermediate bitmaps. The finished bitmap, screen copy and
    animation go into the TDecodedImage it returns.

  Knows
  -----
  - The cancel callback handed to Load (the job's check).
  - The global IOGate (uIOGate): BeginPriorityRead / EndPriorityRead
    for display jobs, YieldToDisplay for preloads.
  - uMemoryGuard: DecodeFits, PhysicalMemoryBytes, EImageTooLarge.
  - The decoders it calls: uJpegDecoder, uJpegHeader,
    uExifOrientation, uGifDecoder, uTiffQuick, uWicDecoder, and
    BGRABitmap's readers; uImageScaling for the screen copies.
  - TMView creates and frees the loader; TJobScheduler's workers
    call it.

  Responsibilities
  ----------------
  - Decode a supported file into 32-bit BGRA pixels.
  - Honour a cancel check, so an obsolete decode can stop early
    (spec §5.6).
  - Make a screen-size copy on the calling (worker) thread, so the UI
    thread never has to scale a huge image down itself (spec §7.1).
  - Quality levels (spec §7.1). Asked for qlScreen, a JPEG is decoded
    at 1/2, 1/4 or 1/8 size, just large enough for the screen, which
    is several times faster (WIC scaling inside the codec, or the own
    decoder's DCT scaling). Other formats (and JPEGs that are not
    larger than the screen) are always decoded in full; the result
    then says qlFull.
  - Preview quality (Phase E): asked for qlPreview, a JPEG's EXIF
    thumbnail is decoded (uJpegHeader reads only the start of the
    file), turned upright and cut to the main image's shape. Files
    without one give an error entry with NoPreviewMessage, which the
    caller treats as "none", not as a broken file.
  - Preloads (not display jobs) let a display job read first: they
    wait at the I/O gate before reading, and between bands (spec §2.2).
  - Uncompressed strip TIFF, Screen quality: uTiffQuick reads only the
    rows it needs (2 of every S), a quarter of the file at S = 8.
  - LZW strip TIFF, both qualities: uTiffQuick's own LZW decoder
    (Day 19; WIC took about 4.5 s for a 108 MP file).
  - GIF (Day 19, uGifDecoder): Screen quality is the first frame only
    (read from the start of the file); it says qlScreen if more frames
    follow, qlFull for a still GIF. Full quality is every frame, as a
    TAnimation on the result (Bitmap = the first frame). Files that
    aren't really GIFs go to BGRABitmap.
  - TIFF, PNG and BMP (with UseWic): WIC reads the file directly, in
    bands (for TIFF whole strips), cancellable between bands. Screen
    quality is averaged down while the bands come in (only a
    screen-size bitmap is allocated, not 432 MB for a 108 MP image, or
    1.9 GB for NASA's 21600 x 21600 PNGs); Full is the whole image plus
    a screen copy, after the memory guard. If WIC can't read a file,
    BGRABitmap's reader takes over. (PNG and BMP went to BGRABitmap
    until Day 19: always in full, no size check before allocating, no
    cancel.)
  - EXIF orientation (AutoRotate): phone and camera JPEGs are turned
    upright on the worker, at both quality levels, before the screen
    copy is made. FullWidth/FullHeight are then the upright size.
  - The I/O gate (spec §5.5): for display jobs the file is read with
    the gate raised, so the directory scanner waits meanwhile.
  - Refuse early, with a clear message: a missing file, an
    unsupported extension, an empty file (0 bytes), a JPEG whose
    header claims more than 1000 pixels per byte of file, a GIF over
    1 GB, and any size uMemoryGuard says won't fit. Files named .jpg
    that aren't JPEGs go to BGRABitmap, which detects the format.
  - Turn every failure (missing, unreadable, corrupt, unsupported,
    cancelled) into an error entry instead of an exception, so
    navigation never stops on a bad file (spec §3.1, §7.4).

  Does NOT
  --------
  - Schedule, cache, or know about threads. (Two exceptions:
    ThreadStart / ThreadEnd set up COM for WIC on each worker, and
    uTiffQuick may run its own helper threads within one call.)
  - Draw anything.

  Threads
  -------
  Load runs on the decode workers (TDecodeWorker in uJobScheduler),
  several at once, never on the UI thread. No lock is needed: the
  settings are only read once the workers run, and every call works
  on its own objects. IOGate protects itself. Each worker calls
  ThreadStart before its first job and ThreadEnd after its last.

  Uses (MView units)
  ------------------
  interface:      uTypes, uImageFormats, uDecodedImage, uJpegDecoder,
                  uExifOrientation, uJpegHeader, uTiffQuick,
                  uAnimation, uGifDecoder, uImageScaling, uWicDecoder,
                  uIOGate, uMemoryGuard, uStopwatch
  Libraries:      Classes, SysUtils, Math, FPImage, BGRABitmap,
                  BGRABitmapTypes

  Used by
  -------
  uJobScheduler, uMView

  Notes on cancellation
  ---------------------
  Cancellation is cooperative; each path checks in its own way:
  - JPEG through WIC (tried first): before and after the decode; the
    own decoder (uJpegDecoder, the fallback) every 16 rows.
  - TIFF / PNG / BMP in WIC bands (LoadWicBands): between bands.
  - TIFF through uTiffQuick: between rows / strips.
  - GIF (uGifDecoder): every 262144 pixels.
  - The rest goes through BGRABitmap / the FPC readers, which report
    progress through the bitmap's OnProgress event; answering
    Continue := False asks the reader to stop. Not every reader asks
    often (the FPC JPEG reader only at start and end, which is why
    JPEGs have their own decoder), so such a decode can still run to
    its end.
  The cancel check is also asked before the decode and before the
  screen-size copy.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  FPImage,
  BGRABitmap,
  BGRABitmapTypes,
  uTypes,
  uImageFormats,
  uDecodedImage,
  uJpegDecoder,
  uExifOrientation,
  uJpegHeader,
  uTiffQuick,
  uAnimation,
  uGifDecoder,
  uImageScaling,
  uWicDecoder,
  uIOGate,
  uMemoryGuard,
  uStopwatch;

const
  { The error text of a qlPreview result when the file has no cheap
    preview: not a failure of the file. }
  NoPreviewMessage = 'No preview in this file';

type

  TMediaLoader = class(TObject)
  private
    FAutoRotate: Boolean;
    FUseWic: Boolean;
    FUseWicQuickView: Boolean;
  public
    constructor Create;

    { Each decode worker thread calls these around its work (COM for
      WIC). }
    procedure ThreadStart;
    procedure ThreadEnd;
    { AQuality: qlPreview (the embedded thumbnail, or an error entry
      with NoPreviewMessage), qlScreen (enough to fit the screen) or
      qlFull. For qlScreen / qlFull the result may be better than
      asked for, never worse.
      APreviewWidth / APreviewHeight: the screen size. A full decode
      larger than that also gets a scaled-down copy of about that size.
      APriorityRead: raise the I/O gate while reading the file. }
    function Load(const AFileName: string; AQuality: TQualityLevel;
      ACancel: TCancelCheck = nil;
      APreviewWidth: Integer = 0; APreviewHeight: Integer = 0;
      APriorityRead: Boolean = False): IDecodedImage;

    { Turn JPEGs upright by their EXIF orientation. Set before the
      decode workers start; they only read it. }
    property AutoRotate: Boolean read FAutoRotate write FAutoRotate;

    { Full-size JPEGs with the Windows Imaging Component (much faster);
      the Pascal decoder remains the fallback. Set before the workers
      start. }
    property UseWic: Boolean read FUseWic write FUseWic;
    { Quick views (Screen quality) of JPEGs scaled inside the WIC codec
      (Phase E); the Pascal decoder remains the fallback. Set before
      the workers start. }
    property UseWicQuickView: Boolean read FUseWicQuickView write FUseWicQuickView;
  end;

{ True if a qlPreview request can succeed for this file at all (JPEG
  by name; whether it has a thumbnail is only known after reading). }
function MayHavePreview(const AFileName: string): Boolean;

implementation

type

  { Connects the FPImage progress event to a TCancelCheck. One per
    decode, so it needs no locking. }
  TProgressAdapter = class(TObject)
  public
    Cancel: TCancelCheck;
    procedure HandleProgress(Sender: TObject; Stage: TFPImgProgressStage;
      PercentDone: Byte; RedrawNow: Boolean; const R: TRect;
      const Msg: AnsiString; var Continue: Boolean);
  end;

procedure TProgressAdapter.HandleProgress(Sender: TObject; Stage: TFPImgProgressStage;
  PercentDone: Byte; RedrawNow: Boolean; const R: TRect;
  const Msg: AnsiString; var Continue: Boolean);
begin
  if Assigned(Cancel) and Cancel() then
    Continue := False;
end;

function IsCancelled(ACancel: TCancelCheck): Boolean;
begin
  Result := Assigned(ACancel) and ACancel();
end;

function IsJpegFileName(const AFileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  Result := (Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.jpe');
end;

{ The screen copy for a full image larger than the screen: exactly the
  size the image has when fitted into AWidth x AHeight, so the
  renderer draws it 1:1 (uImageScaling.FitSize). nil otherwise. }
function MakePreview(ABitmap: TBGRABitmap; AWidth, AHeight: Integer): TBGRACustomBitmap;
var
  FitW, FitH: Integer;
begin
  Result := nil;
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  FitSize(ABitmap.Width, ABitmap.Height, AWidth, AHeight, FitW, FitH);
  if (FitW < ABitmap.Width) or (FitH < ABitmap.Height) then
    Result := ShrinkToSize(ABitmap, FitW, FitH);
end;

function LoadOther(const AKey: TImageKey; ACancel: TCancelCheck;
  APreviewWidth, APreviewHeight: Integer; APriorityRead: Boolean): IDecodedImage; forward;
function OrientBitmap(ABitmap: TBGRABitmap; AOrientation: Integer): TBGRABitmap; forward;

function MayHavePreview(const AFileName: string): Boolean;
begin
  Result := IsJpegFileName(AFileName);
end;

const
  { Thumbnails smaller than this (either side) are not worth showing. }
  MinPreviewSide = 40;
  { ... and larger ones are not thumbnails (4 MP; real ones are well
    under 1 MP). }
  MaxThumbnailPixels = 4000000;

  { Rows per WIC call for TIFF: whole strips of the common strip
    heights (IrfanView writes 1024-row strips). }
  TiffBandRows = 1024;

function IsTiffFileName(const AFileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  Result := (Ext = '.tif') or (Ext = '.tiff');
end;

{ Formats read through WIC in bands (see LoadWicBands). }
function IsWicBandFileName(const AFileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  Result := IsTiffFileName(AFileName) or (Ext = '.png') or (Ext = '.bmp');
end;

{ TIFF, PNG, BMP through WIC (TIFF: the own quick readers first). nil
  if WIC can't read the file (the caller then uses BGRABitmap's
  reader). }
function LoadWicBands(const AKey: TImageKey; AQuality: TQualityLevel;
  ACancel: TCancelCheck; APreviewWidth, APreviewHeight: Integer;
  APriorityRead: Boolean): IDecodedImage;
var
  Bitmap, Shrunk: TBGRABitmap;
  Preview: TBGRACustomBitmap;
  FullW, FullH, Scale, FitW, FitH: Integer;
  StartMs, DecodeMs, ShrinkStartMs: Double;
  Handled, IsTiff: Boolean;
  BandRows: Integer;
begin
  Result := nil;
  Bitmap := nil;
  Preview := nil;
  StartMs := NowMs;
  IsTiff := IsTiffFileName(AKey.FileName);
  { TIFF: whole strips per call. Others: about 8 MB per call. }
  if IsTiff then
    BandRows := TiffBandRows
  else
    BandRows := 0;
  try
    { The file is read while it is decoded: the gate stays raised for
      the whole decode of a display job. }
    if APriorityRead then
      IOGate.BeginPriorityRead;
    try
      Handled := False;
      { Quick view of an uncompressed TIFF: only the rows needed. }
      if IsTiff and (AQuality < qlFull) then
        Bitmap := LoadUncompressedTiffQuick(AKey.FileName, APreviewWidth, APreviewHeight,
          ACancel, not APriorityRead, Handled, FullW, FullH, Scale);
      { LZW strip TIFF: the own decoder, quick view or full size. }
      if IsTiff and not Handled then
      begin
        if AQuality >= qlFull then
          Bitmap := LoadLzwTiff(AKey.FileName, 0, 0, ACancel, not APriorityRead,
            Handled, FullW, FullH, Scale)
        else
          Bitmap := LoadLzwTiff(AKey.FileName, APreviewWidth, APreviewHeight, ACancel,
            not APriorityRead, Handled, FullW, FullH, Scale);
      end;
      { Everything else: WIC. }
      if not Handled then
      begin
        if AQuality >= qlFull then
          Bitmap := DecodeFileWithWic(AKey.FileName, 0, 0, BandRows, ACancel,
            not APriorityRead, FullW, FullH, Scale)
        else
          Bitmap := DecodeFileWithWic(AKey.FileName, APreviewWidth, APreviewHeight,
            BandRows, ACancel, not APriorityRead, FullW, FullH, Scale);
      end;
    finally
      if APriorityRead then
        IOGate.EndPriorityRead;
    end;
    if Bitmap = nil then
      Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
    DecodeMs := NowMs - StartMs;

    ShrinkStartMs := NowMs;
    if Scale > 1 then
    begin
      { Averaged down while reading; now exactly to the fitted size,
        so the renderer draws it 1:1. }
      FitSize(FullW, FullH, APreviewWidth, APreviewHeight, FitW, FitH);
      if (Bitmap.Width > FitW) or (Bitmap.Height > FitH) then
      begin
        Shrunk := ShrinkToSize(Bitmap, FitW, FitH);
        Bitmap.Free;
        Bitmap := Shrunk;
      end;
      Result := TDecodedImage.Create(AKey, qlScreen, Bitmap, nil,
        DecodeMs, NowMs - ShrinkStartMs, FullW, FullH);
    end
    else
    begin
      Preview := MakePreview(Bitmap, APreviewWidth, APreviewHeight);
      Result := TDecodedImage.Create(AKey, qlFull, Bitmap, Preview,
        DecodeMs, NowMs - ShrinkStartMs);
    end;
    Bitmap := nil;    { owned by the result now }
    Preview := nil;
  except
    on E: EOutOfMemory do
    begin
      Preview.Free;
      Bitmap.Free;
      Result := TDecodedImage.CreateError(AKey, E.Message, NowMs - StartMs);
    end;
    on E: EImageTooLarge do
    begin
      Preview.Free;
      Bitmap.Free;
      Result := TDecodedImage.CreateError(AKey, E.Message, NowMs - StartMs);
    end;
    on E: Exception do
    begin
      Preview.Free;
      Bitmap.Free;
      Result := nil;   { WIC can't: the other reader }
    end;
  end;
end;

{ The EXIF thumbnail as Preview quality. Reads only the start of the
  file. Any problem means "no preview": the Screen decode follows
  anyway and reports real errors. }
function LoadJpegPreview(const AKey: TImageKey; ACancel: TCancelCheck;
  APriorityRead, AAutoRotate: Boolean): IDecodedImage;
var
  Head: TJpegHead;
  Data: TMemoryStream;
  Bitmap, Part: TBGRABitmap;
  FullW, FullH, Tmp, X, Y, W, H, ThumbW, ThumbH: Integer;
  StartMs: Double;
  HeadOk: Boolean;
begin
  StartMs := NowMs;
  if APriorityRead then
    IOGate.BeginPriorityRead;
  try
    HeadOk := ReadJpegHead(AKey.FileName, Head);
  finally
    if APriorityRead then
      IOGate.EndPriorityRead;
  end;
  if (not HeadOk) or (Length(Head.Thumbnail) = 0) then
    Exit(TDecodedImage.CreateError(AKey, NoPreviewMessage));
  if IsCancelled(ACancel) then
    Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));

  FullW := Head.Width;
  FullH := Head.Height;
  if not AAutoRotate then
    Head.Orientation := 1;
  if OrientationSwapsSize(Head.Orientation) then
  begin
    Tmp := FullW;
    FullW := FullH;
    FullH := Tmp;
  end;

  Bitmap := nil;
  Data := TMemoryStream.Create;
  try
    try
      Data.WriteBuffer(Head.Thumbnail[0], Length(Head.Thumbnail));
      Data.Position := 0;
      { A thumbnail is small; a corrupt one may claim anything. }
      if not ReadJpegSize(Data, ThumbW, ThumbH)
        or (Int64(ThumbW) * ThumbH > MaxThumbnailPixels) then
        Exit(TDecodedImage.CreateError(AKey, NoPreviewMessage));
      Data.Position := 0;
      Bitmap := DecodeJpeg(Data, 1, ACancel, True);
      if Bitmap = nil then
        Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));

      if Head.Orientation <> 1 then
        Bitmap := OrientBitmap(Bitmap, Head.Orientation);

      { Black bars of a thumbnail in another shape: cut them off. }
      AspectCrop(Bitmap.Width, Bitmap.Height, FullW, FullH, X, Y, W, H);
      if (W <> Bitmap.Width) or (H <> Bitmap.Height) then
      begin
        Part := Bitmap.GetPart(Rect(X, Y, X + W, Y + H)) as TBGRABitmap;
        Bitmap.Free;
        Bitmap := Part;
      end;

      if (Bitmap.Width < MinPreviewSide) or (Bitmap.Height < MinPreviewSide) then
      begin
        FreeAndNil(Bitmap);
        Exit(TDecodedImage.CreateError(AKey, NoPreviewMessage));
      end;

      Result := TDecodedImage.Create(AKey, qlPreview, Bitmap, nil,
        NowMs - StartMs, 0, FullW, FullH);
      Bitmap := nil;   { owned by the result now }
    except
      on E: Exception do
      begin
        FreeAndNil(Bitmap);
        Result := TDecodedImage.CreateError(AKey, NoPreviewMessage);
      end;
    end;
  finally
    Data.Free;
  end;
end;

{ Turns ABitmap as EXIF orientation AOrientation asks (see
  uExifOrientation). Returns ABitmap itself, or a new bitmap, in which
  case ABitmap has been freed. }
function OrientBitmap(ABitmap: TBGRABitmap; AOrientation: Integer): TBGRABitmap;
var
  Turned: TBGRABitmap;
begin
  Result := ABitmap;
  case AOrientation of
    2: ABitmap.HorizontalFlip;
    3: begin
         ABitmap.HorizontalFlip;
         ABitmap.VerticalFlip;
       end;
    4: ABitmap.VerticalFlip;
    5, 7, 6, 8:
      begin
        if AOrientation in [5, 7] then
          ABitmap.HorizontalFlip;
        if AOrientation in [6, 7] then
          Turned := ABitmap.RotateCW as TBGRABitmap
        else
          Turned := ABitmap.RotateCCW as TBGRABitmap;
        ABitmap.Free;
        Result := Turned;
      end;
  end;
end;

{ JPEG: read the file into memory (gate raised only for that), then
  decode it with uJpegDecoder at the scale the quality needs, and turn
  it upright (EXIF orientation). }
function LoadJpeg(const AKey: TImageKey; AQuality: TQualityLevel;
  ACancel: TCancelCheck; APreviewWidth, APreviewHeight: Integer;
  APriorityRead, AAutoRotate, AUseWic, AUseWicQuick: Boolean): IDecodedImage;
var
  Data: TMemoryStream;
  Bitmap, Shrunk: TBGRABitmap;
  Preview: TBGRACustomBitmap;
  FullW, FullH, Scale, Orientation, Tmp, FitW, FitH: Integer;
  WicTried, Fits: Boolean;
  Reason: string;
  StartMs, DecodeMs, PreviewStartMs: Double;
begin
  StartMs := NowMs;
  Bitmap := nil;
  Preview := nil;
  Data := TMemoryStream.Create;
  try
    try
      if APriorityRead then
        IOGate.BeginPriorityRead
      else
        IOGate.YieldToDisplay(ACancel);
      try
        Data.LoadFromFile(AKey.FileName);
      finally
        if APriorityRead then
          IOGate.EndPriorityRead;
      end;

      if IsCancelled(ACancel) then
        Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));

      { Named .jpg but something else (or a JPEG kind the decoder
        can't read the header of): let BGRABitmap try, it detects the
        format from the content. }
      if not (IsJpegStream(Data) and ReadJpegSize(Data, FullW, FullH)) then
      begin
        FreeAndNil(Data);
        Exit(LoadOther(AKey, ACancel, APreviewWidth, APreviewHeight, APriorityRead));
      end;

      { Upright size first: the scale for the screen depends on it. }
      Orientation := 1;
      if AAutoRotate then
        Orientation := ReadExifOrientation(PByte(Data.Memory), Data.Size);
      if OrientationSwapsSize(Orientation) then
      begin
        Tmp := FullW;
        FullW := FullH;
        FullH := Tmp;
      end;

      if AQuality >= qlFull then
        Scale := 1
      else
        Scale := ChooseJpegScale(FullW, FullH, APreviewWidth, APreviewHeight);

      { A damaged header can claim a size the file can't hold: even a
        plain black JPEG needs about a byte per 160 pixels. One byte
        per 1000 is far below anything real (a 108 MP photo would need
        108 KB; real ones are about 10 MB). }
      if Int64(FullW) * FullH > Int64(AKey.FileSize) * 1000 then
        Exit(TDecodedImage.CreateError(AKey, Format(
          'Damaged file: the header claims %d x %d pixels, but the file has only %d KB',
          [FullW, FullH, AKey.FileSize div 1024]), NowMs - StartMs));

      { A corrupt header can claim any size: refuse what can't fit
        instead of paging the whole computer to disk (uMemoryGuard). }
      if Scale = 1 then
        Fits := DecodeFits(FullW, FullH,
          Int64(Max(APreviewWidth, 0)) * Max(APreviewHeight, 0) * 4, Reason)
      else
        Fits := DecodeFits((FullW + Scale - 1) div Scale, (FullH + Scale - 1) div Scale,
          0, Reason);
      if not Fits then
        Exit(TDecodedImage.CreateError(AKey, Reason, NowMs - StartMs));

      { Full size: WIC first (several times faster), the own decoder
        if WIC fails. nil from WIC = cancelled. }
      WicTried := False;
      if (Scale = 1) and AUseWic and WicAvailable then
      begin
        WicTried := True;
        try
          Bitmap := DecodeWithWic(Data, ACancel);
        except
          { Out of memory: the own decoder would need the same memory. }
          on EOutOfMemory do
            raise;
          on Exception do
          begin
            Bitmap := nil;
            WicTried := False;   { failed: use the own decoder below }
          end;
        end;
        if WicTried and (Bitmap = nil) then
          Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
      end;

      { Quick view: WIC scales inside the codec, several times faster
        than pasjpeg on large files. Not cancellable while it runs
        (one call, ~0.1-0.3 s); the own decoder if WIC can't. }
      if (Scale > 1) and AUseWicQuick and WicAvailable then
      begin
        WicTried := True;
        try
          Bitmap := DecodeWithWicScaled(Data, Scale, ACancel);
        except
          on EOutOfMemory do
            raise;
          on Exception do
          begin
            Bitmap := nil;
            WicTried := False;
          end;
        end;
        if WicTried and (Bitmap = nil) then
          Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
      end;

      { Fast DCT for the reduced sizes: the difference is invisible
        there. Full images use the accurate one. }
      if Bitmap = nil then
        Bitmap := DecodeJpeg(Data, Scale, ACancel, Scale > 1);
      DecodeMs := NowMs - StartMs;
      FreeAndNil(Data);   { the compressed data isn't needed any more }

      { nil: cancelled while decoding. A bitmap is always complete; if
        the job was cancelled only after that, the image still goes
        into the cache. }
      if Bitmap = nil then
        Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));

      if Orientation <> 1 then
      begin
        Bitmap := OrientBitmap(Bitmap, Orientation);
        DecodeMs := NowMs - StartMs;
      end;

      if Scale > 1 then
      begin
        { Exactly the fitted size (uImageScaling.FitSize), so the
          renderer draws the quick view 1:1 without resampling. }
        PreviewStartMs := NowMs;
        FitSize(FullW, FullH, APreviewWidth, APreviewHeight, FitW, FitH);
        if (Bitmap.Width > FitW) or (Bitmap.Height > FitH) then
        begin
          Shrunk := ShrinkToSize(Bitmap, FitW, FitH);
          Bitmap.Free;
          Bitmap := Shrunk;
        end;
        Result := TDecodedImage.Create(AKey, qlScreen, Bitmap, nil,
          DecodeMs, NowMs - PreviewStartMs, FullW, FullH);
      end
      else
      begin
        PreviewStartMs := NowMs;
        Preview := MakePreview(Bitmap, APreviewWidth, APreviewHeight);
        Result := TDecodedImage.Create(AKey, qlFull, Bitmap, Preview,
          DecodeMs, NowMs - PreviewStartMs, FullW, FullH);
      end;
    except
      on E: EJpegCancelled do
      begin
        Preview.Free;
        Bitmap.Free;
        Result := TDecodedImage.CreateError(AKey, 'Cancelled');
      end;
      on E: Exception do
      begin
        Preview.Free;
        Bitmap.Free;
        Result := TDecodedImage.CreateError(AKey, E.Message, NowMs - StartMs);
      end;
    end;
  finally
    Data.Free;
  end;
end;

const
  { Screen quality of a GIF reads this much of the file first; the
    whole file only if the first frame isn't complete in it. }
  GifFirstFrameBytes = 8 * 1024 * 1024;
  MaxGifFileBytes = Int64(1024) * 1024 * 1024;
  GifReadChunk = 1024 * 1024;

function IsGifFileName(const AFileName: string): Boolean;
begin
  Result := LowerCase(ExtractFileExt(AFileName)) = '.gif';
end;

{ Reads up to AMaxBytes of the file, in parts, asking ACancel between
  them. False if cancelled. AComplete: the whole file was read. }
function ReadFileStart(const AFileName: string; AMaxBytes: Int64;
  ACancel: TCancelCheck; APriorityRead: Boolean;
  out AData: TBytes; out AComplete: Boolean): Boolean;
var
  Stream: TFileStream;
  Total, Want, Got: Int64;
  Part: Integer;
begin
  Result := False;
  AData := nil;
  AComplete := False;
  if APriorityRead then
    IOGate.BeginPriorityRead
  else
    IOGate.YieldToDisplay(ACancel);
  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      Total := Stream.Size;
      Want := Min(Total, AMaxBytes);
      SetLength(AData, Want);
      Got := 0;
      while Got < Want do
      begin
        if IsCancelled(ACancel) then
          Exit;
        Part := Integer(Min(Int64(GifReadChunk), Want - Got));
        Part := Stream.Read(AData[Got], Part);
        if Part <= 0 then
          Break;
        Inc(Got, Part);
      end;
      SetLength(AData, Got);
      AComplete := Got >= Total;
      Result := True;
    finally
      Stream.Free;
    end;
  finally
    if APriorityRead then
      IOGate.EndPriorityRead;
  end;
end;

{ GIF: nil if the file isn't a GIF after all (the caller then tries
  BGRABitmap). }
function LoadGif(const AKey: TImageKey; AQuality: TQualityLevel; ACancel: TCancelCheck;
  APreviewWidth, APreviewHeight: Integer; APriorityRead: Boolean): IDecodedImage;
var
  Data: TBytes;
  Complete, FirstOnly, More, Incomplete: Boolean;
  Anim: TAnimation;
  Cursor: TAnimationCursor;
  Bitmap: TBGRABitmap;
  Preview: TBGRACustomBitmap;
  Quality: TQualityLevel;
  Error: string;
  StartMs, DecodeMs, PreviewStartMs: Double;
  MaxBytes: Int64;
begin
  Result := nil;
  Anim := nil;
  Bitmap := nil;
  Preview := nil;
  StartMs := NowMs;
  if AKey.FileSize > MaxGifFileBytes then
    Exit(TDecodedImage.CreateError(AKey, Format('GIF file too large (%d MB, limit %d MB)',
      [AKey.FileSize div (1024 * 1024), MaxGifFileBytes div (1024 * 1024)])));
  FirstOnly := AQuality < qlFull;
  { The frames may use a quarter of the memory, at most 2 GB. }
  MaxBytes := Min(PhysicalMemoryBytes div 4, Int64(2048) * 1024 * 1024);
  try
    try
      if FirstOnly then
      begin
        if not ReadFileStart(AKey.FileName, GifFirstFrameBytes, ACancel, APriorityRead,
          Data, Complete) then
          Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
      end
      else if not ReadFileStart(AKey.FileName, MaxGifFileBytes, ACancel, APriorityRead,
        Data, Complete) then
        Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));

      if (Length(Data) = 0) or not IsGifData(@Data[0], Length(Data)) then
        Exit(nil);

      Anim := DecodeGif(@Data[0], Length(Data), Complete, FirstOnly, MaxBytes, ACancel,
        More, Incomplete, Error);
      { The first frame didn't fit in the start of the file: read all. }
      if FirstOnly and Incomplete and not Complete then
      begin
        FreeAndNil(Anim);
        if not ReadFileStart(AKey.FileName, MaxGifFileBytes, ACancel, APriorityRead,
          Data, Complete) then
          Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
        Anim := DecodeGif(@Data[0], Length(Data), Complete, FirstOnly, MaxBytes, ACancel,
          More, Incomplete, Error);
      end;
      Data := nil;
      if Anim = nil then
        Exit(TDecodedImage.CreateError(AKey, 'GIF: ' + Error, NowMs - StartMs));

      Cursor := Anim.CreateCursor;
      try
        Bitmap := Cursor.Frame(0);
      finally
        Cursor.Free;
      end;
      DecodeMs := NowMs - StartMs;

      if IsCancelled(ACancel) then
      begin
        FreeAndNil(Anim);
        FreeAndNil(Bitmap);
        Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
      end;

      PreviewStartMs := NowMs;
      Preview := MakePreview(Bitmap, APreviewWidth, APreviewHeight);

      if FirstOnly and More then
        Quality := qlScreen
      else
        Quality := qlFull;
      { A single frame is a still image. }
      if FirstOnly or (Anim.FrameCount < 2) then
        FreeAndNil(Anim);

      Result := TDecodedImage.Create(AKey, Quality, Bitmap, Preview,
        DecodeMs, NowMs - PreviewStartMs, 0, 0, Anim);
      Anim := nil;
      Bitmap := nil;
      Preview := nil;
    except
      on E: EGifCancelled do
        Result := TDecodedImage.CreateError(AKey, 'Cancelled');
      on E: Exception do
        Result := TDecodedImage.CreateError(AKey, E.Message, NowMs - StartMs);
    end;
  finally
    Anim.Free;
    Preview.Free;
    Bitmap.Free;
  end;
end;

{ The size a PNG, BMP or GIF claims in its header (the formats that may
  end up in BGRABitmap's readers, which allocate first and ask nobody).
  False if unknown. }
function HeaderImageSize(const AFileName: string; out AWidth, AHeight: Int64): Boolean;
var
  Stream: TFileStream;
  B: array[0..31] of Byte;
  N: Integer;

  function BE32(I: Integer): Int64;
  begin
    Result := (Int64(B[I]) shl 24) or (Int64(B[I + 1]) shl 16)
      or (Int64(B[I + 2]) shl 8) or Int64(B[I + 3]);
  end;

  function LE32(I: Integer): Int64;
  begin
    Result := Int64(LongInt(LongWord(B[I]) or (LongWord(B[I + 1]) shl 8)
      or (LongWord(B[I + 2]) shl 16) or (LongWord(B[I + 3]) shl 24)));
  end;

  function LE16(I: Integer): Int64;
  begin
    Result := Int64(B[I]) or (Int64(B[I + 1]) shl 8);
  end;

begin
  Result := False;
  AWidth := 0;
  AHeight := 0;
  N := 0;
  FillChar(B, SizeOf(B), 0);
  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      N := Stream.Read(B[0], SizeOf(B));
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;
  { PNG: the IHDR chunk comes first. }
  if (N >= 24) and (B[0] = $89) and (B[1] = Ord('P')) and (B[2] = Ord('N'))
    and (B[3] = Ord('G')) then
  begin
    AWidth := BE32(16);
    AHeight := BE32(20);
    Exit(True);
  end;
  { BMP: an OS/2 header (12 bytes) has 16-bit sizes; a negative height
    means top-down rows. }
  if (N >= 26) and (B[0] = Ord('B')) and (B[1] = Ord('M')) then
  begin
    if LE32(14) = 12 then
    begin
      AWidth := LE16(18);
      AHeight := LE16(20);
    end
    else
    begin
      AWidth := Abs(LE32(18));
      AHeight := Abs(LE32(22));
    end;
    Exit(True);
  end;
  { GIF: the logical screen. }
  if (N >= 10) and (B[0] = Ord('G')) and (B[1] = Ord('I')) and (B[2] = Ord('F')) then
  begin
    AWidth := LE16(6);
    AHeight := LE16(8);
    Exit(True);
  end;
end;

{ Every other format: BGRABitmap reads and decodes, always in full. }
function LoadOther(const AKey: TImageKey; ACancel: TCancelCheck;
  APreviewWidth, APreviewHeight: Integer; APriorityRead: Boolean): IDecodedImage;
var
  Bitmap: TBGRABitmap;
  Preview: TBGRACustomBitmap;
  Adapter: TProgressAdapter;
  StartMs, DecodeMs, PreviewStartMs: Double;
  HeaderW, HeaderH: Int64;
  Reason: string;
begin
  { The memory guard, before BGRABitmap allocates whatever the header
    claims (a corrupt or a NASA-sized PNG). }
  if HeaderImageSize(AKey.FileName, HeaderW, HeaderH)
    and not DecodeFits(HeaderW, HeaderH, 0, Reason) then
    Exit(TDecodedImage.CreateError(AKey, Reason));

  Bitmap := nil;
  Preview := nil;
  Adapter := TProgressAdapter.Create;
  try
    Adapter.Cancel := ACancel;
    StartMs := NowMs;
    try
      Bitmap := TBGRABitmap.Create;
      Bitmap.OnProgress := @Adapter.HandleProgress;
      { Reading and decoding happen in one call here, so the gate stays
        raised for both. }
      if APriorityRead then
        IOGate.BeginPriorityRead
      else
        IOGate.YieldToDisplay(ACancel);
      try
        Bitmap.LoadFromFileUTF8(AKey.FileName);
      finally
        if APriorityRead then
          IOGate.EndPriorityRead;
      end;
      Bitmap.OnProgress := nil;
      DecodeMs := NowMs - StartMs;

      if IsCancelled(ACancel) then
      begin
        FreeAndNil(Bitmap);
        Exit(TDecodedImage.CreateError(AKey, 'Cancelled'));
      end;

      if (Bitmap.Width = 0) or (Bitmap.Height = 0) then
      begin
        FreeAndNil(Bitmap);
        Exit(TDecodedImage.CreateError(AKey, 'The file contains no image', DecodeMs));
      end;

      PreviewStartMs := NowMs;
      Preview := MakePreview(Bitmap, APreviewWidth, APreviewHeight);

      Result := TDecodedImage.Create(AKey, qlFull, Bitmap, Preview,
        DecodeMs, NowMs - PreviewStartMs);
    except
      on E: Exception do
      begin
        Preview.Free;
        Bitmap.Free;
        Result := TDecodedImage.CreateError(AKey, E.Message, NowMs - StartMs);
      end;
    end;
  finally
    Adapter.Free;
  end;
end;

constructor TMediaLoader.Create;
begin
  inherited Create;
  FAutoRotate := True;
  FUseWic := True;
  FUseWicQuickView := True;
end;

procedure TMediaLoader.ThreadStart;
begin
  WicThreadStart;
end;

procedure TMediaLoader.ThreadEnd;
begin
  WicThreadEnd;
end;

function TMediaLoader.Load(const AFileName: string; AQuality: TQualityLevel;
  ACancel: TCancelCheck; APreviewWidth: Integer; APreviewHeight: Integer;
  APriorityRead: Boolean): IDecodedImage;
var
  Key: TImageKey;
begin
  Key := MakeImageKey(AFileName);

  if IsCancelled(ACancel) then
    Exit(TDecodedImage.CreateError(Key, 'Cancelled'));

  if not FileExists(AFileName) then
    Exit(TDecodedImage.CreateError(Key, 'File not found'));

  if not IsSupportedImageFile(AFileName) then
    Exit(TDecodedImage.CreateError(Key, 'Unsupported file format'));

  { An empty file (a copy or download that was cut off, a placeholder
    left by a sync tool): say so at once instead of letting the
    readers guess. For every quality, so it isn't asked for again. }
  if Key.FileSize = 0 then
    Exit(TDecodedImage.CreateError(Key, 'Empty file (0 bytes)'));

  if AQuality = qlPreview then
  begin
    if MayHavePreview(AFileName) then
      Result := LoadJpegPreview(Key, ACancel, APriorityRead, FAutoRotate)
    else
      Result := TDecodedImage.CreateError(Key, NoPreviewMessage);
  end
  else if IsJpegFileName(AFileName) then
    Result := LoadJpeg(Key, AQuality, ACancel, APreviewWidth, APreviewHeight,
      APriorityRead, FAutoRotate, FUseWic, FUseWicQuickView)
  else if IsGifFileName(AFileName) then
  begin
    Result := LoadGif(Key, AQuality, ACancel, APreviewWidth, APreviewHeight, APriorityRead);
    if Result = nil then
      Result := LoadOther(Key, ACancel, APreviewWidth, APreviewHeight, APriorityRead);
  end
  else if IsWicBandFileName(AFileName) and FUseWic and WicAvailable then
  begin
    Result := LoadWicBands(Key, AQuality, ACancel, APreviewWidth, APreviewHeight,
      APriorityRead);
    if Result = nil then
      Result := LoadOther(Key, ACancel, APreviewWidth, APreviewHeight, APriorityRead);
  end
  else
    Result := LoadOther(Key, ACancel, APreviewWidth, APreviewHeight, APriorityRead);
end;

end.
