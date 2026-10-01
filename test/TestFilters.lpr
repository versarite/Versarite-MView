program TestFilters;

{
  Checks the display filters of Phase H ("Looking closer"), uFilters:
  - neutral settings change nothing (tone table, per pixel);
  - black / white point, brightness, contrast, gamma: the tone table
    at a few grey levels;
  - saturation (0 = grey at the pixel's luma), hue (grey stays grey),
    inversion;
  - PrepareFilters + FilterPixel give the same as FilterRGB;
  - SetFilter keeps the ranges and the black / white gap; the panel's
    bar positions (gamma on a log scale, 1.0 in the middle); a wheel
    step snaps to neutral when passing it;
  - AutoLevels (step 2): empty and one-level histograms change nothing,
    the points of a two-level image, outliers within 0.35 % ignored;
  - Mirror: a toggle like Invert, no colour work, in the suffix;
  - FilterSuffix (for "Apply filters to a copy").

  No files. Build and run with build_test.bat.
}

{$mode ObjFPC}{$H+}

uses
  SysUtils,
  uFilters;

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

function Rgb(R, G, B: Byte): string;
begin
  Result := Format('%d,%d,%d', [R, G, B]);
end;

{ One pixel through the filters. }
function Filtered(const F: TFilterSettings; R, G, B: Byte): string;
var
  T: TToneTable;
begin
  BuildToneTable(F, T);
  FilterRGB(F, T, R, G, B);
  Result := Rgb(R, G, B);
end;

procedure TestNeutral;
var
  F: TFilterSettings;
  T: TToneTable;
  I: Integer;
  Same: Boolean;
begin
  WriteLn('Neutral');
  F := NeutralFilters;
  Check('NeutralFilters is neutral', FiltersNeutral(F));
  Check('SameFilters with itself', SameFilters(F, NeutralFilters));
  Check('no colour step when neutral', not NeedsColourStep(F));
  BuildToneTable(F, T);
  Same := True;
  for I := 0 to 255 do
    if T[I] <> I then
      Same := False;
  Check('tone table is the identity', Same);
  Check('a pixel stays as it is', Filtered(F, 200, 50, 7) = '200,50,7', Filtered(F, 200, 50, 7));
  F.Gamma := 1.2;
  Check('a changed gamma is not neutral', not FiltersNeutral(F));
  Check('SameFilters sees the change', not SameFilters(F, NeutralFilters));
end;

procedure TestTone;
var
  F: TFilterSettings;
  T: TToneTable;
begin
  WriteLn('Tone (black / white point, brightness, contrast, gamma)');
  F := NeutralFilters;
  F.Black := 0.2;
  F.White := 0.6;
  BuildToneTable(F, T);
  Check('below the black point: 0', (T[40] = 0) and (T[51] = 0), Format('%d %d', [T[40], T[51]]));
  Check('at the white point: 255', T[153] = 255, IntToStr(T[153]));
  Check('in between: stretched (127 -> 190)', T[127] = 190, IntToStr(T[127]));

  F := NeutralFilters;
  F.Gamma := 2;
  BuildToneTable(F, T);
  Check('gamma 2: 128 -> 64', T[128] = 64, IntToStr(T[128]));
  Check('gamma keeps black and white', (T[0] = 0) and (T[255] = 255));

  F := NeutralFilters;
  F.Contrast := -1;
  BuildToneTable(F, T);
  Check('contrast -100 %: flat grey', (T[0] = 128) and (T[255] = 128),
    Format('%d %d', [T[0], T[255]]));
  F.Contrast := 0.5;
  BuildToneTable(F, T);
  Check('contrast +50 %: 64 -> 7, 192 -> 250', (T[64] = 7) and (T[192] = 250),
    Format('%d %d', [T[64], T[192]]));
  Check('ContrastFactor(0) = 1', Abs(ContrastFactor(0) - 1) < 1e-9);
  Check('ContrastFactor(1) = 20', Abs(ContrastFactor(1) - 20) < 1e-6);

  F := NeutralFilters;
  F.Brightness := 1;
  BuildToneTable(F, T);
  Check('brightness +100 %: 0 -> 128, 128 -> 255', (T[0] = 128) and (T[128] = 255),
    Format('%d %d', [T[0], T[128]]));
end;

procedure TestColour;
var
  F: TFilterSettings;
  T: TToneTable;
  Prep: TFilterPrep;
  R, G, B, R2, G2, B2: Byte;
  I: Integer;
  Same: Boolean;
begin
  WriteLn('Colour (saturation, hue, invert)');
  F := NeutralFilters;
  F.Saturation := 0;
  Check('saturation 0: grey at the luma (200,50,50 -> 95)', Filtered(F, 200, 50, 50) = '95,95,95',
    Filtered(F, 200, 50, 50));
  F := NeutralFilters;
  F.Hue := 120;
  Check('hue: grey stays grey', Filtered(F, 128, 128, 128) = '128,128,128',
    Filtered(F, 128, 128, 128));
  Check('hue: a colour changes', Filtered(F, 200, 50, 50) <> '200,50,50');
  F := NeutralFilters;
  F.Invert := True;
  Check('invert: 10,20,30 -> 245,235,225', Filtered(F, 10, 20, 30) = '245,235,225',
    Filtered(F, 10, 20, 30));
  Check('invert needs the colour step', NeedsColourStep(F));

  { The prepared version gives the same, for a mixed setting. }
  F := NeutralFilters;
  F.Black := 0.05;
  F.Contrast := 0.3;
  F.Gamma := 0.8;
  F.Saturation := 1.7;
  F.Hue := -40;
  F.Invert := True;
  BuildToneTable(F, T);
  PrepareFilters(F, Prep);
  Same := True;
  for I := 0 to 99 do
  begin
    R := (I * 37) mod 256;
    G := (I * 91 + 13) mod 256;
    B := (I * 53 + 200) mod 256;
    R2 := R;
    G2 := G;
    B2 := B;
    FilterRGB(F, T, R, G, B);
    FilterPixel(Prep, R2, G2, B2);
    if (R <> R2) or (G <> G2) or (B <> B2) then
      Same := False;
  end;
  Check('FilterPixel (prepared) = FilterRGB', Same);
end;

procedure TestSettings;
var
  F: TFilterSettings;
begin
  WriteLn('Settings (ranges, bar, steps)');
  F := NeutralFilters;
  SetFilter(F, fkWhite, 0.5);
  SetFilter(F, fkBlack, 0.9);
  Check('black stays below white', (F.Black < F.White) and (F.Black > 0.45),
    FloatToStr(F.Black));
  SetFilter(F, fkWhite, 0.1);
  Check('white stays above black', F.White > F.Black, FloatToStr(F.White));
  F := NeutralFilters;
  SetFilter(F, fkGamma, 99);
  Check('gamma clamped to 5', Abs(F.Gamma - 5) < 1e-9);
  SetFilter(F, fkHue, -500);
  Check('hue clamped to -180', Abs(F.Hue + 180) < 1e-9);
  SetFilter(F, fkInvert, 1);
  Check('SetFilter invert', F.Invert);

  Check('gamma 1.0 sits in the middle of its bar', Abs(FilterBarPos(fkGamma, 1) - 0.5) < 1e-9);
  Check('bar middle -> gamma 1.0', Abs(FilterValueAt(fkGamma, 0.5) - 1) < 1e-9);
  Check('brightness 0 sits in the middle', Abs(FilterBarPos(fkBrightness, 0) - 0.5) < 1e-9);
  Check('bar and value round trip (saturation 2.2)',
    Abs(FilterValueAt(fkSaturation, FilterBarPos(fkSaturation, 2.2)) - 2.2) < 1e-9);

  F := NeutralFilters;
  F.Brightness := 0.012;
  StepFilter(F, fkBrightness, -1);
  Check('a wheel step snaps to neutral when passing it', F.Brightness = 0,
    FloatToStr(F.Brightness));
  StepFilter(F, fkBrightness, 3);
  Check('three steps up: +6 %', Abs(F.Brightness - 0.06) < 1e-9, FloatToStr(F.Brightness));
  StepFilter(F, fkInvert, 1);
  Check('wheel up on Invert: on', F.Invert);
  StepFilter(F, fkInvert, -1);
  Check('wheel down on Invert: off', not F.Invert);
end;

procedure TestAuto;
var
  H: THistogram;
  B, W: Double;
  I: Integer;
begin
  WriteLn('Auto (black / white point from the histogram)');
  FillChar(H, SizeOf(H), 0);
  Check('empty histogram: no change', not AutoLevels(H, B, W) and (B = 0) and (W = 1));
  H[100] := 5000;
  Check('one grey level: no change', not AutoLevels(H, B, W));
  FillChar(H, SizeOf(H), 0);
  H[50] := 1000;
  H[200] := 1000;
  Check('two levels: black 50, white 200',
    AutoLevels(H, B, W) and (Round(B * 255) = 50) and (Round(W * 255) = 200),
    Format('%d %d', [Round(B * 255), Round(W * 255)]));
  { 50 pixels on each level 20 .. 219, and two outliers at each end:
    0.35 % (17 pixels at each end) may clip, so the outliers are ignored. }
  FillChar(H, SizeOf(H), 0);
  for I := 20 to 219 do
    H[I] := 50;
  H[0] := 2;
  H[255] := 2;
  Check('outliers ignored: black 20, white 219',
    AutoLevels(H, B, W) and (Round(B * 255) = 20) and (Round(W * 255) = 219),
    Format('%d %d', [Round(B * 255), Round(W * 255)]));
end;

procedure TestMirror;
var
  F: TFilterSettings;
begin
  WriteLn('Mirror (a toggle, geometry only)');
  F := NeutralFilters;
  Check('neutral: not mirrored', not F.Mirror);
  SetFilter(F, fkMirror, 1);
  Check('SetFilter mirror', F.Mirror);
  Check('mirrored is not neutral', not FiltersNeutral(F));
  Check('mirrored alone: no colour work', ColourNeutral(F));
  Check('a pixel is unchanged by Mirror', Filtered(F, 200, 50, 7) = '200,50,7', Filtered(F, 200, 50, 7));
  Check('Mirror and Invert are toggles', IsToggleFilter(fkMirror) and IsToggleFilter(fkInvert)
    and not IsToggleFilter(fkGamma));
  Check('Mirror text: on', FilterText(F, fkMirror) = 'on', FilterText(F, fkMirror));
  Check('Invert text stays off', FilterText(F, fkInvert) = 'off', FilterText(F, fkInvert));
  StepFilter(F, fkMirror, -1);
  Check('wheel down on Mirror: off', not F.Mirror);
  F := NeutralFilters;
  F.Mirror := True;
  Check('SameFilters sees Mirror', not SameFilters(F, NeutralFilters));
end;

procedure TestSuffix;
var
  F: TFilterSettings;
begin
  WriteLn('File name suffix');
  F := NeutralFilters;
  Check('neutral: no suffix', FilterSuffix(F) = '', FilterSuffix(F));
  F.Brightness := 0.1;
  F.Gamma := 0.8;
  F.Invert := True;
  Check('_b+10_g0.80_inv', FilterSuffix(F) = '_b+10_g0.80_inv', FilterSuffix(F));
  F.Mirror := True;
  Check('_b+10_g0.80_inv_mirror', FilterSuffix(F) = '_b+10_g0.80_inv_mirror', FilterSuffix(F));
end;

begin
  PassCount := 0;
  FailCount := 0;
  WriteLn('MView filter test (Phase H)');
  TestNeutral;
  TestTone;
  TestColour;
  TestSettings;
  TestAuto;
  TestMirror;
  TestSuffix;
  WriteLn;
  WriteLn(Format('%d passed, %d failed', [PassCount, FailCount]));
  if FailCount > 0 then
    ExitCode := 1;
end.
