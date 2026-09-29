unit uIconFile;

{
  Unit: uIconFile

  Purpose
  -------
  Reads and writes Windows icon files (.ico) for the sort panel's
  buttons (Phase G, G1 stage 2): the list of pictures in a file, the
  choice of the one that fits a button best, the old-style pictures
  (DIB: 1, 4, 8, 24 and 32 bit with the AND mask) decoded to plain
  pixels, and a new icon written from PNG pictures ("Make icon from
  this image").

  Owns
  ----
  Nothing (plain functions on byte arrays).

  Knows
  -----
  Nothing else.

  Responsibilities
  ----------------
  - ReadIconDirectory: the entries of an .ico held in memory (size,
    colour depth, where its data is, PNG or DIB). Entries pointing
    outside the data are dropped; a file that isn't an icon gives False.
  - ChooseIconEntry: the smallest picture at least as large as the size
    asked for (the best depth among equals), else the largest one: so a
    button gets a picture shrunk, not blown up.
  - DecodeIconDib: an old-style entry to 32-bit pixels, top row first,
    $AARRGGBB, with transparency from the alpha channel or the AND mask.
  - PngImageSize: the size stored in a PNG entry's header (the
    directory says 0 for 256 px).
  - WriteIconFile: an .ico from PNG pictures (Windows Vista and later
    read PNG entries of every size, as its own icons use).

  Does NOT
  --------
  - Decode PNG (the caller does, with BGRABitmap) or scale pictures.
  - Read or write files: byte arrays and streams only.
  - Handle 16-bit DIBs or compressed DIBs (rare in icons): False.

  Threads
  -------
  Any thread; no state.

  Uses (MView units)
  ------------------
  (none)
  Libraries:      Classes, SysUtils

  Used by
  -------
  uSortIcons, uMView (Make icon), TestSort
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils;

type
  TIconEntry = record
    Width: Integer;
    Height: Integer;
    BitCount: Integer;     { 32 for PNG entries }
    Offset: LongWord;      { of the picture's data in the file }
    Size: LongWord;
    IsPng: Boolean;
  end;
  TIconEntries = array of TIconEntry;

  { Plain pixels, top row first, $AARRGGBB. }
  TIconPixels = record
    Width: Integer;
    Height: Integer;
    Data: array of LongWord;
  end;

function ReadIconDirectory(const AData: TBytes; out AEntries: TIconEntries): Boolean;
function ChooseIconEntry(const AEntries: TIconEntries; ASize: Integer): Integer;
function DecodeIconDib(const AData: TBytes; const AEntry: TIconEntry;
  out APixels: TIconPixels): Boolean;
function PngImageSize(const AData: TBytes; AOffset: LongWord; out AWidth, AHeight: Integer): Boolean;
{ APngs[i]: a complete PNG file of ASizes[i] x ASizes[i] pixels. }
procedure WriteIconFile(AStream: TStream; const APngs: array of TBytes;
  const ASizes: array of Integer);

implementation

const
  MaxIconSide = 1024;

function U16(const AData: TBytes; AOffset: Int64): LongWord;
begin
  Result := LongWord(AData[AOffset]) or (LongWord(AData[AOffset + 1]) shl 8);
end;

function U32(const AData: TBytes; AOffset: Int64): LongWord;
begin
  Result := LongWord(AData[AOffset]) or (LongWord(AData[AOffset + 1]) shl 8)
    or (LongWord(AData[AOffset + 2]) shl 16) or (LongWord(AData[AOffset + 3]) shl 24);
end;

function BigU32(const AData: TBytes; AOffset: Int64): LongWord;
begin
  Result := (LongWord(AData[AOffset]) shl 24) or (LongWord(AData[AOffset + 1]) shl 16)
    or (LongWord(AData[AOffset + 2]) shl 8) or LongWord(AData[AOffset + 3]);
end;

function IsPngAt(const AData: TBytes; AOffset: Int64): Boolean;
begin
  Result := (AOffset + 8 <= Length(AData)) and (AData[AOffset] = $89)
    and (AData[AOffset + 1] = Ord('P')) and (AData[AOffset + 2] = Ord('N'))
    and (AData[AOffset + 3] = Ord('G'));
end;

function PngImageSize(const AData: TBytes; AOffset: LongWord; out AWidth, AHeight: Integer): Boolean;
begin
  AWidth := 0;
  AHeight := 0;
  { Signature (8), then the IHDR chunk: length (4), 'IHDR' (4), width, height. }
  Result := IsPngAt(AData, AOffset) and (Int64(AOffset) + 24 <= Length(AData));
  if not Result then
    Exit;
  AWidth := Integer(BigU32(AData, Int64(AOffset) + 16));
  AHeight := Integer(BigU32(AData, Int64(AOffset) + 20));
  Result := (AWidth > 0) and (AHeight > 0) and (AWidth <= MaxIconSide * 4)
    and (AHeight <= MaxIconSide * 4);
end;

function ReadIconDirectory(const AData: TBytes; out AEntries: TIconEntries): Boolean;
var
  Count, I, N, W, H: Integer;
  P: Int64;
  E: TIconEntry;
begin
  AEntries := nil;
  Result := False;
  if Length(AData) < 6 then
    Exit;
  if (U16(AData, 0) <> 0) or ((U16(AData, 2) <> 1) and (U16(AData, 2) <> 2)) then
    Exit;
  Count := U16(AData, 4);
  if (Count = 0) or (6 + Int64(Count) * 16 > Length(AData)) then
    Exit;
  N := 0;
  SetLength(AEntries, Count);
  for I := 0 to Count - 1 do
  begin
    P := 6 + Int64(I) * 16;
    E.Width := AData[P];
    E.Height := AData[P + 1];
    if E.Width = 0 then
      E.Width := 256;
    if E.Height = 0 then
      E.Height := 256;
    E.BitCount := U16(AData, P + 6);
    E.Size := U32(AData, P + 8);
    E.Offset := U32(AData, P + 12);
    if (E.Size = 0) or (Int64(E.Offset) + E.Size > Length(AData)) then
      Continue;
    E.IsPng := IsPngAt(AData, E.Offset);
    if E.IsPng then
    begin
      E.BitCount := 32;
      if PngImageSize(AData, E.Offset, W, H) then
      begin
        E.Width := W;
        E.Height := H;
      end;
    end
    else if Int64(E.Offset) + 40 <= Length(AData) then
    begin
      { The DIB header knows the depth better (the directory may say 0). }
      if U16(AData, Int64(E.Offset) + 14) <> 0 then
        E.BitCount := U16(AData, Int64(E.Offset) + 14);
    end
    else
      Continue;
    AEntries[N] := E;
    Inc(N);
  end;
  SetLength(AEntries, N);
  Result := N > 0;
end;

function ChooseIconEntry(const AEntries: TIconEntries; ASize: Integer): Integer;
var
  I, Best, Side, BestSide: Integer;
  Better: Boolean;
begin
  Result := -1;
  if Length(AEntries) = 0 then
    Exit;
  { The smallest at least ASize. }
  Best := -1;
  BestSide := 0;
  for I := 0 to High(AEntries) do
  begin
    Side := AEntries[I].Width;
    if AEntries[I].Height < Side then
      Side := AEntries[I].Height;
    if Side < ASize then
      Continue;
    Better := (Best < 0) or (Side < BestSide)
      or ((Side = BestSide) and (AEntries[I].BitCount > AEntries[Best].BitCount));
    if Better then
    begin
      Best := I;
      BestSide := Side;
    end;
  end;
  if Best >= 0 then
    Exit(Best);
  { None large enough: the largest. }
  for I := 0 to High(AEntries) do
  begin
    Side := AEntries[I].Width;
    if AEntries[I].Height < Side then
      Side := AEntries[I].Height;
    Better := (Best < 0) or (Side > BestSide)
      or ((Side = BestSide) and (AEntries[I].BitCount > AEntries[Best].BitCount));
    if Better then
    begin
      Best := I;
      BestSide := Side;
    end;
  end;
  Result := Best;
end;

function DecodeIconDib(const AData: TBytes; const AEntry: TIconEntry;
  out APixels: TIconPixels): Boolean;
var
  Base, PalPos, XorPos, AndPos, RowPos, Limit: Int64;
  HeaderSize, W, H, Bpp, Compression, PalCount, XorStride, AndStride: Integer;
  X, Y, Src, Idx: Integer;
  Palette: array of LongWord;
  B: Byte;
  Pixel: LongWord;
  AnyAlpha, Masked: Boolean;
begin
  Result := False;
  APixels.Width := 0;
  APixels.Height := 0;
  APixels.Data := nil;
  if AEntry.IsPng then
    Exit;
  Base := AEntry.Offset;
  Limit := Int64(AEntry.Offset) + AEntry.Size;
  if Limit > Length(AData) then
    Limit := Length(AData);
  if Base + 40 > Limit then
    Exit;
  HeaderSize := Integer(U32(AData, Base));
  W := Integer(U32(AData, Base + 4));
  H := Integer(U32(AData, Base + 8)) div 2;   { the XOR and AND pictures }
  Bpp := U16(AData, Base + 14);
  Compression := Integer(U32(AData, Base + 16));
  PalCount := Integer(U32(AData, Base + 32));
  if (HeaderSize < 40) or (W <= 0) or (H <= 0) or (W > MaxIconSide) or (H > MaxIconSide)
    or (Compression <> 0)
    or not ((Bpp = 1) or (Bpp = 4) or (Bpp = 8) or (Bpp = 24) or (Bpp = 32)) then
    Exit;
  if Bpp <= 8 then
  begin
    if (PalCount <= 0) or (PalCount > (1 shl Bpp)) then
      PalCount := 1 shl Bpp;
  end
  else
    PalCount := 0;

  PalPos := Base + HeaderSize;
  XorPos := PalPos + Int64(PalCount) * 4;
  XorStride := ((W * Bpp + 31) div 32) * 4;
  AndPos := XorPos + Int64(XorStride) * H;
  AndStride := ((W + 31) div 32) * 4;
  if AndPos > Limit then
    Exit;
  { Some 32-bit icons leave out the AND mask: then there is no mask. }
  Masked := AndPos + Int64(AndStride) * H <= Limit;

  SetLength(Palette, PalCount);
  for Idx := 0 to PalCount - 1 do
    Palette[Idx] := U32(AData, PalPos + Int64(Idx) * 4) and $00FFFFFF;

  APixels.Width := W;
  APixels.Height := H;
  SetLength(APixels.Data, W * H);
  AnyAlpha := False;
  for Y := 0 to H - 1 do
  begin
    RowPos := XorPos + Int64(H - 1 - Y) * XorStride;   { bottom-up }
    for X := 0 to W - 1 do
    begin
      case Bpp of
        32:
          begin
            Src := X * 4;
            Pixel := U32(AData, RowPos + Src);
            if (Pixel shr 24) <> 0 then
              AnyAlpha := True;
          end;
        24:
          begin
            Src := X * 3;
            Pixel := LongWord(AData[RowPos + Src]) or (LongWord(AData[RowPos + Src + 1]) shl 8)
              or (LongWord(AData[RowPos + Src + 2]) shl 16) or $FF000000;
          end;
        8:
          Pixel := Palette[AData[RowPos + X] mod PalCount] or $FF000000;
        4:
          begin
            B := AData[RowPos + X div 2];
            if X mod 2 = 0 then
              Idx := B shr 4
            else
              Idx := B and $0F;
            Pixel := Palette[Idx mod PalCount] or $FF000000;
          end;
      else { 1 }
        begin
          B := AData[RowPos + X div 8];
          Idx := (B shr (7 - X mod 8)) and 1;
          Pixel := Palette[Idx mod PalCount] or $FF000000;
        end;
      end;
      APixels.Data[Y * W + X] := Pixel;
    end;
  end;

  { Transparency: a 32-bit picture with alpha keeps it; otherwise the AND
    mask (1 = transparent). }
  if (Bpp = 32) and AnyAlpha then
    Exit(True);
  for Y := 0 to H - 1 do
  begin
    RowPos := AndPos + Int64(H - 1 - Y) * AndStride;
    for X := 0 to W - 1 do
    begin
      Pixel := APixels.Data[Y * W + X] or $FF000000;
      if Masked and (((AData[RowPos + X div 8] shr (7 - X mod 8)) and 1) = 1) then
        Pixel := 0;
      APixels.Data[Y * W + X] := Pixel;
    end;
  end;
  Result := True;
end;

procedure WriteU16(AStream: TStream; AValue: Word);
var
  B: array[0..1] of Byte;
begin
  B[0] := AValue and $FF;
  B[1] := AValue shr 8;
  AStream.WriteBuffer(B, 2);
end;

procedure WriteU32(AStream: TStream; AValue: LongWord);
var
  B: array[0..3] of Byte;
begin
  B[0] := AValue and $FF;
  B[1] := (AValue shr 8) and $FF;
  B[2] := (AValue shr 16) and $FF;
  B[3] := AValue shr 24;
  AStream.WriteBuffer(B, 4);
end;

procedure WriteIconFile(AStream: TStream; const APngs: array of TBytes;
  const ASizes: array of Integer);
var
  I, Count: Integer;
  Offset: LongWord;
  Side: Byte;
begin
  Count := Length(APngs);
  if Length(ASizes) < Count then
    Count := Length(ASizes);
  WriteU16(AStream, 0);        { reserved }
  WriteU16(AStream, 1);        { icon }
  WriteU16(AStream, Count);
  Offset := 6 + 16 * Count;
  for I := 0 to Count - 1 do
  begin
    if ASizes[I] >= 256 then
      Side := 0
    else
      Side := ASizes[I];
    AStream.WriteByte(Side);   { width }
    AStream.WriteByte(Side);   { height }
    AStream.WriteByte(0);      { colours: none (true colour) }
    AStream.WriteByte(0);      { reserved }
    WriteU16(AStream, 1);      { planes }
    WriteU16(AStream, 32);     { bits per pixel }
    WriteU32(AStream, Length(APngs[I]));
    WriteU32(AStream, Offset);
    Inc(Offset, Length(APngs[I]));
  end;
  for I := 0 to Count - 1 do
    if Length(APngs[I]) > 0 then
      AStream.WriteBuffer(APngs[I][0], Length(APngs[I]));
end;

end.
