unit uExifOrientation;

{
  Unit: uExifOrientation

  Purpose
  -------
  Reads the EXIF orientation tag of a JPEG held in memory. Cameras and
  phones store the pixels as the sensor saw them and only note in this
  tag how the picture has to be turned to stand upright.

  Owns
  ----
  - Nothing: stateless routines on memory the caller owns.

  Knows
  -----
  - Nothing else.

  Responsibilities
  ----------------
  - ReadExifOrientation: the tag's value, 1..8 (1 = upright, also when
    there is no tag or anything is wrong with the data). Walks the
    JPEG markers up to the image data; only the first EXIF block
    counts (XMP in APP1 is skipped).
  - OrientationSwapsSize: True for the values that turn the picture
    by 90 degrees (width and height change places).
  - Working on the EXIF block alone (the TIFF structure after
    "Exif"#0#0, as uJpegHeader collects it):
    OrientationFromExif, and ExifThumbnailRange, where the embedded
    thumbnail JPEG is (IFD1, tags 0x0201 / 0x0202). Phase E uses the
    thumbnail as the Preview quality.

  Does NOT
  --------
  - Turn pixels (TMediaLoader does, with BGRABitmap).
  - Read any other EXIF data.
  - Read files (the callers hand in memory: uMediaLoader the JPEG,
    uJpegHeader the EXIF block).

  Threads
  -------
  Any thread; pure functions. Used on the decode workers.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.

  Used by
  -------
  uJpegHeader, uMediaLoader

  Values (EXIF 2.3, tag 0x0112)
  -----------------------------
    1  upright                  5  mirrored along the main diagonal
    2  mirrored left-right      6  turn 90 degrees clockwise to view
    3  upside down              7  mirrored along the other diagonal
    4  mirrored top-bottom      8  turn 90 degrees anticlockwise

  Notes
  -----
  The parser only trusts what it has checked: every offset and length
  is compared with the data size first, so a broken or hostile file
  gives 1, never an access violation. No BGRABitmap here, so the
  command-line test can use this unit.
}

{$mode ObjFPC}{$H+}

interface

{ AData/ASize: the complete JPEG file (or at least its beginning up to
  the image data). }
function ReadExifOrientation(AData: PByte; ASize: Int64): Integer;

function OrientationSwapsSize(AOrientation: Integer): Boolean;

{ ATiff: the EXIF block from its TIFF header on ("II" or "MM"), ALen
  bytes long. 1..8; 1 also when there is no usable tag. }
function OrientationFromExif(ATiff: PByte; ALen: Int64): Integer;

