unit uJpegDecoder;

{
  Unit: uJpegDecoder

  Purpose
  -------
  MView's own JPEG decoder, built directly on FPC's pasjpeg library
  (the same library TFPReaderJPEG and BGRABitmap use).

  Owns
  ----
  - Per call only: the library's decompress state (destroyed in a
    finally block with jpeg_destroy_decompress), one row buffer, and
    the new TBGRABitmap until it is handed to the caller.

  Knows
  -----
  - The TMemoryStream handed in (the caller's; its position is reset
    to 0).
  - The cancel callback (TCancelCheck) handed in.

  Responsibilities
  ----------------
  - IsJpegStream: the stream starts with FF D8 (position unchanged).
  - ReadJpegSize: the image size from the header only.
  - ChooseJpegScale: the largest of 1, 2, 4, 8 that still gives at
    least the size the image has when fitted to the screen.
  - DecodeJpeg: decode from memory into a new TBGRABitmap, at the
    scale denominator given (1, 2, 4 or 8), checking the cancel
    callback while it works. Grey, RGB and CMYK/YCCK (Adobe's inverted
    CMYK too) become BGRA; fast DCT on request (the loader uses it
    for reduced sizes). A truncated file keeps the rows decoded, the
    rest is black. Fatal library errors raise an exception instead of
    calling Halt; warnings are ignored.

  Does NOT
  --------
  - Read files (the loader reads them into memory first, so the I/O
    gate can be lowered before the decode starts).
  - Apply EXIF orientation (later; TMediaLoader now turns the bitmap
    after the decode).
  - Shrink to an exact size (uImageScaling).

  Threads
  -------
  Decode workers (called by uMediaLoader). No shared state: each call
  has its own library state and cancel context, so several workers
  can decode at once.

  Uses (MView units)
  ------------------
  interface:      uTypes
  Libraries:      Classes, SysUtils, BGRABitmap, BGRABitmapTypes,
                  JPEGLib, JdAPImin, JDataSrc, JdAPIstd, JmoreCfg

  Used by
  -------
  uMediaLoader

  Why not the standard reader
  ---------------------------
  1. It can't be cancelled: its progress hook is an empty stub
     ("ToDo" in fpreadjpeg.pas, FPC 3.2.2), so an obsolete decode of a
     50 MP photo runs for seconds to its end (spec §5.6).
  2. It writes every pixel through Img.Colors[x, y] (a virtual call
     and a 16-bit colour conversion per pixel). Here each row goes
     straight into the BGRA bitmap.
  3. It can't be asked for "just big enough for the screen". Here the
     JPEG is decoded at 1/2, 1/4 or 1/8 size inside the library (DCT
     scaling), which is several times faster than a full decode and
     then shrinking (spec §7.1, "Screen" quality).

  Cancellation
  ------------
  While rows are being produced (almost all of the work for normal
  JPEGs) the decode checks every 16 rows and simply stops: DecodeJpeg
  returns nil. No exception, so a debugger isn't interrupted by every
  cancelled preload while browsing quickly.
  Only while jpeg_start_decompress reads in a progressive JPEG (the
  library has the control then) does the progress hook raise
  EJpegCancelled to get out. Either way the library's memory is
  released in a finally block (jpeg_destroy_decompress).
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  BGRABitmap,
  BGRABitmapTypes,
  JPEGLib,
  JdAPImin,
  JDataSrc,
  JdAPIstd,
  JmoreCfg,
  uTypes;

type
  EJpegCancelled = class(Exception);

{ True if the stream starts with the JPEG signature FF D8. The stream
  position is left unchanged. }
function IsJpegStream(AStream: TStream): Boolean;

{ Reads the header only. False if it is not a readable JPEG. }
function ReadJpegSize(AStream: TMemoryStream; out AWidth, AHeight: Integer): Boolean;

{ The largest of 1, 2, 4, 8 that still gives an image at least as
  large as the image appears when fitted to the screen. 1 means a
  full decode. }
function ChooseJpegScale(AWidth, AHeight, AScreenWidth, AScreenHeight: Integer): Integer;

{ Decodes AStream (a complete JPEG in memory) at 1/AScaleDenom size.
  Returns nil if ACancel says so while rows are produced; raises
  EJpegCancelled if it says so while a progressive JPEG is read in;
  any other exception for a broken file. The caller owns the result. }
function DecodeJpeg(AStream: TMemoryStream; AScaleDenom: Integer;
  ACancel: TCancelCheck; AFastDct: Boolean): TBGRABitmap;

implementation

type
  { Passed to the library callbacks through client_data. }
  PDecodeContext = ^TDecodeContext;
  TDecodeContext = record
    Cancel: TCancelCheck;
    InRowLoop: Boolean;    { the row loop checks for itself }
  end;

