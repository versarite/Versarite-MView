unit uDirectoryScanner;

{
  Unit: uDirectoryScanner

  Purpose
  -------
  The scanner thread (spec §4.1, §5.1). Everything the viewer needs to
  know about folders comes from here, so the UI thread never reads a
  folder itself (Day 19: a slow or hung disk must not freeze the
  window; spec §10 "the navigator never touches the disk").

  Owns
  ----
  - The thread, its lock (FLock) and wake-up event (FWakeUp).
  - Finished results (FResultStart, FResultTree) until the UI thread
    takes them, and the TDirectoryTree being built.
  - TScanStart owns its Listing (the start folder's images).

  Knows
  -----
  - TNavigator.ChooseRoot and IsInside (class functions; no navigator
    object is used).
  - IOGate, the global I/O gate.
  - The OnStartReady and OnTreeReady handlers of the owner (TMView);
    they take ownership of what they are given.

  Responsibilities
  ----------------
  For each request (a file or folder to open, and optionally a file to
  resume on):
  1. Resolve it: file or folder, the navigation root (TNavigator.
     ChooseRoot), the folder and file to start on. Deliver TScanStart
     with the start folder's image list (OnStartReady), or "not found".
  2. Build the directory tree under the root, collecting every
     folder's image list on the way. Deliver it (OnTreeReady). If an
     opened file's folder is not in the tree (a link or a system
     folder), that folder becomes the root.
  - The newest request wins: an obsolete scan stops early and its
    results are thrown away. Every result carries its generation.
  - Deliveries go to the UI thread with TThread.Queue (spec §5.7); the
    receiver takes ownership. Nothing is touched by the scanner after
    it is handed over (spec §2.4).
  - Stuck detection: LastAliveAgeMs says how long the thread has not
    come back from the file system. The owner can abandon a stuck
    scanner (Abandon) and start a new one; the old thread is never
    waited for or freed then.
  - Shut down cleanly (spec §5.8).

  Does NOT
  --------
  - Decide what the user sees.
  - Touch the navigator or the GUI.

  Threads
  -------
  Execute, Resolve, ScanCancelled and Alive run on the scanner thread.
  Request, LastAliveAgeMs, Abandon, Shutdown and the queued
  DeliverStart / DeliverTree run on the UI thread. The request, the
  results, the generations and the alive time are guarded by FLock.
  FWorkingGeneration is scanner thread only; the event handlers and
  FShuttingDown are UI thread only. A tree is not delivered while a
  newer request's start is still waiting to be delivered.

  Uses (MView units)
  ------------------
  interface:      uDirectoryTree, uDirectoryImages, uNavigator,
                  uIOGate
  Libraries:      Classes, SysUtils, SyncObjs

  Used by
  -------
  uMView

  I/O gate
  --------
  The I/O gate (spec §5.5): between folders the scanner waits while
  the file of the current image is being read (uIOGate).
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  uDirectoryTree,
  uDirectoryImages,
  uNavigator,
  uIOGate;

type

  { The start of a request: what to open. Handed to the UI thread. }
  TScanStart = class(TObject)
  public
    Generation: Cardinal;
    RequestedPath: string;
    Found: Boolean;
    Root: string;
    TargetDirectory: string;
    TargetFile: string;          { '' = the first image }
    Listing: TDirectoryImages;   { owned; the start folder's images }
    destructor Destroy; override;
  end;

  TStartReadyEvent = procedure(AStart: TScanStart) of object;
  TTreeReadyEvent = procedure(ATree: TDirectoryTree; AGeneration: Cardinal) of object;

  TDirectoryScanner = class(TThread)
  private
    FLock: TCriticalSection;
    FWakeUp: TEvent;

    { Guarded by FLock }
    FLatestGeneration: Cardinal;
    FHasRequest: Boolean;
    FRequestPath: string;
    FRequestSelect: string;
    FRequestRecursive: Boolean;
    FResultStart: TScanStart;
    FResultTree: TDirectoryTree;
    FResultGeneration: Cardinal;
    FBusy: Boolean;
    FLastAlive: QWord;           { GetTickCount64 }

    { Scanner thread only }
    FWorkingGeneration: Cardinal;

    { UI thread only }
    FOnStartReady: TStartReadyEvent;
    FOnTreeReady: TTreeReadyEvent;
    FShuttingDown: Boolean;

    procedure Alive;
    function ScanCancelled: Boolean;
    function Resolve(const APath, ASelect: string; ARecursive: Boolean): TScanStart;
    procedure DeliverStart;
    procedure DeliverTree;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;

    { UI thread. Opens APath (file or folder); ASelectFile: a file to
      resume on inside a folder. Cancels any older request. Returns
      the generation number. }
    function Request(const APath, ASelectFile: string; ARecursive: Boolean): Cardinal;

    { UI thread: ms since the thread last came back from the file
      system while working on a request; 0 when idle. }
    function LastAliveAgeMs: QWord;

    { UI thread: give up on this scanner (stuck in the file system).
      No more deliveries; the thread is left to finish on its own and
      must not be freed or waited for. }
    procedure Abandon;

    { UI thread. Stops the thread and waits for it. Safe to call more
      than once. }
    procedure Shutdown;

    property OnStartReady: TStartReadyEvent read FOnStartReady write FOnStartReady;
    property OnTreeReady: TTreeReadyEvent read FOnTreeReady write FOnTreeReady;
  end;

implementation

const
  IdleWaitMs = 200;

{ TScanStart }

destructor TScanStart.Destroy;
begin
  Listing.Free;
  inherited Destroy;
end;

{ TDirectoryScanner }

constructor TDirectoryScanner.Create;
begin
  FLock := TCriticalSection.Create;
  FWakeUp := TEvent.Create(nil, False, False, '');
  FLatestGeneration := 0;
  FHasRequest := False;
  FResultStart := nil;
  FResultTree := nil;
  FBusy := False;
  FLastAlive := GetTickCount64;
  { Starts running after the constructor has finished. }
  inherited Create(False);
end;

destructor TDirectoryScanner.Destroy;
begin
  Shutdown;
  FreeAndNil(FResultStart);
  FreeAndNil(FResultTree);
  inherited Destroy;
  FWakeUp.Free;
  FLock.Free;
end;

function TDirectoryScanner.Request(const APath, ASelectFile: string; ARecursive: Boolean): Cardinal;
begin
  FLock.Acquire;
  try
    Inc(FLatestGeneration);
    FRequestPath := APath;
    FRequestSelect := ASelectFile;
    FRequestRecursive := ARecursive;
    FHasRequest := True;
    Result := FLatestGeneration;
  finally
    FLock.Release;
  end;
  FWakeUp.SetEvent;
end;

procedure TDirectoryScanner.Alive;
begin
  FLock.Acquire;
  try
    FLastAlive := GetTickCount64;
  finally
    FLock.Release;
  end;
end;

function TDirectoryScanner.LastAliveAgeMs: QWord;
begin
  FLock.Acquire;
  try
    if FBusy then
      Result := GetTickCount64 - FLastAlive
    else
      Result := 0;
  finally
    FLock.Release;
  end;
end;

{ Scanner thread, asked by TDirectoryTree.Build for every folder.
  Also the place where the scanner gives way to the current image: it
  waits while a display job reads its file (I/O gate, spec §5.5). }
function TDirectoryScanner.ScanCancelled: Boolean;
begin
  if Terminated then
    Exit(True);
  IOGate.WaitWhileRaised(1000);
  if Terminated then
    Exit(True);
  FLock.Acquire;
  try
    FLastAlive := GetTickCount64;
    Result := FWorkingGeneration <> FLatestGeneration;
  finally
    FLock.Release;
  end;
end;

{ Scanner thread: step 1 of a request. }
function TDirectoryScanner.Resolve(const APath, ASelect: string; ARecursive: Boolean): TScanStart;
var
  Path, SelectPath, SelectDirectory: string;
begin
  Result := TScanStart.Create;
  Result.RequestedPath := APath;
  Result.Found := False;
  Result.TargetFile := '';

  Path := ExcludeTrailingPathDelimiter(TNavigator.FullPath(APath));
  if DirectoryExists(Path) then
  begin
    Result.Found := True;
    Result.Root := Path;
    Result.TargetDirectory := Path;
    { Resume on a given file, if it lies inside this folder's tree. }
    if ASelect <> '' then
    begin
      SelectPath := TNavigator.FullPath(ASelect);
      SelectDirectory := ExcludeTrailingPathDelimiter(ExtractFileDir(SelectPath));
      if TNavigator.IsInside(SelectDirectory, Path) and FileExists(SelectPath) then
      begin
        Result.TargetFile := SelectPath;
        Result.TargetDirectory := SelectDirectory;
      end;
    end;
  end
  else if FileExists(Path) then
  begin
    Result.Found := True;
    Result.TargetFile := Path;
    Result.TargetDirectory := ExcludeTrailingPathDelimiter(ExtractFileDir(Path));
    Result.Root := TNavigator.ChooseRoot(Result.TargetDirectory, ARecursive);
  end;
  Alive;

  if Result.Found then
  begin
    Result.Listing := TDirectoryImages.Create;
    Result.Listing.Scan(Result.TargetDirectory);
    Alive;
  end;
end;

procedure TDirectoryScanner.Execute;
var
  HaveRequest, Recursive, Completed, Found: Boolean;
  Path, Select, Root, TargetDirectory, TargetFile: string;
  Opened: TScanStart;
  Tree: TDirectoryTree;
begin
  while not Terminated do
  begin
    FLock.Acquire;
    try
      HaveRequest := FHasRequest;
      if HaveRequest then
      begin
        Path := FRequestPath;
        Select := FRequestSelect;
        Recursive := FRequestRecursive;
        FWorkingGeneration := FLatestGeneration;
        FHasRequest := False;
        FBusy := True;
        FLastAlive := GetTickCount64;
      end
      else
        FBusy := False;
    finally
      FLock.Release;
    end;

    if not HaveRequest then
    begin
      FWakeUp.WaitFor(IdleWaitMs);
      Continue;
    end;

    { 1. What to open, and the start folder's images. }
    Opened := Resolve(Path, Select, Recursive);
    Opened.Generation := FWorkingGeneration;
    if ScanCancelled then
    begin
      Opened.Free;
      Continue;
    end;
    { Copies: once queued, Opened belongs to the UI thread and may be
      freed at any moment. }
    Found := Opened.Found;
    Root := Opened.Root;
    TargetDirectory := Opened.TargetDirectory;
    TargetFile := Opened.TargetFile;
    FLock.Acquire;
    try
      FreeAndNil(FResultStart);   { an older one the UI never took }
      FResultStart := Opened;
    finally
      FLock.Release;
    end;
    Opened := nil;
    Queue(@DeliverStart);
    if not Found then
      Continue;

    { 2. The tree, with every folder's images. }
    Tree := TDirectoryTree.Create;
    try
      Completed := Tree.Build(Root, Recursive, @ScanCancelled, True);

      { An opened file can sit in a folder the scan skips (a link or a
        system folder): then its own folder is the root. }
      if Completed and (TargetFile <> '')
        and (Tree.IndexOf(TargetDirectory) < 0) then
        Completed := Tree.Build(TargetDirectory, Recursive, @ScanCancelled, True);

      if Completed and not ScanCancelled then
      begin
        FLock.Acquire;
        try
          FreeAndNil(FResultTree);
          FResultTree := Tree;
          FResultGeneration := FWorkingGeneration;
          Tree := nil;
        finally
          FLock.Release;
        end;
        Queue(@DeliverTree);
      end;
    finally
      Tree.Free;   { nil if it was handed over }
    end;
  end;
end;

{ UI thread. }
procedure TDirectoryScanner.DeliverStart;
var
  Opened: TScanStart;
begin
  FLock.Acquire;
  try
    Opened := FResultStart;
    FResultStart := nil;
  finally
    FLock.Release;
  end;
  if Opened = nil then
    Exit;
  if (not FShuttingDown) and Assigned(FOnStartReady) then
    FOnStartReady(Opened)   { takes ownership }
  else
    Opened.Free;
end;

{ UI thread. }
procedure TDirectoryScanner.DeliverTree;
var
  Tree: TDirectoryTree;
  Generation: Cardinal;
begin
  FLock.Acquire;
  try
    { A newer request's start is still waiting to be delivered: its
      tree must not arrive before it (OpenListed would drop it). The
      tree's own queued delivery comes after the start's. }
    if FResultStart <> nil then
      Tree := nil
    else
    begin
      Tree := FResultTree;
      Generation := FResultGeneration;
      FResultTree := nil;
    end;
  finally
    FLock.Release;
  end;

  if Tree = nil then
    Exit;

  if (not FShuttingDown) and Assigned(FOnTreeReady) then
    FOnTreeReady(Tree, Generation)   { takes ownership }
  else
    Tree.Free;
end;

procedure TDirectoryScanner.Abandon;
begin
  FShuttingDown := True;
  FOnStartReady := nil;
  FOnTreeReady := nil;
  Terminate;
  FWakeUp.SetEvent;
  TThread.RemoveQueuedEvents(Self);
end;

procedure TDirectoryScanner.Shutdown;
begin
  if FShuttingDown then
    Exit;
  FShuttingDown := True;
  FOnStartReady := nil;
  FOnTreeReady := nil;

  Terminate;
  FWakeUp.SetEvent;
  WaitFor;
  TThread.RemoveQueuedEvents(Self);
end;

end.
