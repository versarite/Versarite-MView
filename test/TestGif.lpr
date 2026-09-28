program TestGif;

{
  Checks the GIF decoder (uGifDecoder) and the frame clock (uAnimation),
  Day 19.

  - The GIF test suite in test\images\gif (animated_*.gif, static_*.gif):
    every frame against the reference picture in gif\frames, and the
    loop counts.
  - The other GIFs in test\images\gif (and test\images\Test.gif if it
    is there): size, frame count, total delay and every frame as built
    by the cursor, against expected.txt. expected.txt comes from a Python
    copy of the same algorithm that was checked frame by frame against
    Pillow.
  - The first frame alone (the Screen quality), from the whole file and
    from its start only.
  - Damaged data: every length the file could have been cut to, and
    bytes changed at random. Nothing may crash or raise.
  - Cancel and the memory limit.
  - TFrameClock: which frame is due when, skipping, stalls.

  Needs BGRABitmap, so it is built with lazbuild (TestGif.lpi);
  build_test.bat does that.
}

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Classes,
  SysUtils,
  Math,
  BGRABitmap,
  BGRABitmapTypes,
  uAnimation,
  uGifDecoder;

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

{ FNV-1a over the picture: rows from the top, each pixel as B, G, R, A. }
function FrameHash(ABmp: TBGRABitmap): Cardinal;
var
  X, Y: Integer;
  P: PBGRAPixel;
  H: QWord;
begin
  H := $811C9DC5;
  for Y := 0 to ABmp.Height - 1 do
  begin
    P := ABmp.ScanLine[Y];
    for X := 0 to ABmp.Width - 1 do
    begin
      H := ((H xor P[X].blue) * 16777619) and $FFFFFFFF;
      H := ((H xor P[X].green) * 16777619) and $FFFFFFFF;
      H := ((H xor P[X].red) * 16777619) and $FFFFFFFF;
      H := ((H xor P[X].alpha) * 16777619) and $FFFFFFFF;
    end;
  end;
  Result := Cardinal(H);
end;

