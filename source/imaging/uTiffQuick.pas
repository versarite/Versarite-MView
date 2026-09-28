unit uTiffQuick;

{
  Unit: uTiffQuick

  Purpose
  -------
  Quick view (Screen quality) of an uncompressed TIFF without reading
  the whole file. In an uncompressed strip TIFF every row sits at a
  known place in the file, so a quick view reduced by a factor S only
  needs a few of every S rows. A 108 MP RGB TIFF is 324 MB; at S = 8
  this reads 2 rows of every 8, about 81 MB. (WIC, which handles all
  other TIFFs, reads and decodes everything.) Since Day 19 also
  LZW-compressed strip TIFFs, quick view and full size.

  Owns
  ----
  - Per call: the TFileStream(s) it opens (each strip decoder opens
    its own), row and strip buffers, and the result TBGRABitmap until
    it is handed to the caller.
  - LoadLzwTiff, for a display job: up to 3 helper threads
    (TLzwStripThread, MaxLzwHelpers), started, waited for and freed
    within the call, and the TLzwJob record they share.

  Knows
  -----
  - The global IOGate (uIOGate): background jobs call YieldToDisplay.
  - The cancel callback handed in.
  - uMemoryGuard: DecodeFits and EImageTooLarge for full-size LZW.
  - The stream handed to ReadTiffLayout (read, not freed).

  Responsibilities
  ----------------
  - ReadTiffLayout: the first IFD's layout (size, samples, bits,
    compression, strips), checked against the file size.
  - LoadUncompressedTiffQuick: for the layouts it supports, the image
    averaged down by S: every column of the sampled rows, 2 sampled
    rows per group of S (a quarter and three quarters in), so fine
    patterns don't alias the way one row per group would.

  - LoadLzwTiff (Day 19): LZW-compressed strip TIFFs, quick view and
    full size, with an own decoder. WIC needed about 4.5 s for a 108 MP
    LZW TIFF (55 MB file, 324 MB of pixels). Here:
      * LZW decoding the fast way: every code stands for a piece of the
        output already written (its position and length), so decoding
        is short copies inside the output, no string walking. Verified
        bit-exact against Pillow on the test file.
      * The horizontal predictor (TIFF Predictor 2) is undone only for
        the rows that are used: the quick view uses 2 of every S.
      * Full size is written straight into the bitmap.
      * Strips are decoded in parallel for display jobs (see Threads).
  - LzwDecodeStrip: one strip, exposed for testing.
  - AHandled = False whenever it can't or shouldn't (unsupported
    layout, S < 2, a broken or cut-off file, one strip larger than
    256 MB): the caller then uses WIC, which also reports errors.

  Supported: strips (not tiles), 8 bits per sample, chunky
  (PlanarConfiguration 1), RGB (3 samples, or 4 with an extra sample,
  which is ignored) or grey (1 sample, BlackIsZero or WhiteIsZero);
  uncompressed (quick view only; WIC reads those at full size quickly)
  or LZW with predictor 1 or 2. Anything else: AHandled = False, the
  caller uses WIC.

  Does NOT
  --------
  - 16-bit or float samples (microscopy formats: later, spec §7.3).
  - Tiles, planar files, other compressions (WIC).
  - BigTIFF.
  - Make the exact screen size (uMediaLoader shrinks the result with
    uImageScaling).

  Threads
  -------
  Runs on the calling decode worker. For a display job (AYield =
  False) LoadLzwTiff also starts up to min(ProcessorCount - 1, 3)
  helper threads; each decodes every (helpers + 1)-th strip. They
  share only the TLzwJob record: filled in before they start, then
  only its Abort / Damaged flags change (Interlocked), and each thread
  writes only its own rows (bitmap row pointers taken beforehand on
  the worker) or its own PickBuf slots. Only the worker asks the
  cancel callback (between strips); helpers watch Abort. The worker
  waits for every helper before it returns. Background jobs (AYield)
  decode alone and give way to display reads (IOGate.YieldToDisplay)
  every 32 output rows or every strip.

  Uses (MView units)
  ------------------
  interface:      uTypes, uIOGate, uMemoryGuard
  Libraries:      Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uMediaLoader
}

{$mode ObjFPC}{$H+}
{ Tight decoding loops: -O2 here whatever the project setting (Day 19:
  the LZW decoder at the default level was about 3x slower). }
{$OPTIMIZATION ON}

interface

uses
  Classes,
  SysUtils,
  Math,
  BGRABitmap,
  BGRABitmapTypes,
  uTypes,
  uIOGate,
  uMemoryGuard;

