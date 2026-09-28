unit uIOGate;

{
  Unit: uIOGate

  Purpose
  -------
  The I/O gate (spec §5.5). While the file of the current image is
  being read, the directory scanner waits, so it doesn't compete for
  the disk. This matters on hard disks and network shares.

  Owns
  ----
  - TIOGate: a critical section (FLock), a manual-reset event (FOpen,
    set = open) and the count of raised reads (FRaisedCount).
  - The global IOGate, created in the initialization section and never
    freed (see Notes).

  Knows
  -----
  - TCancelCheck (uTypes), handed in to YieldToDisplay.

  Responsibilities
  ----------------
  - BeginPriorityRead / EndPriorityRead: called by a decode worker
    around reading the file of a P0 (display) job. Nested and parallel
    raises are counted.
  - WaitWhileRaised: called by the scanner between directory entries.
  - YieldToDisplay: called by background decodes (preloads) between
    parts of their read; waits while a display job reads (spec §2.2,
    §5.5), checks the cancel callback every 50 ms, gives up after
    AMaxWaitMs.
  - IsRaised: True while a display job reads its file.
  - Release: opens the gate for good (shutdown).

  Does NOT
  --------
  - Block display decodes. Preload jobs never raise the gate; a
    preload waits only between parts of its read while it is raised
    (YieldToDisplay, at most AMaxWaitMs), so the display read gets
    the disk first.
  - Decide which job is a display job (uMediaLoader does).

  Threads
  -------
  Called from decode workers (BeginPriorityRead / EndPriorityRead,
  YieldToDisplay), the scanner thread (WaitWhileRaised) and at
  shutdown (Release, from uMView and uJobScheduler). The count is
  guarded by FLock; waiting is on the event, outside the lock.

  Uses (MView units)
  ------------------
  interface:      uTypes
  Libraries:      SyncObjs

  Used by
  -------
  uDirectoryScanner, uJobScheduler, uMView, uMediaLoader, uTiffQuick,
  uWicDecoder

  Notes
  -----
  One gate for the whole program, created in the initialization
  section, so loader and scanner don't need to know each other.
  The wait has an upper limit, so a missed EndPriorityRead can never
  stop the scanner for good.
  Not freed in finalization: a thread stuck in a read (Day 19) may
  still come back and use it while the process ends.
}

{$mode ObjFPC}{$H+}

interface

uses
  SyncObjs,
  uTypes;

type

  TIOGate = class(TObject)
  private
    FLock: TCriticalSection;
    FOpen: TEvent;              { manual reset: set = open }
    FRaisedCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    procedure BeginPriorityRead;
    procedure EndPriorityRead;

    { Waits until the gate is open, at most AMaxWaitMs. }
    procedure WaitWhileRaised(AMaxWaitMs: Cardinal = 2000);

    { True while a display job reads its file. }
    function IsRaised: Boolean;

    { For background decodes (preloads), between parts of their read:
      waits while a display job reads, so the image the user wants
      gets the disk (spec §2.2, §5.5). Checks ACancel every 50 ms and
      gives up after AMaxWaitMs, so nothing can hang on it. }
    procedure YieldToDisplay(ACancel: TCancelCheck; AMaxWaitMs: Cardinal = 5000);

    { Opens the gate for good (shutdown). }
    procedure Release;
  end;

var
  IOGate: TIOGate;

implementation

constructor TIOGate.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FOpen := TEvent.Create(nil, True, True, '');
  FRaisedCount := 0;
end;

destructor TIOGate.Destroy;
begin
  FOpen.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIOGate.BeginPriorityRead;
begin
  FLock.Acquire;
  try
    Inc(FRaisedCount);
    FOpen.ResetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TIOGate.EndPriorityRead;
begin
  FLock.Acquire;
  try
    if FRaisedCount > 0 then
      Dec(FRaisedCount);
    if FRaisedCount = 0 then
      FOpen.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TIOGate.WaitWhileRaised(AMaxWaitMs: Cardinal);
begin
  FOpen.WaitFor(AMaxWaitMs);
end;

function TIOGate.IsRaised: Boolean;
begin
  FLock.Acquire;
  try
    Result := FRaisedCount > 0;
  finally
    FLock.Release;
  end;
end;

procedure TIOGate.YieldToDisplay(ACancel: TCancelCheck; AMaxWaitMs: Cardinal);
var
  Waited: Cardinal;
begin
  Waited := 0;
  while IsRaised and (Waited < AMaxWaitMs) do
  begin
    if Assigned(ACancel) and ACancel() then
      Exit;
    FOpen.WaitFor(50);
    Inc(Waited, 50);
  end;
end;

procedure TIOGate.Release;
begin
  FLock.Acquire;
  try
    FRaisedCount := 0;
    FOpen.SetEvent;
  finally
    FLock.Release;
  end;
end;

initialization
  IOGate := TIOGate.Create;

finalization
  { Not freed: a thread stuck in a read (Day 19) may still come back
    and use it while the process ends. }

end.
