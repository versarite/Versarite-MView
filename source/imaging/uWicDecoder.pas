unit uWicDecoder;

{
  Unit: uWicDecoder

  Purpose
  -------
  Decodes images with the Windows Imaging Component (WIC), the decoder
  built into Windows. For JPEG it is several times faster than the
  Pascal decoder (measured in Phase C: 6.1 s for a 108 MP photo with
  pasjpeg). It also reads TIFF, which is where it will matter most
  for microscopy archives.

  Owns
  ----
  - Per call: the WIC COM objects (factory, stream, decoder, frame,
    converter; released by reference counting when the call ends),
    the band buffer (freed in a finally block), and the result
    TBGRABitmap until it is handed to the caller.
  - Per thread: whether COM was started (threadvar ComStarted).
  - PixelOrderIsBGRA, set once when the unit is initialised.

  Knows
  -----
  - The TMemoryStream handed in: WIC reads its memory directly (no
    copy), so it must live until the call returns.
  - The cancel callback handed in.
  - The global IOGate (uIOGate): DecodeFileWithWic lets display reads
    go first when AYield is set.
  - uMemoryGuard: DecodeFits / EImageTooLarge in DecodeFileWithWic.
  - ole32.dll and WIC (Windows only).

  Responsibilities
  ----------------
  - WicThreadStart / WicThreadEnd: COM for the calling (worker)
    thread.
  - WicAvailable: True on Windows only.
  - DecodeWithWic: decode an image file held in memory into a new
    TBGRABitmap, in bands of rows, checking the cancel callback
    between bands.
  - DecodeWithWicScaled (Phase E): the first frame scaled inside the
    codec (for JPEG: DCT scaling), in one call.
  - DecodeFileWithWic: straight from the file, in bands (about 8 MB,
    or whole TIFF strips, at most 128 MB); the quick view is averaged
    down while the bands come in.
  - Hand pixels over as TBGRAPixel (a plain copy when the layouts
    match, which is the normal case on Windows).

  Does NOT
  --------
  - Read files (the loader does, for the I/O gate). This holds for
    DecodeWithWic and DecodeWithWicScaled; DecodeFileWithWic lets WIC
    read the file itself, band by band.
  - Apply EXIF orientation (the loader does, for all decoders alike).
  - Run on the UI thread (COM is initialised multithreaded here).
  - Do anything off Windows: there every decode raises EWicError.

  Threads
  -------
  Decode workers only. Each worker calls WicThreadStart before its
  work and WicThreadEnd after it (via TMediaLoader.ThreadStart /
  ThreadEnd). No lock is needed: COM objects live within one call,
  ComStarted is per thread, and PixelOrderIsBGRA is written once, at
  unit initialisation.

  Uses (MView units)
  ------------------
  interface:      uTypes
  implementation: uIOGate, uMemoryGuard
  Libraries:      Classes, SysUtils, BGRABitmap, BGRABitmapTypes,
                  Types, Math

  Used by
  -------
  uMediaLoader

  Notes
  -----
  Only the few WIC interfaces and methods MView needs are declared
  here, in their exact vtable order from wincodec.h. Methods after
  the last one used are left out; that is safe for COM interfaces.
  Any failure raises EWicError; the loader then falls back to its
  own decoder, so a machine where WIC misbehaves still shows images.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  BGRABitmap,
  BGRABitmapTypes,
  uTypes;

type
  EWicError = class(Exception);

{ Decode worker threads call these around their work. }
procedure WicThreadStart;
procedure WicThreadEnd;

{ True on Windows. }
function WicAvailable: Boolean;

{ Decodes the first frame of the image in AData. nil if ACancel said
  so; EWicError (or another exception) if WIC can't do it. The caller
  owns the result. }
function DecodeWithWic(AData: TMemoryStream; ACancel: TCancelCheck): TBGRABitmap;

{ Phase E: decodes the first frame at about 1/AScale of its size,
  scaled inside the codec (for JPEG: DCT scaling, like pasjpeg's, but
  several times faster). The size is the nearest the codec offers
  (GetClosestSize), so it may differ from 1/AScale by a few pixels.
  One CopyPixels call: cancel is only checked before it. EWicError if
  the codec can't scale or deliver a usable pixel format (e.g. CMYK):
  the caller then uses its own decoder. }
function DecodeWithWicScaled(AData: TMemoryStream; AScale: Integer;
  ACancel: TCancelCheck): TBGRABitmap;

{ Decodes the first frame straight from the file (no copy of the file
  in memory: a 108 MP uncompressed TIFF is 324 MB), in bands with a
  cancel check between them.
  AFitWidth / AFitHeight = 0: the full image.
  Otherwise the quick view: the image is averaged down while the bands
  come in, by the largest whole factor that keeps it at least as large
  as the fitted size; only that small bitmap is ever allocated. The
  caller shrinks it to the exact size. AScale returns the factor used
  (1 = full size).
  ABandRows: rows per CopyPixels call, 0 = about 8 MB. For TIFF, the
  strip height (whole strips per call, in case the codec doesn't keep
  a half-used strip between calls).
  nil if cancelled; EWicError if WIC can't read the file. }
function DecodeFileWithWic(const AFileName: string; AFitWidth, AFitHeight: Integer;
  ABandRows: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;

implementation

{$IFDEF WINDOWS}

uses
  Types,
  Math,
  uIOGate,
  uMemoryGuard;

type
  WICRect = record
    X, Y, Width, Height: LongInt;
  end;
  PWICRect = ^WICRect;

  IWICBitmapSource = interface(IUnknown)
    ['{00000120-a8f2-4877-ba0a-fd2b6645fb94}']
    function GetSize(out puiWidth, puiHeight: LongWord): HResult; stdcall;
    function GetPixelFormat(out pPixelFormat: TGUID): HResult; stdcall;
    function GetResolution(out pDpiX, pDpiY: Double): HResult; stdcall;
    function CopyPalette(pIPalette: IUnknown): HResult; stdcall;
    function CopyPixels(prc: PWICRect; cbStride, cbBufferSize: LongWord;
      pbBuffer: PByte): HResult; stdcall;
  end;

  IWICBitmapFrameDecode = interface(IWICBitmapSource)
    ['{3B16811B-6A43-4ec9-A813-3D930C13B940}']
  end;

  { Scaling inside the codec (wincodec.h). The rectangle is nil here:
    the whole scaled image in one call. }
  IWICBitmapSourceTransform = interface(IUnknown)
    ['{3B16811B-6A43-4ec9-B713-3D5A0C13B940}']
    function CopyPixels(prc: PWICRect; uiWidth, uiHeight: LongWord;
      pguidDstFormat: PGUID; dstTransform: LongWord;
      nStride, cbBufferSize: LongWord; pbBuffer: PByte): HResult; stdcall;
    function GetClosestSize(var puiWidth, puiHeight: LongWord): HResult; stdcall;
    function GetClosestPixelFormat(var pguidDstFormat: TGUID): HResult; stdcall;
    function DoesSupportTransform(dstTransform: LongWord; out pfIsSupported: LongBool): HResult; stdcall;
  end;

  IWICFormatConverter = interface(IWICBitmapSource)
    ['{00000301-a8f2-4877-ba0a-fd2b6645fb94}']
    function Initialize(pISource: IWICBitmapSource; constref dstFormat: TGUID;
      dither: LongWord; pIPalette: IUnknown; alphaThresholdPercent: Double;
      paletteTranslate: LongWord): HResult; stdcall;
  end;

  IWICBitmapDecoder = interface(IUnknown)
    ['{9EDDE9E7-8DEE-47ea-99DF-E6FAF2ED44BF}']
    function QueryCapability(pIStream: IStream; out pdwCapability: LongWord): HResult; stdcall;
    function Initialize(pIStream: IStream; cacheOptions: LongWord): HResult; stdcall;
    function GetContainerFormat(out pguidContainerFormat: TGUID): HResult; stdcall;
    function GetDecoderInfo(out ppIDecoderInfo: IUnknown): HResult; stdcall;
    function CopyPalette(pIPalette: IUnknown): HResult; stdcall;
    function GetMetadataQueryReader(out ppIMetadataQueryReader: IUnknown): HResult; stdcall;
    function GetPreview(out ppIBitmapSource: IWICBitmapSource): HResult; stdcall;
    function GetColorContexts(cCount: LongWord; ppIColorContexts: Pointer;
      out pcActualCount: LongWord): HResult; stdcall;
    function GetThumbnail(out ppIThumbnail: IWICBitmapSource): HResult; stdcall;
    function GetFrameCount(out pCount: LongWord): HResult; stdcall;
    function GetFrame(index: LongWord; out ppIBitmapFrame: IWICBitmapFrameDecode): HResult; stdcall;
  end;

  IWICStream = interface(IStream)
    ['{135FF860-22B7-4DDF-B0F6-218F4F299A43}']
    function InitializeFromIStream(pIStream: IStream): HResult; stdcall;
    function InitializeFromFilename(wzFileName: PWideChar; dwDesiredAccess: LongWord): HResult; stdcall;
    function InitializeFromMemory(pbBuffer: PByte; cbBufferSize: LongWord): HResult; stdcall;
  end;

  IWICImagingFactory = interface(IUnknown)
    ['{ec5ec8a9-c395-4314-9c77-54d7a935ff70}']
    function CreateDecoderFromFilename(wzFilename: PWideChar; pguidVendor: PGUID;
      dwDesiredAccess: LongWord; metadataOptions: LongWord;
      out ppIDecoder: IWICBitmapDecoder): HResult; stdcall;
    function CreateDecoderFromStream(pIStream: IStream; pguidVendor: PGUID;
      metadataOptions: LongWord; out ppIDecoder: IWICBitmapDecoder): HResult; stdcall;
    function CreateDecoderFromFileHandle(hFile: PtrUInt; pguidVendor: PGUID;
      metadataOptions: LongWord; out ppIDecoder: IWICBitmapDecoder): HResult; stdcall;
    function CreateComponentInfo(constref clsidComponent: TGUID; out ppIInfo: IUnknown): HResult; stdcall;
    function CreateDecoder(constref guidContainerFormat: TGUID; pguidVendor: PGUID;
      out ppIDecoder: IWICBitmapDecoder): HResult; stdcall;
    function CreateEncoder(constref guidContainerFormat: TGUID; pguidVendor: PGUID;
      out ppIEncoder: IUnknown): HResult; stdcall;
    function CreatePalette(out ppIPalette: IUnknown): HResult; stdcall;
    function CreateFormatConverter(out ppIFormatConverter: IWICFormatConverter): HResult; stdcall;
    function CreateBitmapScaler(out ppIBitmapScaler: IUnknown): HResult; stdcall;
    function CreateBitmapClipper(out ppIBitmapClipper: IUnknown): HResult; stdcall;
    function CreateBitmapFlipRotator(out ppIBitmapFlipRotator: IUnknown): HResult; stdcall;
    function CreateStream(out ppIWICStream: IWICStream): HResult; stdcall;
  end;

const
  CLSID_WICImagingFactory: TGUID = '{cacaf262-9370-4615-a13b-9f5539da4c0a}';
  IID_IWICImagingFactory: TGUID = '{ec5ec8a9-c395-4314-9c77-54d7a935ff70}';
  GUID_WICPixelFormat32bppBGRA: TGUID = '{6fddc324-4e03-4bfe-b185-3d77768dc90f}';
  GUID_WICPixelFormat32bppBGR: TGUID = '{6fddc324-4e03-4bfe-b185-3d77768dc90e}';
  GUID_WICPixelFormat24bppBGR: TGUID = '{6fddc324-4e03-4bfe-b185-3d77768dc90c}';
  GUID_WICPixelFormat8bppGray: TGUID = '{6fddc324-4e03-4bfe-b185-3d77768dc908}';
  WICBitmapTransformRotate0 = 0;
  GENERIC_READ_ACCESS = $80000000;
  { A band may be larger than BandBytes to hold whole strips, but not
    larger than this. }
  MaxBandBytes = 128 * 1024 * 1024;

  CLSCTX_INPROC_SERVER = 1;
  COINIT_MULTITHREADED = 0;
  WICDecodeMetadataCacheOnDemand = 0;
  WICBitmapDitherTypeNone = 0;
  WICBitmapPaletteTypeCustom = 0;

  { Rows per CopyPixels call: about 8 MB of pixels; the cancel check
    runs between bands. }
  BandBytes = 8 * 1024 * 1024;

function MViewCoInitializeEx(pvReserved: Pointer; dwCoInit: LongWord): HResult; stdcall;
  external 'ole32.dll' name 'CoInitializeEx';
procedure MViewCoUninitialize; stdcall;
  external 'ole32.dll' name 'CoUninitialize';
function MViewCoCreateInstance(constref rclsid: TGUID; pUnkOuter: Pointer;
  dwClsContext: LongWord; constref riid: TGUID; out ppv): HResult; stdcall;
  external 'ole32.dll' name 'CoCreateInstance';

threadvar
  ComStarted: Boolean;

var
  { True if TBGRAPixel is laid out B, G, R, A in memory, like WIC's
    32bppBGRA (the normal case on Windows). }
  PixelOrderIsBGRA: Boolean;

procedure WicThreadStart;
begin
  { S_OK or S_FALSE (already started): both need a matching
    CoUninitialize. }
  ComStarted := MViewCoInitializeEx(nil, COINIT_MULTITHREADED) >= 0;
end;

procedure WicThreadEnd;
begin
  if ComStarted then
  begin
    ComStarted := False;
    MViewCoUninitialize;
  end;
end;

function WicAvailable: Boolean;
begin
  Result := True;
end;

procedure Check(AResult: HResult; const AStep: string);
begin
  if AResult < 0 then
    raise EWicError.CreateFmt('WIC: %s failed (0x%.8x)', [AStep, LongWord(AResult)]);
end;

procedure CopyRow(ASource: PByte; ADest: PBGRAPixel; AWidth: Integer);
var
  X: Integer;
begin
  if PixelOrderIsBGRA then
    Move(ASource^, ADest^, AWidth * 4)
  else
    for X := 0 to AWidth - 1 do
    begin
      ADest^.blue := ASource[0];
      ADest^.green := ASource[1];
      ADest^.red := ASource[2];
      ADest^.alpha := ASource[3];
      Inc(ASource, 4);
      Inc(ADest);
    end;
end;

function DecodeWithWic(AData: TMemoryStream; ACancel: TCancelCheck): TBGRABitmap;
var
  Factory: IWICImagingFactory;
  Stream: IWICStream;
  Decoder: IWICBitmapDecoder;
  Frame: IWICBitmapFrameDecode;
  Converter: IWICFormatConverter;
  W, H: LongWord;
  Width, Height, BandRows, Y, Rows, R: Integer;
  Stride: LongWord;
  Buffer: PByte;
  Rect: WICRect;
  Bitmap: TBGRABitmap;
begin
  Result := nil;
  if (AData = nil) or (AData.Size <= 0) then
    raise EWicError.Create('WIC: no data');
  if AData.Size > High(LongInt) then
    raise EWicError.Create('WIC: file too large');

  Factory := nil;
  Check(MViewCoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
    IID_IWICImagingFactory, Factory), 'creating the factory');
  Check(Factory.CreateStream(Stream), 'CreateStream');
  Check(Stream.InitializeFromMemory(PByte(AData.Memory), LongWord(AData.Size)),
    'InitializeFromMemory');
  Check(Factory.CreateDecoderFromStream(Stream, nil, WICDecodeMetadataCacheOnDemand, Decoder),
    'CreateDecoderFromStream');
  Check(Decoder.GetFrame(0, Frame), 'GetFrame');
  Check(Factory.CreateFormatConverter(Converter), 'CreateFormatConverter');
  Check(Converter.Initialize(Frame, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
    nil, 0.0, WICBitmapPaletteTypeCustom), 'converter Initialize');
  Check(Converter.GetSize(W, H), 'GetSize');
  if (W = 0) or (H = 0) or (W > 65535) or (H > 65535) then
    raise EWicError.CreateFmt('WIC: unusable image size %d x %d', [W, H]);

  Width := Integer(W);
  Height := Integer(H);
  Stride := LongWord(Width) * 4;
  BandRows := Max(1, BandBytes div Integer(Stride));
  if BandRows > Height then
    BandRows := Height;

  Bitmap := TBGRABitmap.Create(Width, Height);
  Buffer := nil;
  try
    GetMem(Buffer, PtrUInt(Stride) * PtrUInt(BandRows));

    Y := 0;
    while Y < Height do
    begin
      if Assigned(ACancel) and ACancel() then
        Exit;   { Result stays nil; the finally block frees everything }

      Rows := Min(BandRows, Height - Y);
      Rect.X := 0;
      Rect.Y := Y;
      Rect.Width := Width;
      Rect.Height := Rows;
      Check(Converter.CopyPixels(@Rect, Stride, Stride * LongWord(Rows), Buffer), 'CopyPixels');

      for R := 0 to Rows - 1 do
        CopyRow(Buffer + PtrUInt(R) * Stride, Bitmap.ScanLine[Y + R], Width);
      Inc(Y, Rows);
    end;

    Bitmap.InvalidateBitmap;
    Result := Bitmap;
    Bitmap := nil;
  finally
    if Buffer <> nil then
      FreeMem(Buffer);
    Bitmap.Free;
  end;
end;

{ Opens AData and returns its first frame. }
function OpenFrame(AData: TMemoryStream; out AFactory: IWICImagingFactory): IWICBitmapFrameDecode;
var
  Stream: IWICStream;
  Decoder: IWICBitmapDecoder;
begin
  Result := nil;
  if (AData = nil) or (AData.Size <= 0) then
    raise EWicError.Create('WIC: no data');
  if AData.Size > High(LongInt) then
    raise EWicError.Create('WIC: file too large');
  AFactory := nil;
  Check(MViewCoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
    IID_IWICImagingFactory, AFactory), 'creating the factory');
  Check(AFactory.CreateStream(Stream), 'CreateStream');
  Check(Stream.InitializeFromMemory(PByte(AData.Memory), LongWord(AData.Size)),
    'InitializeFromMemory');
  Check(AFactory.CreateDecoderFromStream(Stream, nil, WICDecodeMetadataCacheOnDemand, Decoder),
    'CreateDecoderFromStream');
  Check(Decoder.GetFrame(0, Result), 'GetFrame');
end;

function DecodeWithWicScaled(AData: TMemoryStream; AScale: Integer;
  ACancel: TCancelCheck): TBGRABitmap;
var
  Factory: IWICImagingFactory;
  Frame: IWICBitmapFrameDecode;
  Transform: IWICBitmapSourceTransform;
  Format: TGUID;
  FullW, FullH, W, H: LongWord;
  BytesPerPixel, Width, Height, X, Y: Integer;
  Stride: LongWord;
  Buffer, Src: PByte;
  Dest: PBGRAPixel;
  Bitmap: TBGRABitmap;
begin
  Result := nil;
  if AScale < 1 then
    AScale := 1;
  Frame := OpenFrame(AData, Factory);
  if not Supports(Frame, IWICBitmapSourceTransform, Transform) then
    raise EWicError.Create('WIC: this codec can''t scale');

  Check(Frame.GetSize(FullW, FullH), 'GetSize');
  W := (FullW + LongWord(AScale) - 1) div LongWord(AScale);
  H := (FullH + LongWord(AScale) - 1) div LongWord(AScale);
  Check(Transform.GetClosestSize(W, H), 'GetClosestSize');
  if (W = 0) or (H = 0) or (W > FullW) or (H > FullH) or (W > 65535) or (H > 65535) then
    raise EWicError.CreateFmt('WIC: unusable scaled size %d x %d', [W, H]);

  { BGRA if the codec offers it; JPEG usually offers 24-bit BGR, or
    8-bit grey. Anything else (CMYK): not here. }
  Format := GUID_WICPixelFormat32bppBGRA;
  Check(Transform.GetClosestPixelFormat(Format), 'GetClosestPixelFormat');
  if IsEqualGUID(Format, GUID_WICPixelFormat32bppBGRA)
    or IsEqualGUID(Format, GUID_WICPixelFormat32bppBGR) then
    BytesPerPixel := 4
  else if IsEqualGUID(Format, GUID_WICPixelFormat24bppBGR) then
    BytesPerPixel := 3
  else if IsEqualGUID(Format, GUID_WICPixelFormat8bppGray) then
    BytesPerPixel := 1
  else
    raise EWicError.Create('WIC: no usable pixel format for scaling');

  Width := Integer(W);
  Height := Integer(H);
  { Rows padded to 4 bytes, as WIC expects for most formats. }
  Stride := (LongWord(Width) * LongWord(BytesPerPixel) + 3) and not LongWord(3);
  if Int64(Stride) * Height > High(LongWord) then
    raise EWicError.Create('WIC: scaled image too large');

  if Assigned(ACancel) and ACancel() then
    Exit;

  Bitmap := nil;
  Buffer := nil;
  try
    GetMem(Buffer, PtrUInt(Stride) * PtrUInt(Height));
    Check(Transform.CopyPixels(nil, W, H, @Format, WICBitmapTransformRotate0,
      Stride, Stride * LongWord(Height), Buffer), 'scaled CopyPixels');

    if Assigned(ACancel) and ACancel() then
      Exit;   { a complete image, but nobody wants it }

    Bitmap := TBGRABitmap.Create(Width, Height);
    for Y := 0 to Height - 1 do
    begin
      Src := Buffer + PtrUInt(Y) * Stride;
      Dest := Bitmap.ScanLine[Y];
      case BytesPerPixel of
        4:
          begin
            CopyRow(Src, Dest, Width);
            { 32bppBGR: the fourth byte is undefined. }
            if IsEqualGUID(Format, GUID_WICPixelFormat32bppBGR) then
              for X := 0 to Width - 1 do
              begin
                Dest^.alpha := 255;
                Inc(Dest);
              end;
          end;
        3:
          for X := 0 to Width - 1 do
          begin
            Dest^.blue := Src[0];
            Dest^.green := Src[1];
            Dest^.red := Src[2];
            Dest^.alpha := 255;
            Inc(Src, 3);
            Inc(Dest);
          end;
        1:
          for X := 0 to Width - 1 do
          begin
            Dest^.blue := Src^;
            Dest^.green := Src^;
            Dest^.red := Src^;
            Dest^.alpha := 255;
            Inc(Src);
            Inc(Dest);
          end;
      end;
    end;

    Bitmap.InvalidateBitmap;
    Result := Bitmap;
    Bitmap := nil;
  finally
    if Buffer <> nil then
      FreeMem(Buffer);
    Bitmap.Free;
  end;
end;

function DecodeFileWithWic(const AFileName: string; AFitWidth, AFitHeight: Integer;
  ABandRows: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;
var
  Factory: IWICImagingFactory;
  Decoder: IWICBitmapDecoder;
  Frame: IWICBitmapFrameDecode;
  Converter: IWICFormatConverter;
  W, H: LongWord;
  Width, Height, BandRows, Y, Rows, R, X, S, OutW, OutH, OutY, GroupRows, Count, K: Integer;
  Stride: LongWord;
  Buffer, Src: PByte;
  Rect: WICRect;
  Bitmap: TBGRABitmap;
  Sums: array of LongWord;     { 4 per output column: B, G, R, A }
  WideName: UnicodeString;
  Reason: string;
  Ratio: Double;
  Dest: PBGRAPixel;

  { Writes the averaged output row and clears the sums. }
  procedure FlushRow;
  var
    OX, Cols, N: Integer;
  begin
    Dest := Bitmap.ScanLine[OutY];
    for OX := 0 to OutW - 1 do
    begin
      Cols := Min(S, Width - OX * S);
      N := Cols * GroupRows;
      if N < 1 then
        N := 1;
      Dest^.blue := Sums[OX * 4] div LongWord(N);
      Dest^.green := Sums[OX * 4 + 1] div LongWord(N);
      Dest^.red := Sums[OX * 4 + 2] div LongWord(N);
      Dest^.alpha := Sums[OX * 4 + 3] div LongWord(N);
      Inc(Dest);
    end;
    FillChar(Sums[0], Length(Sums) * SizeOf(LongWord), 0);
    Inc(OutY);
    GroupRows := 0;
  end;

begin
  Result := nil;
  AFullWidth := 0;
  AFullHeight := 0;
  AScale := 1;

  Factory := nil;
  Check(MViewCoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
    IID_IWICImagingFactory, Factory), 'creating the factory');
  WideName := UnicodeString(AFileName);
  Check(Factory.CreateDecoderFromFilename(PWideChar(WideName), nil, GENERIC_READ_ACCESS,
    WICDecodeMetadataCacheOnDemand, Decoder), 'CreateDecoderFromFilename');
  Check(Decoder.GetFrame(0, Frame), 'GetFrame');
  Check(Factory.CreateFormatConverter(Converter), 'CreateFormatConverter');
  Check(Converter.Initialize(Frame, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
    nil, 0.0, WICBitmapPaletteTypeCustom), 'converter Initialize');
  Check(Converter.GetSize(W, H), 'GetSize');
  if (W = 0) or (H = 0) or (W > 65535) or (H > 65535) then
    raise EWicError.CreateFmt('WIC: unusable image size %d x %d', [W, H]);

  Width := Integer(W);
  Height := Integer(H);
  AFullWidth := Width;
  AFullHeight := Height;

  { The factor for the quick view: as large as possible while the
    result stays at least as large as the fitted size. }
  S := 1;
  if (AFitWidth > 0) and (AFitHeight > 0) then
  begin
    Ratio := Min(AFitWidth / Width, AFitHeight / Height);
    if Ratio < 1 then
      S := Max(1, Trunc(1 / Ratio));
  end;
  { The sums are 32-bit: S x S x 255 must fit. }
  if S > 4096 then
    S := 4096;
  AScale := S;

  Stride := LongWord(Width) * 4;
  if ABandRows > 0 then
    BandRows := ABandRows
  else
    BandRows := Max(1, BandBytes div Integer(Stride));
  if Int64(BandRows) * Stride > MaxBandBytes then
    BandRows := Max(1, MaxBandBytes div Integer(Stride));
  if BandRows > Height then
    BandRows := Height;

  if S = 1 then
  begin
    OutW := Width;
    OutH := Height;
  end
  else
  begin
    OutW := (Width + S - 1) div S;
    OutH := (Height + S - 1) div S;
    SetLength(Sums, OutW * 4);
    FillChar(Sums[0], Length(Sums) * SizeOf(LongWord), 0);
  end;

  { A corrupt file can claim any size: refuse what can't fit (the
    loader turns EOutOfMemory into an error entry). }
  if not DecodeFits(OutW, OutH, 0, Reason) then
    raise EImageTooLarge.Create(Reason);

  Bitmap := TBGRABitmap.Create(OutW, OutH);
  Buffer := nil;
  try
    GetMem(Buffer, PtrUInt(Stride) * PtrUInt(BandRows));
    OutY := 0;
    GroupRows := 0;

    Y := 0;
    while Y < Height do
    begin
      { A preload lets the image the user is waiting for read first. }
      if AYield then
        IOGate.YieldToDisplay(ACancel);
      if Assigned(ACancel) and ACancel() then
        Exit;   { Result stays nil; the finally block frees everything }

      Rows := Min(BandRows, Height - Y);
      Rect.X := 0;
      Rect.Y := Y;
      Rect.Width := Width;
      Rect.Height := Rows;
      Check(Converter.CopyPixels(@Rect, Stride, Stride * LongWord(Rows), Buffer), 'CopyPixels');

      for R := 0 to Rows - 1 do
      begin
        Src := Buffer + PtrUInt(R) * Stride;
        if S = 1 then
          CopyRow(Src, Bitmap.ScanLine[Y + R], Width)
        else
        begin
          { Add the row into its output row's sums (WIC's order: B, G,
            R, A per pixel). }
          Count := 0;
          K := 0;
          for X := 0 to Width - 1 do
          begin
            Inc(Sums[Count], Src[0]);
            Inc(Sums[Count + 1], Src[1]);
            Inc(Sums[Count + 2], Src[2]);
            Inc(Sums[Count + 3], Src[3]);
            Inc(Src, 4);
            Inc(K);
            if K = S then
            begin
              K := 0;
              Inc(Count, 4);
            end;
          end;
          Inc(GroupRows);
          if (GroupRows = S) or (Y + R = Height - 1) then
            FlushRow;
        end;
      end;
      Inc(Y, Rows);
    end;

    Bitmap.InvalidateBitmap;
    Result := Bitmap;
    Bitmap := nil;
  finally
    if Buffer <> nil then
      FreeMem(Buffer);
    Bitmap.Free;
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

{$ELSE}

procedure WicThreadStart;
begin
end;

procedure WicThreadEnd;
begin
end;

function WicAvailable: Boolean;
begin
  Result := False;
end;

function DecodeWithWic(AData: TMemoryStream; ACancel: TCancelCheck): TBGRABitmap;
begin
  raise EWicError.Create('WIC is only available on Windows');
end;

function DecodeWithWicScaled(AData: TMemoryStream; AScale: Integer;
  ACancel: TCancelCheck): TBGRABitmap;
begin
  raise EWicError.Create('WIC is only available on Windows');
end;

function DecodeFileWithWic(const AFileName: string; AFitWidth, AFitHeight: Integer;
  ABandRows: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;
begin
  AFullWidth := 0;
  AFullHeight := 0;
  AScale := 1;
  raise EWicError.Create('WIC is only available on Windows');
end;

{$ENDIF}

end.
