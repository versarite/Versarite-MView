unit uFilters;

{
  Unit: uFilters

  Purpose
  -------
  The display filters (Phase H, "Looking closer"; user, Day 22): black
  point and white point (dynamic range), brightness, contrast, gamma,
  saturation, hue, inversion. One set of values and one definition of
  the maths, used by the GPU renderer (as shader uniforms, the same
  formulas in GLSL) and by the CPU renderer (per pixel, here), so both
  show the same picture.

  Owns
  ----
  Nothing (a record and plain functions).

  Knows
  -----
  Nothing else.

  Responsibilities
  ----------------
  - TFilterSettings and its neutral values; FiltersNeutral (nothing to
    do, the renderers skip the work).
  - Per filter (TFilterKind): name, range, neutral value, wheel step,
    the text shown, and the position on the panel's bar (gamma on a log
    scale, so 1.0 sits in the middle).
  - The maths, in this order (fixed; the panel lists them so):
      1. black / white point: v := (v - black) / (white - black)
      2. brightness / contrast: v := (v - 0.5) * factor + 0.5 + offset
      3. gamma: v := v ^ gamma   (< 1 brightens the dark parts)
      4. saturation / hue: in YIQ (luma stays), the colour turned by
         the hue and scaled by the saturation
      5. inversion: v := 1 - v
    Mirror (left <-> right) is geometry: the renderers turn the view.
    each step clamped to 0..1. Steps 1-3 are the same for every channel:
    a 256-entry table (BuildToneTable); FilterRGB applies it and steps
    4-5 to one pixel.
  - FilterSuffix: the settings as a short text for a file name
    ("Apply filters to a copy").
  - AutoLevels (step 2): black / white point from a histogram, like
    Fiji's auto contrast (0.35 % of the pixels saturated, half at each
    end).

  Does NOT
  --------
  - Draw, or know about bitmaps (the renderers loop over their pixels).
  - Keep the user's settings (TMView does, with "Lock filters").

  Threads
  -------
  Any; no state.

  Uses (MView units)
  ------------------
  (none)
  Libraries:      SysUtils, Math

  Used by
  -------
  uRenderer, uGLRenderer, uFilterPanel, uMView, TestFilters
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Math;

type
  TFilterKind = (fkBlack, fkWhite, fkBrightness, fkContrast, fkGamma,
    fkSaturation, fkHue, fkInvert, fkMirror);

  TFilterSettings = record
    Black: Double;        { 0 .. 1 of the value range }
    White: Double;        { 0 .. 1, above Black }
    Brightness: Double;   { -1 .. 1 }
    Contrast: Double;     { -1 .. 1 }
    Gamma: Double;        { 0.2 .. 5 }
    Saturation: Double;   { 0 .. 3 }
    Hue: Double;          { degrees, -180 .. 180 }
    Invert: Boolean;
    { Mirrored left <-> right (Day 22, user: an inverted microscope's
      images are mirrored). Geometry, not colour: the renderers turn the
      view; it travels with the filters (Lock, Reset, apply to a copy). }
    Mirror: Boolean;
  end;

  TToneTable = array[0..255] of Byte;

  { How many pixels have each grey level (luma), for Auto and the panel. }
  THistogram = array[0..255] of Int64;

  { Everything per pixel work needs, worked out once per picture
    (PrepareFilters), so the loop does no trigonometry. }
  TFilterPrep = record
    Table: TToneTable;
    Colour: Boolean;       { saturation / hue step }
    Invert: Boolean;
    Sat, HueCos, HueSin: Double;
  end;

function NeutralFilters: TFilterSettings;
function FiltersNeutral(const AFilters: TFilterSettings): Boolean;
{ Neutral apart from Mirror: no colour work for the renderers. }
function ColourNeutral(const AFilters: TFilterSettings): Boolean;
{ Invert and Mirror are on / off rows, not bars. }
function IsToggleFilter(AKind: TFilterKind): Boolean;
function SameFilters(const A, B: TFilterSettings): Boolean;

