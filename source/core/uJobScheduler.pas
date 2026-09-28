unit uJobScheduler;

{
  Unit: uJobScheduler

  Purpose
  -------
  Runs decode jobs on worker threads and brings the results back to
  the UI thread (spec §5).

  Owns
  ----
  - TJobQueue (FQueue).
  - The TDecodeWorker threads (FWorkers), including replacements
    started for stuck workers. An abandoned worker is never waited
    for or freed.
  - The wake-up event (FWakeUp, auto-reset TEvent).

  Knows
  -----
  - TMediaLoader (the workers call it; it is stateless). Handed in by
    the owner, not freed here.
  - IOGate, the global I/O gate (opened for a stuck display read).
  - The OnImageReady handler of the owner (TMView).

  Responsibilities
  ----------------
  - Reconcile: after every navigation the owner says what should
    exist (the wanted set, spec §5.3); the queue drops, cancels,
    promotes and adds jobs to match. A job already running for a
    wanted image is kept, not restarted ("promote, don't restart").
  - N workers (spec §5.1), one of them always kept free for the
    current image (spec §5.4, rule in TJobQueue.TakeNext).
    AutomaticWorkerCount: CPU cores - 1, at least 1, at most 4.
  - Results of jobs that were cancelled but ran to their end anyway
    are still delivered, so they can go into the cache (spec §5.6).
  - Deliver finished images on the UI thread through OnImageReady,
    using TThread.Queue, never Synchronize (spec §5.7).
  - Find workers stuck in a read and replace them (CheckStuck, Day 19;
    at most MaxReplacements = 4 per session).
  - Testing aid: DecodeDelayMs makes every decode slow.
  - Shut down cleanly (spec §5.8).

  Does NOT
  --------
  - Decode (TMediaLoader does), cache or draw.
  - Touch the GUI, the navigator or the renderer from a worker.

  Threads
  -------
  TDecodeWorker.Execute runs on the worker thread (with RunJobs,
  LeaveIfReplaced and SimulateSlowDecode). It only talks to the queue
  (locked) and the loader (stateless), and posts ProcessResults to
  the UI thread. Everything else here runs on the UI thread. A
  worker's FCurrentJob, FAbandoned and FHasReplacement are plain
  fields shared by the worker and the UI thread; see their comments.

  Uses (MView units)
  ------------------
  interface:      uTypes, uDecodedImage, uMediaLoader, uIOGate,
                  uJobQueue
  Libraries:      Classes, SysUtils, SyncObjs

  Used by
  -------
  uMView
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  uTypes,
  uDecodedImage,
  uMediaLoader,
  uIOGate,
  uJobQueue;

type

  TImageReadyEvent = procedure(const AImage: IDecodedImage) of object;

  TJobScheduler = class;

  TDecodeWorker = class(TThread)
  private
    FScheduler: TJobScheduler;
    { The job being decoded, nil between jobs. Written by the worker,
      read by the UI thread (CheckStuck); the job can't be freed while
      it is set (the UI thread frees jobs only after Finish). }
    FCurrentJob: TDecodeJob;
    { Set by the UI thread: this worker is stuck and was replaced. When
      its read ever returns, it hands in the job and ends. }
    FAbandoned: Boolean;
    { Set by the UI thread before FAbandoned: a replacement worker was
      started for this one. }
    FHasReplacement: Boolean;
    function LeaveIfReplaced: Boolean;
    procedure RunJobs;
  protected
    procedure Execute; override;
  public
    constructor Create(AScheduler: TJobScheduler);
  end;

  TJobScheduler = class(TObject)
  private
    FLoader: TMediaLoader;
    FQueue: TJobQueue;
    FWorkers: array of TDecodeWorker;
    FWakeUp: TEvent;
    FOnImageReady: TImageReadyEvent;
    FShuttingDown: Boolean;
    FDecodeDelayMs: Integer;
    FWorkerCount: Integer;
    FReplacements: Integer;
    FAnyAbandoned: Boolean;

    procedure ProcessResults;
    procedure SimulateSlowDecode(AJob: TDecodeJob);
  public
    constructor Create(ALoader: TMediaLoader; AWorkerCount: Integer);
    destructor Destroy; override;

    { UI thread. What should be decoded now, most important first
      (spec §5.3). Everything else is dropped or cancelled. }
    procedure Reconcile(const AWanted: TWantedItems; APreviewWidth, APreviewHeight: Integer);

    { UI thread. Runs deliveries that are waiting, without waiting for
      the queued call. }
    procedure ProcessResultsNow;

    procedure GetCounts(out AWaiting, ARunning: Integer);
    property WorkerCount: Integer read FWorkerCount;

    { UI thread (Day 19): workers whose job hasn't come back to its
      cancel check for ATimeoutMs are taken as stuck in a read (a
      failing or hung disk). Each is abandoned: its job cancelled, the
      read cancelled if Windows can (CancelSynchronousIo), a
      replacement worker started (at most MaxReplacements in all).
      Returns the stuck jobs' file names. }
    function CheckStuck(ATimeoutMs: QWord): TStringArray;

    { True if a worker was abandoned: the scheduler must then not be
      freed (that thread may still come back and use it). }
    property HasAbandonedWorkers: Boolean read FAnyAbandoned;

    { UI thread. Cancels all work and stops the workers. Safe to call
      more than once. }
    procedure Shutdown;

    property OnImageReady: TImageReadyEvent read FOnImageReady write FOnImageReady;

    { Testing aid: every decode first waits this long (in small,
      cancellable steps), to make slow files easy to simulate. }
    property DecodeDelayMs: Integer read FDecodeDelayMs write FDecodeDelayMs;
  end;

{ Spec §5.1: CPU cores - 1, at least 1, at most 4. }
function AutomaticWorkerCount: Integer;

implementation

{$IFDEF WINDOWS}
type
  TMViewSystemInfo = record
    wProcessorArchitecture: Word;
    wReserved: Word;
    dwPageSize: LongWord;
    lpMinimumApplicationAddress: Pointer;
    lpMaximumApplicationAddress: Pointer;
    dwActiveProcessorMask: PtrUInt;
    dwNumberOfProcessors: LongWord;
    dwProcessorType: LongWord;
    dwAllocationGranularity: LongWord;
    wProcessorLevel: Word;
    wProcessorRevision: Word;
  end;

procedure MViewGetSystemInfo(var AInfo: TMViewSystemInfo); stdcall;
  external 'kernel32.dll' name 'GetSystemInfo';
{$ENDIF}

function AutomaticWorkerCount: Integer;
{$IFDEF WINDOWS}
var
  Info: TMViewSystemInfo;
{$ENDIF}
begin
  Result := 2;
  {$IFDEF WINDOWS}
  FillChar(Info, SizeOf(Info), 0);
  MViewGetSystemInfo(Info);
  if Info.dwNumberOfProcessors > 0 then
    Result := Integer(Info.dwNumberOfProcessors) - 1;
  {$ENDIF}
  if Result < 1 then
    Result := 1;
  if Result > 4 then
    Result := 4;
end;

{$IFDEF WINDOWS}
type
  TCancelSynchronousIo = function(AThread: THandle): LongBool; stdcall;

function MViewGetModuleHandle(AName: PWideChar): THandle; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleW';
function MViewGetProcAddress(AModule: THandle; AName: PAnsiChar): Pointer; stdcall;
  external 'kernel32.dll' name 'GetProcAddress';

{ Asks Windows to cancel the blocking read the thread is in. Works for
  network shares and most drivers that support cancellation; a disk
  retrying a bad sector may ignore it. Vista and later. }
procedure TryCancelSynchronousIo(AThread: THandle);
var
  Proc: TCancelSynchronousIo;
begin
  Pointer(Proc) := MViewGetProcAddress(MViewGetModuleHandle('kernel32.dll'),
    'CancelSynchronousIo');
  if Assigned(Proc) then
    Proc(AThread);
end;
{$ELSE}
procedure TryCancelSynchronousIo(AThread: THandle);
begin
end;
{$ENDIF}

const
  { Stuck workers replaced at most this many times per session, so a
    dead disk can't make threads pile up. }
  MaxReplacements = 4;

  { How long an idle worker sleeps before it looks again. New jobs
    wake one worker at once through FWakeUp; the others notice within
    this time (for example a background job that was held back by the
    reserved-worker rule). }
  IdleWaitMs = 50;

{ TDecodeWorker }

constructor TDecodeWorker.Create(AScheduler: TJobScheduler);
begin
  FScheduler := AScheduler;
  { Starts running only after the constructor has finished, so
    FScheduler is set before Execute can use it. FreeOnTerminate stays
    False: the scheduler frees the worker after WaitFor. }
  inherited Create(False);
end;

procedure TDecodeWorker.Execute;
begin
  { Per-thread setup of the loader (COM for the WIC decoder). }
  FScheduler.FLoader.ThreadStart;
  try
    RunJobs;
  finally
    FScheduler.FLoader.ThreadEnd;
  end;
end;

procedure TDecodeWorker.RunJobs;
var
  Job: TDecodeJob;
begin
  while not Terminated do
  begin
    { Marked stuck just after it came back. }
    if FAbandoned and LeaveIfReplaced then
      Exit;
    Job := FScheduler.FQueue.TakeNext;
    if Job = nil then
    begin
      FScheduler.FWakeUp.WaitFor(IdleWaitMs);
      Continue;
    end;

    FCurrentJob := Job;
    try
      if not Job.IsCancelled then
        FScheduler.SimulateSlowDecode(Job);
      if not Job.IsCancelled then
        Job.Image := FScheduler.FLoader.Load(Job.FileName, Job.Quality,
          @Job.WorkerCancelCheck, Job.PreviewWidth, Job.PreviewHeight, Job.PriorityRead);
    except
      { The loader turns failures into error entries; anything that
        still escapes must not kill the worker. }
      Job.Image := nil;
    end;
    FCurrentJob := nil;

    { Taken as stuck and back now. During shutdown the job is left
      alone (the scheduler doesn't free jobs once a worker was
      abandoned). }
    if FAbandoned and Terminated then
      Exit;

    FScheduler.FQueue.Finish(Job);
    { A worker is free again: a held-back background job may start. }
    FScheduler.FWakeUp.SetEvent;

    { Hand over to the UI thread without waiting for it. Queued with
      this thread as the owner, so Shutdown can remove calls that are
      still pending. }
    Queue(@FScheduler.ProcessResults);

    if FAbandoned and LeaveIfReplaced then
      Exit;
  end;
end;

{ A stuck worker that came back: if a replacement took its place, it
  leaves (True); otherwise it simply goes on working, so the pool
  never shrinks. }
function TDecodeWorker.LeaveIfReplaced: Boolean;
begin
  Result := FHasReplacement;
  if Result then
    FScheduler.FQueue.RemoveWorkerSlot
  else
    FAbandoned := False;
end;

{ TJobScheduler }

constructor TJobScheduler.Create(ALoader: TMediaLoader; AWorkerCount: Integer);
var
  I: Integer;
begin
  inherited Create;
  FLoader := ALoader;
  if AWorkerCount < 1 then
    AWorkerCount := 1;
  FWorkerCount := AWorkerCount;
  FQueue := TJobQueue.Create(AWorkerCount);
  { Auto-reset: one SetEvent wakes one waiting worker. }
  FWakeUp := TEvent.Create(nil, False, False, '');

  if AWorkerCount < 1 then
    AWorkerCount := 1;
  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
    FWorkers[I] := TDecodeWorker.Create(Self);
end;

destructor TJobScheduler.Destroy;
begin
  Shutdown;
  FQueue.Free;
  FWakeUp.Free;
  inherited Destroy;
end;
{ (The owner doesn't free a scheduler with HasAbandonedWorkers: a
  stuck worker that comes back uses FQueue.) }

procedure TJobScheduler.Reconcile(const AWanted: TWantedItems;
  APreviewWidth, APreviewHeight: Integer);
var
  Added, I: Integer;
begin
  if FShuttingDown then
    Exit;

  Added := FQueue.Reconcile(AWanted, APreviewWidth, APreviewHeight);
  { Auto-reset event: one SetEvent wakes one worker. At least one, as
    a promoted job may now be allowed to start. }
  if Added < 1 then
    Added := 1;
  for I := 1 to Added do
    FWakeUp.SetEvent;
end;

procedure TJobScheduler.ProcessResultsNow;
begin
  if not FShuttingDown then
    ProcessResults;
end;

procedure TJobScheduler.GetCounts(out AWaiting, ARunning: Integer);
begin
  FQueue.GetCounts(AWaiting, ARunning);
end;

{ UI thread. Collects finished jobs, delivers the wanted results and
  frees the jobs. }
procedure TJobScheduler.ProcessResults;
var
  Done: TFPList;
  I: Integer;
  Job: TDecodeJob;
begin
  Done := TFPList.Create;
  try
    FQueue.TakeDone(Done);
    for I := 0 to Done.Count - 1 do
    begin
      Job := TDecodeJob(Done[I]);
      try
        { A cancelled job that still produced a proper image (the
          decoder couldn't stop in time) is delivered too: the owner
          caches it. A cancelled job's error ("Cancelled") is not. }
        if (not FShuttingDown) and (Job.Image <> nil) and Assigned(FOnImageReady)
          and not (Job.IsCancelled and Job.Image.IsError) then
          FOnImageReady(Job.Image);
      finally
        Job.Free;
      end;
    end;
  finally
    Done.Free;
  end;
end;

function TJobScheduler.CheckStuck(ATimeoutMs: QWord): TStringArray;
var
  I, N, Count: Integer;
  Worker: TDecodeWorker;
  Job: TDecodeJob;
  NowTick, Alive: QWord;
begin
  Result := nil;
  if FShuttingDown then
    Exit;
  Count := Length(FWorkers);
  for I := 0 to Count - 1 do
  begin
    Worker := FWorkers[I];
    if Worker.FAbandoned then
      Continue;
    Job := Worker.FCurrentJob;
    if Job = nil then
      Continue;
    { The tick after the job's: the worker may check in meanwhile. }
    Alive := Job.AliveTick;
    NowTick := GetTickCount64;
    if (NowTick <= Alive) or (NowTick - Alive < ATimeoutMs) then
      Continue;

    { Stuck in a read. }
    Worker.FHasReplacement := FReplacements < MaxReplacements;
    Worker.FAbandoned := True;
    FAnyAbandoned := True;
    Job.Cancel;
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N] := Job.FileName;
    { A display job keeps the I/O gate raised while it reads: open it,
      or the preloads would wait for a read that doesn't end. }
    if Job.PriorityRead then
      IOGate.Release;
    TryCancelSynchronousIo(Worker.Handle);

    if Worker.FHasReplacement then
    begin
      Inc(FReplacements);
      FQueue.AddWorkerSlot;
      SetLength(FWorkers, Length(FWorkers) + 1);
      FWorkers[High(FWorkers)] := TDecodeWorker.Create(Self);
    end;
  end;
end;

procedure TJobScheduler.SimulateSlowDecode(AJob: TDecodeJob);
var
  Waited: Integer;
begin
  Waited := 0;
  while (Waited < FDecodeDelayMs) and not AJob.WorkerCancelCheck do
  begin
    Sleep(20);
    Inc(Waited, 20);
  end;
end;

{ Shutdown order (spec §5.8): stop accepting work, cancel everything,
  stop and wait for the workers, remove their pending deliveries, free
  what is left. While we wait, the RTL may still run queued
  ProcessResults calls; FShuttingDown makes them only free jobs. }
procedure TJobScheduler.Shutdown;
var
  I: Integer;
  Remaining: TFPList;
begin
  if FShuttingDown then
    Exit;
  FShuttingDown := True;
  FOnImageReady := nil;

  FQueue.CancelAllExcept('');

  for I := 0 to High(FWorkers) do
    FWorkers[I].Terminate;
  for I := 0 to High(FWorkers) do
    FWakeUp.SetEvent;

  for I := 0 to High(FWorkers) do
  begin
    if FWorkers[I].FAbandoned then
    begin
      { Stuck in a read: never waited for, never freed. Its job stays
        with it (not freed below). }
      if FWorkers[I].FCurrentJob <> nil then
        FQueue.Forget(FWorkers[I].FCurrentJob);
      TThread.RemoveQueuedEvents(FWorkers[I]);
      Continue;
    end;
    FWorkers[I].WaitFor;
    TThread.RemoveQueuedEvents(FWorkers[I]);
    FWorkers[I].Free;
  end;
  FWorkers := nil;

  { With a worker still stuck, jobs are left alone: it may come back
    and hand its job in at any moment. (The process ends soon.) }
  if FAnyAbandoned then
    Exit;

  Remaining := TFPList.Create;
  try
    FQueue.TakeAll(Remaining);
    for I := 0 to Remaining.Count - 1 do
      TDecodeJob(Remaining[I]).Free;
  finally
    Remaining.Free;
  end;
end;

end.
