unit uImageScaling;

{
  Unit: uImageScaling

  Purpose
  -------
  Fast, good-quality shrinking of large bitmaps on the decode workers,
  so the UI thread never has to scale a big image down (spec §7.1).

  Owns
  ----
  - Nothing: stateless routines. Each new bitmap goes to the caller.

  Knows
  -----
  - Nothing else. The source bitmap is the caller's; it is only read.

  Responsibilities
  ----------------
  - FitSize: the size an image appears at when fitted into a window
    (never enlarged). The renderer uses the same rule, so a bitmap of
    exactly this size is drawn 1:1, without any resampling.
  - ShrinkToSize: a new bitmap of exactly the size asked for (at least
    1 x 1). Block averaging first (factor at most 4096, so the 32-bit
    sums can't overflow), then bilinear for the rest; if the blocks
    already give the exact size, that bitmap is returned.

  Does NOT
  --------
  - Enlarge (asked for a larger size it still works, but that is not
    what it is for).
  - Change the source bitmap's pixels.
  - Decide the target size (the caller, uMediaLoader, does, with
    FitSize).

  Threads
  -------
  Any thread; no shared state. Called on the decode workers by
  uMediaLoader.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      SysUtils, Math, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uMediaLoader

  Method
  ------
  Measured in Phase C: BGRABitmap's fine resample of a 108 MP photo
  down to screen size took 1.8 s, and even 1500 -> 1440 pixels wide
  took 340 ms. Here the bulk of a large reduction is done first by
  averaging K x K blocks (plain integer sums over at most 4 x 4
  evenly spread samples per block), and only the last step, by less
  than a factor of 2, is a plain bilinear resize (BilinearResize, Day
  18: BGRABitmap's resampler still took ~340 ms for that step).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Math,
  BGRABitmap,
  BGRABitmapTypes;

{ Size of an AWidth x AHeight image fitted into ABoxWidth x ABoxHeight,
  keeping its proportions, never larger than the image itself. }
procedure FitSize(AWidth, AHeight, ABoxWidth, ABoxHeight: Integer;
  out AFitWidth, AFitHeight: Integer);

{ A new bitmap of exactly AWidth x AHeight. The caller owns it. }
function ShrinkToSize(ASource: TBGRABitmap; AWidth, AHeight: Integer): TBGRABitmap;

implementation

const
  { Samples per block side in BoxShrink (see there). }
  MaxSamplesPerSide = 4;

procedure FitSize(AWidth, AHeight, ABoxWidth, ABoxHeight: Integer;
  out AFitWidth, AFitHeight: Integer);
var
  Factor: Double;
begin
  AFitWidth := AWidth;
  AFitHeight := AHeight;
  if (AWidth <= 0) or (AHeight <= 0) or (ABoxWidth <= 0) or (ABoxHeight <= 0) then
    Exit;
  Factor := Min(ABoxWidth / AWidth, ABoxHeight / AHeight);
  if Factor >= 1.0 then
    Exit;
  AFitWidth := Max(1, Round(AWidth * Factor));
  AFitHeight := Max(1, Round(AHeight * Factor));
end;

{ Averages AFactor x AFactor blocks. The last Width mod AFactor
  columns and Height mod AFactor rows (fewer than AFactor pixels) are
  left out; ShrinkToSize's final step makes up for the difference. }
function BoxShrink(ASource: TBGRABitmap; AFactor: Integer): TBGRABitmap;
var
  DW, DH, X, Y, R, C, N: Integer;
  Area: LongWord;
  Offsets: array of Integer;     { sampled rows / columns inside a block }
  Sums: array of LongWord;       { blue, green, red, alpha per pixel }
  Row, Src, Dst: PBGRAPixel;
  S: PLongWord;
begin
  DW := ASource.Width div AFactor;
  DH := ASource.Height div AFactor;

  { Large blocks: an evenly spread grid of at most 4 x 4 samples per
    block instead of every pixel. For a screen copy that is plenty of
    smoothing and, at the 11 x reduction of a 108 MP photo, about 7x
    faster (measured before: 1.2 s for the whole screen copy). }
  N := AFactor;
  if N > MaxSamplesPerSide then
    N := MaxSamplesPerSide;
  SetLength(Offsets, N);
  for C := 0 to N - 1 do
    Offsets[C] := (C * AFactor + AFactor div 2) div N;

  Result := TBGRABitmap.Create(DW, DH);
  try
    SetLength(Sums, DW * 4);
    Area := LongWord(N) * LongWord(N);

    for Y := 0 to DH - 1 do
    begin
      FillChar(Sums[0], Length(Sums) * SizeOf(LongWord), 0);

      for R := 0 to N - 1 do
      begin
        Row := ASource.ScanLine[Y * AFactor + Offsets[R]];
        S := @Sums[0];
        for X := 0 to DW - 1 do
        begin
          for C := 0 to N - 1 do
          begin
            Src := Row + X * AFactor + Offsets[C];
            Inc(S[0], Src^.blue);
            Inc(S[1], Src^.green);
            Inc(S[2], Src^.red);
            Inc(S[3], Src^.alpha);
          end;
          Inc(S, 4);
        end;
      end;

      Dst := Result.ScanLine[Y];
      S := @Sums[0];
      for X := 0 to DW - 1 do
      begin
        Dst^.blue := S[0] div Area;
        Dst^.green := S[1] div Area;
        Dst^.red := S[2] div Area;
        Dst^.alpha := S[3] div Area;
        Inc(Dst);
        Inc(S, 4);
      end;
    end;

    Result.InvalidateBitmap;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

{ Bilinear, 8-bit fractions, pixel centres aligned. For the last step
  of ShrinkToSize, which is always less than a factor of 2: there it
  looks the same as BGRABitmap's fine resampler and takes a few ms
  instead of a few hundred (measured 344 ms for 1500 x 1125 ->
  1440 x 1080 with four workers busy). }
function BilinearResize(ASource: TBGRABitmap; AWidth, AHeight: Integer): TBGRABitmap;
var
  SW, SH, X, Y, Y0, Y1, FY, FX: Integer;
  Pos: Int64;
  X0, X1, XF: array of Integer;
  R0, R1, A, B, C, D: PBGRAPixel;
  Dst: PBGRAPixel;

  { Source position of destination index I (pixel centres), 16.16. }
  function SourcePos(I, ADest, ASrc: Integer): Int64;
  begin
    Result := ((2 * Int64(I) + 1) * ASrc * 65536) div (2 * Int64(ADest)) - 32768;
    if Result < 0 then
      Result := 0;
  end;

  function Mix(PA, PB, PC, PD: Byte): Byte;
  var
    Top, Bottom: Integer;
  begin
    Top := PA * (256 - FX) + PB * FX;
    Bottom := PC * (256 - FX) + PD * FX;
    Result := (Top * (256 - FY) + Bottom * FY) shr 16;
  end;

begin
  SW := ASource.Width;
  SH := ASource.Height;
  Result := TBGRABitmap.Create(AWidth, AHeight);
  try
    SetLength(X0, AWidth);
    SetLength(X1, AWidth);
    SetLength(XF, AWidth);
    for X := 0 to AWidth - 1 do
    begin
      Pos := SourcePos(X, AWidth, SW);
      X0[X] := Min(Integer(Pos shr 16), SW - 1);
      X1[X] := Min(X0[X] + 1, SW - 1);
      XF[X] := (Pos and $FFFF) shr 8;
    end;

    for Y := 0 to AHeight - 1 do
    begin
      Pos := SourcePos(Y, AHeight, SH);
      Y0 := Min(Integer(Pos shr 16), SH - 1);
      Y1 := Min(Y0 + 1, SH - 1);
      FY := (Pos and $FFFF) shr 8;
      R0 := ASource.ScanLine[Y0];
      R1 := ASource.ScanLine[Y1];
      Dst := Result.ScanLine[Y];
      for X := 0 to AWidth - 1 do
      begin
        FX := XF[X];
        A := R0 + X0[X];
        B := R0 + X1[X];
        C := R1 + X0[X];
        D := R1 + X1[X];
        Dst^.blue := Mix(A^.blue, B^.blue, C^.blue, D^.blue);
        Dst^.green := Mix(A^.green, B^.green, C^.green, D^.green);
        Dst^.red := Mix(A^.red, B^.red, C^.red, D^.red);
        Dst^.alpha := Mix(A^.alpha, B^.alpha, C^.alpha, D^.alpha);
        Inc(Dst);
      end;
    end;
    Result.InvalidateBitmap;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function ShrinkToSize(ASource: TBGRABitmap; AWidth, AHeight: Integer): TBGRABitmap;
var
  Factor: Integer;
  Reduced, Base: TBGRABitmap;
begin
  AWidth := Max(1, AWidth);
  AHeight := Max(1, AHeight);

  { Whole blocks that still leave at least the target size. At most
    4096 x 4096 per block, so the 32-bit sums can't overflow. }
  Factor := Min(ASource.Width div AWidth, ASource.Height div AHeight);
  if Factor > 4096 then
    Factor := 4096;
  Reduced := nil;
  try
    if Factor >= 2 then
    begin
      Reduced := BoxShrink(ASource, Factor);
      Base := Reduced;
    end
    else
      Base := ASource;

    if (Base.Width = AWidth) and (Base.Height = AHeight) then
    begin
      if Reduced <> nil then
      begin
        Result := Reduced;
        Reduced := nil;          { handed over }
      end
      else
        Result := ASource.Duplicate as TBGRABitmap;
    end
    else
      { Less than a factor of 2 left: bilinear is enough. }
      Result := BilinearResize(Base, AWidth, AHeight);
  finally
    Reduced.Free;
  end;
end;

end.
