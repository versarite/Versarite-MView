unit uJpegHeader;

{
  Unit: uJpegHeader

  Purpose
  -------
  Phase E, Preview quality (spec §7.1): what a JPEG file says about
  itself before its image data, read without loading the file. A
  108 MP photo is 30 MB and needs about 600 ms even at 1/8 size, most
  of it for decoding every compressed block; its header, with the
  EXIF thumbnail most cameras and phones store, is a few dozen KB at
  the very start and takes a millisecond or two.

  Owns
  ----
  - The TFileStream ReadJpegHead opens; it is closed before the call
    returns.
  - Nothing afterwards: the thumbnail bytes (TJpegHead.Thumbnail) go
    to the caller.

  Knows
  -----
  - The stream handed to ReadJpegHeadFromStream (read, not freed).

  Responsibilities
  ----------------
  - ReadJpegHead: walk the marker segments from the start of the file
    up to the frame header (SOFn): image size, EXIF orientation, and
    the EXIF thumbnail's bytes. Only those segments are read; all
    others are skipped with a seek. Only the first EXIF block counts;
    after 200 segments (MaxSegments) it gives up.
    ReadJpegHeadFromStream does the same on a stream.
  - AspectCrop: the part of a thumbnail that has the main image's
    shape (many cameras store 160 x 120 thumbnails for 16:9 photos,
    with black bars). Shapes within 2 % keep the whole thumbnail.

  Does NOT
  --------
  - Decode anything (the loader decodes the thumbnail with
    uJpegDecoder).
  - Use BGRABitmap or the LCL, so the command-line tests can use it.
  - Parse the EXIF block itself (uExifOrientation does).

  Threads
  -------
  Any thread; no shared state. Called on the decode workers by
  uMediaLoader (Preview quality).

  Uses (MView units)
  ------------------
  interface:      uExifOrientation
  Libraries:      Classes, SysUtils

  Used by
  -------
  uMediaLoader

  Notes
  -----
  Every length is checked before it is used; a broken or hostile file
  gives False (or no thumbnail), never an access violation. The EXIF
  block of a JPEG can be at most 64 KB (one segment).
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  uExifOrientation;

type

  TJpegHead = record
    Width: Integer;          { as stored (before EXIF orientation) }
    Height: Integer;
    Orientation: Integer;    { EXIF 1..8; 1 if none }
    Thumbnail: TBytes;       { the EXIF thumbnail JPEG; empty if none }
  end;

{ False if the file can't be opened or is not a JPEG whose frame
  header could be found. }
function ReadJpegHead(const AFileName: string; out AHead: TJpegHead): Boolean;

{ The same for a stream positioned at the start of the JPEG. }
function ReadJpegHeadFromStream(AStream: TStream; out AHead: TJpegHead): Boolean;

{ The centred part (AX, AY, AW, AH) of an AThumbW x AThumbH thumbnail
  that has the shape of an AFullW x AFullH image. The whole thumbnail
  if the shapes differ by less than 2 %. }
procedure AspectCrop(AThumbW, AThumbH, AFullW, AFullH: Integer;
  out AX, AY, AW, AH: Integer);

implementation

const
  { Give up after this many segments (a file that is not what it
    claims to be). }
  MaxSegments = 200;

function ReadByte(AStream: TStream; out AValue: Byte): Boolean;
begin
  Result := AStream.Read(AValue, 1) = 1;
end;

function ReadBE16(AStream: TStream; out AValue: Integer): Boolean;
var
  B: array[0..1] of Byte;
begin
  Result := AStream.Read(B, 2) = 2;
  if Result then
    AValue := (Integer(B[0]) shl 8) or B[1]
  else
    AValue := 0;
end;

{ SOF0..SOF15 carry the image size, except DHT (C4), JPG (C8) and
  DAC (CC), which share the range. }
function IsFrameMarker(AMarker: Byte): Boolean;
begin
  Result := (AMarker >= $C0) and (AMarker <= $CF)
    and (AMarker <> $C4) and (AMarker <> $C8) and (AMarker <> $CC);
end;

{ AData: an APP1 segment's content (after the length field). If it is
  the EXIF block, takes orientation and thumbnail from it. }
procedure ReadExifSegment(const AData: TBytes; var AHead: TJpegHead);
var
  Tiff: PByte;
  TiffLen, Offset, Len: Int64;
begin
  if Length(AData) < 6 + 8 then
    Exit;
  if not ((AData[0] = Ord('E')) and (AData[1] = Ord('x')) and (AData[2] = Ord('i'))
    and (AData[3] = Ord('f')) and (AData[4] = 0) and (AData[5] = 0)) then
    Exit;   { XMP or something else in APP1 }

  Tiff := @AData[6];
  TiffLen := Length(AData) - 6;
  AHead.Orientation := OrientationFromExif(Tiff, TiffLen);
  if ExifThumbnailRange(Tiff, TiffLen, Offset, Len) then
  begin
    SetLength(AHead.Thumbnail, Len);
    Move(Tiff[Offset], AHead.Thumbnail[0], Len);
  end;
end;

function ReadJpegHeadFromStream(AStream: TStream; out AHead: TJpegHead): Boolean;
var
  B, Marker: Byte;
  SegLen, Segments, Precision: Integer;
  Data: TBytes;
  ExifSeen: Boolean;
begin
  Result := False;
  AHead.Width := 0;
  AHead.Height := 0;
  AHead.Orientation := 1;
  AHead.Thumbnail := nil;
  ExifSeen := False;

  { SOI }
  if not (ReadByte(AStream, B) and (B = $FF) and ReadByte(AStream, B) and (B = $D8)) then
    Exit;

  for Segments := 1 to MaxSegments do
  begin
    { A marker: FF, possibly more FF fill bytes, then the code. }
    if not ReadByte(AStream, B) or (B <> $FF) then
      Exit;
    repeat
      if not ReadByte(AStream, Marker) then
        Exit;
    until Marker <> $FF;

    { Markers without a length. }
    if (Marker = $01) or ((Marker >= $D0) and (Marker <= $D7)) then
      Continue;
    { Image data or end: the frame header should have come already. }
    if (Marker = $DA) or (Marker = $D9) then
      Exit;

    if not ReadBE16(AStream, SegLen) or (SegLen < 2) then
      Exit;
    Dec(SegLen, 2);   { the content after the length field }

    if IsFrameMarker(Marker) then
    begin
      { Precision (1 byte), height, width (2 bytes each). }
      if (SegLen < 5) or not ReadByte(AStream, B) then
        Exit;
      Precision := B;
      if not (ReadBE16(AStream, AHead.Height) and ReadBE16(AStream, AHead.Width)) then
        Exit;
      Result := (Precision > 0) and (AHead.Width > 0) and (AHead.Height > 0);
      Exit;
    end;

    if (Marker = $E1) and not ExifSeen then
    begin
      SetLength(Data, SegLen);
      if (SegLen > 0) and (AStream.Read(Data[0], SegLen) <> SegLen) then
        Exit;
      if (SegLen >= 6) and (Data[0] = Ord('E')) and (Data[1] = Ord('x')) then
      begin
        ExifSeen := True;   { only the first EXIF block counts }
        ReadExifSegment(Data, AHead);
      end;
      Data := nil;
    end
    else
      AStream.Seek(SegLen, soCurrent);
  end;
end;

function ReadJpegHead(const AFileName: string; out AHead: TJpegHead): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  AHead.Width := 0;
  AHead.Height := 0;
  AHead.Orientation := 1;
  AHead.Thumbnail := nil;
  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      Result := ReadJpegHeadFromStream(Stream, AHead);
    finally
      Stream.Free;
    end;
  except
    Result := False;   { can't open: the full decode will say why }
  end;
end;

procedure AspectCrop(AThumbW, AThumbH, AFullW, AFullH: Integer;
  out AX, AY, AW, AH: Integer);
var
  ThumbAspect, FullAspect: Double;
begin
  AX := 0;
  AY := 0;
  AW := AThumbW;
  AH := AThumbH;
  if (AThumbW <= 0) or (AThumbH <= 0) or (AFullW <= 0) or (AFullH <= 0) then
    Exit;

  ThumbAspect := AThumbW / AThumbH;
  FullAspect := AFullW / AFullH;
  if Abs(ThumbAspect / FullAspect - 1) < 0.02 then
    Exit;

  if ThumbAspect > FullAspect then
  begin
    { Thumbnail wider: bars left and right. }
    AW := Round(AThumbH * FullAspect);
    if AW < 1 then
      AW := 1;
    AX := (AThumbW - AW) div 2;
  end
  else
  begin
    { Thumbnail taller: bars top and bottom. }
    AH := Round(AThumbW / FullAspect);
    if AH < 1 then
      AH := 1;
    AY := (AThumbH - AH) div 2;
  end;
end;

end.
