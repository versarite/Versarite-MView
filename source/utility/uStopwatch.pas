unit uStopwatch;

{
  Unit: uStopwatch

  Purpose
  -------
  A precise clock for performance measurements (spec §12).

  Owns
  ----
  - CounterFrequency (Windows): the performance counter frequency,
    read once in the initialization section.

  Knows
  -----
  Nothing else.

  Responsibilities
  ----------------
  - NowMs: milliseconds from a fixed but arbitrary starting point, with
    sub-millisecond resolution. Only differences are meaningful.
  - ProcessAgeMs: milliseconds since this process was started, for the
    start-up measurement; 0 if unknown (always 0 outside Windows).

  Does NOT
  --------
  - Tell the time of day.

  Threads
  -------
  Safe to call from any thread: no state is written after the
  initialization section.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      Windows

  Used by
  -------
  uGLRenderer, uMView, uMainForm, uMediaLoader, uRenderer

  Notes
  -----
  On Windows this uses QueryPerformanceCounter, which resolves well
  below a microsecond. GetTickCount64 would only resolve about 15 ms,
  too coarse to measure a paint (it is what NowMs uses outside
  Windows).
}

{$mode ObjFPC}{$H+}

interface

function NowMs: Double;

{ Milliseconds since this process was started (start-up measurement);
  0 if unknown. }
function ProcessAgeMs: Double;

implementation

{$IFDEF WINDOWS}
uses
  Windows;

var
  CounterFrequency: Int64 = 0;

function NowMs: Double;
var
  Counter: Int64;
begin
  QueryPerformanceCounter(Counter);
  Result := Counter * 1000.0 / CounterFrequency;
end;

function ProcessAgeMs: Double;
var
  Creation, ExitTime, KernelTime, UserTime, NowTime: TFileTime;
  C, N: Int64;
begin
  Result := 0;
  if not GetProcessTimes(GetCurrentProcess, Creation, ExitTime, KernelTime, UserTime) then
    Exit;
  GetSystemTimeAsFileTime(NowTime);
  C := Int64(Creation.dwLowDateTime) or (Int64(Creation.dwHighDateTime) shl 32);
  N := Int64(NowTime.dwLowDateTime) or (Int64(NowTime.dwHighDateTime) shl 32);
  { 100 ns units. }
  Result := (N - C) / 10000.0;
end;

initialization
  QueryPerformanceFrequency(CounterFrequency);
  if CounterFrequency = 0 then
    CounterFrequency := 1;
{$ELSE}
uses
  SysUtils;

function NowMs: Double;
begin
  Result := GetTickCount64;
end;

function ProcessAgeMs: Double;
begin
  Result := 0;
end;
{$ENDIF}

end.
