unit uFilterImage;

{
  Unit: uFilterImage

  Purpose
  -------
  The display filters (Phase H) on bitmaps: the filters applied to every
  pixel of a bitmap (the CPU renderer's screen-sized part, and "Apply
  filters to a copy"), and the histogram of a bitmap or of a rectangle
  of it (Auto, the filter panel).

  Owns
  ----
  Nothing (plain functions).

  Knows
  -----
  Nothing else (uFilters for the maths).

  Responsibilities
  ----------------
  - SharpenBitmap: an unsharp mask for the magnifier (CPU renderer).
  - ApplyFiltersToBitmap: in place, with the per-pixel work prepared
    once (PrepareFilters); AMirror: also mirror it (a filtered copy).
  - RotatedBitmap (Day 24): a turned copy (quarter turns exact, other
    angles bilinear on a larger canvas).
  - ImageHistogram: the luma (0.299 R + 0.587 G + 0.114 B, in integers)
    of the pixels in a rectangle; large areas are sampled on a regular
    grid (about AMaxSamples pixels), so a 100 MP image costs a few ms.

  Does NOT
  --------
  - Decide which bitmap or rectangle (TMView does), or keep anything.

  Threads
  -------
  Any; no state. MView calls them on the UI thread.

  Uses (MView units)
  ------------------
  interface:      uFilters
  Libraries:      Types, Math, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uRenderer, uMView
}

{$mode ObjFPC}{$H+}

interface

uses
  Types,
  Math,
  BGRABitmap,
  BGRABitmapTypes,
  uFilters;

procedure ApplyFiltersToBitmap(ABitmap: TBGRACustomBitmap; const AFilters: TFilterSettings;
  AMirror: Boolean = False);

{ Unsharp mask (the magnifier, CPU): each pixel + AAmount x (pixel -
  the mean of its 4 neighbours), in place; edge pixels stay. }
procedure SharpenBitmap(ABitmap: TBGRACustomBitmap; AAmount: Single);

{ ARect in bitmap pixels (clipped to the bitmap). Returns the number of
  pixels counted (0: nothing). }
function ImageHistogram(ABitmap: TBGRACustomBitmap; const ARect: TRect; out AHist: THistogram;
  AMaxSamples: Integer = 1000000): Int64;

{ ABitmap turned by ADegrees clockwise (as on screen), as a new bitmap
  (Day 24: "Apply filters to a copy" takes the rotation). Quarter turns
  exactly; other angles bilinear, on a canvas large enough for the
  whole image, the corners in ABackground. }
function RotatedBitmap(ABitmap: TBGRABitmap; ADegrees: Double;
  ABackground: TBGRAPixel): TBGRABitmap;

implementation

procedure ApplyFiltersToBitmap(ABitmap: TBGRACustomBitmap; const AFilters: TFilterSettings;
  AMirror: Boolean);
var
  Prep: TFilterPrep;
  X, Y: Integer;
  P: PBGRAPixel;
begin
  if ABitmap = nil then
    Exit;
  { Mirror is geometry: only a filtered copy ("Apply filters to a copy")
    asks for it (the renderers mirror the view instead). }
  if AFilters.Mirror and AMirror then
    ABitmap.HorizontalFlip;
  if ColourNeutral(AFilters) then
  begin
    if AFilters.Mirror and AMirror then
      ABitmap.InvalidateBitmap;
    Exit;
  end;
  PrepareFilters(AFilters, Prep);
  for Y := 0 to ABitmap.Height - 1 do
  begin
    P := ABitmap.ScanLine[Y];
    for X := 0 to ABitmap.Width - 1 do
    begin
      FilterPixel(Prep, P^.red, P^.green, P^.blue);
      Inc(P);
    end;
  end;
  ABitmap.InvalidateBitmap;
end;

procedure SharpenBitmap(ABitmap: TBGRACustomBitmap; AAmount: Single);
var
  W, H, X, Y, C, V: Integer;
  Orig: array of TBGRAPixel;
  P: PBGRAPixel;
  Up, Mid, Down: PBGRAPixel;

  function Channel(const APixel: TBGRAPixel; AIndex: Integer): Integer; inline;
  begin
    case AIndex of
      0: Result := APixel.red;
      1: Result := APixel.green;
    else
      Result := APixel.blue;
    end;
  end;

begin
  if (ABitmap = nil) or (AAmount <= 0) then
    Exit;
  W := ABitmap.Width;
  H := ABitmap.Height;
  if (W < 3) or (H < 3) then
    Exit;
  { The original rows, row by row top-down (ScanLine handles the
    bitmap's own row order). }
  SetLength(Orig, W * H);
  for Y := 0 to H - 1 do
    Move(ABitmap.ScanLine[Y]^, Orig[Y * W], W * SizeOf(TBGRAPixel));
  for Y := 1 to H - 2 do
  begin
    P := ABitmap.ScanLine[Y];
    Up := @Orig[(Y - 1) * W];
    Mid := @Orig[Y * W];
    Down := @Orig[(Y + 1) * W];
    for X := 1 to W - 2 do
      for C := 0 to 2 do
      begin
        V := Channel(Mid[X], C);
        V := V + Round(AAmount * (V - (Channel(Mid[X - 1], C) + Channel(Mid[X + 1], C)
          + Channel(Up[X], C) + Channel(Down[X], C)) / 4));
        if V < 0 then
          V := 0
        else if V > 255 then
          V := 255;
        case C of
          0: P[X].red := V;
          1: P[X].green := V;
        else
          P[X].blue := V;
        end;
      end;
  end;
  ABitmap.InvalidateBitmap;
end;

function RotatedBitmap(ABitmap: TBGRABitmap; ADegrees: Double;
  ABackground: TBGRAPixel): TBGRABitmap;
var
  A, Rad, C, S, CX, CY, NCX, NCY, DX, DY, SX, SY, FX, FY: Double;
  W, H, NW, NH, X, Y, X0, Y0, Turns: Integer;
  P: PBGRAPixel;
  Rows: array of PBGRAPixel;
  P00, P10, P01, P11: TBGRAPixel;

  function At(AX, AY: Integer): TBGRAPixel;
  begin
    if (AX < 0) or (AY < 0) or (AX >= W) or (AY >= H) then
      Result := ABackground
    else
      Result := Rows[AY][AX];
  end;

  function Mix(V00, V10, V01, V11: Byte): Byte;
  var
    V: Double;
  begin
    V := (V00 * (1 - FX) + V10 * FX) * (1 - FY) + (V01 * (1 - FX) + V11 * FX) * FY;
    Result := EnsureRange(Round(V), 0, 255);
  end;

begin
  Result := nil;
  if ABitmap = nil then
    Exit;
  A := ADegrees - 360.0 * Floor(ADegrees / 360.0);
  { Quarter turns: exact, no resampling. }
  Turns := Round(A / 90.0);
  if Abs(A - Turns * 90.0) < 0.01 then
  begin
    case Turns mod 4 of
      1: Result := ABitmap.RotateCW as TBGRABitmap;
      2: begin
           Result := ABitmap.Duplicate as TBGRABitmap;
           Result.HorizontalFlip;
           Result.VerticalFlip;
         end;
      3: Result := ABitmap.RotateCCW as TBGRABitmap;
    else
      Result := ABitmap.Duplicate as TBGRABitmap;
    end;
    Exit;
  end;

  W := ABitmap.Width;
  H := ABitmap.Height;
  Rad := DegToRad(A);
  C := Cos(Rad);
  S := Sin(Rad);
  NW := Max(1, Ceil(Abs(W * C) + Abs(H * S) - 1e-6));
  NH := Max(1, Ceil(Abs(W * S) + Abs(H * C) - 1e-6));
  Result := TBGRABitmap.Create(NW, NH, ABackground);
  SetLength(Rows, H);
  for Y := 0 to H - 1 do
    Rows[Y] := ABitmap.ScanLine[Y];
  CX := W / 2;
  CY := H / 2;
  NCX := NW / 2;
  NCY := NH / 2;
  for Y := 0 to NH - 1 do
  begin
    P := Result.ScanLine[Y];
    DY := Y + 0.5 - NCY;
    for X := 0 to NW - 1 do
    begin
      DX := X + 0.5 - NCX;
      { Back into the source: the inverse of a clockwise turn (screen y
        points down), pixel centres at +0.5. }
      SX := DX * C + DY * S + CX - 0.5;
      SY := -DX * S + DY * C + CY - 0.5;
      if (SX > -1) and (SY > -1) and (SX < W) and (SY < H) then
      begin
        X0 := Floor(SX);
        Y0 := Floor(SY);
        FX := SX - X0;
        FY := SY - Y0;
        P00 := At(X0, Y0);
        P10 := At(X0 + 1, Y0);
        P01 := At(X0, Y0 + 1);
        P11 := At(X0 + 1, Y0 + 1);
        P^.red := Mix(P00.red, P10.red, P01.red, P11.red);
        P^.green := Mix(P00.green, P10.green, P01.green, P11.green);
        P^.blue := Mix(P00.blue, P10.blue, P01.blue, P11.blue);
        P^.alpha := Mix(P00.alpha, P10.alpha, P01.alpha, P11.alpha);
      end;
      Inc(P);
    end;
  end;
  Result.InvalidateBitmap;
end;

function ImageHistogram(ABitmap: TBGRACustomBitmap; const ARect: TRect; out AHist: THistogram;
  AMaxSamples: Integer): Int64;
var
  X0, Y0, X1, Y1, X, Y, StepPx: Integer;
  Area: Int64;
  P: PBGRAPixel;
begin
  FillChar(AHist, SizeOf(AHist), 0);
  Result := 0;
  if (ABitmap = nil) or (ABitmap.Width <= 0) or (ABitmap.Height <= 0) then
    Exit;
  X0 := EnsureRange(ARect.Left, 0, ABitmap.Width);
  Y0 := EnsureRange(ARect.Top, 0, ABitmap.Height);
  X1 := EnsureRange(ARect.Right, X0, ABitmap.Width);
  Y1 := EnsureRange(ARect.Bottom, Y0, ABitmap.Height);
  if (X1 <= X0) or (Y1 <= Y0) then
    Exit;
  Area := Int64(X1 - X0) * (Y1 - Y0);
  { A regular grid: every StepPx-th pixel of every StepPx-th row. }
  StepPx := 1;
  if AMaxSamples > 0 then
    while Area div (Int64(StepPx) * StepPx) > AMaxSamples do
      Inc(StepPx);
  Y := Y0;
  while Y < Y1 do
  begin
    P := ABitmap.ScanLine[Y];
    Inc(P, X0);
    X := X0;
    while X < X1 do
    begin
      Inc(AHist[(77 * P^.red + 150 * P^.green + 29 * P^.blue) shr 8]);
      Inc(Result);
      Inc(P, StepPx);
      Inc(X, StepPx);
    end;
    Inc(Y, StepPx);
  end;
end;

end.
