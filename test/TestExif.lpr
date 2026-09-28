program TestExif;

{
  Checks uExifOrientation.ReadExifOrientation on JPEG headers built in
  memory (both byte orders, tag position, broken data), and on the test
  pictures in test\images\exif if they are there (orient_N.jpg must give
  N).

  Phase E: uJpegHeader (size, orientation and EXIF thumbnail read from
  the start of the file) on the pictures in test\images\thumb, and
  AspectCrop.

  Build and run with build_test.bat.
}

{$mode ObjFPC}{$H+}

uses
  SysUtils, Classes,
  uExifOrientation,
  uJpegHeader;

var
  PassCount, FailCount: Integer;

procedure Check(const ALabel: string; ACondition: Boolean; const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(PassCount);
    WriteLn('  PASS  ', ALabel);
  end
  else
  begin
    Inc(FailCount);
    WriteLn('  FAIL  ', ALabel);
    if ADetail <> '' then
      WriteLn('         got: ', ADetail);
  end;
end;

{ ---- building JPEG headers in memory ---- }

type
  TByteBuilder = record
    Data: TBytes;
  end;

procedure AddByte(var B: TByteBuilder; AValue: Integer);
var
  N: Integer;
begin
  N := Length(B.Data);
  SetLength(B.Data, N + 1);
  B.Data[N] := Byte(AValue);
end;

procedure AddBE16(var B: TByteBuilder; AValue: Integer);
begin
  AddByte(B, (AValue shr 8) and $FF);
  AddByte(B, AValue and $FF);
end;

procedure Add16(var B: TByteBuilder; AValue: Integer; ALittle: Boolean);
begin
  if ALittle then
  begin
    AddByte(B, AValue and $FF);
    AddByte(B, (AValue shr 8) and $FF);
  end
  else
    AddBE16(B, AValue);
end;

procedure Add32(var B: TByteBuilder; AValue: Int64; ALittle: Boolean);
begin
  if ALittle then
  begin
    Add16(B, AValue and $FFFF, True);
    Add16(B, (AValue shr 16) and $FFFF, True);
  end
  else
  begin
    AddBE16(B, (AValue shr 16) and $FFFF);
    AddBE16(B, AValue and $FFFF);
  end;
end;

procedure AddText(var B: TByteBuilder; const AText: string);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    AddByte(B, Ord(AText[I]));
end;

{ An IFD entry: tag, type, count 1, and a 16-bit value. }
procedure AddEntry(var B: TByteBuilder; ATag, AType, AValue: Integer; ALittle: Boolean);
begin
  Add16(B, ATag, ALittle);
  Add16(B, AType, ALittle);
  Add32(B, 1, ALittle);
  Add16(B, AValue, ALittle);
  Add16(B, 0, ALittle);
end;

{ A small JPEG header: SOI, optional JFIF APP0, APP1 Exif with an IFD
  of two entries (the orientation first or second), then SOS and EOI.
  AOrientation 0: no orientation entry at all. }
function MakeJpeg(ALittle: Boolean; AOrientation: Integer; AOrientationSecond,
  AWithJfif: Boolean; AType: Integer = 3): TBytes;
var
  B, Tiff: TByteBuilder;
  I: Integer;
begin
  B.Data := nil;
  Tiff.Data := nil;

  { TIFF part }
  if ALittle then
    AddText(Tiff, 'II')
  else
    AddText(Tiff, 'MM');
  Add16(Tiff, 42, ALittle);
  Add32(Tiff, 8, ALittle);
  Add16(Tiff, 2, ALittle);              { two entries }
  if AOrientationSecond or (AOrientation = 0) then
    AddEntry(Tiff, $0100, 3, 640, ALittle);   { ImageWidth }
  if AOrientation <> 0 then
    AddEntry(Tiff, $0112, AType, AOrientation, ALittle);
  if not AOrientationSecond or (AOrientation = 0) then
    AddEntry(Tiff, $0101, 3, 480, ALittle);   { ImageLength }
  Add32(Tiff, 0, ALittle);              { no next IFD }

  AddByte(B, $FF);
  AddByte(B, $D8);

  if AWithJfif then
  begin
    AddByte(B, $FF);
    AddByte(B, $E0);
    AddBE16(B, 16);
    AddText(B, 'JFIF'#0);
    AddByte(B, 1); AddByte(B, 1); AddByte(B, 0);
    AddBE16(B, 1); AddBE16(B, 1);
    AddByte(B, 0); AddByte(B, 0);
  end;

  AddByte(B, $FF);
  AddByte(B, $E1);
  AddBE16(B, 2 + 6 + Length(Tiff.Data));
  AddText(B, 'Exif'#0#0);
  for I := 0 to High(Tiff.Data) do
    AddByte(B, Tiff.Data[I]);

  AddByte(B, $FF);
  AddByte(B, $DA);
  AddBE16(B, 2);
  AddByte(B, $12);
  AddByte(B, $34);
  AddByte(B, $FF);
  AddByte(B, $D9);

  Result := B.Data;
end;

function Orient(const AData: TBytes): Integer;
begin
  if Length(AData) = 0 then
    Result := ReadExifOrientation(nil, 0)
  else
    Result := ReadExifOrientation(@AData[0], Length(AData));
end;

procedure TestBuilt;
var
  Data: TBytes;
  V: Integer;
  Ok: Boolean;
begin
  WriteLn;
  WriteLn('-- Headers built in memory --');

  Ok := True;
  for V := 1 to 8 do
    if Orient(MakeJpeg(True, V, False, False)) <> V then
      Ok := False;
  Check('little-endian (II), values 1..8', Ok);

  Ok := True;
  for V := 1 to 8 do
    if Orient(MakeJpeg(False, V, False, False)) <> V then
      Ok := False;
  Check('big-endian (MM), values 1..8', Ok);

  V := Orient(MakeJpeg(True, 6, True, False));
  Check('orientation as second entry', V = 6, IntToStr(V));

  V := Orient(MakeJpeg(False, 8, False, True));
  Check('after a JFIF APP0 segment', V = 8, IntToStr(V));

  V := Orient(MakeJpeg(True, 0, False, False));
  Check('EXIF without orientation: 1', V = 1, IntToStr(V));

  V := Orient(MakeJpeg(True, 9, False, False));
  Check('value 9 (invalid): 1', V = 1, IntToStr(V));

  V := Orient(MakeJpeg(True, 6, False, False, 4));
  Check('wrong type (LONG instead of SHORT): 1', V = 1, IntToStr(V));

  Data := MakeJpeg(True, 6, False, False);
  SetLength(Data, 20);
  V := Orient(Data);
  Check('cut off inside the EXIF block: 1', V = 1, IntToStr(V));

  Data := MakeJpeg(True, 6, False, False);
  Data[0] := $89;
  V := Orient(Data);
  Check('not a JPEG: 1', V = 1, IntToStr(V));

  Data := MakeJpeg(True, 6, False, False);
  { The IFD offset (TIFF header bytes 4..7; the TIFF header starts at
    byte 12: SOI 2 + APP1 marker 2 + length 2 + 'Exif'#0#0 6) now
    points far outside. }
  Data[12 + 4] := $FF;
  Data[12 + 5] := $FF;
  V := Orient(Data);
  Check('IFD offset outside the data: 1', V = 1, IntToStr(V));

  Data := nil;
  V := Orient(Data);
  Check('no data: 1', V = 1, IntToStr(V));

  Check('5..8 swap width and height, 1..4 do not',
    OrientationSwapsSize(5) and OrientationSwapsSize(8)
    and not OrientationSwapsSize(1) and not OrientationSwapsSize(4));
end;

{ The pictures made for looking at (test\images\exif\orient_N.jpg). }
procedure TestFiles;
var
  Dir, FileName: string;
  Stream: TMemoryStream;
  N, V: Integer;
begin
  WriteLn;
  WriteLn('-- Test pictures --');
  Dir := ExpandFileName('images' + PathDelim + 'exif');
  if not DirectoryExists(Dir) then
  begin
    WriteLn('  (skipped: ', Dir, ' not found)');
    Exit;
  end;

  for N := 1 to 8 do
  begin
    FileName := Dir + PathDelim + 'orient_' + IntToStr(N) + '.jpg';
    if not FileExists(FileName) then
    begin
      Check('orient_' + IntToStr(N) + '.jpg exists', False);
      Continue;
    end;
    Stream := TMemoryStream.Create;
    try
      Stream.LoadFromFile(FileName);
      V := ReadExifOrientation(PByte(Stream.Memory), Stream.Size);
      Check('orient_' + IntToStr(N) + '.jpg reads ' + IntToStr(N), V = N, IntToStr(V));
    finally
      Stream.Free;
    end;
  end;
end;

{ Phase E: header, orientation and thumbnail from the file start. The
  pictures were made with Python and checked with Pillow. }
procedure TestThumbnails;
var
  Dir: string;
  Head: TJpegHead;

  function Load(const AName: string): Boolean;
  begin
    Result := ReadJpegHead(Dir + PathDelim + AName, Head);
  end;

  function ThumbIsJpeg: Boolean;
  begin
    Result := (Length(Head.Thumbnail) > 4) and (Head.Thumbnail[0] = $FF)
      and (Head.Thumbnail[1] = $D8);
  end;

begin
  WriteLn;
  WriteLn('-- EXIF thumbnails (uJpegHeader) --');
  Dir := ExpandFileName('images' + PathDelim + 'thumb');
  if not DirectoryExists(Dir) then
  begin
    WriteLn('  (skipped: ', Dir, ' not found)');
    Exit;
  end;

  Check('thumb_plain: header read', Load('thumb_plain.jpg'));
  Check('thumb_plain: 1600 x 1200', (Head.Width = 1600) and (Head.Height = 1200),
    Format('%d x %d', [Head.Width, Head.Height]));
  Check('thumb_plain: orientation 1', Head.Orientation = 1, IntToStr(Head.Orientation));
  Check('thumb_plain: thumbnail is a JPEG', ThumbIsJpeg, IntToStr(Length(Head.Thumbnail)));

  Check('thumb_letterbox: header read', Load('thumb_letterbox.jpg'));
  Check('thumb_letterbox: 1920 x 1080', (Head.Width = 1920) and (Head.Height = 1080),
    Format('%d x %d', [Head.Width, Head.Height]));
  Check('thumb_letterbox: thumbnail', ThumbIsJpeg);

  Check('thumb_orient6: header read (big-endian EXIF)', Load('thumb_orient6.jpg'));
  Check('thumb_orient6: stored 1600 x 1200', (Head.Width = 1600) and (Head.Height = 1200),
    Format('%d x %d', [Head.Width, Head.Height]));
  Check('thumb_orient6: orientation 6', Head.Orientation = 6, IntToStr(Head.Orientation));
  Check('thumb_orient6: thumbnail', ThumbIsJpeg);

  Check('nothumb: header read', Load('nothumb.jpg'));
  Check('nothumb: no thumbnail', Length(Head.Thumbnail) = 0, IntToStr(Length(Head.Thumbnail)));

  Check('exif\orient_1: header read, no thumbnail',
    ReadJpegHead(ExpandFileName('images' + PathDelim + 'exif' + PathDelim + 'orient_1.jpg'), Head)
    and (Length(Head.Thumbnail) = 0));

  Check('missing file: False', not Load('does_not_exist.jpg'));
end;

procedure TestAspectCrop;
var
  X, Y, W, H: Integer;
begin
  WriteLn;
  WriteLn('-- AspectCrop --');
  AspectCrop(160, 120, 1600, 1200, X, Y, W, H);
  Check('same shape: whole thumbnail', (X = 0) and (Y = 0) and (W = 160) and (H = 120));
  AspectCrop(160, 120, 1920, 1080, X, Y, W, H);
  Check('16:9 in 160x120: bars top/bottom cut', (X = 0) and (Y = 15) and (W = 160) and (H = 90),
    Format('%d %d %d %d', [X, Y, W, H]));
  AspectCrop(160, 120, 1080, 1920, X, Y, W, H);
  Check('9:16 in 160x120: bars left/right cut', (Y = 0) and (H = 120) and (W = 68) and (X = 46),
    Format('%d %d %d %d', [X, Y, W, H]));
  AspectCrop(160, 120, 1601, 1200, X, Y, W, H);
  Check('under 2 % off: whole thumbnail', (W = 160) and (H = 120));
  AspectCrop(0, 0, 100, 100, X, Y, W, H);
  Check('empty: no crash', (W = 0) and (H = 0));
end;

begin
  PassCount := 0;
  FailCount := 0;
  WriteLn('MView EXIF orientation test');

  TestBuilt;
  TestFiles;
  TestThumbnails;
  TestAspectCrop;

  WriteLn;
  WriteLn(Format('%d passed, %d failed', [PassCount, FailCount]));
  if FailCount > 0 then
    ExitCode := 1;
end.