{ Error handling as in fpreadjpeg: the library must never call Halt,
  so a fatal error raises an exception instead. }
procedure JpegErrorExit(CurInfo: j_common_ptr);
begin
  if CurInfo = nil then
    raise Exception.Create('JPEG error');
  raise Exception.CreateFmt('JPEG error %d', [CurInfo^.err^.msg_code]);
end;

procedure JpegEmitMessage(CurInfo: j_common_ptr; msg_level: Integer);
begin
  { Warnings (corrupt data the library can work around) are ignored. }
end;

procedure JpegOutputMessage(CurInfo: j_common_ptr);
begin
end;

procedure JpegFormatMessage(CurInfo: j_common_ptr; var buffer: string);
begin
end;

procedure JpegResetErrorMgr(CurInfo: j_common_ptr);
begin
  if CurInfo = nil then
    Exit;
  CurInfo^.err^.num_warnings := 0;
  CurInfo^.err^.msg_code := 0;
end;

procedure JpegProgress(CurInfo: j_common_ptr);
var
  Context: PDecodeContext;
begin
  if CurInfo = nil then
    Exit;
  Context := PDecodeContext(CurInfo^.client_data);
  if (Context <> nil) and not Context^.InRowLoop
    and Assigned(Context^.Cancel) and Context^.Cancel() then
    raise EJpegCancelled.Create('Cancelled');
end;

procedure InitErrorMgr(var AError: jpeg_error_mgr);
begin
  FillChar(AError, SizeOf(AError), 0);
  AError.error_exit := @JpegErrorExit;
  AError.emit_message := @JpegEmitMessage;
  AError.output_message := @JpegOutputMessage;
  AError.format_message := @JpegFormatMessage;
  AError.reset_error_mgr := @JpegResetErrorMgr;
end;

function IsJpegStream(AStream: TStream): Boolean;
var
  Buf: array[0..1] of Byte;
  P: Int64;
begin
  Result := False;
  if AStream = nil then
    Exit;
  P := AStream.Position;
  Buf[0] := 0;
  Buf[1] := 0;
  Result := (AStream.Read(Buf, 2) = 2) and (Buf[0] = $FF) and (Buf[1] = $D8);
  AStream.Position := P;
end;

function ReadJpegSize(AStream: TMemoryStream; out AWidth, AHeight: Integer): Boolean;
var
  Info: jpeg_decompress_struct;
  Error: jpeg_error_mgr;
  Source: TStream;
begin
  AWidth := 0;
  AHeight := 0;
  Result := False;
  if (AStream = nil) or (AStream.Size < 4) then
    Exit;

  AStream.Position := 0;
  Source := AStream;
  FillChar(Info, SizeOf(Info), 0);
  InitErrorMgr(Error);
  Info.err := @Error;
  try
    jpeg_CreateDecompress(@Info, JPEG_LIB_VERSION, SizeOf(Info));
    try
      jpeg_stdio_src(@Info, @Source);
      jpeg_read_header(@Info, True);
      AWidth := Info.image_width;
      AHeight := Info.image_height;
      Result := (AWidth > 0) and (AHeight > 0);
    finally
      jpeg_destroy_decompress(@Info);
    end;
  except
    Result := False;
  end;
  AStream.Position := 0;
end;

function ChooseJpegScale(AWidth, AHeight, AScreenWidth, AScreenHeight: Integer): Integer;
var
  FitWidth: Double;
begin
  Result := 1;
  if (AWidth <= 0) or (AHeight <= 0) or (AScreenWidth <= 0) or (AScreenHeight <= 0) then
    Exit;

  { Width of the image when fitted to the screen (never enlarged). }
  FitWidth := AScreenWidth;
  if AWidth * AScreenHeight / AHeight < FitWidth then
    FitWidth := AWidth * AScreenHeight / AHeight;
  if FitWidth > AWidth then
    FitWidth := AWidth;

  while (Result < 8) and (AWidth / (Result * 2) >= FitWidth) do
    Result := Result * 2;
end;

function DecodeJpeg(AStream: TMemoryStream; AScaleDenom: Integer;
  ACancel: TCancelCheck; AFastDct: Boolean): TBGRABitmap;
var
  Info: jpeg_decompress_struct;
  Error: jpeg_error_mgr;
  ProgressMgr: jpeg_progress_mgr;
  Context: TDecodeContext;
  Source: TStream;
  RowBuffer: PByte;
  RowPointer: JSAMPROW;
  Components, X, Y, W, H: Integer;
  Src: PByte;
  Dst: PBGRAPixel;
  C, M, Ye, K: Integer;
  Bitmap: TBGRABitmap;