type

  TInt64DynArray = array of Int64;

  TTiffLayout = record
    Width: Integer;
    Height: Integer;
    SamplesPerPixel: Integer;
    BitsPerSample: Integer;      { the first sample's; all must match }
    SameBits: Boolean;           { all samples have BitsPerSample }
    Compression: Integer;
    Photometric: Integer;
    Planar: Integer;
    RowsPerStrip: Integer;
    Predictor: Integer;          { 1 none, 2 horizontal differencing }
    Tiled: Boolean;
    StripOffsets: TInt64DynArray;
    StripByteCounts: TInt64DynArray;
  end;

{ Reads the first IFD. False if it is not a TIFF or the IFD is broken. }
function ReadTiffLayout(AStream: TStream; out ALayout: TTiffLayout): Boolean;

{ AHandled = False: not a layout this unit reads (use WIC). Otherwise
  the result is the averaged bitmap, or nil if cancelled. AFitWidth /
  AFitHeight: the size the image will be shown at; the factor S is
  the largest whole one that keeps the result at least that large
  (1 = not larger than the fit: AHandled = False, nothing to gain).
  AYield: a background job; it lets display reads go first. }
function LoadUncompressedTiffQuick(const AFileName: string;
  AFitWidth, AFitHeight: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AHandled: Boolean; out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;

{ LZW-compressed strip TIFF. AFitWidth / AFitHeight = 0: full size
  (AScale 1); otherwise the quick view as above (AHandled = False if the
  image is hardly larger than the fit). EImageTooLarge if the full
  image can't fit in memory (uMemoryGuard). nil if cancelled. }
function LoadLzwTiff(const AFileName: string;
  AFitWidth, AFitHeight: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AHandled: Boolean; out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;

{ Decodes one LZW strip (TIFF variant: MSB-first codes, 9..12 bits,
  "early change"). Returns the number of bytes written (at most
  ADestLen; fewer for a damaged or short strip). Exposed for testing. }
function LzwDecodeStrip(ASrc: PByte; ASrcLen: Integer; ADest: PByte; ADestLen: Integer): Integer;

implementation

const
  TagWidth = 256;
  TagHeight = 257;
  TagBitsPerSample = 258;
  TagCompression = 259;
  TagPhotometric = 262;
  TagStripOffsets = 273;
  TagSamplesPerPixel = 277;
  TagRowsPerStrip = 278;
  TagStripByteCounts = 279;
  TagPlanar = 284;
  TagPredictor = 317;
  TagTileWidth = 322;

  TypeShort = 3;
  TypeLong = 4;

  MaxStrips = 1000000;
  { Output rows between checks of cancel and the I/O gate. }
  RowsPerCheck = 32;

type
  TTiffReader = class
  private
    FStream: TStream;
    FLittle: Boolean;
    FSize: Int64;
  public
    constructor Create(AStream: TStream);
    function U16(const B: array of Byte; AOffset: Integer): Integer;
    function U32(const B: array of Byte; AOffset: Integer): Int64;
    function ReadAt(APos: Int64; var ABuffer; ACount: Integer): Boolean;
    { Values of a SHORT or LONG entry (inline or at its offset). }
    function Values(const AEntry: array of Byte; out AValues: TInt64DynArray): Boolean;
  end;

constructor TTiffReader.Create(AStream: TStream);
begin
  inherited Create;
  FStream := AStream;
  FSize := AStream.Size;
end;

function TTiffReader.U16(const B: array of Byte; AOffset: Integer): Integer;
begin
  if FLittle then
    Result := B[AOffset] or (Integer(B[AOffset + 1]) shl 8)
  else
    Result := (Integer(B[AOffset]) shl 8) or B[AOffset + 1];
end;

function TTiffReader.U32(const B: array of Byte; AOffset: Integer): Int64;
begin
  if FLittle then
    Result := Int64(B[AOffset]) or (Int64(B[AOffset + 1]) shl 8)
      or (Int64(B[AOffset + 2]) shl 16) or (Int64(B[AOffset + 3]) shl 24)
  else
    Result := (Int64(B[AOffset]) shl 24) or (Int64(B[AOffset + 1]) shl 16)
      or (Int64(B[AOffset + 2]) shl 8) or Int64(B[AOffset + 3]);
end;

function TTiffReader.ReadAt(APos: Int64; var ABuffer; ACount: Integer): Boolean;
begin
  Result := False;
  if (APos < 0) or (ACount < 0) or (APos + ACount > FSize) then
    Exit;
  FStream.Position := APos;
  Result := FStream.Read(ABuffer, ACount) = ACount;
end;

function TTiffReader.Values(const AEntry: array of Byte; out AValues: TInt64DynArray): Boolean;
var
  ValueType, I, ItemSize: Integer;
  Count, Offset: Int64;
  Data: array of Byte;
begin
  Result := False;
  AValues := nil;
  ValueType := U16(AEntry, 2);
  Count := U32(AEntry, 4);
  if ValueType = TypeShort then
    ItemSize := 2
  else if ValueType = TypeLong then
    ItemSize := 4
  else
    Exit;
  if (Count < 1) or (Count > MaxStrips) then
    Exit;

  SetLength(Data, Count * ItemSize);
  if Count * ItemSize <= 4 then
    Move(AEntry[8], Data[0], Count * ItemSize)
  else
  begin
    Offset := U32(AEntry, 8);
    if not ReadAt(Offset, Data[0], Count * ItemSize) then
      Exit;
  end;

  SetLength(AValues, Count);
  for I := 0 to Count - 1 do
    if ItemSize = 2 then
      AValues[I] := U16(Data, I * 2)
    else
      AValues[I] := U32(Data, I * 4);
  Result := True;
end;

function ReadTiffLayout(AStream: TStream; out ALayout: TTiffLayout): Boolean;
var
  R: TTiffReader;
  Head: array[0..7] of Byte;
  CountBytes: array[0..1] of Byte;
  Entry: array[0..11] of Byte;
  IfdPos: Int64;
  Count, I, K, Tag: Integer;
  V: TInt64DynArray;
begin
  Result := False;
  ALayout.Width := 0;
  ALayout.Height := 0;
  ALayout.SamplesPerPixel := 1;
  ALayout.BitsPerSample := 1;
  ALayout.SameBits := True;
  ALayout.Compression := 1;
  ALayout.Photometric := -1;
  ALayout.Planar := 1;
  ALayout.RowsPerStrip := MaxInt;
  ALayout.Predictor := 1;
  ALayout.Tiled := False;
  ALayout.StripOffsets := nil;
  ALayout.StripByteCounts := nil;

  R := TTiffReader.Create(AStream);
  try
    if not R.ReadAt(0, Head, 8) then
      Exit;
    if (Head[0] = Ord('I')) and (Head[1] = Ord('I')) then
      R.FLittle := True
    else if (Head[0] = Ord('M')) and (Head[1] = Ord('M')) then
      R.FLittle := False
    else
      Exit;
    if R.U16(Head, 2) <> 42 then
      Exit;   { 43 = BigTIFF: not here }

    IfdPos := R.U32(Head, 4);
    if not R.ReadAt(IfdPos, CountBytes, 2) then
      Exit;
    Count := R.U16(CountBytes, 0);

    for I := 0 to Count - 1 do
    begin
      if not R.ReadAt(IfdPos + 2 + Int64(I) * 12, Entry, 12) then
        Exit;
      Tag := R.U16(Entry, 0);
      case Tag of
        TagWidth, TagHeight, TagCompression, TagPhotometric,
        TagSamplesPerPixel, TagRowsPerStrip, TagPlanar, TagPredictor:
          begin
            if not R.Values(Entry, V) then
              Exit;
            case Tag of
              TagWidth:           ALayout.Width := V[0];
              TagHeight:          ALayout.Height := V[0];
              TagCompression:     ALayout.Compression := V[0];
              TagPhotometric:     ALayout.Photometric := V[0];
              TagSamplesPerPixel: ALayout.SamplesPerPixel := V[0];
              TagRowsPerStrip:    ALayout.RowsPerStrip := Min(V[0], MaxInt);
              TagPlanar:          ALayout.Planar := V[0];
              TagPredictor:       ALayout.Predictor := V[0];
            end;
          end;
        TagBitsPerSample:
          begin
            if not R.Values(Entry, V) then
              Exit;
            ALayout.BitsPerSample := V[0];
            ALayout.SameBits := True;
            for K := 1 to High(V) do
              if V[K] <> V[0] then
                ALayout.SameBits := False;
          end;
        TagStripOffsets:
          if not R.Values(Entry, ALayout.StripOffsets) then
            Exit;
        TagStripByteCounts:
          if not R.Values(Entry, ALayout.StripByteCounts) then
            Exit;
        TagTileWidth:
          ALayout.Tiled := True;
      end;
    end;

    Result := (ALayout.Width > 0) and (ALayout.Height > 0);
  finally
    R.Free;
  end;
end;

function LoadUncompressedTiffQuick(const AFileName: string;
  AFitWidth, AFitHeight: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AHandled: Boolean; out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;
var
  Stream: TFileStream;
  L: TTiffLayout;
  S, Spp, RowBytes, OutW, OutH, OY, K, SrcRow, X, OX, C, N, Cols: Integer;
  Ratio: Double;
  Picks: array[0..1] of Integer;
  PickCount: Integer;
  Row: array of Byte;
  Sums: array of LongWord;       { 3 per output column: R, G, B (or grey x3) }
  Strip: Integer;
  Pos: Int64;
  Bitmap: TBGRABitmap;
  Dest: PBGRAPixel;
  P: PByte;
  Grey, Invert: Boolean;
  Value: Integer;
begin
  Result := nil;
  AHandled := False;
  AFullWidth := 0;
  AFullHeight := 0;
  AScale := 1;

  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  except
    Exit;   { WIC will report why }
  end;
  Bitmap := nil;
  try
    if not ReadTiffLayout(Stream, L) then
      Exit;

    { Only what this reader can do. }
    if (L.Compression <> 1) or L.Tiled or (L.Planar <> 1)
      or (L.BitsPerSample <> 8) or not L.SameBits
      or (Length(L.StripOffsets) = 0) then
      Exit;
    Spp := L.SamplesPerPixel;
    Grey := (Spp = 1) and (L.Photometric in [0, 1]);
    Invert := Grey and (L.Photometric = 0);
    if not (Grey or ((Spp in [3, 4]) and (L.Photometric = 2))) then
      Exit;
    if L.RowsPerStrip <= 0 then
      Exit;
    if Int64(L.Height) > Int64(Length(L.StripOffsets)) * L.RowsPerStrip then
      Exit;   { not enough strips for all rows }

    { The factor, as DecodeFileWithWic chooses it. }
    S := 1;
    if (AFitWidth > 0) and (AFitHeight > 0) then
    begin
      Ratio := Min(AFitWidth / L.Width, AFitHeight / L.Height);
      if Ratio < 1 then
        S := Max(1, Trunc(1 / Ratio));
    end;
    if S > 4096 then
      S := 4096;
    if S < 2 then
      Exit;   { hardly smaller: read it all (WIC) }

    AHandled := True;
    AFullWidth := L.Width;
    AFullHeight := L.Height;
    AScale := S;

    RowBytes := L.Width * Spp;
    OutW := (L.Width + S - 1) div S;
    OutH := (L.Height + S - 1) div S;
    SetLength(Row, RowBytes);
    SetLength(Sums, OutW * 3);
    Bitmap := TBGRABitmap.Create(OutW, OutH);

    for OY := 0 to OutH - 1 do
    begin
      if OY mod RowsPerCheck = 0 then
      begin
        if AYield then
          IOGate.YieldToDisplay(ACancel);
        if Assigned(ACancel) and ACancel() then
          Exit;   { Result stays nil; Bitmap is freed below }
      end;

      { Two rows of the group, a quarter and three quarters in (one if
        the group is a single row at the bottom). }
      Picks[0] := OY * S + S div 4;
      Picks[1] := OY * S + (3 * S) div 4;
      PickCount := 2;
      if Picks[1] >= L.Height then
        Picks[1] := L.Height - 1;
      if Picks[0] >= L.Height then
        Picks[0] := L.Height - 1;
      if Picks[1] = Picks[0] then
        PickCount := 1;

      FillChar(Sums[0], Length(Sums) * SizeOf(LongWord), 0);
      for K := 0 to PickCount - 1 do
      begin
        SrcRow := Picks[K];
        Strip := SrcRow div L.RowsPerStrip;
        Pos := L.StripOffsets[Strip] + Int64(SrcRow mod L.RowsPerStrip) * RowBytes;
        Stream.Position := Pos;
        if (Pos < 0) or (Pos + RowBytes > Stream.Size)
          or (Stream.Read(Row[0], RowBytes) <> RowBytes) then
        begin
          { A broken or cut-off file: let WIC try (and report). }
          AHandled := False;
          Exit;
        end;

        P := @Row[0];
        OX := 0;
        C := 0;
        for X := 0 to L.Width - 1 do
        begin
          if Grey then
          begin
            Value := P[0];
            Inc(Sums[OX * 3], Value);
          end
          else
          begin
            Inc(Sums[OX * 3], P[0]);        { R }
            Inc(Sums[OX * 3 + 1], P[1]);    { G }
            Inc(Sums[OX * 3 + 2], P[2]);    { B }
          end;
          Inc(P, Spp);
          Inc(C);
          if C = S then
          begin
            C := 0;
            Inc(OX);
          end;
        end;
      end;

      Dest := Bitmap.ScanLine[OY];
      for OX := 0 to OutW - 1 do
      begin
        Cols := Min(S, L.Width - OX * S);
        N := Max(1, Cols * PickCount);
        if Grey then
        begin
          Value := Sums[OX * 3] div LongWord(N);
          if Invert then
            Value := 255 - Value;
          Dest^.red := Value;
          Dest^.green := Value;
          Dest^.blue := Value;
        end
        else
        begin
          Dest^.red := Sums[OX * 3] div LongWord(N);
          Dest^.green := Sums[OX * 3 + 1] div LongWord(N);
          Dest^.blue := Sums[OX * 3 + 2] div LongWord(N);
        end;
        Dest^.alpha := 255;
        Inc(Dest);
      end;
    end;

    Bitmap.InvalidateBitmap;
    Result := Bitmap;
    Bitmap := nil;
  finally
    Bitmap.Free;
    Stream.Free;
  end;
end;

{ ---- LZW (Day 19) ---- }

const
  LzwClear = 256;
  LzwEnd = 257;
  LzwFirst = 258;
  LzwMaxCodes = 4096;
  { Largest decoded strip held in memory (see LoadLzwTiff). }
  MaxStripBytes = 256 * 1024 * 1024;

function LzwDecodeStrip(ASrc: PByte; ASrcLen: Integer; ADest: PByte; ADestLen: Integer): Integer;
var
  PosTab, LenTab: array[0..LzwMaxCodes - 1] of Integer;
  BitBuf: LongWord;
  BitCnt, InPos, CodeLen, NextCode, Code, OldPos, OldLen, OutPos, Start, Len, K: Integer;
  Src, Dst: PByte;
begin
  BitBuf := 0;
  BitCnt := 0;
  InPos := 0;
  CodeLen := 9;
  NextCode := LzwFirst;
  OldPos := -1;
  OldLen := 0;
  OutPos := 0;

  while True do
  begin
    { MSB-first: the next code is at the top of the bits collected. At
      most 12 + 7 bits are held, so the 32-bit buffer is enough. }
    while BitCnt < CodeLen do
    begin
      if InPos >= ASrcLen then
        Exit(OutPos);           { data ends without an end code }
      BitBuf := (BitBuf shl 8) or ASrc[InPos];
      Inc(InPos);
      Inc(BitCnt, 8);
    end;
    Code := Integer((BitBuf shr (BitCnt - CodeLen)) and ((LongWord(1) shl CodeLen) - 1));
    Dec(BitCnt, CodeLen);

    if Code = LzwEnd then
      Break;
    if Code = LzwClear then
    begin
      CodeLen := 9;
      NextCode := LzwFirst;
      OldPos := -1;
      Continue;
    end;

    if OldPos < 0 then
    begin
      { First code after a clear: always a single byte. }
      if (Code >= 256) or (OutPos >= ADestLen) then
        Break;
      ADest[OutPos] := Byte(Code);
      OldPos := OutPos;
      OldLen := 1;
      Inc(OutPos);
      Continue;
    end;

    Start := OutPos;
    if Code < 256 then
    begin
      if OutPos >= ADestLen then
        Break;
      ADest[OutPos] := Byte(Code);
      Len := 1;
    end
    else if Code < NextCode then
    begin
      { A string written before: copy it (it lies wholly before OutPos). }
      Len := LenTab[Code];
      if OutPos + Len > ADestLen then
        Len := ADestLen - OutPos;
      Src := ADest + PosTab[Code];
      Dst := ADest + OutPos;
      if Len <= 16 then
        for K := 0 to Len - 1 do
          Dst[K] := Src[K]
      else
        Move(Src^, Dst^, Len);
    end
    else if Code = NextCode then
    begin
      { The code being defined right now: the previous string plus its
        own first byte. }
      Len := OldLen + 1;
      if OutPos + Len > ADestLen then
        Break;
      Src := ADest + OldPos;
      Dst := ADest + OutPos;
      for K := 0 to OldLen - 1 do
        Dst[K] := Src[K];
      Dst[OldLen] := Src[0];
    end
    else
      Break;                    { damaged data }

    { New entry: the previous string plus the first byte of this one;
      in the output they stand next to each other. }
    if NextCode < LzwMaxCodes then
    begin
      PosTab[NextCode] := OldPos;
      LenTab[NextCode] := OldLen + 1;
      Inc(NextCode);
    end;
    OldPos := Start;
    OldLen := Len;
    Inc(OutPos, Len);

    { TIFF's "early change": one code before the table is full. }
    if (NextCode + 1 >= (1 shl CodeLen)) and (CodeLen < 12) then
      Inc(CodeLen);
    if OutPos >= ADestLen then
      Break;
  end;
  Result := OutPos;
end;

{ Undoes TIFF Predictor 2 (horizontal differencing, 8-bit samples) in
  one row of AWidth pixels with ASpp samples each. }
procedure UndoPredictor(ARow: PByte; AWidth, ASpp: Integer);
var
  I, N: Integer;
begin
  N := AWidth * ASpp;
  for I := ASpp to N - 1 do
    ARow[I] := Byte(ARow[I] + ARow[I - ASpp]);
end;

{ One decoded row into a BGRA bitmap row. }
procedure RowToBgra(ASrc: PByte; ADest: PBGRAPixel; AWidth, ASpp: Integer;
  AGrey, AInvert: Boolean);
var
  X: Integer;
  V: Byte;
begin
  for X := 0 to AWidth - 1 do
  begin
    if AGrey then
    begin
      V := ASrc[0];
      if AInvert then
        V := 255 - V;
      ADest^.red := V;
      ADest^.green := V;
      ADest^.blue := V;
    end
    else
    begin
      ADest^.red := ASrc[0];
      ADest^.green := ASrc[1];
      ADest^.blue := ASrc[2];
    end;
    ADest^.alpha := 255;
    Inc(ASrc, ASpp);
    Inc(ADest);
  end;
end;

{ ---- LZW TIFF loading, strips in parallel for display jobs ---- }

type
  PBGRAPixelArray = array of PBGRAPixel;

  { What the strip decoders share. Written before they start; while
    they run only the flags change (Interlocked), and each writes only
    its own rows (full: bitmap rows; quick: its slots in PickBuf). }
  TLzwJob = record
    FileName: string;
    L: TTiffLayout;
    Spp, RowBytes, S: Integer;
    Full, Grey, Invert: Boolean;
    RowPtrs: PBGRAPixelArray;    { full: bitmap row pointers, taken on one thread }
    PickBuf: array of Byte;      { quick: 2 used rows per output row }
    Abort: LongInt;              { 1: stop (cancelled or damaged) }
    Damaged: LongInt;            { 1: let WIC try }
  end;
  PLzwJob = ^TLzwJob;

  { A helper for a display job: decodes every AStep-th strip. }
  TLzwStripThread = class(TThread)
  private
    FJob: PLzwJob;
    FFirst, FStep: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AJob: PLzwJob; AFirst, AStep: Integer);
  end;

{ Quick view: the slot in PickBuf for row Y, or -1 if Y isn't used.
  Groups of S rows start at multiples of S; the used rows are a
  quarter and three quarters in, clamped to the last row (as in the
  uncompressed reader). }
function PickIndex(const J: TLzwJob; Y: Integer): Integer;
var
  G, P0, P1: Integer;
begin
  G := Y div J.S;
  P0 := Min(G * J.S + J.S div 4, J.L.Height - 1);
  P1 := Min(G * J.S + (3 * J.S) div 4, J.L.Height - 1);
  if Y = P0 then
    Result := 2 * G
  else if (Y = P1) and (P1 <> P0) then
    Result := 2 * G + 1
  else
    Result := -1;
end;

{ Decodes strips AFirst, AFirst + AStep, ... ACancel (the calling
  worker only) is checked between strips; helpers watch J.Abort. }
procedure DecodeStrips(J: PLzwJob; AFirst, AStep: Integer; ACancel: TCancelCheck;
  AYield: Boolean);
var
  Stream: TFileStream;
  Compressed, Raw: array of Byte;
  Strip, FirstRow, StripRows, R, Y, Idx, PackedLen, Produced: Integer;
  Row: PByte;
begin
  try
    Stream := TFileStream.Create(J^.FileName, fmOpenRead or fmShareDenyNone);
  except
    InterlockedExchange(J^.Damaged, 1);
    InterlockedExchange(J^.Abort, 1);
    Exit;
  end;
  try
    SetLength(Raw, Int64(Min(J^.L.RowsPerStrip, J^.L.Height)) * J^.RowBytes);
    Strip := AFirst;
    while Strip <= High(J^.L.StripOffsets) do
    begin
      if Int64(Strip) * J^.L.RowsPerStrip >= J^.L.Height then
        Break;
      FirstRow := Strip * J^.L.RowsPerStrip;
      StripRows := Min(J^.L.RowsPerStrip, J^.L.Height - FirstRow);

      if InterlockedCompareExchange(J^.Abort, 0, 0) <> 0 then
        Exit;
      if Assigned(ACancel) then
      begin
        if AYield then
          IOGate.YieldToDisplay(ACancel);
        if ACancel() then
        begin
          InterlockedExchange(J^.Abort, 1);
          Exit;
        end;
      end;

      { The compressed strip. }
      if (J^.L.StripOffsets[Strip] < 0) or (J^.L.StripByteCounts[Strip] <= 0)
        or (J^.L.StripOffsets[Strip] + J^.L.StripByteCounts[Strip] > Stream.Size)
        or (J^.L.StripByteCounts[Strip] > High(Integer)) then
      begin
        InterlockedExchange(J^.Damaged, 1);
        InterlockedExchange(J^.Abort, 1);
        Exit;
      end;
      PackedLen := Integer(J^.L.StripByteCounts[Strip]);
      if Length(Compressed) < PackedLen then
        SetLength(Compressed, PackedLen);
      Stream.Position := J^.L.StripOffsets[Strip];
      if Stream.Read(Compressed[0], PackedLen) <> PackedLen then
      begin
        InterlockedExchange(J^.Damaged, 1);
        InterlockedExchange(J^.Abort, 1);
        Exit;
      end;

      Produced := LzwDecodeStrip(@Compressed[0], PackedLen, @Raw[0], StripRows * J^.RowBytes);
      { A short strip: the missing rows stay black. }
      if Produced < StripRows * J^.RowBytes then
        FillChar(Raw[Produced], StripRows * J^.RowBytes - Produced, 0);

      for R := 0 to StripRows - 1 do
      begin
        Y := FirstRow + R;
        Row := @Raw[R * J^.RowBytes];
        if J^.Full then
        begin
          if J^.L.Predictor = 2 then
            UndoPredictor(Row, J^.L.Width, J^.Spp);
          RowToBgra(Row, J^.RowPtrs[Y], J^.L.Width, J^.Spp, J^.Grey, J^.Invert);
        end
        else
        begin
          Idx := PickIndex(J^, Y);
          if Idx >= 0 then
          begin
            if J^.L.Predictor = 2 then
              UndoPredictor(Row, J^.L.Width, J^.Spp);
            Move(Row^, J^.PickBuf[Int64(Idx) * J^.RowBytes], J^.RowBytes);
          end;
        end;
      end;

      Inc(Strip, AStep);
    end;
  finally
    Stream.Free;
  end;
end;

constructor TLzwStripThread.Create(AJob: PLzwJob; AFirst, AStep: Integer);
begin
  FJob := AJob;
  FFirst := AFirst;
  FStep := AStep;
  inherited Create(False);
end;

procedure TLzwStripThread.Execute;
begin
  try
    DecodeStrips(FJob, FFirst, FStep, nil, False);
  except
    InterlockedExchange(FJob^.Damaged, 1);
    InterlockedExchange(FJob^.Abort, 1);
  end;
end;

const
  { Helper threads for one display job, at most. }
  MaxLzwHelpers = 3;

function LoadLzwTiff(const AFileName: string;
  AFitWidth, AFitHeight: Integer; ACancel: TCancelCheck; AYield: Boolean;
  out AHandled: Boolean; out AFullWidth, AFullHeight, AScale: Integer): TBGRABitmap;
var
  Stream: TFileStream;
  J: TLzwJob;
  OutW, OutH, OY, OX, K, Helpers, Strips, Cols, N, Value, PickCount, X: Integer;
  Ratio: Double;
  Sums: array of LongWord;
  Bitmap: TBGRABitmap;
  Threads: array of TLzwStripThread;
  Dest: PBGRAPixel;
  Q: PByte;
  Reason: string;
  LayoutOk: Boolean;
begin
  Result := nil;
  AHandled := False;
  AFullWidth := 0;
  AFullHeight := 0;
  AScale := 1;

  { The layout first (the strip decoders open the file themselves). }
  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  except
    Exit;   { WIC will report why }
  end;
  try
    LayoutOk := ReadTiffLayout(Stream, J.L);
  finally
    Stream.Free;
  end;
  if not LayoutOk then
    Exit;

  if (J.L.Compression <> 5) or not (J.L.Predictor in [1, 2]) or J.L.Tiled or (J.L.Planar <> 1)
    or (J.L.BitsPerSample <> 8) or not J.L.SameBits
    or (Length(J.L.StripOffsets) = 0)
    or (Length(J.L.StripByteCounts) <> Length(J.L.StripOffsets)) then
    Exit;
  J.Spp := J.L.SamplesPerPixel;
  J.Grey := (J.Spp = 1) and (J.L.Photometric in [0, 1]);
  J.Invert := J.Grey and (J.L.Photometric = 0);
  if not (J.Grey or ((J.Spp in [3, 4]) and (J.L.Photometric = 2))) then
    Exit;
  if (J.L.RowsPerStrip <= 0) or (J.L.Width > 65535) then
    Exit;
  if Int64(J.L.Height) > Int64(Length(J.L.StripOffsets)) * J.L.RowsPerStrip then
    Exit;
  { Strips are decoded in memory one at a time per thread. Very large
    strips (a whole image in one strip) are left to WIC. }
  if Int64(Min(J.L.RowsPerStrip, J.L.Height)) * J.L.Width * J.Spp > MaxStripBytes then
    Exit;

  J.FileName := AFileName;
  J.RowBytes := J.L.Width * J.Spp;
  J.Full := (AFitWidth <= 0) or (AFitHeight <= 0);
  J.S := 1;
  J.Abort := 0;
  J.Damaged := 0;
  if not J.Full then
  begin
    Ratio := Min(AFitWidth / J.L.Width, AFitHeight / J.L.Height);
    if Ratio < 1 then
      J.S := Max(1, Trunc(1 / Ratio));
    if J.S > 4096 then
      J.S := 4096;
    if J.S < 2 then
      Exit;   { hardly smaller: the full decode (WIC) is as good }
  end;

  if J.Full then
  begin
    if not DecodeFits(J.L.Width, J.L.Height, 0, Reason) then
      raise EImageTooLarge.Create(Reason);
    OutW := J.L.Width;
    OutH := J.L.Height;
  end
  else
  begin
    OutW := (J.L.Width + J.S - 1) div J.S;
    OutH := (J.L.Height + J.S - 1) div J.S;
  end;

  AHandled := True;
  AFullWidth := J.L.Width;
  AFullHeight := J.L.Height;
  AScale := J.S;

  Strips := Integer((Int64(J.L.Height) + J.L.RowsPerStrip - 1) div J.L.RowsPerStrip);
  { Helpers only for the image the user is waiting for; preloads run
    alone and give way (AYield). }
  Helpers := 0;
  if not AYield then
    Helpers := Max(0, Min(Min(TThread.ProcessorCount - 1, MaxLzwHelpers), Strips - 1));

  Bitmap := TBGRABitmap.Create(OutW, OutH);
  Threads := nil;
  try
    if J.Full then
    begin
      { Row pointers taken here, once: the helpers only write pixels. }
      SetLength(J.RowPtrs, J.L.Height);
      for OY := 0 to J.L.Height - 1 do
        J.RowPtrs[OY] := Bitmap.ScanLine[OY];
    end
    else
      SetLength(J.PickBuf, Int64(2) * OutH * J.RowBytes);

    SetLength(Threads, Helpers);
    for K := 0 to Helpers - 1 do
      Threads[K] := TLzwStripThread.Create(@J, K + 1, Helpers + 1);
    try
      DecodeStrips(@J, 0, Helpers + 1, ACancel, AYield);
    except
      InterlockedExchange(J.Damaged, 1);
      InterlockedExchange(J.Abort, 1);
    end;
    for K := 0 to Helpers - 1 do
    begin
      Threads[K].WaitFor;
      FreeAndNil(Threads[K]);
    end;

    if J.Damaged <> 0 then
    begin
      AHandled := False;   { let WIC try (and report) }
      Exit;
    end;
    if J.Abort <> 0 then
      Exit;                { cancelled: Result stays nil }

    if not J.Full then
    begin
      { The output rows from the used rows: all columns, averaged. }
      SetLength(Sums, OutW * 3);
      for OY := 0 to OutH - 1 do
      begin
        FillChar(Sums[0], Length(Sums) * SizeOf(LongWord), 0);
        if Min(OY * J.S + (3 * J.S) div 4, J.L.Height - 1)
          = Min(OY * J.S + J.S div 4, J.L.Height - 1) then
          PickCount := 1
        else
          PickCount := 2;
        for K := 0 to PickCount - 1 do
        begin
          Q := @J.PickBuf[(Int64(2) * OY + K) * J.RowBytes];
          OX := 0;
          N := 0;
          for X := 0 to J.L.Width - 1 do
          begin
            if J.Grey then
              Inc(Sums[OX * 3], Q[0])
            else
            begin
              Inc(Sums[OX * 3], Q[0]);
              Inc(Sums[OX * 3 + 1], Q[1]);
              Inc(Sums[OX * 3 + 2], Q[2]);
            end;
            Inc(Q, J.Spp);
            Inc(N);
            if N = J.S then
            begin
              N := 0;
              Inc(OX);
            end;
          end;
        end;

        Dest := Bitmap.ScanLine[OY];
        for OX := 0 to OutW - 1 do
        begin
          Cols := Min(J.S, J.L.Width - OX * J.S);
          N := Max(1, Cols * PickCount);
          if J.Grey then
          begin
            Value := Sums[OX * 3] div LongWord(N);
            if J.Invert then
              Value := 255 - Value;
            Dest^.red := Value;
            Dest^.green := Value;
            Dest^.blue := Value;
          end
          else
          begin
            Dest^.red := Sums[OX * 3] div LongWord(N);
            Dest^.green := Sums[OX * 3 + 1] div LongWord(N);
            Dest^.blue := Sums[OX * 3 + 2] div LongWord(N);
          end;
          Dest^.alpha := 255;
          Inc(Dest);
        end;
      end;
    end;

    Bitmap.InvalidateBitmap;
    Result := Bitmap;
    Bitmap := nil;
  finally
    { Normally all helpers were waited for above; only an exception
      before that leaves some here. }
    for K := 0 to High(Threads) do
      if Threads[K] <> nil then
      begin
        InterlockedExchange(J.Abort, 1);
        Threads[K].WaitFor;
        Threads[K].Free;
      end;
    Bitmap.Free;
  end;
end;

end.