{ Where the thumbnail JPEG lies inside the same block (offset from the
  TIFF header). False if there is none, or it doesn't lie completely
  inside the block, or doesn't start like a JPEG. }
function ExifThumbnailRange(ATiff: PByte; ALen: Int64;
  out AOffset, ALength: Int64): Boolean;

implementation

const
  TagOrientation = $0112;
  TagThumbnailOffset = $0201;   { JPEGInterchangeFormat }
  TagThumbnailLength = $0202;   { JPEGInterchangeFormatLength }
  TypeShort = 3;
  TypeLong = 4;

{ Big-endian 16 bits, as in the JPEG marker structure. }
function GetBE16(P: PByte): Integer; inline;
begin
  Result := (Integer(P[0]) shl 8) or P[1];
end;

{ 16/32 bits in the TIFF byte order of the EXIF block. }
function Get16(P: PByte; ALittle: Boolean): Integer; inline;
begin
  if ALittle then
    Result := (Integer(P[1]) shl 8) or P[0]
  else
    Result := (Integer(P[0]) shl 8) or P[1];
end;

function Get32(P: PByte; ALittle: Boolean): Int64; inline;
begin
  if ALittle then
    Result := (Int64(P[3]) shl 24) or (Int64(P[2]) shl 16) or (Int64(P[1]) shl 8) or P[0]
  else
    Result := (Int64(P[0]) shl 24) or (Int64(P[1]) shl 16) or (Int64(P[2]) shl 8) or P[3];
end;

{ AExif points to the byte after "Exif"#0#0, i.e. the TIFF header;
  ALen bytes are available from there. 0 = no usable tag. }
function OrientationFromTiff(AExif: PByte; ALen: Int64): Integer;
var
  Little: Boolean;
  IfdOffset, EntryPos: Int64;
  Count, I, Tag, ValueType, Value: Integer;
begin
  Result := 0;
  if ALen < 8 then
    Exit;

  if (AExif[0] = Ord('I')) and (AExif[1] = Ord('I')) then
    Little := True
  else if (AExif[0] = Ord('M')) and (AExif[1] = Ord('M')) then
    Little := False
  else
    Exit;
  if Get16(AExif + 2, Little) <> 42 then
    Exit;

  IfdOffset := Get32(AExif + 4, Little);
  if (IfdOffset < 8) or (IfdOffset + 2 > ALen) then
    Exit;

  Count := Get16(AExif + IfdOffset, Little);
  for I := 0 to Count - 1 do
  begin
    EntryPos := IfdOffset + 2 + Int64(I) * 12;
    if EntryPos + 12 > ALen then
      Exit;
    Tag := Get16(AExif + EntryPos, Little);
    if Tag <> TagOrientation then
      Continue;

    ValueType := Get16(AExif + EntryPos + 2, Little);
    if ValueType <> TypeShort then
      Exit;
    { A single SHORT sits in the first two bytes of the value field. }
    Value := Get16(AExif + EntryPos + 8, Little);
    if (Value >= 1) and (Value <= 8) then
      Result := Value;
    Exit;
  end;
end;

function ReadExifOrientation(AData: PByte; ASize: Int64): Integer;
var
  Pos, SegLen: Int64;
  Marker, Found: Integer;
begin
  Result := 1;
  if (AData = nil) or (ASize < 4) then
    Exit;
  if (AData[0] <> $FF) or (AData[1] <> $D8) then
    Exit;   { not a JPEG }

  Pos := 2;
  while Pos + 4 <= ASize do
  begin
    if AData[Pos] <> $FF then
      Exit;   { lost in the marker structure: give up }

    Marker := AData[Pos + 1];
    if Marker = $FF then
    begin
      Inc(Pos);   { fill byte }
      Continue;
    end;

    { Start of scan or end of image: the header part is over. }
    if (Marker = $DA) or (Marker = $D9) then
      Exit;

    { Markers without a length field. }
    if (Marker = $01) or ((Marker >= $D0) and (Marker <= $D7)) then
    begin
      Inc(Pos, 2);
      Continue;
    end;

    SegLen := GetBE16(AData + Pos + 2);   { includes its own 2 bytes }
    if (SegLen < 2) or (Pos + 2 + SegLen > ASize) then
      Exit;

    { APP1 with "Exif"#0#0. (XMP also lives in APP1; it is skipped.) }
    if (Marker = $E1) and (SegLen >= 2 + 6 + 8)
      and (AData[Pos + 4] = Ord('E')) and (AData[Pos + 5] = Ord('x'))
      and (AData[Pos + 6] = Ord('i')) and (AData[Pos + 7] = Ord('f'))
      and (AData[Pos + 8] = 0) and (AData[Pos + 9] = 0) then
    begin
      Found := OrientationFromTiff(AData + Pos + 10, SegLen - 2 - 6);
      if Found > 0 then
        Result := Found;
      Exit;   { only the first EXIF block counts }
    end;

    Inc(Pos, 2 + SegLen);
  end;
end;

function OrientationSwapsSize(AOrientation: Integer): Boolean;
begin
  Result := (AOrientation >= 5) and (AOrientation <= 8);
end;

function OrientationFromExif(ATiff: PByte; ALen: Int64): Integer;
begin
  Result := 1;
  if (ATiff = nil) or (ALen < 8) then
    Exit;
  Result := OrientationFromTiff(ATiff, ALen);
  if Result = 0 then
    Result := 1;
end;

{ A SHORT or LONG value from an IFD entry at AEntry. -1 otherwise. }
function EntryNumber(AEntry: PByte; ALittle: Boolean): Int64;
begin
  case Get16(AEntry + 2, ALittle) of
    TypeShort: Result := Get16(AEntry + 8, ALittle);
    TypeLong:  Result := Get32(AEntry + 8, ALittle);
  else
    Result := -1;
  end;
end;

function ExifThumbnailRange(ATiff: PByte; ALen: Int64;
  out AOffset, ALength: Int64): Boolean;
var
  Little: Boolean;
  Ifd0, Ifd1, EntryPos: Int64;
  Count, I, Tag: Integer;
begin
  Result := False;
  AOffset := 0;
  ALength := 0;
  if (ATiff = nil) or (ALen < 8) then
    Exit;

  if (ATiff[0] = Ord('I')) and (ATiff[1] = Ord('I')) then
    Little := True
  else if (ATiff[0] = Ord('M')) and (ATiff[1] = Ord('M')) then
    Little := False
  else
    Exit;
  if Get16(ATiff + 2, Little) <> 42 then
    Exit;

  { IFD0 (the main image), then the offset of the next IFD: IFD1,
    which describes the thumbnail. }
  Ifd0 := Get32(ATiff + 4, Little);
  if (Ifd0 < 8) or (Ifd0 + 2 > ALen) then
    Exit;
  Count := Get16(ATiff + Ifd0, Little);
  EntryPos := Ifd0 + 2 + Int64(Count) * 12;
  if EntryPos + 4 > ALen then
    Exit;
  Ifd1 := Get32(ATiff + EntryPos, Little);
  if (Ifd1 < 8) or (Ifd1 = Ifd0) or (Ifd1 + 2 > ALen) then
    Exit;

  Count := Get16(ATiff + Ifd1, Little);
  for I := 0 to Count - 1 do
  begin
    EntryPos := Ifd1 + 2 + Int64(I) * 12;
    if EntryPos + 12 > ALen then
      Exit;
    Tag := Get16(ATiff + EntryPos, Little);
    if Tag = TagThumbnailOffset then
      AOffset := EntryNumber(ATiff + EntryPos, Little)
    else if Tag = TagThumbnailLength then
      ALength := EntryNumber(ATiff + EntryPos, Little);
  end;

  Result := (AOffset >= 8) and (ALength >= 4) and (AOffset + ALength <= ALen)
    and (ATiff[AOffset] = $FF) and (ATiff[AOffset + 1] = $D8);
  if not Result then
  begin
    AOffset := 0;
    ALength := 0;
  end;
end;

end.