begin
  Result := nil;
  if (AScaleDenom <> 1) and (AScaleDenom <> 2) and (AScaleDenom <> 4) and (AScaleDenom <> 8) then
    AScaleDenom := 1;

  AStream.Position := 0;
  Source := AStream;
  Context.Cancel := ACancel;
  Context.InRowLoop := False;

  FillChar(Info, SizeOf(Info), 0);
  FillChar(ProgressMgr, SizeOf(ProgressMgr), 0);
  InitErrorMgr(Error);
  Info.err := @Error;

  Bitmap := nil;
  RowBuffer := nil;
  jpeg_CreateDecompress(@Info, JPEG_LIB_VERSION, SizeOf(Info));
  try
    Info.client_data := @Context;
    ProgressMgr.progress_monitor := @JpegProgress;
    Info.progress := @ProgressMgr;

    jpeg_stdio_src(@Info, @Source);
    jpeg_read_header(@Info, True);

    Info.scale_num := 1;
    Info.scale_denom := AScaleDenom;
    if AFastDct then
      Info.dct_method := JDCT_IFAST
    else
      Info.dct_method := JDCT_ISLOW;

    { Always 8-bit samples straight from the library: grey, RGB, or
      CMYK (YCCK is converted to CMYK by the library). }
    case Info.jpeg_color_space of
      JCS_GRAYSCALE:    Info.out_color_space := JCS_GRAYSCALE;
      JCS_CMYK, JCS_YCCK: Info.out_color_space := JCS_CMYK;
    else
      Info.out_color_space := JCS_RGB;
    end;
    Info.quantize_colors := False;

    { For a progressive JPEG this reads in the whole file; the progress
      hook keeps it cancellable. }
    jpeg_start_decompress(@Info);

    W := Info.output_width;
    H := Info.output_height;
    Components := Info.output_components;
    if (W <= 0) or (H <= 0) then
      raise Exception.Create('JPEG has no image');

    Bitmap := TBGRABitmap.Create(W, H);
    GetMem(RowBuffer, W * Components);
    RowPointer := JSAMPROW(RowBuffer);

    Context.InRowLoop := True;
    Y := 0;
    while Info.output_scanline < Info.output_height do
    begin
      if ((Y and 15) = 0) and Assigned(ACancel) and ACancel() then
        Exit;   { cancelled: the finally block frees Bitmap; Result is nil }

      if jpeg_read_scanlines(@Info, JSAMPARRAY(@RowPointer), 1) < 1 then
        Break;   { truncated file: keep what was decoded }

      Src := RowBuffer;
      Dst := Bitmap.ScanLine[Y];
      case Components of
        1:
          for X := 0 to W - 1 do
          begin
            Dst^.red := Src^;
            Dst^.green := Src^;
            Dst^.blue := Src^;
            Dst^.alpha := 255;
            Inc(Src);
            Inc(Dst);
          end;
        3:
          for X := 0 to W - 1 do
          begin
            Dst^.red := Src[0];
            Dst^.green := Src[1];
            Dst^.blue := Src[2];
            Dst^.alpha := 255;
            Inc(Src, 3);
            Inc(Dst);
          end;
        4:
          { Adobe CMYK JPEGs (almost all of them) store inverted values,
            so the usual conversion becomes a multiplication. Others are
            inverted here first. }
          for X := 0 to W - 1 do
          begin
            C := Src[0];
            M := Src[1];
            Ye := Src[2];
            K := Src[3];
            if not Info.saw_Adobe_marker then
            begin
              C := 255 - C;
              M := 255 - M;
              Ye := 255 - Ye;
              K := 255 - K;
            end;
            Dst^.red := (C * K) div 255;
            Dst^.green := (M * K) div 255;
            Dst^.blue := (Ye * K) div 255;
            Dst^.alpha := 255;
            Inc(Src, 4);
            Inc(Dst);
          end;
      else
        raise Exception.CreateFmt('Unsupported JPEG with %d components', [Components]);
      end;
      Inc(Y);
    end;

    { Rows a truncated file didn't deliver are black instead of
      transparent. }
    while Y < H do
    begin
      Dst := Bitmap.ScanLine[Y];
      for X := 0 to W - 1 do
      begin
        Dst^ := BGRA(0, 0, 0, 255);
        Inc(Dst);
      end;
      Inc(Y);
    end;

    if Info.output_scanline >= Info.output_height then
      jpeg_finish_decompress(@Info);

    Bitmap.InvalidateBitmap;
    Result := Bitmap;
    Bitmap := nil;
  finally
    if RowBuffer <> nil then
      FreeMem(RowBuffer);
    Bitmap.Free;      { only if something failed }
    jpeg_destroy_decompress(@Info);
  end;
end;

end.