function SplitText(const AText: string; ASep: Char): TStringArray;
var
  I, Start, N: Integer;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = ASep) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(AText, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

function ReadAll(const AFileName: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

const
  NoLimit = Int64(1) shl 40;
  GifDir = 'images' + DirectorySeparator + 'gif' + DirectorySeparator;

{ ---- the test files ---- }

procedure TestFile(const ALine: string);
var
  Fields, Hashes: TStringArray;
  FileName, Err, Detail: string;
  Data: TBytes;
  Anim, First: TGifAnimation;
  Cursor: TAnimationCursor;
  Bmp: TBGRABitmap;
  More, Incomplete: Boolean;
  I, N, Bad, FirstBad, Delays: Integer;
  H, H0: Cardinal;
begin
  Fields := SplitText(ALine, ';');
  if Length(Fields) < 6 then
    Exit;
  FileName := GifDir + Fields[0];
  if not FileExists(FileName) then
  begin
    WriteLn('  (', Fields[0], ' not found, skipped)');
    Exit;
  end;
  Hashes := SplitText(Fields[5], ',');
  N := StrToInt(Fields[3]);
  Data := ReadAll(FileName);

  { All frames. }
  Anim := DecodeGif(@Data[0], Length(Data), True, False, NoLimit, nil, More, Incomplete, Err);
  Check(Fields[0] + ': decoded', Anim <> nil, Err);
  if Anim = nil then
    Exit;
  try
    Check(Fields[0] + ': ' + Fields[1] + ' x ' + Fields[2],
      (Anim.Width = StrToInt(Fields[1])) and (Anim.Height = StrToInt(Fields[2])),
      Format('%d x %d', [Anim.Width, Anim.Height]));
    Check(Fields[0] + ': ' + Fields[3] + ' frames', Anim.FrameCount = N,
      IntToStr(Anim.FrameCount));
    Delays := 0;
    for I := 0 to Anim.FrameCount - 1 do
      Inc(Delays, Anim.FrameDelayMs(I));
    Check(Fields[0] + ': delays ' + Fields[4] + ' ms in all', Delays = StrToInt(Fields[4]),
      IntToStr(Delays));

    Bad := 0;
    FirstBad := -1;
    H0 := 0;
    Detail := '';
    Cursor := Anim.CreateCursor;
    try
      for I := 0 to Min(N, Anim.FrameCount) - 1 do
      begin
        Bmp := Cursor.Frame(I);
        try
          H := FrameHash(Bmp);
        finally
          Bmp.Free;
        end;
        if I = 0 then
          H0 := H;
        if (I > High(Hashes)) or (IntToHex(Int64(H), 8) <> Trim(Hashes[I])) then
        begin
          Inc(Bad);
          if FirstBad < 0 then
          begin
            FirstBad := I;
            Detail := Format('frame %d: %s', [I, IntToHex(Int64(H), 8)]);
          end;
        end;
      end;
      Check(Fields[0] + ': every frame as expected', Bad = 0,
        Format('%d differ, first %s', [Bad, Detail]));

      { Back to the start (the player loops). }
      Bmp := Cursor.Frame(0);
      try
        Check(Fields[0] + ': frame 0 again after the last', FrameHash(Bmp) = H0);
      finally
        Bmp.Free;
      end;
    finally
      Cursor.Free;
    end;
  finally
    Anim.Free;
  end;

  { The first frame alone, from the whole file. }
  First := DecodeGif(@Data[0], Length(Data), True, True, NoLimit, nil, More, Incomplete, Err);
  try
    Check(Fields[0] + ': first frame alone', (First <> nil) and (First.FrameCount = 1));
    if First <> nil then
    begin
      Cursor := First.CreateCursor;
      Bmp := Cursor.Frame(0);
      try
        Check(Fields[0] + ':   same picture', FrameHash(Bmp) = H0);
      finally
        Bmp.Free;
        Cursor.Free;
      end;
    end;
    Check(Fields[0] + ':   more frames follow: ' + BoolToStr(N > 1, 'yes', 'no'), More = (N > 1));
  finally
    First.Free;
  end;

  { From the start of the file only (1 byte missing): for an animation
    more frames may follow, whatever comes. }
  if N > 1 then
  begin
    First := DecodeGif(@Data[0], Length(Data) - 1, False, True, NoLimit, nil, More, Incomplete, Err);
    try
      Check(Fields[0] + ': start of the file only: first frame, more to come',
        (First <> nil) and (First.FrameCount = 1) and More);
    finally
      First.Free;
    end;
  end;
end;

procedure TestExpectedFiles;
var
  Lines: TStringList;
  I: Integer;
begin
  WriteLn;
  WriteLn('-- Test GIFs (', GifDir, 'expected.txt) --');
  if not FileExists(GifDir + 'expected.txt') then
  begin
    Check('expected.txt found', False, GifDir + 'expected.txt');
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(GifDir + 'expected.txt');
    for I := 0 to Lines.Count - 1 do
      if (Lines[I] <> '') and (Lines[I][1] <> '#') then
        TestFile(Lines[I]);
  finally
    Lines.Free;
  end;
end;

{ ---- the GIF test suite: reference frames as PNG ---- }

{ Same picture: sizes equal, and every pixel either transparent in both
  or equal in colour (the references are opaque where not
  transparent). }
function SamePicture(A, B: TBGRABitmap; out ADiffer: Integer): Boolean;
var
  X, Y: Integer;
  PA, PB: PBGRAPixel;
begin
  ADiffer := -1;
  if (A.Width <> B.Width) or (A.Height <> B.Height) then
    Exit(False);
  ADiffer := 0;
  for Y := 0 to A.Height - 1 do
  begin
    PA := A.ScanLine[Y];
    PB := B.ScanLine[Y];
    for X := 0 to A.Width - 1 do
    begin
      if (PA[X].alpha = 0) and (PB[X].alpha = 0) then
        Continue;
      if (PA[X].alpha = 0) <> (PB[X].alpha = 0) then
        Inc(ADiffer)
      else if (PA[X].red <> PB[X].red) or (PA[X].green <> PB[X].green)
        or (PA[X].blue <> PB[X].blue) then
        Inc(ADiffer);
    end;
  end;
  Result := ADiffer = 0;
end;

procedure TestSuiteFile(const AName: string);
var
  Data: TBytes;
  Anim: TGifAnimation;
  Cursor: TAnimationCursor;
  Mine, Ref: TBGRABitmap;
  More, Incomplete, AllSame: Boolean;
  Err, Base, RefName, Detail: string;
  I, Differ: Integer;
begin
  Base := ChangeFileExt(AName, '');
  Data := ReadAll(GifDir + AName);
  Anim := DecodeGif(@Data[0], Length(Data), True, False, NoLimit, nil, More, Incomplete, Err);
  Check(AName + ': decoded', Anim <> nil, Err);
  if Anim = nil then
    Exit;
  AllSame := True;
  Detail := '';
  Cursor := Anim.CreateCursor;
  try
    for I := 0 to Anim.FrameCount - 1 do
    begin
      if Anim.FrameCount = 1 then
        RefName := GifDir + 'frames' + DirectorySeparator + Base + '.png'
      else
        RefName := GifDir + 'frames' + DirectorySeparator + Base + '-' + IntToStr(I) + '.png';
      if not FileExists(RefName) then
      begin
        AllSame := False;
        Detail := 'missing ' + RefName;
        Break;
      end;
      Mine := Cursor.Frame(I);
      Ref := nil;
      try
        try
          Ref := TBGRABitmap.Create(RefName);
        except
          on E: Exception do
          begin
            AllSame := False;
            Detail := RefName + ': ' + E.Message;
            Break;                     { the finally still frees Mine }
          end;
        end;
        if not SamePicture(Mine, Ref, Differ) then
        begin
          AllSame := False;
          if Detail = '' then
            Detail := Format('frame %d: %d x %d vs %d x %d, %d pixels differ',
              [I, Mine.Width, Mine.Height, Ref.Width, Ref.Height, Differ]);
        end;
      finally
        Ref.Free;
        Mine.Free;
      end;
    end;
    Check(AName + ': ' + IntToStr(Anim.FrameCount) + ' frames as the reference', AllSame, Detail);
    if Pos('noloop', AName) > 0 then
      Check(AName + ':   plays once', Anim.PlayCount = 1, IntToStr(Anim.PlayCount))
    else if Pos('loop', AName) > 0 then
      Check(AName + ':   loops forever', Anim.PlayCount = 0, IntToStr(Anim.PlayCount));
  finally
    Cursor.Free;
    Anim.Free;
  end;
end;

procedure TestSuite;
var
  SR: TSearchRec;
  Names: TStringList;
  I: Integer;
begin
  WriteLn;
  WriteLn('-- GIF test suite (', GifDir, 'frames) --');
  Names := TStringList.Create;
  try
    if FindFirst(GifDir + '*.gif', faAnyFile, SR) = 0 then
    begin
      repeat
        if (Pos('animated_', SR.Name) = 1) or (Pos('static_', SR.Name) = 1) then
          Names.Add(SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    Names.Sort;
    if Names.Count = 0 then
      WriteLn('  (not found, skipped)');
    for I := 0 to Names.Count - 1 do
      TestSuiteFile(Names[I]);
  finally
    Names.Free;
  end;
end;

{ ---- damaged data ---- }

{ Decodes and builds every frame; True if nothing raised. }
function SurvivesDecode(AData: PByte; ASize: Integer; AComplete: Boolean): Boolean;
var
  Anim: TGifAnimation;
  Cursor: TAnimationCursor;
  Bmp: TBGRABitmap;
  More, Incomplete: Boolean;
  Err: string;
  I: Integer;
begin
  Result := True;
  try
    Anim := DecodeGif(AData, ASize, AComplete, False, NoLimit, nil, More, Incomplete, Err);
    if Anim <> nil then
    try
      Cursor := Anim.CreateCursor;
      try
        for I := 0 to Anim.FrameCount - 1 do
        begin
          Bmp := Cursor.Frame(I);
          Bmp.Free;
        end;
      finally
        Cursor.Free;
      end;
    finally
      Anim.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('         ', E.ClassName, ': ', E.Message);
      Result := False;
    end;
  end;
end;

procedure TestDamaged;
var
  Data, Damaged: TBytes;
  Len, Failures, K, J: Integer;
  Anim: TGifAnimation;
  More, Incomplete: Boolean;
  Err: string;
begin
  WriteLn;
  WriteLn('-- Damaged data --');

  if FileExists(GifDir + 'not_a_gif.gif') then
  begin
    Data := ReadAll(GifDir + 'not_a_gif.gif');
    Check('not_a_gif.gif (a PNG): not taken as GIF', not IsGifData(@Data[0], Length(Data)));
  end;

  { Only a header. }
  SetLength(Data, 6);
  Data[0] := Ord('G');
  Data[1] := Ord('I');
  Data[2] := Ord('F');
  Data[3] := Ord('8');
  Data[4] := Ord('9');
  Data[5] := Ord('a');
  Anim := DecodeGif(@Data[0], Length(Data), True, False, NoLimit, nil, More, Incomplete, Err);
  Check('header only: no image, no crash', (Anim = nil) and (Err <> ''), Err);
  Anim.Free;

  if not FileExists(GifDir + 'disposal3.gif') then
    Exit;
  Data := ReadAll(GifDir + 'disposal3.gif');

  { Cut off at every length (every 3rd byte). }
  Failures := 0;
  Len := 1;
  while Len < Length(Data) do
  begin
    if not SurvivesDecode(@Data[0], Len, False) then
      Inc(Failures);
    Inc(Len, 3);
  end;
  Check('disposal3.gif cut off at every length: no exception', Failures = 0,
    IntToStr(Failures) + ' failed');

  { Random bytes changed (always the same sequence). }
  RandSeed := 20;
  Failures := 0;
  for K := 1 to 300 do
  begin
    Damaged := Copy(Data, 0, Length(Data));
    for J := 1 to 1 + Random(8) do
      Damaged[13 + Random(Length(Damaged) - 13)] := Random(256);
    if not SurvivesDecode(@Damaged[0], Length(Damaged), True) then
      Inc(Failures);
  end;
  Check('disposal3.gif with random bytes changed (300 times): no exception', Failures = 0,
    IntToStr(Failures) + ' failed');

  { The second frame claims 65535 x 65535 in a 320 x 240 picture:
    damaged, the file ends there. }
  if FileExists(GifDir + 'huge_frame.gif') then
  begin
    Data := ReadAll(GifDir + 'huge_frame.gif');
    Anim := DecodeGif(@Data[0], Length(Data), True, False, NoLimit, nil, More, Incomplete, Err);
    try
      Check('huge_frame.gif: the first frame only', (Anim <> nil) and (Anim.FrameCount = 1));
    finally
      Anim.Free;
    end;
  end;

  { The first frame claims 65535 x 65535: 4.3 gigapixels, refused by
    the memory guard before anything is allocated. }
  if FileExists(GifDir + 'huge_first_frame.gif') then
  begin
    Data := ReadAll(GifDir + 'huge_first_frame.gif');
    Anim := DecodeGif(@Data[0], Length(Data), True, False, NoLimit, nil, More, Incomplete, Err);
    try
      Check('huge_first_frame.gif: refused as too large', (Anim = nil) and (Pos('too large', Err) > 0), Err);
    finally
      Anim.Free;
    end;
  end;
end;

{ ---- cancel and memory limit ---- }

type
  TCancelAlways = class
    function Cancel: Boolean;
  end;

function TCancelAlways.Cancel: Boolean;
begin
  Result := True;
end;

procedure TestCancelAndLimit;
var
  Data: TBytes;
  Anim: TGifAnimation;
  More, Incomplete, Raised: Boolean;
  Err: string;
  Canceller: TCancelAlways;
begin
  WriteLn;
  WriteLn('-- Cancel, memory limit --');
  if not FileExists(GifDir + 'disposal3.gif') then
    Exit;
  Data := ReadAll(GifDir + 'disposal3.gif');

  Canceller := TCancelAlways.Create;
  Raised := False;
  Anim := nil;
  try
    try
      Anim := DecodeGif(@Data[0], Length(Data), True, False, NoLimit, @Canceller.Cancel,
        More, Incomplete, Err);
    except
      on E: EGifCancelled do
        Raised := True;
    end;
  finally
    Anim.Free;
    Canceller.Free;
  end;
  Check('cancel: EGifCancelled', Raised);

  { Frame 0 is 320 x 240 (about 78 KB with its palette), the other 12
    are small (about 3.7 KB each): room for about 7. }
  Anim := DecodeGif(@Data[0], Length(Data), True, False, 100000, nil, More, Incomplete, Err);
  try
    Check('memory limit: fewer frames, and a note',
      (Anim <> nil) and (Anim.FrameCount >= 1) and (Anim.FrameCount < 13) and (Anim.Note <> ''),
      BoolToStr(Anim = nil, 'nil', ''));
    if Anim <> nil then
      WriteLn('         (', Anim.FrameCount, ' frames: ', Anim.Note, ')');
  finally
    Anim.Free;
  end;
end;

{ ---- frame clock ---- }

type
  TDelays = class
    Values: array of Integer;
    function Delay(AIndex: Integer): Integer;
  end;

function TDelays.Delay(AIndex: Integer): Integer;
begin
  Result := Values[AIndex];
end;

procedure TestClock;
var
  D: TDelays;
  C: TFrameClock;
begin
  WriteLn;
  WriteLn('-- Frame clock --');
  D := TDelays.Create;
  SetLength(D.Values, 3);
  D.Values[0] := 100;
  D.Values[1] := 50;
  D.Values[2] := 200;
  C := TFrameClock.Create(3, @D.Delay);
  try
    C.Start(0);
    Check('frame 0 at the start', C.Index = 0);
    Check('99 ms: still frame 0', (not C.Advance(99)) and (C.Index = 0));
    Check('100 ms: frame 1', C.Advance(100) and (C.Index = 1));
    Check('151 ms: frame 2 (due at 150)', C.Advance(151) and (C.Index = 2));
    Check('next in 199 ms', Round(C.MsUntilNext(151)) = 199);
    Check('349 ms: still frame 2', not C.Advance(349));
    Check('350 ms: back to frame 0', C.Advance(350) and (C.Index = 0));
    Check('nothing skipped so far', C.Skipped = 0);

    C.Start(0);
    Check('late (160 ms): frame 2, frame 1 skipped',
      C.Advance(160) and (C.Index = 2) and (C.Skipped = 1));

    C.Start(0);
    Check('stalled 5 s: goes on with frame 1, nothing raced through',
      C.Advance(5000) and (C.Index = 1) and (C.Skipped = 0));
    Check('  and the next is due 50 ms later', Round(C.MsUntilNext(5000)) = 50);
  finally
    C.Free;
  end;

  { Delays of 0 must not make Advance loop forever. }
  D.Values[0] := 0;
  D.Values[1] := 0;
  D.Values[2] := 0;
  C := TFrameClock.Create(3, @D.Delay);
  try
    C.Start(0);
    Check('zero delays: Advance returns', C.Advance(900));
  finally
    C.Free;
  end;

  { Played a set number of times, then the last frame stays. }
  D.Values[0] := 100;
  D.Values[1] := 50;
  D.Values[2] := 200;
  C := TFrameClock.Create(3, @D.Delay, 1);
  try
    C.Start(0);
    C.Advance(100);
    C.Advance(150);
    Check('play once: at 350 ms it stays on the last frame',
      (not C.Advance(350)) and (C.Index = 2) and C.Finished);
    Check('  and never moves again', (not C.Advance(100000)) and (C.Index = 2));
  finally
    C.Free;
  end;
  C := TFrameClock.Create(3, @D.Delay, 2);
  try
    C.Start(0);
    Check('play twice: at 350 ms back to frame 0', C.Advance(350) and (C.Index = 0)
      and not C.Finished);
    Check('  at 650 ms the last frame of the second play',
      C.Advance(650) and (C.Index = 2) and not C.Finished);
    Check('  at 700 ms finished, stays there', (not C.Advance(700)) and C.Finished and (C.Index = 2));
  finally
    C.Free;
  end;

  { A single frame never changes. }
  SetLength(D.Values, 1);
  D.Values[0] := 100;
  C := TFrameClock.Create(1, @D.Delay);
  try
    C.Start(0);
    Check('one frame: never advances', not C.Advance(10000));
  finally
    C.Free;
  end;
  D.Free;
end;

begin
  PassCount := 0;
  FailCount := 0;
  WriteLn('MView GIF test');
  WriteLn('==============');
  TestSuite;
  TestExpectedFiles;
  TestDamaged;
  TestCancelAndLimit;
  TestClock;
  WriteLn;
  WriteLn('==============');
  WriteLn(PassCount, ' passed, ', FailCount, ' failed');
  if FailCount > 0 then
    ExitCode := 1;
end.
