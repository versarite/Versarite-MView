unit uFileMover;

{
  Unit: uFileMover

  Purpose
  -------
  Copies and moves image files for sorting (Phase G, G1): into the sort
  panel's folders, into the deleted-files folder, and back again for
  Undo. On a thread of its own, so copying a 300 MB TIFF or moving it to
  another drive never freezes the window (spec §2). Also writes the
  icon files MView makes (faWrite, "Make icon from this image"): an
  older file of that name is renamed to <name>_previous, never
  overwritten.

  Owns
  ----
  - The mover thread (TFileMoverThread) and its job queue (FJobs, under
    FLock, with the FWake event).
  - The finished results not yet handed to the UI thread (FDone, under
    FLock).

  Knows
  -----
  - OnDone: the owner's handler (TMView), called on the UI thread for
    every finished job, in order.
  - The log file named at Create (sorting.log next to MView.exe).

  Responsibilities
  ----------------
  - Run jobs one after the other, in the order they were added (so an
    Undo always follows the action it undoes).
  - Never overwrite: a name that exists in the target folder gets _1,
    _2 ... before the extension (UniqueFileName).
  - Copy keeps the file's date. Move is a rename on the same drive and
    a copy + delete of the source across drives (Windows MoveFileEx with
    MOVEFILE_COPY_ALLOWED).
  - A file still open for reading (a decode worker, the scanner, a
    virus scanner) is tried again for up to 2 s before the job fails.
  - A missing target folder fails the job, unless the job allows
    creating it (the deleted-files folder does; sort folders don't, so a
    typo never creates a folder).
  - One line per job in the log: time; copy / move; from; to; ok or the
    reason. Log errors are ignored.
  - Hand each result to the UI thread (TThread.Queue); the owner's
    delivery safety net (CheckSynchronize) also picks them up.

  Does NOT
  --------
  - Delete a file for good. MView never does (Delete is a move into the
    deleted-files folder; undoing a copy moves the copy there too).
  - Know about the navigator, the cache or the panel (TMView updates
    them from the results).
  - Check a job's sense (the caller decides what to copy where).

  Threads
  -------
  Add, Busy and Destroy run on the UI thread; the jobs run on the mover
  thread; OnDone runs on the UI thread. FJobs and FDone are guarded by
  FLock. ExecuteFileJob and UniqueFileName are plain functions (also
  used by the tests, on any thread).

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
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
  SyncObjs;

type

  { faWrite (stage 2, "Make icon"): Data is written as TargetName; a
    file of that name is first renamed to <name>_previous<ext> (or
    _previous_1 ...), never overwritten. }
  TFileAction = (faCopy, faMove, faWrite);

  { What a job is for; the mover only passes it on. }
  TFileJobKind = (fjSort, fjDelete, fjUndo, fjIcon);

  TFileJob = record
    Action: TFileAction;
    Kind: TFileJobKind;
    Source: string;         { the file }
    TargetDir: string;      { the folder it goes into }
    TargetName: string;     { name there; '' = the source's name }
    CreateTarget: Boolean;  { create TargetDir if missing }
    Slot: Integer;          { the sort slot (fjSort), else -1 }
    Caption: string;        { for messages, e.g. the slot's name }
    UndoOf: Integer;        { fjUndo: the undo entry's id }
    Id: Integer;            { the caller's number for this job }
    Data: TBytes;           { faWrite: the file's content }
  end;

  TFileJobResult = record
    Job: TFileJob;
    OK: Boolean;
    ResultFile: string;     { the file written (copy) or its new place (move) }
    Message: string;        { the reason, if not OK }
    Size: Int64;            { of ResultFile }
    Modified: TDateTime;    { of ResultFile }
    { A move to another drive: the copy is there, but the original
      could not be removed (in use). OK is True: treat it as a copy. }
    KeptSource: Boolean;
    { faWrite: the old file of that name, renamed ('' = there was none). }
    RenamedTo: string;
  end;

  TFileJobDone = procedure(const AResult: TFileJobResult) of object;

  TFileMover = class;

  TFileMoverThread = class(TThread)
  private
    FOwner: TFileMover;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TFileMover);
  end;

  TFileMover = class(TObject)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FJobs: array of TFileJob;
    FDone: array of TFileJobResult;
    FRunning: Boolean;
    FThread: TFileMoverThread;
    FLogFile: string;
    FOnDone: TFileJobDone;
    function TakeJob(out AJob: TFileJob): Boolean;
    procedure PutResult(const AResult: TFileJobResult);
    procedure Deliver;
  public
    constructor Create(const ALogFile: string);
    { Waits for the job being done (a copy can't be interrupted
      halfway without leaving half a file); jobs not started are
      dropped. }
    destructor Destroy; override;

    procedure Add(const AJob: TFileJob);
    { A job waiting or running. }
    function Busy: Boolean;

    property OnDone: TFileJobDone read FOnDone write FOnDone;
  end;

{ AName in ADir, or with _1, _2 ... before the extension if that exists
  (file or folder). ADir with or without trailing delimiter. }
function UniqueFileName(const ADir, AName: string): string;

{ Does AJob now, on the calling thread; ALogFile '' = no log. }
function ExecuteFileJob(const AJob: TFileJob; const ALogFile: string): TFileJobResult;

implementation

{$IFDEF WINDOWS}
const
  MOVEFILE_COPY_ALLOWED_FLAG = $2;
  MOVEFILE_WRITE_THROUGH_FLAG = $8;
  ERROR_ACCESS_DENIED_CODE = 5;
  ERROR_SHARING_VIOLATION_CODE = 32;
  ERROR_LOCK_VIOLATION_CODE = 33;

function MViewCopyFileW(AExisting, ANew: PWideChar; AFailIfExists: LongBool): LongBool;
  stdcall; external 'kernel32.dll' name 'CopyFileW';
function MViewMoveFileExW(AExisting, ANew: PWideChar; AFlags: LongWord): LongBool;
  stdcall; external 'kernel32.dll' name 'MoveFileExW';
{$ENDIF}

const
  RetryCount = 20;
  RetryWaitMs = 100;

function UniqueFileName(const ADir, AName: string): string;
var
  Dir, Base, Ext: string;
  N: Integer;
begin
  Dir := IncludeTrailingPathDelimiter(ADir);
  Result := Dir + AName;
  if not (FileExists(Result) or DirectoryExists(Result)) then
    Exit;
  Ext := ExtractFileExt(AName);
  Base := Copy(AName, 1, Length(AName) - Length(Ext));
  N := 1;
  repeat
    Result := Dir + Base + '_' + IntToStr(N) + Ext;
    Inc(N);
  until not (FileExists(Result) or DirectoryExists(Result));
end;

procedure AppendLog(const ALogFile: string; const R: TFileJobResult);
var
  F: TextFile;
  Action, Outcome: string;
begin
  if ALogFile = '' then
    Exit;
  case R.Job.Action of
    faCopy:  Action := 'copy';
    faMove:  Action := 'move';
  else
    Action := 'write';
  end;
  case R.Job.Kind of
    fjDelete: Action := Action + ' (delete)';
    fjUndo:   Action := Action + ' (undo)';
    fjIcon:   Action := Action + ' (icon)';
  end;
  if R.OK and (R.RenamedTo <> '') then
    Outcome := 'ok; the one before is now ' + ExtractFileName(R.RenamedTo)
  else if R.OK and R.KeptSource then
    Outcome := 'copied; the original could not be removed (in use)'
  else if R.OK then
    Outcome := 'ok'
  else
    Outcome := R.Message;
  try
    AssignFile(F, ALogFile);
    if FileExists(ALogFile) then
      Append(F)
    else
    begin
      Rewrite(F);
      WriteLn(F, 'sep=;');
      WriteLn(F, 'time;action;from;to;result');
    end;
    try
      WriteLn(F, Format('%s;%s;"%s";"%s";%s',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), Action, R.Job.Source,
         R.ResultFile, Outcome]));
    finally
      CloseFile(F);
    end;
  except
    { A locked or read-only log must not stop the sorting. }
  end;
end;

{ Plain copy for systems without CopyFile: keeps the date. }
function StreamCopy(const ASource, ATarget: string): Boolean;
var
  Src, Dst: TFileStream;
  Age: LongInt;
begin
  Result := False;
  Src := TFileStream.Create(ASource, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(ATarget, fmCreate);
    try
      Dst.CopyFrom(Src, 0);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
  Age := FileAge(ASource);
  if Age <> -1 then
    FileSetDate(ATarget, Age);
  Result := True;
end;

{ One attempt; AError = the OS error code, 0 for other failures. }
function TryOnce(const AJob: TFileJob; const ASource, ATarget: string; out AError: Integer): Boolean;
begin
  AError := 0;
  {$IFDEF WINDOWS}
  if AJob.Action = faCopy then
    Result := MViewCopyFileW(PWideChar(UTF8Decode(ASource)), PWideChar(UTF8Decode(ATarget)), True)
  else
    Result := MViewMoveFileExW(PWideChar(UTF8Decode(ASource)), PWideChar(UTF8Decode(ATarget)),
      MOVEFILE_COPY_ALLOWED_FLAG or MOVEFILE_WRITE_THROUGH_FLAG);
  if not Result then
    AError := GetLastOSError;
  {$ELSE}
  try
    if AJob.Action = faCopy then
      Result := StreamCopy(ASource, ATarget)
    else
    begin
      Result := RenameFile(ASource, ATarget);
      if not Result then
      begin
        Result := StreamCopy(ASource, ATarget);
        if Result then
          Result := SysUtils.DeleteFile(ASource);
      end;
    end;
  except
    Result := False;
  end;
  if not Result then
    AError := GetLastOSError;
  {$ENDIF}
end;

function IsTransient(AError: Integer): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := (AError = ERROR_SHARING_VIOLATION_CODE) or (AError = ERROR_LOCK_VIOLATION_CODE)
    or (AError = ERROR_ACCESS_DENIED_CODE);
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{ faWrite: the old file (if any) steps aside as <name>_previous<ext>. }
procedure WriteNewFile(const AJob: TFileJob; var AResult: TFileJobResult);
var
  Target, Previous, Ext: string;
  Stream: TFileStream;
  Try_: Integer;
  Info: TSearchRec;
begin
  try
    if (not DirectoryExists(AJob.TargetDir))
      and not (AJob.CreateTarget and ForceDirectories(AJob.TargetDir)) then
    begin
      AResult.Message := 'folder not found: ' + AJob.TargetDir;
      Exit;
    end;
    Target := IncludeTrailingPathDelimiter(AJob.TargetDir) + AJob.TargetName;
    if FileExists(Target) then
    begin
      Ext := ExtractFileExt(AJob.TargetName);
      Previous := UniqueFileName(AJob.TargetDir,
        Copy(AJob.TargetName, 1, Length(AJob.TargetName) - Length(Ext)) + '_previous' + Ext);
      for Try_ := 1 to RetryCount do
      begin
        if RenameFile(Target, Previous) then
          Break;
        Sleep(RetryWaitMs);
      end;
      if FileExists(Target) then
      begin
        AResult.Message := 'the old ' + AJob.TargetName + ' could not be renamed (in use?)';
        Exit;
      end;
      AResult.RenamedTo := Previous;
    end;
    try
      Stream := TFileStream.Create(Target, fmCreate);
      try
        if Length(AJob.Data) > 0 then
          Stream.WriteBuffer(AJob.Data[0], Length(AJob.Data));
      finally
        Stream.Free;
      end;
    except
      { Not written: the old one gets its name back (slots find it by
        name). }
      if AResult.RenamedTo <> '' then
      begin
        SysUtils.DeleteFile(Target);   { a half-written new file, ours }
        if RenameFile(AResult.RenamedTo, Target) then
          AResult.RenamedTo := '';
      end;
      raise;
    end;
    AResult.OK := True;
    AResult.ResultFile := Target;
    if FindFirst(Target, faAnyFile, Info) = 0 then
    begin
      AResult.Size := Info.Size;
      AResult.Modified := FileDateToDateTime(Info.Time);
      FindClose(Info);
    end;
  except
    on E: Exception do
      AResult.Message := E.Message;
  end;
end;

function ExecuteFileJob(const AJob: TFileJob; const ALogFile: string): TFileJobResult;
var
  Name, Target: string;
  Err, Try_: Integer;
  Done: Boolean;
  Info: TSearchRec;
begin
  Result.Job := AJob;
  Result.OK := False;
  Result.ResultFile := '';
  Result.Message := '';
  Result.Size := 0;
  Result.Modified := 0;
  Result.KeptSource := False;
  Result.RenamedTo := '';
  if AJob.Action = faWrite then
  begin
    WriteNewFile(AJob, Result);
    AppendLog(ALogFile, Result);
    Exit;
  end;
  try
    if not FileExists(AJob.Source) then
      Result.Message := 'the file is not there any more'
    else if (not DirectoryExists(AJob.TargetDir))
      and not (AJob.CreateTarget and ForceDirectories(AJob.TargetDir)) then
      Result.Message := 'folder not found: ' + AJob.TargetDir
    else
    begin
      Name := AJob.TargetName;
      if Name = '' then
        Name := ExtractFileName(AJob.Source);
      Target := UniqueFileName(AJob.TargetDir, Name);
      Done := False;
      Err := 0;
      for Try_ := 1 to RetryCount do
      begin
        Done := TryOnce(AJob, AJob.Source, Target, Err);
        if Done or not IsTransient(Err) then
          Break;
        Sleep(RetryWaitMs);
      end;
      { A move to another drive is a copy and a delete; Windows reports
        success even when the delete failed (the file was in use). Try
        the delete again for a while, else say so. }
      if Done and (AJob.Action = faMove) and FileExists(AJob.Source) then
        for Try_ := 1 to RetryCount do
        begin
          if SysUtils.DeleteFile(AJob.Source) or not FileExists(AJob.Source) then
            Break;
          Sleep(RetryWaitMs);
        end;
      if Done and (AJob.Action = faMove) and FileExists(AJob.Source) then
        Result.KeptSource := True;
      if Done then
      begin
        Result.OK := True;
        Result.ResultFile := Target;
        if FindFirst(Target, faAnyFile, Info) = 0 then
        begin
          Result.Size := Info.Size;
          Result.Modified := FileDateToDateTime(Info.Time);
          FindClose(Info);
        end;
      end
      else if Err <> 0 then
        Result.Message := SysErrorMessage(Err)
      else
        Result.Message := 'failed';
    end;
  except
    on E: Exception do
      Result.Message := E.Message;
  end;
  AppendLog(ALogFile, Result);
end;

{ TFileMoverThread }

constructor TFileMoverThread.Create(AOwner: TFileMover);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TFileMoverThread.Execute;
var
  Job: TFileJob;
begin
  while not Terminated do
  begin
    if FOwner.TakeJob(Job) then
    begin
      FOwner.PutResult(ExecuteFileJob(Job, FOwner.FLogFile));
      Queue(@FOwner.Deliver);
    end
    else
      FOwner.FWake.WaitFor(250);
  end;
end;

{ TFileMover }

constructor TFileMover.Create(const ALogFile: string);
begin
  inherited Create;
  FLogFile := ALogFile;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FThread := TFileMoverThread.Create(Self);
end;

destructor TFileMover.Destroy;
begin
  FLock.Acquire;
  try
    FJobs := nil;          { not started: dropped }
  finally
    FLock.Release;
  end;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    FWake.SetEvent;
    FThread.WaitFor;
    TThread.RemoveQueuedEvents(FThread);
    FThread.Free;
  end;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFileMover.Add(const AJob: TFileJob);
begin
  FLock.Acquire;
  try
    SetLength(FJobs, Length(FJobs) + 1);
    FJobs[High(FJobs)] := AJob;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TFileMover.Busy: Boolean;
begin
  FLock.Acquire;
  try
    Result := FRunning or (Length(FJobs) > 0) or (Length(FDone) > 0);
  finally
    FLock.Release;
  end;
end;

function TFileMover.TakeJob(out AJob: TFileJob): Boolean;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FJobs) > 0;
    if Result then
    begin
      AJob := FJobs[0];
      for I := 0 to High(FJobs) - 1 do
        FJobs[I] := FJobs[I + 1];
      SetLength(FJobs, Length(FJobs) - 1);
      FRunning := True;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TFileMover.PutResult(const AResult: TFileJobResult);
begin
  FLock.Acquire;
  try
    SetLength(FDone, Length(FDone) + 1);
    FDone[High(FDone)] := AResult;
    FRunning := False;
  finally
    FLock.Release;
  end;
end;

{ UI thread: hands every finished result to OnDone, oldest first. }
procedure TFileMover.Deliver;
var
  Results: array of TFileJobResult;
  I: Integer;
begin
  FLock.Acquire;
  try
    Results := FDone;
    FDone := nil;
  finally
    FLock.Release;
  end;
  if Assigned(FOnDone) then
    for I := 0 to High(Results) do
      FOnDone(Results[I]);
end;

end.
