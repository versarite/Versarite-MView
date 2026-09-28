unit uNaturalSort;

{
  Unit: uNaturalSort

  Purpose
  -------
  "Natural" string comparison, as used by Windows Explorer and Total
  Commander: runs of digits are compared by their numeric value, the
  rest is compared case-insensitively.

      Image2  <  Image10        (plain CompareText says the opposite)
      scan_9  <  scan_010

  Owns
  ----
  Nothing: stateless routines.

  Knows
  -----
  Nothing else.

  Responsibilities
  ----------------
  - Compare two strings naturally (NaturalCompareText).
  - Provide a comparison function for TStringList.CustomSort
    (NaturalCompareStringList).

  Does NOT
  --------
  - Know about files, directories or sort modes.

  Threads
  -------
  Any thread: no shared state.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      Classes, SysUtils

  Used by
  -------
  uDirectoryImages, uDirectoryTree

  Notes
  -----
  Non-digit parts are compared with CompareText, which folds only the
  ASCII letters A..Z. Other characters are compared byte by byte, so
  names with accented letters still sort in a fixed, repeatable order.
  Numbers are compared by their count of significant digits first,
  then digit by digit, so any length works without overflow; numbers
  sort before letters.
  If two names are equal by these rules ("File1" / "file1", "x1" /
  "x01"), CompareStr decides, so the order never depends on the sort
  algorithm.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils;

function NaturalCompareText(const A, B: string): Integer;

{ For TStringList.CustomSort. }
function NaturalCompareStringList(AList: TStringList; AIndex1, AIndex2: Integer): Integer;

implementation

function IsDigitChar(C: Char): Boolean; inline;
begin
  Result := (C >= '0') and (C <= '9');
end;

function SignOf(AValue: Integer): Integer; inline;
begin
  if AValue < 0 then
    Result := -1
  else if AValue > 0 then
    Result := 1
  else
    Result := 0;
end;

function NaturalCompareText(const A, B: string): Integer;
var
  I, J: Integer;           { current position in A and B }
  StartA, StartB: Integer; { start of the current run }
  SigA, SigB: Integer;     { first significant (non-zero) digit of a number }
  LenA, LenB: Integer;
begin
  I := 1;
  J := 1;

  while (I <= Length(A)) and (J <= Length(B)) do
  begin
    if IsDigitChar(A[I]) and IsDigitChar(B[J]) then
    begin
      { Both sides are at a number: compare by value. }
      StartA := I;
      while (I <= Length(A)) and IsDigitChar(A[I]) do
        Inc(I);
      StartB := J;
      while (J <= Length(B)) and IsDigitChar(B[J]) do
        Inc(J);

      { Skip leading zeros, but keep at least one digit. }
      SigA := StartA;
      while (SigA < I - 1) and (A[SigA] = '0') do
        Inc(SigA);
      SigB := StartB;
      while (SigB < J - 1) and (B[SigB] = '0') do
        Inc(SigB);

      { More significant digits = larger number. This works for numbers
        of any length, with no risk of overflow. }
      LenA := I - SigA;
      LenB := J - SigB;
      if LenA <> LenB then
        Exit(SignOf(LenA - LenB));

      { Same number of digits: the digit strings compare like the values. }
      Result := SignOf(CompareStr(Copy(A, SigA, LenA), Copy(B, SigB, LenB)));
      if Result <> 0 then
        Exit;
    end
    else
    begin
      { Compare the next non-digit runs. If only one side is at a digit,
        its run is empty, so numbers sort before letters. }
      StartA := I;
      while (I <= Length(A)) and not IsDigitChar(A[I]) do
        Inc(I);
      StartB := J;
      while (J <= Length(B)) and not IsDigitChar(B[J]) do
        Inc(J);

      Result := SignOf(CompareText(Copy(A, StartA, I - StartA),
                                   Copy(B, StartB, J - StartB)));
      if Result <> 0 then
        Exit;
    end;
  end;

  { One string is a prefix of the other: the shorter one comes first. }
  Result := SignOf((Length(A) - I) - (Length(B) - J));
  if Result <> 0 then
    Exit;

  { Equal by the natural rules: fall back to an exact comparison. }
  Result := SignOf(CompareStr(A, B));
end;

function NaturalCompareStringList(AList: TStringList; AIndex1, AIndex2: Integer): Integer;
begin
  Result := NaturalCompareText(AList[AIndex1], AList[AIndex2]);
end;

end.