{ Per filter. }
function FilterName(AKind: TFilterKind): string;
function FilterMin(AKind: TFilterKind): Double;
function FilterMax(AKind: TFilterKind): Double;
function FilterNeutral(AKind: TFilterKind): Double;
function FilterStep(AKind: TFilterKind): Double;
function GetFilter(const AFilters: TFilterSettings; AKind: TFilterKind): Double;
{ Clamped to the filter's range; black and white keep a small gap. }
procedure SetFilter(var AFilters: TFilterSettings; AKind: TFilterKind; AValue: Double);
function FilterText(const AFilters: TFilterSettings; AKind: TFilterKind): string;
{ 0 .. 1 along the panel's bar, and back. }
function FilterBarPos(AKind: TFilterKind; AValue: Double): Double;
function FilterValueAt(AKind: TFilterKind; APos: Double): Double;
{ One wheel notch (+1 / -1 ...) from the current value. }
procedure StepFilter(var AFilters: TFilterSettings; AKind: TFilterKind; ANotches: Double);

{ The maths (see the header). }
function ContrastFactor(AContrast: Double): Double;
function BrightnessOffset(ABrightness: Double): Double;
procedure BuildToneTable(const AFilters: TFilterSettings; out ATable: TToneTable);
{ Steps 4 and 5 needed (per pixel colour work)? }
function NeedsColourStep(const AFilters: TFilterSettings): Boolean;
procedure FilterRGB(const AFilters: TFilterSettings; const ATable: TToneTable;
  var R, G, B: Byte);
{ The same, prepared once: for loops over many pixels. }
procedure PrepareFilters(const AFilters: TFilterSettings; out APrep: TFilterPrep);
procedure FilterPixel(const APrep: TFilterPrep; var R, G, B: Byte);

{ Auto (step 2, like Fiji's auto contrast): black and white point so
  that ASaturatedPercent of the pixels (half at each end) become fully
  black / white. False if the histogram is empty or (almost) one level:
  then nothing is changed. }
function AutoLevels(const AHist: THistogram; out ABlack, AWhite: Double;
  ASaturatedPercent: Double = 0.35): Boolean;

{ "_bp12_wp94_b+10_c+20_g0.80_s1.50_h+30_inv" (only what isn't neutral). }
function FilterSuffix(const AFilters: TFilterSettings): string;

implementation

const
  MinGap = 0.01;     { white point at least this far above black }

{ "+12" / "-3" / "+0" (FPC's Format has no "+" flag). }
function Signed(AValue: Int64): string;
begin
  if AValue >= 0 then
    Result := '+' + IntToStr(AValue)
  else
    Result := IntToStr(AValue);
end;

function NeutralFilters: TFilterSettings;
begin
  Result.Black := 0;
  Result.White := 1;
  Result.Brightness := 0;
  Result.Contrast := 0;
  Result.Gamma := 1;
  Result.Saturation := 1;
  Result.Hue := 0;
  Result.Invert := False;
  Result.Mirror := False;
end;

function Near(A, B: Double): Boolean;
begin
  Result := Abs(A - B) < 1e-6;
end;

function FiltersNeutral(const AFilters: TFilterSettings): Boolean;
begin
  with AFilters do
    Result := Near(Black, 0) and Near(White, 1) and Near(Brightness, 0) and Near(Contrast, 0)
      and Near(Gamma, 1) and Near(Saturation, 1) and Near(Hue, 0) and not Invert
      and not Mirror;
end;

function ColourNeutral(const AFilters: TFilterSettings): Boolean;
var
  F: TFilterSettings;
begin
  F := AFilters;
  F.Mirror := False;
  Result := FiltersNeutral(F);
end;

function IsToggleFilter(AKind: TFilterKind): Boolean;
begin
  Result := AKind in [fkInvert, fkMirror];
end;

function SameFilters(const A, B: TFilterSettings): Boolean;
begin
  Result := Near(A.Black, B.Black) and Near(A.White, B.White)
    and Near(A.Brightness, B.Brightness) and Near(A.Contrast, B.Contrast)
    and Near(A.Gamma, B.Gamma) and Near(A.Saturation, B.Saturation)
    and Near(A.Hue, B.Hue) and (A.Invert = B.Invert) and (A.Mirror = B.Mirror);
end;

function FilterName(AKind: TFilterKind): string;
begin
  case AKind of
    fkBlack:      Result := 'Black point';
    fkWhite:      Result := 'White point';
    fkBrightness: Result := 'Brightness';
    fkContrast:   Result := 'Contrast';
    fkGamma:      Result := 'Gamma';
    fkSaturation: Result := 'Saturation';
    fkHue:        Result := 'Hue';
    fkInvert:     Result := 'Invert';
  else
    Result := 'Mirror left / right';
  end;
end;

function FilterMin(AKind: TFilterKind): Double;
begin
  case AKind of
    fkBrightness, fkContrast: Result := -1;
    fkGamma:                  Result := 0.2;
    fkHue:                    Result := -180;
  else
    Result := 0;
  end;
end;

function FilterMax(AKind: TFilterKind): Double;
begin
  case AKind of
    fkGamma:      Result := 5;
    fkSaturation: Result := 3;
    fkHue:        Result := 180;
  else
    Result := 1;
  end;
end;

function FilterNeutral(AKind: TFilterKind): Double;
begin
  case AKind of
    fkWhite, fkGamma, fkSaturation: Result := 1;
  else
    Result := 0;
  end;
end;

function FilterStep(AKind: TFilterKind): Double;
begin
  case AKind of
    fkBlack, fkWhite:         Result := 1 / 255 * 2;   { 2 grey levels }
    fkBrightness, fkContrast: Result := 0.02;
    fkGamma:                  Result := 0.05;
    fkSaturation:             Result := 0.05;
    fkHue:                    Result := 5;
  else
    Result := 1;
  end;
end;

function GetFilter(const AFilters: TFilterSettings; AKind: TFilterKind): Double;
begin
  with AFilters do
    case AKind of
      fkBlack:      Result := Black;
      fkWhite:      Result := White;
      fkBrightness: Result := Brightness;
      fkContrast:   Result := Contrast;
      fkGamma:      Result := Gamma;
      fkSaturation: Result := Saturation;
      fkHue:        Result := Hue;
      fkInvert:     Result := Ord(Invert);
    else
      Result := Ord(Mirror);
    end;
end;

procedure SetFilter(var AFilters: TFilterSettings; AKind: TFilterKind; AValue: Double);
begin
  AValue := EnsureRange(AValue, FilterMin(AKind), FilterMax(AKind));
  with AFilters do
    case AKind of
      fkBlack:      Black := Min(AValue, White - MinGap);
      fkWhite:      White := Max(AValue, Black + MinGap);
      fkBrightness: Brightness := AValue;
      fkContrast:   Contrast := AValue;
      fkGamma:      Gamma := AValue;
      fkSaturation: Saturation := AValue;
      fkHue:        Hue := AValue;
      fkInvert:     Invert := AValue >= 0.5;
    else
      Mirror := AValue >= 0.5;
    end;
end;

function FilterText(const AFilters: TFilterSettings; AKind: TFilterKind): string;
var
  V: Double;
begin
  V := GetFilter(AFilters, AKind);
  case AKind of
    fkBlack, fkWhite:         Result := IntToStr(Round(V * 255));
    fkBrightness, fkContrast: Result := Signed(Round(V * 100)) + ' %';
    fkGamma:                  Result := FormatFloat('0.00', V);
    fkSaturation:             Result := FormatFloat('0.00', V);
    fkHue:                    Result := Signed(Round(V)) + '°';
  else
    if V >= 0.5 then
      Result := 'on'
    else
      Result := 'off';
  end;
end;

function FilterBarPos(AKind: TFilterKind; AValue: Double): Double;
begin
  if AKind = fkGamma then
    { log scale: 0.2 .. 1 .. 5 -> 0 .. 0.5 .. 1 }
    Result := (Ln(EnsureRange(AValue, 0.2, 5)) - Ln(0.2)) / (Ln(5) - Ln(0.2))
  else
    Result := (AValue - FilterMin(AKind)) / (FilterMax(AKind) - FilterMin(AKind));
  Result := EnsureRange(Result, 0, 1);
end;

function FilterValueAt(AKind: TFilterKind; APos: Double): Double;
begin
  APos := EnsureRange(APos, 0, 1);
  if AKind = fkGamma then
    Result := Exp(Ln(0.2) + APos * (Ln(5) - Ln(0.2)))
  else
    Result := FilterMin(AKind) + APos * (FilterMax(AKind) - FilterMin(AKind));
end;

procedure StepFilter(var AFilters: TFilterSettings; AKind: TFilterKind; ANotches: Double);
var
  V: Double;
begin
  if IsToggleFilter(AKind) then
  begin
    if Abs(ANotches) >= 0.5 then
      SetFilter(AFilters, AKind, Ord(ANotches > 0));
    Exit;
  end;
  V := GetFilter(AFilters, AKind) + ANotches * FilterStep(AKind);
  { Snap to neutral when passing close to it: easy to get back. }
  if Abs(V - FilterNeutral(AKind)) < FilterStep(AKind) * 0.5 then
    V := FilterNeutral(AKind);
  SetFilter(AFilters, AKind, V);
end;

function ContrastFactor(AContrast: Double): Double;
begin
  if AContrast >= 0 then
    Result := 1 / (1 - 0.95 * EnsureRange(AContrast, 0, 1))   { up to 20 x }
  else
    Result := 1 + EnsureRange(AContrast, -1, 0);              { down to flat grey }
end;

function BrightnessOffset(ABrightness: Double): Double;
begin
  Result := 0.5 * EnsureRange(ABrightness, -1, 1);
end;

function Clamp01(V: Double): Double; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 1 then
    Result := 1
  else
    Result := V;
end;

procedure BuildToneTable(const AFilters: TFilterSettings; out ATable: TToneTable);
var
  I: Integer;
  V, Span, Factor, Offset: Double;
begin
  Span := Max(AFilters.White - AFilters.Black, 1e-5);
  Factor := ContrastFactor(AFilters.Contrast);
  Offset := BrightnessOffset(AFilters.Brightness);
  for I := 0 to 255 do
  begin
    V := Clamp01((I / 255 - AFilters.Black) / Span);
    V := Clamp01((V - 0.5) * Factor + 0.5 + Offset);
    if not Near(AFilters.Gamma, 1) then
      V := Power(V, AFilters.Gamma);
    ATable[I] := Round(Clamp01(V) * 255);
  end;
end;

function NeedsColourStep(const AFilters: TFilterSettings): Boolean;
begin
  Result := (not Near(AFilters.Saturation, 1)) or (not Near(AFilters.Hue, 0)) or AFilters.Invert;
end;

procedure PrepareFilters(const AFilters: TFilterSettings; out APrep: TFilterPrep);
begin
  BuildToneTable(AFilters, APrep.Table);
  APrep.Colour := (not Near(AFilters.Saturation, 1)) or (not Near(AFilters.Hue, 0));
  APrep.Invert := AFilters.Invert;
  APrep.Sat := AFilters.Saturation;
  APrep.HueCos := Cos(DegToRad(AFilters.Hue));
  APrep.HueSin := Sin(DegToRad(AFilters.Hue));
end;

procedure FilterPixel(const APrep: TFilterPrep; var R, G, B: Byte);
var
  RF, GF, BF, Y, I, Q, I2, Q2: Double;
begin
  R := APrep.Table[R];
  G := APrep.Table[G];
  B := APrep.Table[B];
  if APrep.Colour then
  begin
    RF := R / 255;
    GF := G / 255;
    BF := B / 255;
    { YIQ: the luma stays, the colour is turned and scaled. }
    Y := 0.299 * RF + 0.587 * GF + 0.114 * BF;
    I := 0.596 * RF - 0.274 * GF - 0.322 * BF;
    Q := 0.211 * RF - 0.523 * GF + 0.312 * BF;
    I2 := (I * APrep.HueCos - Q * APrep.HueSin) * APrep.Sat;
    Q2 := (I * APrep.HueSin + Q * APrep.HueCos) * APrep.Sat;
    R := Round(Clamp01(Y + 0.956 * I2 + 0.621 * Q2) * 255);
    G := Round(Clamp01(Y - 0.272 * I2 - 0.647 * Q2) * 255);
    B := Round(Clamp01(Y - 1.106 * I2 + 1.703 * Q2) * 255);
  end;
  if APrep.Invert then
  begin
    R := 255 - R;
    G := 255 - G;
    B := 255 - B;
  end;
end;

procedure FilterRGB(const AFilters: TFilterSettings; const ATable: TToneTable;
  var R, G, B: Byte);
var
  Prep: TFilterPrep;
begin
  PrepareFilters(AFilters, Prep);
  Prep.Table := ATable;
  FilterPixel(Prep, R, G, B);
end;

function AutoLevels(const AHist: THistogram; out ABlack, AWhite: Double;
  ASaturatedPercent: Double): Boolean;
var
  Total, Limit, Sum: Int64;
  I, Lo, Hi: Integer;
begin
  ABlack := 0;
  AWhite := 1;
  Result := False;
  Total := 0;
  for I := 0 to 255 do
    Inc(Total, AHist[I]);
  if Total <= 0 then
    Exit;
  { Pixels allowed to clip at each end. }
  Limit := Trunc(Total * ASaturatedPercent / 100 / 2);
  Sum := 0;
  Lo := 0;
  for I := 0 to 255 do
  begin
    Inc(Sum, AHist[I]);
    if Sum > Limit then
    begin
      Lo := I;
      Break;
    end;
  end;
  Sum := 0;
  Hi := 255;
  for I := 255 downto 0 do
  begin
    Inc(Sum, AHist[I]);
    if Sum > Limit then
    begin
      Hi := I;
      Break;
    end;
  end;
  { At least 3 levels apart: more than SetFilter's smallest gap. }
  if Hi - Lo < 3 then
    Exit;
  ABlack := Lo / 255;
  AWhite := Hi / 255;
  Result := True;
end;

function FilterSuffix(const AFilters: TFilterSettings): string;
begin
  Result := '';
  with AFilters do
  begin
    if not Near(Black, 0) then
      Result := Result + '_bp' + IntToStr(Round(Black * 255));
    if not Near(White, 1) then
      Result := Result + '_wp' + IntToStr(Round(White * 255));
    if not Near(Brightness, 0) then
      Result := Result + '_b' + Signed(Round(Brightness * 100));
    if not Near(Contrast, 0) then
      Result := Result + '_c' + Signed(Round(Contrast * 100));
    if not Near(Gamma, 1) then
      Result := Result + '_g' + StringReplace(FormatFloat('0.00', Gamma), ',', '.', []);
    if not Near(Saturation, 1) then
      Result := Result + '_s' + StringReplace(FormatFloat('0.00', Saturation), ',', '.', []);
    if not Near(Hue, 0) then
      Result := Result + '_h' + Signed(Round(Hue));
    if Invert then
      Result := Result + '_inv';
    if Mirror then
      Result := Result + '_mirror';
  end;
end;

end.
