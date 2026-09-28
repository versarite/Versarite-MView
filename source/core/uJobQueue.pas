unit uJobQueue;

{
  Unit: uJobQueue

  Purpose
  -------
  Decode jobs and the thread-safe queue that holds them (spec §5.2,
  §5.6). The queue is guarded by a lock (spec §2.4), as are the
  cache, the directory scanner and the I/O gate.

  Owns
  ----
  - TJobQueue owns every job it holds, in three lists: waiting,
    running and done (FWaiting, FRunning, FDone).
  - Its lock, FLock (TCriticalSection).
  - Each TDecodeJob holds a reference to its result, an IDecodedImage
    (shared; freed with its last reference).

  Knows
  -----
  - Nothing else. The number of workers is handed in (and changed by
    AddWorkerSlot / RemoveWorkerSlot).

  Responsibilities
  ----------------
  - Hand the most urgent waiting job to a worker (TakeNext). Equal
    priorities go first come, first served.
  - Move finished jobs to the done list (Finish), from where the UI
    thread collects them (TakeDone).
  - Cancel jobs that are no longer wanted (CancelAllExcept).
  - Reconcile (spec §5.3): make the jobs match a "wanted set" - drop
    waiting jobs nobody wants any more, cancel running ones, promote
    jobs that are still wanted, add what is missing.
  - Keep one worker free for the current image (spec §5.4): TakeNext
    hands out a non-display job only if another worker stays idle.
    With a single worker, Reconcile instead cancels a running
    background job when a display job is waiting.
  - Report counts for the diagnostics line, whether a file has an
    active job, and give up all jobs at shutdown (TakeAll, Forget).

  Does NOT
  --------
  - Decode, deliver results or free running jobs.
  - Start or stop threads (uJobScheduler).

  Threads
  -------
  TakeNext, Finish and TDecodeJob.WorkerCancelCheck run on worker
  threads; everything else on the UI thread. The three lists are only
  touched under FLock. A job's Priority is changed only under the
  lock. The cancel flag uses Interlocked* calls, so Cancel and
  IsCancelled are safe from any thread. AliveTick is written by the
  worker and read by the UI thread (atomic on x64).

  Uses (MView units)
  ------------------
  interface:      uTypes, uDecodedImage
  Libraries:      Classes, SysUtils, SyncObjs

  Used by
  -------
  uJobScheduler, uMView

  Job lifetime (important)
  ------------------------
  A job is created on the UI thread and freed on the UI thread only:
  - waiting jobs that get cancelled are freed at once (no worker has
    seen them), by the UI thread that cancels them;
  - running jobs are only flagged; the worker finishes them, puts them
    on the done list, and the UI thread frees them after delivery.
  So a worker never frees a job, and a job is never freed while a
  worker uses it.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  uTypes,
  uDecodedImage;

type

  { Lower ordinal = more urgent (spec §5.2). }
  TJobPriority = (jpDisplay, jpRefine, jpAhead, jpBehind);

  { One entry of the wanted set. }
  TWantedItem = record
    FileName: string;
    Quality: TQualityLevel;
    Priority: TJobPriority;
  end;
  TWantedItems = array of TWantedItem;

  TDecodeJob = class(TObject)
  private
    FFileName: string;
    FQuality: TQualityLevel;
    FPriority: TJobPriority;
    FPriorityRead: Boolean;      { started as a display job }
    FPreviewWidth: Integer;
    FPreviewHeight: Integer;
    FCancelled: LongInt;         { 0 or 1, only via Interlocked* }
    FAliveTick: QWord;           { GetTickCount64 of the worker's last cancel check }
    FImage: IDecodedImage;       { set by the worker }
  public
    constructor Create(const AFileName: string; AQuality: TQualityLevel;
      APriority: TJobPriority; APreviewWidth, APreviewHeight: Integer);

    { Safe from any thread. }
    procedure Cancel;
    function IsCancelled: Boolean;
    { The cancel check handed to the loader (worker thread): also notes
      that the worker is alive, i.e. not stuck in a read (Day 19). }
    function WorkerCancelCheck: Boolean;
    { When the worker last came back to check; set when it takes the
      job. A 64-bit value written by the worker, read by the UI thread
      (atomic on x64). }
    property AliveTick: QWord read FAliveTick;

    property FileName: string read FFileName;
    property Quality: TQualityLevel read FQuality;
    { Changed only under the queue's lock. }
    property Priority: TJobPriority read FPriority write FPriority;
    { Set when a worker takes the job: it was a display job then, so
      the file is read with the I/O gate raised. }
    property PriorityRead: Boolean read FPriorityRead;
    property PreviewWidth: Integer read FPreviewWidth;
    property PreviewHeight: Integer read FPreviewHeight;
    property Image: IDecodedImage read FImage write FImage;
  end;

  TJobQueue = class(TObject)
  private
    FLock: TCriticalSection;
    FWaiting: TFPList;
    FRunning: TFPList;
    FDone: TFPList;
    FWorkerCount: Integer;

    function Matches(AJob: TDecodeJob; const AItem: TWantedItem): Boolean;
  public
    constructor Create(AWorkerCount: Integer);
    destructor Destroy; override;

    { UI thread: adds a new job. }
    procedure Add(AJob: TDecodeJob);

    { Worker thread: the most urgent waiting job, now counted as
      running; nil if none, or if the only jobs left are background
      jobs and taking one would leave no worker free (spec §5.4). }
    function TakeNext: TDecodeJob;

    { UI thread: makes the jobs match AWanted (spec §5.3). Returns the
      number of new jobs. }
    function Reconcile(const AWanted: TWantedItems;
      APreviewWidth, APreviewHeight: Integer): Integer;

    { Numbers for the diagnostics line. }
    procedure GetCounts(out AWaiting, ARunning: Integer);

    { Worker thread: the job is finished (or was cancelled). }
    procedure Finish(AJob: TDecodeJob);

    { UI thread: moves all finished jobs into AList. The caller frees
      them. }
    procedure TakeDone(AList: TFPList);

    { UI thread: True if a job for this file is waiting or running and
      not cancelled. }
    function HasActive(const AFileName: string): Boolean;

    { UI thread: cancels every job whose file is not AFileName ('' =
      all). Waiting ones are freed at once, running ones only flagged. }
    procedure CancelAllExcept(const AFileName: string);

    { UI thread, after all workers have stopped: moves every remaining
      job into AList. }
    procedure TakeAll(AList: TFPList);

    { UI thread: one more / one less worker (a stuck worker was
      replaced / has come back and left). Keeps the reserved-worker
      rule right. }
    procedure AddWorkerSlot;
    procedure RemoveWorkerSlot;

    { UI thread, at shutdown: forget a job a stuck worker still holds,
      so TakeAll doesn't free it under that worker. }
    procedure Forget(AJob: TDecodeJob);
  end;

implementation

{ TDecodeJob }

constructor TDecodeJob.Create(const AFileName: string; AQuality: TQualityLevel;
  APriority: TJobPriority; APreviewWidth, APreviewHeight: Integer);
begin
  inherited Create;
  FFileName := AFileName;
  FQuality := AQuality;
  FPriority := APriority;
  FPriorityRead := False;
  FPreviewWidth := APreviewWidth;
  FPreviewHeight := APreviewHeight;
  FCancelled := 0;
  FImage := nil;
end;

procedure TDecodeJob.Cancel;
begin
  InterlockedExchange(FCancelled, 1);
end;

function TDecodeJob.IsCancelled: Boolean;
begin
  { CompareExchange with equal values reads the flag atomically. }
  Result := InterlockedCompareExchange(FCancelled, 0, 0) <> 0;
end;

function TDecodeJob.WorkerCancelCheck: Boolean;
begin
  FAliveTick := GetTickCount64;
  Result := IsCancelled;
end;

{ TJobQueue }

constructor TJobQueue.Create(AWorkerCount: Integer);
begin
  inherited Create;
  if AWorkerCount < 1 then
    AWorkerCount := 1;
  FWorkerCount := AWorkerCount;
  FLock := TCriticalSection.Create;
  FWaiting := TFPList.Create;
  FRunning := TFPList.Create;
  FDone := TFPList.Create;
end;

destructor TJobQueue.Destroy;
var
  All: TFPList;
  I: Integer;
begin
  { Normally empty by now (the scheduler takes everything at shutdown). }
  All := TFPList.Create;
  try
    TakeAll(All);
    for I := 0 to All.Count - 1 do
      TDecodeJob(All[I]).Free;
  finally
    All.Free;
  end;
  FDone.Free;
  FRunning.Free;
  FWaiting.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TJobQueue.Add(AJob: TDecodeJob);
begin
  FLock.Acquire;
  try
    FWaiting.Add(AJob);
  finally
    FLock.Release;
  end;
end;

function TJobQueue.TakeNext: TDecodeJob;
var
  I, Best: Integer;
  Job: TDecodeJob;
begin
  Result := nil;
  FLock.Acquire;
  try
    Best := -1;
    I := 0;
    while I < FWaiting.Count do
    begin
      Job := TDecodeJob(FWaiting[I]);
      if Job.IsCancelled then
      begin
        { Normally already removed by CancelAllExcept; just in case. }
        FWaiting.Delete(I);
        FDone.Add(Job);
        Continue;
      end;
      { Strictly more urgent wins, so equal priorities keep their
        order (first come, first served). }
      if (Best < 0) or (Job.Priority < TDecodeJob(FWaiting[Best]).Priority) then
        Best := I;
      Inc(I);
    end;

    { Spec §5.4: a background job only if one other worker stays free
      for the current image. With a single worker there is nothing to
      keep free; Reconcile cancels its background job instead. }
    if (Best >= 0) and (FWorkerCount > 1)
      and (TDecodeJob(FWaiting[Best]).Priority <> jpDisplay)
      and (FWorkerCount - FRunning.Count < 2) then
      Best := -1;

    if Best >= 0 then
    begin
      Result := TDecodeJob(FWaiting[Best]);
      FWaiting.Delete(Best);
      FRunning.Add(Result);
      Result.FPriorityRead := Result.Priority = jpDisplay;
      Result.FAliveTick := GetTickCount64;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.Finish(AJob: TDecodeJob);
begin
  FLock.Acquire;
  try
    FRunning.Remove(AJob);
    FDone.Add(AJob);
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.TakeDone(AList: TFPList);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FDone.Count - 1 do
      AList.Add(FDone[I]);
    FDone.Clear;
  finally
    FLock.Release;
  end;
end;

function TJobQueue.HasActive(const AFileName: string): Boolean;
var
  I: Integer;
  Job: TDecodeJob;
begin
  Result := False;
  FLock.Acquire;
  try
    for I := 0 to FWaiting.Count - 1 do
    begin
      Job := TDecodeJob(FWaiting[I]);
      if (not Job.IsCancelled) and SameText(Job.FileName, AFileName) then
        Exit(True);
    end;
    for I := 0 to FRunning.Count - 1 do
    begin
      Job := TDecodeJob(FRunning[I]);
      if (not Job.IsCancelled) and SameText(Job.FileName, AFileName) then
        Exit(True);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.CancelAllExcept(const AFileName: string);
var
  I: Integer;
  Job: TDecodeJob;
  Obsolete: TFPList;
begin
  Obsolete := TFPList.Create;
  try
    FLock.Acquire;
    try
      I := 0;
      while I < FWaiting.Count do
      begin
        Job := TDecodeJob(FWaiting[I]);
        if (AFileName = '') or not SameText(Job.FileName, AFileName) then
        begin
          Job.Cancel;
          FWaiting.Delete(I);
          Obsolete.Add(Job);
        end
        else
          Inc(I);
      end;

      for I := 0 to FRunning.Count - 1 do
      begin
        Job := TDecodeJob(FRunning[I]);
        if (AFileName = '') or not SameText(Job.FileName, AFileName) then
          Job.Cancel;
      end;
    finally
      FLock.Release;
    end;

    { No worker has seen these; free them outside the lock. }
    for I := 0 to Obsolete.Count - 1 do
      TDecodeJob(Obsolete[I]).Free;
  finally
    Obsolete.Free;
  end;
end;

function TJobQueue.Matches(AJob: TDecodeJob; const AItem: TWantedItem): Boolean;
begin
  Result := (AJob.Quality = AItem.Quality) and SameText(AJob.FileName, AItem.FileName);
end;

function TJobQueue.Reconcile(const AWanted: TWantedItems;
  APreviewWidth, APreviewHeight: Integer): Integer;
var
  I, J: Integer;
  Job: TDecodeJob;
  Found: Boolean;
  Obsolete, NewWaiting: TFPList;
  DisplayRunning: Boolean;
begin
  Result := 0;
  Obsolete := TFPList.Create;
  NewWaiting := TFPList.Create;
  try
    FLock.Acquire;
    try
      { Running jobs: promote the wanted ones (don't restart them),
        cancel the others. }
      for I := 0 to FRunning.Count - 1 do
      begin
        Job := TDecodeJob(FRunning[I]);
        if Job.IsCancelled then
          Continue;
        Found := False;
        for J := 0 to High(AWanted) do
          if Matches(Job, AWanted[J]) then
          begin
            Job.Priority := AWanted[J].Priority;
            Found := True;
            Break;
          end;
        if not Found then
          Job.Cancel;
      end;

      { Waiting jobs, rebuilt in the order of the wanted set (nearest
        first), so equal priorities run in that order. }
      for J := 0 to High(AWanted) do
      begin
        { Already running? Nothing to add. }
        Found := False;
        for I := 0 to FRunning.Count - 1 do
        begin
          Job := TDecodeJob(FRunning[I]);
          if (not Job.IsCancelled) and Matches(Job, AWanted[J]) then
          begin
            Found := True;
            Break;
          end;
        end;
        if Found then
          Continue;

        { Waiting already? Keep that job, with the new priority. }
        Job := nil;
        for I := 0 to FWaiting.Count - 1 do
          if (FWaiting[I] <> nil)
            and not TDecodeJob(FWaiting[I]).IsCancelled
            and Matches(TDecodeJob(FWaiting[I]), AWanted[J]) then
          begin
            Job := TDecodeJob(FWaiting[I]);
            FWaiting[I] := nil;   { taken over into NewWaiting }
            Break;
          end;

        { Listed twice in the wanted set? Only once in the queue. }
        if Job = nil then
          for I := 0 to NewWaiting.Count - 1 do
            if Matches(TDecodeJob(NewWaiting[I]), AWanted[J]) then
            begin
              Found := True;
              Break;
            end;
        if Found then
          Continue;

        if Job = nil then
        begin
          Job := TDecodeJob.Create(AWanted[J].FileName, AWanted[J].Quality,
            AWanted[J].Priority, APreviewWidth, APreviewHeight);
          Inc(Result);
        end
        else
          Job.Priority := AWanted[J].Priority;
        NewWaiting.Add(Job);
      end;

      { What is left in the old waiting list is no longer wanted. No
        worker has seen those jobs, so they can simply go. }
      for I := 0 to FWaiting.Count - 1 do
        if FWaiting[I] <> nil then
        begin
          TDecodeJob(FWaiting[I]).Cancel;
          Obsolete.Add(FWaiting[I]);
        end;
      FWaiting.Clear;
      for I := 0 to NewWaiting.Count - 1 do
        FWaiting.Add(NewWaiting[I]);

      { Single worker (spec §5.4): a waiting display job must not wait
        behind a background job for another image. }
      if FWorkerCount = 1 then
      begin
        DisplayRunning := False;
        Found := False;
        for I := 0 to FWaiting.Count - 1 do
          if TDecodeJob(FWaiting[I]).Priority = jpDisplay then
            Found := True;
        for I := 0 to FRunning.Count - 1 do
          if (not TDecodeJob(FRunning[I]).IsCancelled)
            and (TDecodeJob(FRunning[I]).Priority = jpDisplay) then
            DisplayRunning := True;
        if Found and not DisplayRunning then
          for I := 0 to FRunning.Count - 1 do
            TDecodeJob(FRunning[I]).Cancel;
      end;
    finally
      FLock.Release;
    end;

    for I := 0 to Obsolete.Count - 1 do
      TDecodeJob(Obsolete[I]).Free;
  finally
    NewWaiting.Free;
    Obsolete.Free;
  end;
end;

procedure TJobQueue.GetCounts(out AWaiting, ARunning: Integer);
begin
  FLock.Acquire;
  try
    AWaiting := FWaiting.Count;
    ARunning := FRunning.Count;
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.AddWorkerSlot;
begin
  FLock.Acquire;
  try
    Inc(FWorkerCount);
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.RemoveWorkerSlot;
begin
  FLock.Acquire;
  try
    if FWorkerCount > 1 then
      Dec(FWorkerCount);
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.Forget(AJob: TDecodeJob);
begin
  FLock.Acquire;
  try
    FWaiting.Remove(AJob);
    FRunning.Remove(AJob);
    FDone.Remove(AJob);
  finally
    FLock.Release;
  end;
end;

procedure TJobQueue.TakeAll(AList: TFPList);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FWaiting.Count - 1 do
      AList.Add(FWaiting[I]);
    for I := 0 to FRunning.Count - 1 do
      AList.Add(FRunning[I]);
    for I := 0 to FDone.Count - 1 do
      AList.Add(FDone[I]);
    FWaiting.Clear;
    FRunning.Clear;
    FDone.Clear;
  finally
    FLock.Release;
  end;
end;

end.
