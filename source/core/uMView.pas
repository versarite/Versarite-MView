unit uMView;

{
  Unit: uMView

  Purpose
  -------
  Central application controller. TMView represents the application;
  the Windows GUI is represented by TMainForm (spec §4.1).

  Owns
  ----
  TConfig, TNavigator, TMediaLoader, TImageCache, TJobScheduler,
  TDirectoryScanner, TRenderer, and the current IDecodedImage.
  In detail:
  - FConfig (TConfig): loaded in Initialize, saved in the destructor.
  - FNavigator, FMediaLoader, FCache, FScheduler (with its decode
    workers), FScanner (the scanner thread).
  - FRenderer: a TCpuRenderer from the start, so it is never nil;
    replaced by the one the form attaches (AttachView), which is then
    owned here too.
  - FMouseProfile (TMouseProfile): the mouse profile file, read in
    Initialize (the surfaces get a copy).
  - FAbandonedScanners: scanners stuck in the file system, never
    freed (only the list is).
  - FSaveThread (TImageSaveThread): a "Save image" in progress.
  - Animation playback: FAnimTimer (TTimer), FAnimCursor, FAnimClock.
  - The lists FNoRoom and FNoPreview (TStringList).
  - The files startup.csv and timing.csv next to MView.exe (appended
    to with [Debug] TimingLog=1). It also writes the mouse profile
    file with the built-in profile if it isn't there yet.
  If a decode worker is stuck (abandoned), the scheduler and the
  media loader are not freed at the end: the worker may still use
  them.

  Knows
  -----
  The drawing surface (TMediaView or TGLMediaView, to ask for a
  repaint). The renderer (TCpuRenderer or TGLRenderer) is owned here;
  the form chooses which one (AttachView).
  - OnExitRequest, OnToggleFullscreen, OnSettingsRequest: the form's
    handlers for window actions.
  - The global IOGate (uIOGate), released at shutdown so the scanner
    doesn't wait.
  - The clipboard (paste) and the save folder of TConfig.

  Responsibilities
  ----------------
  - Create the subsystems, and shut them down in the right order
    (spec §5.8).
  - Carry out commands (Execute).
  - Start up from the command line or the last session (spec §11).
  - Connect navigation, cache, scheduler, scanner and renderer.
  - Decide what should be decoded (UpdateWanted), switch Browse /
    Skim, and allow the Full quality after RefineDelayMs.
  - Put results into the cache and on screen; play animations.
  - Watch for stuck reads (workers and scanner) and replace them.
  - Info and diagnostics lines, timing.csv and startup.csv.
  - Paste from the clipboard, edit mode (selection, crop), save the
    image (on a save thread), sort order, parent folder.
  - Show the zone name and the gesture preview of the mouse language
    (only with the diagnostics line on).
  - Keep the settings that change while viewing (info line,
    diagnostics line, sort mode, last folder and file) and save them
    first on shutdown.

  Does NOT
  --------
  - Draw, decode or scan directories itself.
  - Handle raw input.
  - Depend on the form. Window actions (exit, fullscreen) are
    requested through events that the form connects.
  - Show the menu (the main form does, on cmdShowMenu).

  Threads
  -------
  UI thread. Results from the decode workers (HandleImageReady) and
  the scanner thread (HandleStartReady, HandleTreeReady) arrive
  through TThread.Queue and so also run on the UI thread;
  PumpDeliveries (the form's 50 ms timer) picks up any that wait
  (CheckSynchronize). The save thread only writes its file; its
  result is read in PumpDeliveries once it has finished. The
  animation runs on a UI-thread TTimer. No locks of its own.

  Uses (MView units)
  ------------------
  interface:      uTypes, uCommands, uConfig, uDirectoryTree,
                  uNavigator, uDecodedImage, uMediaLoader,
                  uImageCache, uJobScheduler, uDirectoryScanner,
                  uRenderer, uAnimation, uMouseProfile, uJobQueue,
                  uIOGate, uMemoryGuard, uImageSaver, uStopwatch
  Libraries:      Classes, SysUtils, Math, Controls, ExtCtrls,
                  Graphics, Clipbrd, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uMainForm

  Flow (Phase C)
  --------------
  Navigation changes the current file at once (UI thread, cheap).
  ShowCurrent shows it from the cache if it is there; otherwise the
  previous image stays on screen and the info line says "loading".

  Either way UpdateWanted then tells the scheduler what should exist
  (the wanted set, spec §5.3):
    - the current image at Preview quality (its EXIF thumbnail, P0),
      if nothing is cached and the file may have one;
    - the current image at Screen quality (P0), unless only a preview
      is wanted (Skim);
    - the current image at Full quality (P1), once Screen is there
      and the image has been shown for RefineDelayMs (or the user
      zoomed in / chose 100 %);
    - previews of the next PreviewAhead images (P2): tiny and read
      from the start of the file only;
    - PreloadCount images ahead in the direction of travel (P2) and
      PreloadBehind images behind (P3), at Screen quality.
  The same list, current first, is the cache's eviction window.

  Browse and Skim (Phase E, spec §6)
  ----------------------------------
  An average of SkimRate or more images per second over the last
  SkimEnterMs switches to Skim (short pauses don't reset it): only
  previews are wanted (the current one and those ahead), no Screen or
  Full decodes, no Screen preloads. Files
  without a preview still get a Screen decode, which the next step
  cancels. SkimExitMs without navigation (checked in PumpDeliveries)
  switches back to Browse: the Screen version of the image the user
  stopped at is decoded at once, Full after RefineDelayMs as usual.
  So holding the wheel never queues up work, and the disk only reads
  file headers while skimming.

  Every result (HandleImageReady) goes into the cache. If it is the
  current file it goes on screen: a new image resets the view, a
  better version of the one shown (Screen -> Full) keeps zoom and pan.
  Then UpdateWanted runs again, because the cache has changed.

  The directory tree comes from the scanner thread (HandleTreeReady).
  Until then, browsing works inside the start folder.

  Animated GIF (Day 19, spec §8.7): the Screen quality of a GIF is its
  first frame, Full has every frame (after the usual RefineDelayMs
  pause). When an image with frames is displayed, a UI-thread timer
  plays it: TFrameClock says which frame is due, the animation's
  cursor builds it, and it goes to the renderer as the same image in
  a new version (the view stays). Not while skimming; stops when
  another image is displayed. Plays as often as the file says (loop
  extension; without one: once), then stays on the last frame.

  Measurements (spec §12)
  -----------------------
  A navigation command records its time (FCommandMs). When the image
  is handed to the renderer, the renderer measures the latency up to
  its first paint and reports it through OnImagePainted. The
  diagnostics line (D key, [Debug] ShowFPS) shows decode, screen copy,
  cache, latency and paint times; [Debug] TimingLog=1 writes one line
  per displayed image to timing.csv next to MView.exe (width and height
  are those of the original image; quality says which version was
  shown first).

  Disk trouble (Day 19)
  ---------------------
  The UI thread never reads the disk for images or folders (it only
  reads and writes its own small files: MView.ini, Default.mouse,
  timing.csv, startup.csv): the
  scanner resolves what to open and lists every folder (OpenMedia ->
  HandleStartReady -> HandleTreeReady), the navigator works on those
  lists only (ReadsDisk = False), and the cache is asked by file name
  (GetByName), not by a key read from the disk. A failing or hung
  disk can therefore only stall a worker or the scanner:
  - a decode worker that hasn't come back for StuckReadMs is abandoned
    and replaced (TJobScheduler.CheckStuck); its file gets an error
    placeholder "Disk not responding" and browsing goes on;
  - a scanner that hangs is replaced when the user opens something
    else; meanwhile the info line says the disk isn't responding.
  Opening (and F5) clears the cache: the new lists may name other file
  versions.

  Delivery safety net
  -------------------
  Results from the worker and scanner threads arrive through
  TThread.Queue; the LCL runs them when the main thread wakes up. When
  a wake-up gets lost (seen after fast scrolling through large images:
  the name of the new image showed, its picture never came until the
  next key press), the result waits in the queue. The form therefore
  calls PumpDeliveries on a short timer; it runs whatever is waiting.
  The diagnostics line counts these late pickups ("timer pickups").
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  uTypes,
  uCommands,
  uConfig,
  uDirectoryTree,
  uNavigator,
  uDecodedImage,
  uMediaLoader,
  uImageCache,
  uJobScheduler,
  uDirectoryScanner,
  uRenderer,
  Controls,
  ExtCtrls,
  Graphics,
  Clipbrd,
  BGRABitmap,
  BGRABitmapTypes,
  uAnimation,
  uMouseProfile,
  uJobQueue,
  uIOGate,
  uMemoryGuard,
  uImageSaver,
  uStopwatch;

type

  TMView = class(TObject)
  private
    FConfig: TConfig;
    FNavigator: TNavigator;
    FMediaLoader: TMediaLoader;
    FCache: TImageCache;
    FScheduler: TJobScheduler;
    FScanner: TDirectoryScanner;
    FRenderer: TRenderer;
    FSurface: TWinControl;
    FCurrentImage: IDecodedImage;

    FScanGeneration: Cardinal;   { latest scanner request }
    FAbandonedScanners: TFPList; { stuck scanners, never freed }
    FScannerReplacements: Integer;
    FScannerNoteShown: Boolean;
    FLastStuckCheckMs: Double;
    FPendingFile: string;        { requested, not yet delivered }
    FPreviewWidth: Integer;      { screen size, for the worker's copy }
    FPreviewHeight: Integer;

    { Measurements }
    FCommandMs: Double;          { NowMs of the last navigation; 0 = used }
    FLastWasHit: Boolean;        { current image came from the cache }
    FDirection: Integer;         { +1 forward, -1 backward (preloading) }
    FTypicalBytes: Int64;        { size of a recent preloaded image }
    FNoRoom: TStringList;        { preloads that didn't fit, this step }
    FTimerPickups: Integer;      { deliveries that only the timer found }

    { Phase E: previews and Skim mode. }
    FNoPreview: TStringList;     { files known to have no preview }
    FSkim: Boolean;
    FLastNavMs: Double;          { NowMs of the last navigation step; 0 = none }
    FStepTimes: array[0..63] of Double;   { NowMs of the latest steps (ring) }
    FStepHead: Integer;          { next slot to write }
    FStepCount: Integer;         { slots in use }

    { Debugging: "Save current image" (context menu). }
    FSaveThread: TImageSaveThread;
    FStatusNote: string;         { shown at the end of the info line }
    FStatusUntilMs: Double;      { 0 = until replaced }
    FViewNote: string;           { window picture result, while the image is still saving }

    { Mouse language (Phase F): the profile (Default.mouse), and until
      when the zone's name stays on screen. }
    FMouseProfile: TMouseProfile;
    FZoneLabelUntilMs: Double;

    { An image pasted from the clipboard is shown instead of the
      current file until the next step (Day 19). }
    FShowingPaste: Boolean;      { a pasted or cropped image is shown }
    FPasteSavedAs: string;
    FSavingPaste: Boolean;
    FScratchTitle: string;       { 'Clipboard image', 'Cropped from x.jpg' }
    FScratchPrefix: string;      { file name start when saved }

    { Edit mode: left drag selects an area of the image, which "Crop
      selection" makes the image shown. The anchor is where the drag
      started, in original image pixels. }
    FEditMode: Boolean;
    FSelAnchorX, FSelAnchorY: Double;
    FSelAnchorValid: Boolean;

    { Start-up measurement (startup.csv). }
    FStartupWindowMs: Double;
    FStartupViewReadyMs: Double;
    FStartupViewSetupMs: Double;
    FStartupLogged: Boolean;

    { Full quality of the current image only after a pause (or zoom). }
    FShownFile: string;          { current file the pause is timed for }
    FShownSinceMs: Double;       { NowMs when it became current }
    FFullAllowed: Boolean;       { the pause is over, or the user zoomed }

    { Window size changed: quick views are remade once it is stable. }
    FSizeChanged: Boolean;
    FSizeChangedMs: Double;

    { Skipping undecodable files (PlaceholderForBadImages = 0) }
    FLastStep: TCommand;
    FSkipCount: Integer;
    FSkipStartFile: string;

    FOnExitRequest: TNotifyEvent;
    FOnToggleFullscreen: TNotifyEvent;
    FOnSettingsRequest: TNotifyEvent;

    { Animation playback (Day 19, spec §8.7): the image playing, the
      cursor that builds its frames, the clock that says which frame is
      due, and a UI-thread timer. }
    FAnimImage: IDecodedImage;
    FAnimCursor: TAnimationCursor;
    FAnimClock: TFrameClock;
    FAnimTimer: TTimer;

    procedure ShowCurrent;
    procedure UpdateWanted;
    procedure SaveCurrentImage;
    procedure SaveImageOnly;
    procedure PasteFromClipboard;
    procedure ShowScratch(const AImage: IDecodedImage; const ATitle, APrefix: string);
    procedure SetEditMode(AOn: Boolean);
    procedure ClearSelection;
    procedure DragSelection(AX, AY: Double; AStart: Boolean);
    procedure CropSelection;
    procedure GoBack;
    procedure ParentFolder;
    procedure SetSort(AMode: TSortMode);
    procedure ShowZone(AZone: Integer);
    procedure ShowGesturePreview(AZone, AValue: Integer);
    procedure LoadMouseProfile;
    procedure AppendStartupRow(AFirstImageMs: Double);
    procedure ShowStatus(const AText: string; ADurationMs: Double);
    procedure AllowFull;
    function UpdateSkim: Boolean;
    procedure LeaveSkim;
    procedure Display(const AImage: IDecodedImage; AUpgrade: Boolean = False);
    procedure StartAnimation(const AImage: IDecodedImage);
    procedure StopAnimation;
    procedure HandleAnimationTimer(Sender: TObject);
    function AnimationDelay(AIndex: Integer): Integer;
    procedure SkipBadImage;
    procedure Navigate(ACommand: TCommand);
    procedure HandleImageReady(const AImage: IDecodedImage);
    procedure HandleTreeReady(ATree: TDirectoryTree; AGeneration: Cardinal);
    procedure HandleStartReady(AStart: TScanStart);
    function CreateScanner: TDirectoryScanner;
    procedure ReplaceScanner;
    procedure CheckStuckReads;
    function IsDiskError(const AImage: IDecodedImage): Boolean;
    procedure HandleImagePainted(ALatencyMs, APaintMs: Double);
    procedure AppendTimingRow(ALatencyMs, APaintMs: Double);
    procedure ShowMessageText(const AText: string);
    procedure UpdateInfo;
    procedure UpdateDiagnostics;
    procedure Refresh;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Initialize;
    { The drawing surface and its renderer, chosen by the form. TMView
      takes over the renderer (and frees the default CPU one). }
    procedure AttachView(ASurface: TWinControl; ARenderer: TRenderer);

    { The size of the screen, used for the screen-size copy that the
      worker makes of large images. }
    procedure SetDisplaySize(AWidth, AHeight: Integer);

    { Startup (spec §11): AParam is the first command line argument,
      a file or a folder. Empty: resume the last session. }
    procedure Start(const AParam: string);

    { Opens a file or a folder (through the scanner). ASelectFile: a
      file inside the folder to start on (resuming the last session). }
    procedure OpenMedia(const APath: string; const ASelectFile: string = '');

    { UI thread, called by the form's timer: runs queued deliveries
      from the worker and scanner threads that are still waiting. }
    procedure PumpDeliveries;

    procedure Execute(ACommand: TCommand); overload;
    procedure Execute(ACommand: TCommand; const AArgs: TCommandArgs); overload;

    { Stops the worker and scanner threads (spec §5.8). Called by the
      destructor; the form may call it earlier. Safe to call twice. }
    procedure Shutdown;

    property Config: TConfig read FConfig;
    property Navigator: TNavigator read FNavigator;
    property Renderer: TRenderer read FRenderer;
    { The mouse profile, read by Initialize (the surfaces get a copy). }
    property MouseProfile: TMouseProfile read FMouseProfile;
    { Edit mode is on and an area is selected (the menu's "Crop
      selection"). }
    function CanCrop: Boolean;
    property EditMode: Boolean read FEditMode;

    { Start-up times from the main form, in ms since the process
      started: window created, drawing surface ready; and how long the
      surface took (OpenGL set-up). Logged with the first image. }
    procedure NoteStartup(AWindowMs, AViewReadyMs, AViewSetupMs: Double);
    { A viewer opened again from the settings screen (after Esc): not a
      program start, no row in startup.csv. }
    procedure SkipStartupLog;
    property OnExitRequest: TNotifyEvent read FOnExitRequest write FOnExitRequest;
    property OnToggleFullscreen: TNotifyEvent read FOnToggleFullscreen write FOnToggleFullscreen;
    { Esc while viewing (no mode on): back to the settings editor, as if
      started without an image. The form does it (later, not inside the
      key handler). }
    property OnSettingsRequest: TNotifyEvent read FOnSettingsRequest write FOnSettingsRequest;
  end;

implementation

const
  { Upper limit for skipping undecodable files in one go (only used
    when PlaceholderForBadImages is off). }
  MaxSkippedFiles = 1000;

  { How long the window size must stay unchanged before quick views
    are remade for it. }
  WindowSettleMs = 400;

  { Room assumed for an EXIF thumbnail not yet read (160 x 120 is
    77 KB; some cameras store larger ones). }
  PreviewEstimateBytes = 256 * 1024;

  { FNoPreview is only a hint; forget it before it grows large. }
  MaxNoPreviewNames = 20000;

  { A decode worker that hasn't come back from the file system for this
    long is taken as stuck (legitimate decodes check in every few
    hundred ms at most). The scanner likewise. }
  StuckReadMs = 20000;
  ScannerStuckMs = 20000;
  MaxScannerReplacements = 4;
  DiskNotRespondingText = 'Disk not responding';

  { Animation: while the previous frame is still being uploaded, look
    again this soon. }
  AnimationRetryMs = 10;

  { How long the zone's name stays on screen (mouse language). }
  ZoneLabelMs = 1500;

  NoStartMessage =
    'No image or folder given.   Start MView with:   MView.exe <image file or folder>';

constructor TMView.Create;
begin
  inherited Create;
  FConfig := TConfig.Create;
  FNavigator := TNavigator.Create;
  FMediaLoader := TMediaLoader.Create;
  { A CPU renderer until the form attaches the real one (AttachView),
    so FRenderer is never nil. }
  FRenderer := TCpuRenderer.Create;
  { Cache, scheduler and scanner need the configuration: Initialize. }
  FCurrentImage := nil;
  FPreviewWidth := 1920;
  FPreviewHeight := 1080;
  FLastStep := cmdNextImage;
  FDirection := 1;
  FTypicalBytes := 0;
  FNoRoom := TStringList.Create;
  FNoRoom.CaseSensitive := False;
  FNoRoom.Sorted := True;
  FNoRoom.Duplicates := dupIgnore;
  FNoPreview := TStringList.Create;
  FNoPreview.CaseSensitive := False;
  FNoPreview.Sorted := True;
  FNoPreview.Duplicates := dupIgnore;
  FAbandonedScanners := TFPList.Create;
  FMouseProfile := TMouseProfile.Create;
  FMouseProfile.LoadDefaults;
end;

destructor TMView.Destroy;
begin
  { Settings first: if a worker hangs in the shutdown below, the
    watchdog may end the process (uWatchdog), and they are saved. }
  FConfig.ShowInfo := FRenderer.ShowInfo;
  FConfig.ShowDiagnostics := FRenderer.ShowDiagnostics;
  FConfig.SortMode := FNavigator.SortMode;
  FConfig.Save;

  Shutdown;

  { Reverse order of creation. The threads are stopped already, except
    any stuck in the file system: those are left alone (and whatever
    they may still use, the scheduler, is not freed). }
  FCurrentImage := nil;
  FAnimTimer.Free;
  FScanner.Free;
  FAbandonedScanners.Free;
  FCache.Free;
  FRenderer.Free;
  if not FScheduler.HasAbandonedWorkers then
  begin
    FScheduler.Free;
    FMediaLoader.Free;
  end;
  FNavigator.Free;
  FNoRoom.Free;
  FNoPreview.Free;
  FMouseProfile.Free;
  FConfig.Free;
  inherited Destroy;
end;

procedure TMView.Shutdown;
begin
  StopAnimation;

  { A save still running: let it finish (it only writes a file). }
  if Assigned(FSaveThread) then
  begin
    FSaveThread.WaitFor;
    FreeAndNil(FSaveThread);
  end;

  { Waiting for the threads below runs queued calls; they must not
    reach the viewer any more. (The scheduler clears its own event.) }
  if Assigned(FScanner) then
  begin
    FScanner.OnTreeReady := nil;
    FScanner.OnStartReady := nil;
  end;
  { Threads first: after this no delivery can arrive any more. (Stuck
    workers are not waited for, see TJobScheduler.Shutdown.) }
  if Assigned(FScheduler) then
    FScheduler.Shutdown;
  { No read can be under way any more; don't let the scanner wait. }
  IOGate.Release;
  if Assigned(FScanner) then
  begin
    { A scanner that hasn't come back from the disk for a second may
      be stuck: don't wait for it. }
    if FScanner.LastAliveAgeMs > 1000 then
    begin
      FScanner.Abandon;
      FAbandonedScanners.Add(FScanner);
      FScanner := nil;
    end
    else
      FScanner.Shutdown;
  end;
end;

function TMView.CreateScanner: TDirectoryScanner;
begin
  Result := TDirectoryScanner.Create;
  Result.OnStartReady := @HandleStartReady;
  Result.OnTreeReady := @HandleTreeReady;
end;

{ The scanner hangs in the file system and the user wants something
  else: leave it (it can't be stopped) and start a new one. }
procedure TMView.ReplaceScanner;
begin
  if FScannerReplacements >= MaxScannerReplacements then
    Exit;
  Inc(FScannerReplacements);
  FScanner.Abandon;
  FAbandonedScanners.Add(FScanner);
  FScanner := CreateScanner;
  FScannerNoteShown := False;
end;

procedure TMView.Initialize;
var
  CacheMB, Workers: Integer;
begin
  FConfig.Load;
  LoadMouseProfile;

  FNavigator.Recursive := FConfig.Recursive;
  FNavigator.WrapAround := FConfig.WrapAround;
  FNavigator.WrapScope := FConfig.WrapScope;
  FNavigator.SetSortMode(FConfig.SortMode);

  FRenderer.ZoomStepPercent := FConfig.ZoomStepPercent;
  { Before the scheduler starts its workers, which read it. }
  FMediaLoader.AutoRotate := FConfig.AutoRotate;
  FMediaLoader.UseWic := FConfig.UseWic;
  FMediaLoader.UseWicQuickView := FConfig.UseWicQuickView;
  FRenderer.ShowInfo := FConfig.ShowInfo;
  FRenderer.ShowDiagnostics := FConfig.ShowDiagnostics;
  FRenderer.OverlaySolid := FConfig.OverlaySolid;
  FRenderer.SetOverlayColorName(FConfig.OverlayColor);
  FRenderer.OnImagePainted := @HandleImagePainted;
  FRenderer.SetMessage('');

  CacheMB := FConfig.CacheSizeMB;
  if CacheMB <= 0 then
    CacheMB := AutomaticCacheSizeMB;
  FCache := TImageCache.Create(CacheMB);

  Workers := FConfig.DecodeThreads;
  if Workers <= 0 then
    Workers := AutomaticWorkerCount;
  FScheduler := TJobScheduler.Create(FMediaLoader, Workers);
  FScheduler.DecodeDelayMs := FConfig.DecodeDelayMs;
  FScheduler.OnImageReady := @HandleImageReady;

  { Folders come only from the scanner (Day 19). }
  FNavigator.ReadsDisk := False;
  FScanner := CreateScanner;
end;

procedure TMView.AttachView(ASurface: TWinControl; ARenderer: TRenderer);
begin
  FSurface := ASurface;
  if (ARenderer = nil) or (ARenderer = FRenderer) then
    Exit;
  ARenderer.ZoomStepPercent := FRenderer.ZoomStepPercent;
  ARenderer.ShowInfo := FRenderer.ShowInfo;
  ARenderer.ShowDiagnostics := FRenderer.ShowDiagnostics;
  ARenderer.OverlaySolid := FConfig.OverlaySolid;
  ARenderer.SetOverlayColorName(FConfig.OverlayColor);
  ARenderer.EditMode := FRenderer.EditMode;
  ARenderer.OnImagePainted := @HandleImagePainted;
  ARenderer.SetMessage('');
  FRenderer.Free;
  FRenderer := ARenderer;
end;

procedure TMView.SetDisplaySize(AWidth, AHeight: Integer);
begin
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  if (AWidth = FPreviewWidth) and (AHeight = FPreviewHeight) then
    Exit;
  FPreviewWidth := AWidth;
  FPreviewHeight := AHeight;
  { Cached quick views were made for the old size. Remade once the
    size has been stable for a moment (PumpDeliveries), not for every
    step of a drag. }
  FSizeChanged := True;
  FSizeChangedMs := NowMs;
end;

procedure TMView.Start(const AParam: string);
begin
  if AParam <> '' then
    OpenMedia(AParam)
  else if FConfig.LastDirectory <> '' then
    OpenMedia(FConfig.LastDirectory, FConfig.LastFile)   { the scanner says if it's gone }
  else
    { No last session (the settings editor's "View images" on a new
      installation). }
    ShowMessageText(NoStartMessage);
end;

{ Spec §11: the first image has priority over everything, including
  knowing the rest of the tree. The scanner resolves the path and
  lists the start folder first (HandleStartReady: the first image goes
  to a worker at once), then scans the tree (HandleTreeReady). Nothing
  here touches the disk (Day 19). }
procedure TMView.OpenMedia(const APath: string; const ASelectFile: string);
begin
  { The scanner is stuck in an earlier request: a new one wouldn't be
    looked at. }
  if FScanner.LastAliveAgeMs > ScannerStuckMs then
    ReplaceScanner;

  FCommandMs := NowMs;
  FDirection := 1;
  FNoRoom.Clear;
  FSkim := False;
  FLastNavMs := 0;
  FStepCount := 0;
  { New lists may name other versions of the files. }
  FCache.Clear;
  FScanGeneration := FScanner.Request(APath, ASelectFile, FConfig.Recursive);

  ShowStatus('opening ' + APath + ' ...', 0);
  if not FNavigator.HasCurrentImage then
  begin
    FRenderer.SetMessage('Opening   ' + APath + '  ...');
    Refresh;
  end;
end;

{ UI thread: the scanner has resolved what to open and listed its
  folder. Takes ownership of AStart. }
procedure TMView.HandleStartReady(AStart: TScanStart);
begin
  try
    if AStart.Generation <> FScanGeneration then
      Exit;   { from an older request }
    ShowStatus('', 0);
    if not AStart.Found then
    begin
      ShowMessageText('Not found:   ' + AStart.RequestedPath);
      Exit;
    end;

    FNavigator.OpenListed(AStart.Root, AStart.TargetDirectory, AStart.Listing,
      AStart.TargetFile);
    FConfig.LastDirectory := FNavigator.RootDirectory;
    FLastStep := cmdNextImage;
    FSkipCount := 0;
    FSkipStartFile := FNavigator.CurrentFileName;
    ShowCurrent;
  finally
    AStart.Free;
  end;
end;

{ Shows the navigator's current file: from the cache if possible,
  otherwise keeps the previous image on screen until it arrives. }
procedure TMView.ShowCurrent;
var
  FileName: string;
  Cached: IDecodedImage;
begin
  if not FNavigator.HasCurrentImage then
  begin
    FPendingFile := '';
    StopAnimation;
    FShowingPaste := False;
    FCurrentImage := nil;
    FShownFile := '';
    UpdateWanted;               { nothing wanted: stops all jobs }
    FRenderer.SetImage(nil);
    if FNavigator.TreeReady then
      FRenderer.SetMessage('No images found in   ' + FNavigator.RootDirectory)
    else
      FRenderer.SetMessage('Looking for images in   ' + FNavigator.RootDirectory + '  ...');
    UpdateInfo;
    Refresh;
    Exit;
  end;

  FileName := FNavigator.CurrentFileName;
  FConfig.LastFile := FileName;
  { A pasted image gives way to the file (the next step). }
  FShowingPaste := False;

  { Another file: the animation shown stops (its last frame stays until
    the new image arrives) and no longer holds its frames in memory. }
  if Assigned(FAnimImage) and not SameText(FAnimImage.Key.FileName, FileName) then
    StopAnimation;

  { A new current image: the pause before its full-size decode starts
    now (see UpdateWanted, PumpDeliveries). }
  if not SameText(FileName, FShownFile) then
  begin
    FShownFile := FileName;
    FShownSinceMs := NowMs;
    FFullAllowed := FConfig.RefineDelayMs <= 0;
  end;

  Cached := FCache.GetByName(FileName);
  { Only the thumbnail was readable, the file itself failed: show the
    failure (and skip it if placeholders are off), not the thumbnail. }
  if (Cached <> nil) and (not Cached.IsError) and (Cached.Quality < qlScreen)
    and FCache.HasError(FileName) and (FCache.ErrorOf(FileName) <> nil) then
    Cached := FCache.ErrorOf(FileName);
  FLastWasHit := Cached <> nil;
  { A preview is shown at once, but the real image is still to come. }
  if (Cached <> nil) and (Cached.IsError or (Cached.Quality >= qlScreen)
    or FCache.HasError(FileName)) then
    FPendingFile := ''
  else
    FPendingFile := FileName;

  { The wanted set first: it also sets the cache's eviction window. }
  UpdateWanted;

  if Cached <> nil then
    Display(Cached)
  else
  begin
    UpdateInfo;
    UpdateDiagnostics;
    Refresh;
  end;
end;

{ Tells the scheduler what should exist now (spec §5.3), and the cache
  which files matter most. Cheap enough to run after every step and
  every delivery. }
procedure TMView.UpdateWanted;
var
  Wanted: TWantedItems;
  Window, Ahead, Behind, Neighbors, PreviewFiles: TStringArray;
  NeighborPriority: array of TJobPriority;
  Current, Name: string;
  Cached: IDecodedImage;
  I, N, A, B, W: Integer;
  Room, Size, Estimate: Int64;
  CanPreview, NeedsScreen: Boolean;

  function InWindow(const AName: string): Boolean;
  var
    K: Integer;
  begin
    Result := False;
    for K := 0 to W - 1 do
      if SameText(Window[K], AName) then
        Exit(True);
  end;

  procedure Want(const AFileName: string; AQuality: TQualityLevel; APriority: TJobPriority);
  begin
    SetLength(Wanted, N + 1);
    Wanted[N].FileName := AFileName;
    Wanted[N].Quality := AQuality;
    Wanted[N].Priority := APriority;
    Inc(N);
  end;

begin
  Wanted := nil;
  N := 0;

  if not FNavigator.HasCurrentImage then
  begin
    Window := nil;
    FCache.SetWindow(Window);
    FScheduler.Reconcile(Wanted, FPreviewWidth, FPreviewHeight);
    Exit;
  end;

  Current := FNavigator.CurrentFileName;
  Room := FCache.BudgetBytes - FCache.BytesOf(Current);

  { The current image: Preview, Screen, then Full (spec §7.1). A
    decode that failed (e.g. Full out of memory) is not retried. Room
    is kept for the Full version before any neighbour gets some. }
  Cached := FCache.GetByName(Current);
  CanPreview := MayHavePreview(Current) and (FNoPreview.IndexOf(Current) < 0);
  if Cached = nil then
  begin
    { The thumbnail is read in a millisecond or two; the Screen decode
      runs next to it (or, with one worker, right after it). Skim:
      the thumbnail only, if there is one. }
    if CanPreview then
      Want(Current, qlPreview, jpDisplay);
    if not (FSkim and CanPreview) then
      Want(Current, qlScreen, jpDisplay);
  end
  else if (not Cached.IsError) and not FCache.HasError(Current) then
  begin
    if Cached.Quality = qlPreview then
    begin
      if not FSkim then
        Want(Current, qlScreen, jpDisplay);
    end
    { Full only after a short pause on this image, or when the user
      zooms in (RefineDelayMs): while browsing, the quick view is all
      that is seen, and a 100 MP decode would only keep a worker busy. }
    else if (Cached.Quality < qlFull) and FFullAllowed and not FSkim then
      Want(Current, qlFull, jpRefine);
    { The room is kept free for the full size (and its screen copy)
      either way, and for the Screen version still to come. }
    if Cached.Quality < qlFull then
      Dec(Room, Int64(Cached.FullWidth) * Int64(Cached.FullHeight) * 4
        + Int64(FPreviewWidth) * Int64(FPreviewHeight) * 4);
    if Cached.Quality = qlPreview then
      Dec(Room, Int64(FPreviewWidth) * Int64(FPreviewHeight) * 4);
  end;

  { Previews ahead: tiny, from the start of the file only. First in
    the queue among the neighbours, so the next steps show at least a
    thumbnail at once. }
  PreviewFiles := nil;
  if FConfig.PreviewAhead > 0 then
    PreviewFiles := FNavigator.FilesAhead(FConfig.PreviewAhead, FDirection);
  for I := 0 to High(PreviewFiles) do
  begin
    Name := PreviewFiles[I];
    if MayHavePreview(Name) and (FNoPreview.IndexOf(Name) < 0)
      and not FCache.Contains(Name) and (FNoRoom.IndexOf(Name) < 0) then
      Want(Name, qlPreview, jpAhead);
  end;

  { Neighbours in order of importance: a step behind counts as two
    steps ahead (a1, a2, b1, a3, a4, b2, ...). }
  { Skim: no Screen preloads, the user is past them before they are
    done. }
  if FSkim then
  begin
    Ahead := nil;
    Behind := nil;
  end
  else
  begin
    Ahead := FNavigator.FilesAhead(FConfig.PreloadCount, FDirection);
    Behind := FNavigator.FilesAhead(FConfig.PreloadBehind, -FDirection);
  end;
  SetLength(Neighbors, Length(Ahead) + Length(Behind));
  SetLength(NeighborPriority, Length(Neighbors));
  A := 0;
  B := 0;
  W := 0;
  while (A < Length(Ahead)) or (B < Length(Behind)) do
  begin
    if (A < Length(Ahead)) and ((B >= Length(Behind)) or (A + 1 <= 2 * (B + 1))) then
    begin
      Neighbors[W] := Ahead[A];
      NeighborPriority[W] := jpAhead;
      Inc(A);
    end
    else
    begin
      Neighbors[W] := Behind[B];
      NeighborPriority[W] := jpBehind;
      Inc(B);
    end;
    Inc(W);
  end;

  { Only as many neighbours as fit in the cache next to the current
    image (spec §13, "effective preload count"). Otherwise a preloaded
    image would push out another one, which would then be wanted and
    decoded again, forever. }
  Estimate := FTypicalBytes;
  if Estimate <= 0 then
    Estimate := Int64(FPreviewWidth) * Int64(FPreviewHeight) * 4;

  SetLength(Window, 1 + Length(Neighbors) + Length(PreviewFiles));
  Window[0] := Current;
  W := 1;
  for I := 0 to High(Neighbors) do
  begin
    Name := Neighbors[I];
    { Only a preview (or nothing) cached: the Screen version is still
      to come, count its size. }
    NeedsScreen := (FCache.BestQuality(Name) < qlScreen) and not FCache.HasError(Name);
    if NeedsScreen then
      Size := Max(FCache.BytesOf(Name), Estimate)
    else
      Size := FCache.BytesOf(Name);
    if Size > Room then
      Break;
    Dec(Room, Size);
    Window[W] := Name;
    Inc(W);

    if NeedsScreen and (FNoRoom.IndexOf(Name) < 0) then
      Want(Name, qlScreen, NeighborPriority[I]);
  end;
  { The previews ahead stay in the cache too, behind the neighbours. }
  for I := 0 to High(PreviewFiles) do
  begin
    Name := PreviewFiles[I];
    if InWindow(Name) then
      Continue;
    if FCache.Contains(Name) then
      Size := FCache.BytesOf(Name)
    else
      Size := PreviewEstimateBytes;
    if Size > Room then
      Break;
    Dec(Room, Size);
    Window[W] := Name;
    Inc(W);
  end;
  SetLength(Window, W);
  FCache.SetWindow(Window);

  FScheduler.Reconcile(Wanted, FPreviewWidth, FPreviewHeight);
end;

{ AUpgrade: a better version of the image already shown; keep the
  view, and it doesn't count as a new image for the measurements. }
procedure TMView.Display(const AImage: IDecodedImage; AUpgrade: Boolean);
begin
  FCurrentImage := AImage;
  FRenderer.SetImage(AImage, AUpgrade);
  if (FCommandMs > 0) and not AUpgrade then
  begin
    FRenderer.StartLatency(FCommandMs);
    FCommandMs := 0;
  end;
  { Another image: the selection was for the old one. (A better version
    of the same image keeps it: the same original pixels.) }
  if not AUpgrade then
    ClearSelection;
  { Animated: play (not while skimming past it). }
  if Assigned(AImage) and (AImage.Animation <> nil) and not FSkim then
    StartAnimation(AImage)
  else
    StopAnimation;
  UpdateInfo;
  UpdateDiagnostics;
  Refresh;

  if (not AUpgrade) and AImage.IsError and not FConfig.PlaceholderForBadImages then
    SkipBadImage;
end;

{ Plays an animated image from its first frame (which is on screen
  already: it is the image's Bitmap). }
procedure TMView.StartAnimation(const AImage: IDecodedImage);
begin
  StopAnimation;
  if (AImage = nil) or AImage.IsError or (AImage.Animation = nil)
    or (AImage.FrameCount < 2) then
    Exit;
  FAnimImage := AImage;
  FAnimCursor := AImage.Animation.CreateCursor;
  FAnimClock := TFrameClock.Create(AImage.FrameCount, @AnimationDelay,
    AImage.Animation.PlayCount);
  FAnimClock.Start(NowMs);
  if FAnimTimer = nil then
  begin
    FAnimTimer := TTimer.Create(nil);
    FAnimTimer.Enabled := False;
    FAnimTimer.OnTimer := @HandleAnimationTimer;
  end;
  FAnimTimer.Interval := Max(1, Round(FAnimClock.MsUntilNext(NowMs)));
  FAnimTimer.Enabled := True;
end;

procedure TMView.StopAnimation;
begin
  if Assigned(FAnimTimer) then
    FAnimTimer.Enabled := False;
  { The cursor reads the animation: free it first. }
  FreeAndNil(FAnimCursor);
  FreeAndNil(FAnimClock);
  FAnimImage := nil;
end;

function TMView.AnimationDelay(AIndex: Integer): Integer;
begin
  if Assigned(FAnimImage) then
    Result := FAnimImage.FrameDelayMs(AIndex)
  else
    Result := 100;
end;

{ The next frame, if one is due. The frame is a new bitmap handed to
  the renderer as "the same image, keep the view", so zoom, pan and
  rotation stay. While the renderer is still uploading the previous
  frame (a large GIF), nothing is built: the clock then skips frames
  instead of queueing them. }
procedure TMView.HandleAnimationTimer(Sender: TObject);
var
  Bmp: TBGRABitmap;
  Frame: IDecodedImage;
begin
  if (FAnimImage = nil) or (FAnimClock = nil) or (FAnimCursor = nil) then
  begin
    if Assigned(FAnimTimer) then
      FAnimTimer.Enabled := False;
    Exit;
  end;
  if FAnimImage <> FCurrentImage then
  begin
    StopAnimation;
    Exit;
  end;
  if FRenderer.IsUploading then
  begin
    FAnimTimer.Interval := AnimationRetryMs;
    Exit;
  end;

  if FAnimClock.Advance(NowMs) then
  begin
    Bmp := FAnimCursor.Frame(FAnimClock.Index);
    Frame := TDecodedImage.Create(FAnimImage.Key, FAnimImage.Quality, Bmp, nil,
      FAnimImage.DecodeMs, 0, FAnimImage.FullWidth, FAnimImage.FullHeight);
    FRenderer.SetImage(Frame, True);
    UpdateDiagnostics;
    Refresh;
  end;
  { Played as often as the file says: the last frame stays. }
  if FAnimClock.Finished then
  begin
    FAnimTimer.Enabled := False;
    UpdateDiagnostics;
    Refresh;
    Exit;
  end;
  FAnimTimer.Interval := Max(1, Round(FAnimClock.MsUntilNext(NowMs)));
end;

{ The current file can't be decoded and placeholders are off: move on
  in the direction of the last navigation. Each step decodes on the
  worker again, so this runs step by step, never in a blocking loop. }
procedure TMView.SkipBadImage;
var
  Moved: Boolean;
  Cached: IDecodedImage;
begin
  Inc(FSkipCount);
  if FSkipCount >= MaxSkippedFiles then
    Exit;

  if FLastStep = cmdPreviousImage then
    Moved := FNavigator.PreviousImage
  else
    Moved := FNavigator.NextImage;

  if not Moved then
    Exit;

  if not SameText(FNavigator.CurrentFileName, FSkipStartFile) then
    ShowCurrent
  else
  begin
    { Back where the user started. If that file is fine (the user came
      from it), show it; if it is bad too, every file failed: stop. }
    Cached := FCache.GetByName(FSkipStartFile);
    if (Cached = nil) or not Cached.IsError then
      ShowCurrent;
  end;
end;

{ UI thread, called by the scheduler when a decode has finished. }
procedure TMView.HandleImageReady(const AImage: IDecodedImage);
var
  SameFileShown: Boolean;
begin
  { A preview request for a file without a thumbnail: not an error of
    the file, just "don't ask again". The Screen decode follows. }
  if AImage.IsError and (AImage.ErrorMessage = NoPreviewMessage) then
  begin
    if FNoPreview.Count >= MaxNoPreviewNames then
      FNoPreview.Clear;
    FNoPreview.Add(AImage.Key.FileName);
    UpdateWanted;
    UpdateDiagnostics;
    Refresh;
    Exit;
  end;

  { The disk answers again for a file taken as stuck: forget that
    error, the real image counts. }
  if (not AImage.IsError) and IsDiskError(FCache.ErrorOf(AImage.Key.FileName)) then
    FCache.DropError(AImage.Key.FileName);

  { A preload that was pushed out again at once doesn't fit: don't ask
    for it again until the next step (see UpdateWanted). }
  if not FCache.Put(AImage) then
    FNoRoom.Add(AImage.Key.FileName);

  { Remember how big preloads are, for the room estimate. Reacts to
    larger images at once, to smaller ones slowly. }
  if (not AImage.IsError) and (AImage.Quality >= qlScreen)
    and ((AImage.Quality = qlScreen) or (AImage.Preview = nil))
    and not SameText(AImage.Key.FileName, FNavigator.CurrentFileName) then
  begin
    if AImage.SizeInBytes > FTypicalBytes then
      FTypicalBytes := AImage.SizeInBytes
    else
      FTypicalBytes := (3 * FTypicalBytes + AImage.SizeInBytes) div 4;
  end;

  { A pasted image is shown: the file's results only go to the cache. }
  if (not FShowingPaste) and SameText(AImage.Key.FileName, FNavigator.CurrentFileName) then
  begin
    if AImage.IsError or (AImage.Quality >= qlScreen) then
      FPendingFile := '';
    SameFileShown := Assigned(FCurrentImage)
      and SameText(FCurrentImage.Key.FileName, AImage.Key.FileName);
    if not SameFileShown then
      Display(AImage)                        { the image the user is waiting for }
    else if (AImage.Quality > FCurrentImage.Quality)
      and ((not FCurrentImage.IsError) or IsDiskError(FCurrentImage)) then
    begin
      FLastWasHit := False;
      Display(AImage, True);                 { Preview -> Screen -> Full: keep the view }
    end
    else if AImage.IsError and (FCurrentImage.Quality = qlPreview) then
      Display(AImage)                        { only the thumbnail was readable }
    else
      UpdateInfo;                            { "loading" may be over }
    { else: a late, smaller version of what is shown; cache only }
  end;

  { The cache changed: the next thing to decode may be different
    (Full of the current image, the next preload). }
  UpdateWanted;
  UpdateDiagnostics;
  Refresh;
end;

{ UI thread, called by the scanner when the tree is ready. }
procedure TMView.HandleTreeReady(ATree: TDirectoryTree; AGeneration: Cardinal);
begin
  if AGeneration <> FScanGeneration then
  begin
    ATree.Free;   { from an older request }
    Exit;
  end;

  { The scanner may have chosen another root. }
  if FNavigator.SetTree(ATree) then
  begin
    FConfig.LastDirectory := FNavigator.RootDirectory;
    ShowCurrent;                { an empty start folder moved on }
  end
  else if not FNavigator.HasCurrentImage then
    ShowCurrent                 { still nothing: "No images found" }
  else
  begin
    UpdateWanted;               { neighbour folders are known now }
    UpdateInfo;
    Refresh;
  end;
end;

procedure TMView.Navigate(ACommand: TCommand);
var
  Moved, SkimEnded: Boolean;
begin
  FCommandMs := NowMs;
  FLastStep := ACommand;
  if ACommand in [cmdPreviousImage] then
    FDirection := -1
  else
    FDirection := 1;
  FNoRoom.Clear;
  FSkipCount := 0;
  FSkipStartFile := FNavigator.CurrentFileName;
  SkimEnded := UpdateSkim;
  { A slow step ends Skim; it is left properly (Screen wanted again)
    whether or not the step moves. }
  if SkimEnded then
    FSkim := False;

  case ACommand of
    cmdNextImage:         Moved := FNavigator.NextImage;
    cmdPreviousImage:     Moved := FNavigator.PreviousImage;
    cmdNextDirectory:     Moved := FNavigator.NextDirectory;
    cmdPreviousDirectory: Moved := FNavigator.PreviousDirectory;
  else
    Moved := False;
  end;

  if Moved then
    ShowCurrent
  else if SkimEnded then
    LeaveSkim;
end;

{ Phase E (spec §6): called for every navigation step, before the
  step. Skim while the steps of the last SkimEnterMs average at least
  SkimRate per second; it ends when they don't any more, or after
  SkimExitMs without a step (PumpDeliveries). True if this step ended
  Skim: the caller must then make sure LeaveSkim runs. }
function TMView.UpdateSkim: Boolean;
var
  NowTime: Double;
  Needed, Count, I, Idx: Integer;
begin
  Result := False;
  NowTime := NowMs;
  FStepTimes[FStepHead] := NowTime;
  FStepHead := (FStepHead + 1) mod Length(FStepTimes);
  if FStepCount < Length(FStepTimes) then
    Inc(FStepCount);
  FLastNavMs := NowTime;

  if FConfig.SkimEnterMs <= 0 then
  begin
    Result := FSkim;   { never skim }
    Exit;
  end;

  { The average rate over the last SkimEnterMs: at least SkimRate
    steps per second. Short pauses (moving the finger on the wheel)
    don't reset it, as a run of uninterrupted fast steps did (Day 19:
    Skim came too rarely). }
  Needed := EnsureRange(Round(FConfig.SkimRate * FConfig.SkimEnterMs / 1000),
    2, Length(FStepTimes));
  Count := 0;
  for I := 0 to FStepCount - 1 do
  begin
    Idx := (FStepHead - 1 - I + 2 * Length(FStepTimes)) mod Length(FStepTimes);
    if NowTime - FStepTimes[Idx] > FConfig.SkimEnterMs then
      Break;
    Inc(Count);
  end;

  if Count >= Needed then
    FSkim := True
  else
    Result := FSkim;   { below the rate: Skim ends (the caller leaves it) }
end;

{ Browsing has stopped: back to Browse. The image the user stopped at
  gets its Screen decode now, and its Full one after RefineDelayMs
  from now (not counted from while it was skimmed past). }
procedure TMView.LeaveSkim;
begin
  FSkim := False;
  FShownSinceMs := NowMs;
  FFullAllowed := FConfig.RefineDelayMs <= 0;
  { An animation that was only skimmed past: play it now. }
  if Assigned(FCurrentImage) and (FCurrentImage.Animation <> nil) and (FAnimImage = nil) then
    StartAnimation(FCurrentImage);
  UpdateWanted;
  UpdateInfo;
  UpdateDiagnostics;
  Refresh;
end;

procedure TMView.Execute(ACommand: TCommand);
begin
  Execute(ACommand, NoArgs);
end;

procedure TMView.Execute(ACommand: TCommand; const AArgs: TCommandArgs);
begin
  case ACommand of
    cmdNextImage,
    cmdPreviousImage,
    cmdNextDirectory,
    cmdPreviousDirectory:
      begin
        Navigate(ACommand);
        Exit;   { ShowCurrent refreshes }
      end;

    cmdToggleSortMode:
      begin
        FNavigator.ToggleSortMode;
        FConfig.SortMode := FNavigator.SortMode;
        UpdateWanted;             { other neighbours now }
        UpdateInfo;
      end;

    cmdRescan:
      if FNavigator.RootDirectory <> '' then
      begin
        OpenMedia(FNavigator.RootDirectory, FNavigator.CurrentFileName);
        Exit;
      end;

    cmdZoomIn:
      begin
        FRenderer.ZoomIn;
        AllowFull;              { details wanted: full size now }
      end;
    cmdZoomOut:      FRenderer.ZoomOut;
    cmdFitToScreen:  FRenderer.FitToScreen;
    cmdOriginalSize:
      begin
        FRenderer.OriginalSize;
        AllowFull;
      end;
    cmdRotateLeft:   FRenderer.Rotate(-1);
    cmdRotateRight:  FRenderer.Rotate(1);

    cmdZoomAt:
      begin
        { Value: wheel notches; the same step as the + key. }
        FRenderer.ZoomAt(Power(1.0 + FRenderer.ZoomStepPercent / 100.0, AArgs.Value),
          AArgs.X, AArgs.Y);
        if AArgs.Value > 0 then
          AllowFull;
      end;

    cmdPanBy:
      { Edit mode: the drag selects instead (cmdDragPoint). }
      if FEditMode then
        Exit
      else
        FRenderer.PanBy(AArgs.X, AArgs.Y);

    cmdRotateBy:
      FRenderer.RotateBy(AArgs.Value);

    cmdToggleFit:
      if FRenderer.IsFitView then
      begin
        FRenderer.OriginalSizeAt(AArgs.X, AArgs.Y);
        AllowFull;
      end
      else
        FRenderer.FitToScreen;

    cmdInputMode:
      FRenderer.InputMode := TInputMode(EnsureRange(Round(AArgs.Value),
        Ord(Low(TInputMode)), Ord(High(TInputMode))));

    cmdToggleInfo:
      FRenderer.ShowInfo := not FRenderer.ShowInfo;

    cmdToggleDiagnostics:
      begin
        FRenderer.ShowDiagnostics := not FRenderer.ShowDiagnostics;
        { The zone names belong to the diagnostics (user: distracting
          otherwise). }
        if not FRenderer.ShowDiagnostics then
          FRenderer.ZoneLabel := '';
        UpdateDiagnostics;
      end;

    cmdToggleFullscreen:
      if Assigned(FOnToggleFullscreen) then
        FOnToggleFullscreen(Self);

    cmdSortByDate:
      SetSort(smDateDescending);
    cmdSortByName:
      SetSort(smFileNameAscending);

    cmdParentDirectory:
      begin
        ParentFolder;
        Exit;
      end;

    cmdOriginalSizeAt:
      begin
        FRenderer.OriginalSizeAt(AArgs.X, AArgs.Y);
        AllowFull;
      end;

    cmdPaste:
      begin
        PasteFromClipboard;
        Exit;
      end;

    cmdSaveImage:
      SaveImageOnly;

    cmdSaveDebug:
      SaveCurrentImage;

    cmdEditMode:
      SetEditMode(not FEditMode);
    cmdEditModeOn:
      SetEditMode(True);
    cmdEditModeOff:
      SetEditMode(False);
    cmdCropSelection:
      begin
        CropSelection;
        Exit;
      end;
    cmdDragStart:
      if FEditMode then
        DragSelection(AArgs.X, AArgs.Y, True)
      else
        Exit;
    cmdDragPoint:
      if FEditMode then
        DragSelection(AArgs.X, AArgs.Y, False)
      else
        Exit;
    cmdBack:
      begin
        GoBack;
        Exit;
      end;

    cmdShowZone:
      ShowZone(Round(AArgs.Value));

    cmdGesturePreview:
      ShowGesturePreview(Round(AArgs.X), Round(AArgs.Value));

    cmdShowMenu:
      ;   { the main form shows it }

    cmdExit:
      begin
        if Assigned(FOnExitRequest) then
          FOnExitRequest(Self);
        Exit;
      end;
  end;

  Refresh;
end;

procedure TMView.ShowMessageText(const AText: string);
begin
  FPendingFile := '';
  StopAnimation;
  FShowingPaste := False;
  FCurrentImage := nil;
  FRenderer.SetImage(nil);
  FRenderer.SetMessage(AText);
  FRenderer.InfoText := '';
  Refresh;
end;

procedure TMView.UpdateInfo;
var
  Text: string;
begin
  { A pasted image (also when no file is open). }
  if FShowingPaste and Assigned(FCurrentImage) then
  begin
    Text := Format('%s     %d x %d', [FScratchTitle, FCurrentImage.Width, FCurrentImage.Height]);
    if FPasteSavedAs <> '' then
      Text := Text + '     saved as ' + FPasteSavedAs
    else
      Text := Text + '     not saved (menu: Save image)';
    if FStatusNote <> '' then
      Text := Text + '     ' + FStatusNote;
    FRenderer.InfoText := Text;
    Exit;
  end;

  if not FNavigator.HasCurrentImage then
  begin
    FRenderer.InfoText := '';
    Exit;
  end;

  Text := Format('%s     %d / %d', [FNavigator.CurrentFileName,
    FNavigator.CurrentIndex + 1, FNavigator.ImageCount]);

  if FNavigator.SortMode in [smFileNameAscending, smFileNameDescending] then
    Text := Text + '     by name'
  else
    Text := Text + '     by date';

  if FSkim then
    Text := Text + '     skimming'
  else if FPendingFile <> '' then
    Text := Text + '     loading ...';
  if not FNavigator.TreeReady then
    Text := Text + '     scanning folders ...';
  if Assigned(FCurrentImage) and (FCurrentImage.FrameCount > 1) then
    Text := Text + Format('     animated, %d frames', [FCurrentImage.FrameCount]);
  if FStatusNote <> '' then
    Text := Text + '     ' + FStatusNote;

  FRenderer.InfoText := Text;
end;

{ The part of the diagnostics line that the renderer can't know. }
procedure TMView.UpdateDiagnostics;
var
  Text: string;
  Waiting, Running: Integer;
begin
  Text := '';
  if Assigned(FCurrentImage) then
  begin
    case FCurrentImage.Quality of
      qlPreview: Text := 'preview';
      qlScreen:  Text := 'screen';
      qlFull:    Text := 'full';
    else
      Text := 'error';
    end;
    if FCurrentImage.IsError then
      Text := 'error';
    if FLastWasHit then
      Text := Text + ' from cache'
    else
      Text := Text + Format(' decode %d ms', [Round(FCurrentImage.DecodeMs)]);
    if FCurrentImage.PreviewMs > 0 then
      Text := Text + Format('     screen copy %d ms', [Round(FCurrentImage.PreviewMs)]);
    if not FCurrentImage.IsError then
      Text := Text + Format('     %d x %d', [FCurrentImage.FullWidth, FCurrentImage.FullHeight]);
    if Assigned(FAnimClock) and (FAnimImage = FCurrentImage) then
    begin
      Text := Text + Format('     frame %d / %d, %d skipped',
        [FAnimClock.Index + 1, FAnimClock.FrameCount, FAnimClock.Skipped]);
      if FAnimClock.Finished then
        Text := Text + ', done';
    end;
    if (FCurrentImage.Animation <> nil) and (FCurrentImage.Animation.Note <> '') then
      Text := Text + '     ' + FCurrentImage.Animation.Note;
  end;

  Text := Text + Format('     cache %d / %d MB',
    [FCache.UsedBytes div (1024 * 1024), FCache.BudgetMB]);

  FScheduler.GetCounts(Waiting, Running);
  Text := Text + Format('     jobs %d waiting, %d of %d workers busy',
    [Waiting, Running, FScheduler.WorkerCount]);

  if FSkim then
    Text := Text + '     SKIM'
  else
    Text := Text + '     browse';

  if FTimerPickups > 0 then
    Text := Text + Format('     timer pickups %d', [FTimerPickups]);

  if FConfig.DecodeDelayMs > 0 then
    Text := Text + Format('     (+%d ms simulated delay)', [FConfig.DecodeDelayMs]);

  FRenderer.DiagnosticsText := Text;
end;

{ UI thread: the renderer painted a new image for the first time. }
procedure TMView.HandleImagePainted(ALatencyMs, APaintMs: Double);
begin
  if FConfig.TimingLog then
  begin
    AppendTimingRow(ALatencyMs, APaintMs);
    if not FStartupLogged then
      AppendStartupRow(ProcessAgeMs);
  end;
  FStartupLogged := True;
end;

procedure TMView.NoteStartup(AWindowMs, AViewReadyMs, AViewSetupMs: Double);
begin
  FStartupWindowMs := AWindowMs;
  FStartupViewReadyMs := AViewReadyMs;
  FStartupViewSetupMs := AViewSetupMs;
end;

procedure TMView.SkipStartupLog;
begin
  FStartupLogged := True;
end;

{ One line per start in startup.csv next to MView.exe (TimingLog=1):
  where the time from the double-click to the first image goes. Any
  file error is ignored. }
procedure TMView.AppendStartupRow(AFirstImageMs: Double);
var
  LogFile: TextFile;
  LogName, ExeName, FirstFile: string;
  IsNew: Boolean;
  Info: TSearchRec;
  ExeMB: Double;
begin
  LogName := ExtractFilePath(ParamStr(0)) + 'startup.csv';
  IsNew := not FileExists(LogName);
  ExeName := ParamStr(0);
  ExeMB := 0;
  if FindFirst(ExeName, faAnyFile, Info) = 0 then
  begin
    ExeMB := Info.Size / (1024 * 1024);
    FindClose(Info);
  end;
  if Assigned(FCurrentImage) then
    FirstFile := FCurrentImage.Key.FileName
  else
    FirstFile := '';
  try
    AssignFile(LogFile, LogName);
    if IsNew then
      Rewrite(LogFile)
    else
      Append(LogFile);
    try
      if IsNew then
      begin
        WriteLn(LogFile, 'sep=;');
        WriteLn(LogFile, 'time;exe_mb;to_window_ms;view_setup_ms;to_view_ready_ms;'
          + 'to_first_image_ms;renderer;first_file');
      end;
      WriteLn(LogFile, Format('%s;%d;%d;%d;%d;%d;"%s";"%s"',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), Round(ExeMB),
         Round(FStartupWindowMs), Round(FStartupViewSetupMs), Round(FStartupViewReadyMs),
         Round(AFirstImageMs), FRenderer.Description, FirstFile]));
    finally
      CloseFile(LogFile);
    end;
  except
    { logging must never disturb viewing }
  end;
end;

{ Default.mouse (or [Mouse] Profile) next to MView.ini; written with
  the built-in profile if it isn't there yet, so it can be edited.
  Problems in the file are shown in the info line (the rest of the
  file still counts). }
procedure TMView.LoadMouseProfile;
var
  FileName: string;
  Lines: TStringList;
begin
  FileName := FConfig.MouseProfileFileName;
  try
    if FileExists(FileName) then
      FMouseProfile.LoadFromFile(FileName)
    else
    begin
      FMouseProfile.LoadDefaults;
      Lines := TStringList.Create;
      try
        Lines.Text := DefaultProfileText;
        try
          Lines.SaveToFile(FileName);
        except
          { read-only folder: the built-in profile is used }
        end;
      finally
        Lines.Free;
      end;
    end;
    if FMouseProfile.Errors.Count > 0 then
      ShowStatus(Format('%s: %d problem(s), e.g. %s', [ExtractFileName(FileName),
        FMouseProfile.Errors.Count, FMouseProfile.Errors[0]]), 20000);
  except
    on E: Exception do
    begin
      FMouseProfile.LoadDefaults;
      ShowStatus('mouse profile not readable, the built-in one is used: ' + E.Message, 20000);
    end;
  end;
end;

procedure TMView.SetSort(AMode: TSortMode);
begin
  if FNavigator.SortMode = AMode then
    Exit;
  FNavigator.SetSortMode(AMode);
  FConfig.SortMode := AMode;
  UpdateWanted;                 { other neighbours now }
  UpdateInfo;
end;

{ Browse from the parent of the opened folder: the current image stays
  (it is inside), the folders around it join the tree. }
procedure TMView.ParentFolder;
var
  Root, Parent: string;
begin
  Root := ExcludeTrailingPathDelimiter(FNavigator.RootDirectory);
  if Root = '' then
    Exit;
  Parent := ExtractFileDir(Root);
  if (Parent = '') or SameText(ExcludeTrailingPathDelimiter(Parent), Root) then
  begin
    ShowStatus('already at the top: ' + Root, 3000);
    Exit;
  end;
  ShowStatus('browsing from ' + Parent, 4000);
  OpenMedia(Parent, FNavigator.CurrentFileName);
end;

procedure TMView.ShowZone(AZone: Integer);
begin
  if (AZone < Ord(Low(TMouseZone))) or (AZone > Ord(High(TMouseZone))) then
    Exit;
  { Only with the diagnostics line (D): otherwise distracting. }
  if not FRenderer.ShowDiagnostics then
    Exit;
  FRenderer.ZoneLabel := FMouseProfile.ZoneTitle(TMouseZone(AZone));
  FRenderer.ZoneCorner := AZone;
  FZoneLabelUntilMs := NowMs + ZoneLabelMs;
end;

{ AValue: Ord(TMouseEvent) + 1 of the gesture being made, 0 = none. }
procedure TMView.ShowGesturePreview(AZone, AValue: Integer);
var
  Event: TMouseEvent;
  Zone: TMouseZone;
  Actions: TActionList;
begin
  if (AValue <= 0) or (AValue - 1 > Ord(High(TMouseEvent)))
    or (AZone < Ord(Low(TMouseZone))) or (AZone > Ord(High(TMouseZone))) then
  begin
    FRenderer.GestureText := '';
    Exit;
  end;
  Event := TMouseEvent(AValue - 1);
  Zone := TMouseZone(AZone);
  { What the engine will run: with the zones off, the Anywhere entry. }
  if FConfig.ZonesEnabled then
    Actions := FMouseProfile.ActionsFor(Zone, Event)
  else
    Actions := FMouseProfile.AnywhereActionsFor(Event);
  FRenderer.GestureText := MouseEventCaption(Event) + ':   ' + ActionListCaption(Actions);
end;

{ The clipboard's image (a screenshot, a picture copied in another
  program) is shown instead of the current file, until the next step;
  "Save image" writes it to the save folder. }
procedure TMView.PasteFromClipboard;
var
  Pic: TPicture;
  Stream: TMemoryStream;
  Bmp: TBGRABitmap;
  Img: IDecodedImage;
  Key: TImageKey;
  P: PBGRAPixel;
  I: Integer;
  AnyAlpha: Boolean;
begin
  Bmp := nil;
  Pic := TPicture.Create;
  Stream := TMemoryStream.Create;
  try
    try
      Pic.Assign(Clipboard);
      if (Pic.Graphic = nil) or (Pic.Width <= 0) or (Pic.Height <= 0) then
        raise Exception.Create('the clipboard holds no image');
      { Through a stream in the graphic's own format (BMP, PNG, ...):
        BGRABitmap reads that whatever the graphic class. }
      Pic.Graphic.SaveToStream(Stream);
      Stream.Position := 0;
      Bmp := TBGRABitmap.Create;
      Bmp.LoadFromStream(Stream);
      if (Bmp.Width <= 0) or (Bmp.Height <= 0) then
        raise Exception.Create('the clipboard image is empty');
      { Screenshots often come without alpha (all 0): make them opaque. }
      AnyAlpha := False;
      P := Bmp.Data;
      for I := 0 to Bmp.NbPixels - 1 do
      begin
        if P^.alpha <> 0 then
        begin
          AnyAlpha := True;
          Break;
        end;
        Inc(P);
      end;
      if not AnyAlpha then
      begin
        P := Bmp.Data;
        for I := 0 to Bmp.NbPixels - 1 do
        begin
          P^.alpha := 255;
          Inc(P);
        end;
        Bmp.InvalidateBitmap;
      end;
    except
      on E: Exception do
      begin
        FreeAndNil(Bmp);
        ShowStatus('paste: ' + E.Message, 5000);
        Exit;
      end;
    end;
  finally
    Stream.Free;
    Pic.Free;
  end;

  Key.FileName := 'Clipboard';
  Key.FileSize := 0;
  Key.FileTime := Now;
  Img := TDecodedImage.Create(Key, qlFull, Bmp);
  ShowScratch(Img, 'Clipboard image', 'clipboard');
end;

{ A pasted or cropped image, shown instead of the current file until
  the next step; "Save image" writes it. }
procedure TMView.ShowScratch(const AImage: IDecodedImage; const ATitle, APrefix: string);
begin
  FShowingPaste := True;
  FScratchTitle := ATitle;
  FScratchPrefix := APrefix;
  FPasteSavedAs := '';
  { A save of an earlier one may still be running: its result is not
    this image's. }
  FSavingPaste := False;
  FPendingFile := '';
  FCommandMs := 0;
  Display(AImage);
end;

function TMView.CanCrop: Boolean;
begin
  Result := FEditMode and FRenderer.Selection.Active and Assigned(FCurrentImage)
    and not FCurrentImage.IsError;
end;

procedure TMView.SetEditMode(AOn: Boolean);
begin
  if AOn = FEditMode then
    Exit;
  FEditMode := AOn;
  FRenderer.EditMode := AOn;
  ClearSelection;
  { Cropping wants the real pixels: the full image now. }
  if AOn then
    AllowFull;
  UpdateInfo;
  Refresh;
end;

procedure TMView.ClearSelection;
var
  Sel: TImageRect;
begin
  FSelAnchorValid := False;
  Sel := FRenderer.Selection;
  if not Sel.Active then
    Exit;
  Sel.Active := False;
  FRenderer.Selection := Sel;
end;

{ AX, AY: surface pixels. The selection runs from where the drag
  started to where it is, in original image pixels, inside the image. }
procedure TMView.DragSelection(AX, AY: Double; AStart: Boolean);
var
  IX, IY, W, H: Double;
  Sel: TImageRect;
begin
  if (FCurrentImage = nil) or FCurrentImage.IsError then
    Exit;
  if not FRenderer.ScreenToImage(AX, AY, IX, IY) then
    Exit;
  W := FCurrentImage.FullWidth;
  H := FCurrentImage.FullHeight;
  if (W <= 0) or (H <= 0) then
  begin
    W := FCurrentImage.Width;
    H := FCurrentImage.Height;
  end;
  IX := EnsureRange(IX, 0.0, W);
  IY := EnsureRange(IY, 0.0, H);
  if AStart or not FSelAnchorValid then
  begin
    FSelAnchorX := IX;
    FSelAnchorY := IY;
    FSelAnchorValid := True;
    if AStart then
      Exit;
  end;
  Sel.X0 := Min(FSelAnchorX, IX);
  Sel.X1 := Max(FSelAnchorX, IX);
  Sel.Y0 := Min(FSelAnchorY, IY);
  Sel.Y1 := Max(FSelAnchorY, IY);
  Sel.Active := (Sel.X1 - Sel.X0 >= 1) and (Sel.Y1 - Sel.Y0 >= 1);
  FRenderer.Selection := Sel;
end;

{ The selected area becomes the image shown, fitted to the screen (same
  rotation); "Save image" writes it. From the best version in memory:
  the full image if it is there, else the quick view (said so). }
procedure TMView.CropSelection;
var
  Img, Cropped: IDecodedImage;
  Src, Bmp: TBGRABitmap;
  Sel: TImageRect;
  FullW, FullH, BX0, BY0, BX1, BY1, W, H, Row: Integer;
  FX, FY, Angle: Double;
  Key: TImageKey;
  Reason, SourceName, Note: string;
begin
  if not CanCrop then
  begin
    if FEditMode then
      ShowStatus('nothing selected: drag over the image first', 4000)
    else
      ShowStatus('crop: switch edit mode on (Edit zone) and drag over the image first', 5000);
    Exit;
  end;
  Sel := FRenderer.Selection;

  { The pixels: while an animation plays, the frame on screen; a pasted
    or cropped image as it is; a file: its best version in memory. }
  if Assigned(FAnimImage) and Assigned(FRenderer.Image) then
    Img := FRenderer.Image
  else if FShowingPaste then
    Img := FCurrentImage
  else
  begin
    Img := FCache.Get(FCurrentImage.Key);
    if (Img = nil) or Img.IsError or (Img.Quality < FCurrentImage.Quality) then
      Img := FCurrentImage;
  end;
  Src := Img.Bitmap;
  if (Src = nil) or (Src.Width <= 0) or (Src.Height <= 0) then
  begin
    ShowStatus('crop: the image is not in memory (yet)', 4000);
    Exit;
  end;
  FullW := Img.FullWidth;
  FullH := Img.FullHeight;
  if (FullW <= 0) or (FullH <= 0) then
  begin
    FullW := Src.Width;
    FullH := Src.Height;
  end;

  { Original pixels -> pixels of the bitmap at hand (smaller for a quick
    view). }
  FX := Src.Width / FullW;
  FY := Src.Height / FullH;
  BX0 := EnsureRange(Floor(Sel.X0 * FX), 0, Src.Width - 1);
  BY0 := EnsureRange(Floor(Sel.Y0 * FY), 0, Src.Height - 1);
  BX1 := EnsureRange(Ceil(Sel.X1 * FX), BX0 + 1, Src.Width);
  BY1 := EnsureRange(Ceil(Sel.Y1 * FY), BY0 + 1, Src.Height);
  W := BX1 - BX0;
  H := BY1 - BY0;
  if not DecodeFits(W, H, 0, Reason) then
  begin
    ShowStatus('crop: ' + Reason, 6000);
    Exit;
  end;

  Bmp := TBGRABitmap.Create(W, H);
  for Row := 0 to H - 1 do
    Move((Src.ScanLine[BY0 + Row] + BX0)^, Bmp.ScanLine[Row]^, W * SizeOf(TBGRAPixel));
  Bmp.InvalidateBitmap;

  if FShowingPaste then
    SourceName := FScratchPrefix
  else
    SourceName := ChangeFileExt(ExtractFileName(FCurrentImage.Key.FileName), '');
  Key.FileName := SourceName + '_crop';
  Key.FileSize := 0;
  Key.FileTime := Now;
  { Its size in original pixels, so 100 % still means one original
    pixel per screen pixel when it came from the quick view. }
  Cropped := TDecodedImage.Create(Key, qlFull, Bmp, nil, 0, 0,
    Max(1, Round(W / FX)), Max(1, Round(H / FY)));

  Note := '';
  if Img.Quality < qlFull then
    Note := '  (from the quick view: the full image wasn''t loaded yet)';
  Angle := FRenderer.View.Angle;
  ShowScratch(Cropped, 'Cropped from ' + SourceName + Note, SourceName + '_crop');
  { The same way round as before, fitted to the screen. }
  if Angle <> 0 then
    FRenderer.RotateBy(Angle);
  UpdateInfo;
  Refresh;
end;

{ Esc (Back), hard-wired (user, 2026-09-27): edit mode ends first;
  otherwise back to the settings editor (the start screen). Only there
  does Esc end MView. (A zoom / rotate mode is ended by the engine.) }
procedure TMView.GoBack;
begin
  if FEditMode then
    SetEditMode(False)
  else if Assigned(FOnSettingsRequest) then
    FOnSettingsRequest(Self)
  else if Assigned(FOnExitRequest) then
    FOnExitRequest(Self);
end;

{ "Save image": the image as PNG into the save folder (Documents the
  first time, see TConfig.SaveDirectory). The best version in memory:
  the full image if it is there. }
procedure TMView.SaveImageOnly;
var
  Img: IDecodedImage;
  Dir, FileName: string;
begin
  if Assigned(FSaveThread) then
  begin
    ShowStatus('still saving the previous image ...', 3000);
    Exit;
  end;
  if (FCurrentImage = nil) or FCurrentImage.IsError then
  begin
    ShowStatus('nothing to save', 3000);
    Exit;
  end;
  Dir := FConfig.SaveDirectory;
  if FShowingPaste then
  begin
    Img := FCurrentImage;
    FileName := Dir + FScratchPrefix + '_' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.png';
    FSavingPaste := True;
  end
  else
  begin
    Img := FCache.Get(FCurrentImage.Key);
    if (Img = nil) or Img.IsError or (Img.Quality < FCurrentImage.Quality) then
      Img := FCurrentImage;
    FileName := SavedImageFileName(Dir, Img);
    FSavingPaste := False;
  end;
  FSaveThread := TImageSaveThread.Create(Img, FileName);
  ShowStatus('saving ' + ExtractFileName(FileName) + ' ...', 0);
end;

{ One line per displayed image in timing.csv next to MView.exe.
  The first line "sep=;" tells Excel the separator, whatever the
  regional settings. Whole milliseconds only, so no decimal separator
  question arises. Logging must never disturb viewing, so any file
  error is ignored. }
procedure TMView.AppendTimingRow(ALatencyMs, APaintMs: Double);
var
  LogFile: TextFile;
  LogName, Source, Outcome, QualityName: string;
  IsNew: Boolean;
begin
  if FCurrentImage = nil then
    Exit;

  LogName := ExtractFilePath(ParamStr(0)) + 'timing.csv';
  IsNew := not FileExists(LogName);

  if FLastWasHit then
    Source := 'cache'
  else
    Source := 'decoded';
  if FCurrentImage.IsError then
    Outcome := 'error'
  else
    Outcome := 'ok';
  case FCurrentImage.Quality of
    qlPreview: QualityName := 'preview';
    qlScreen:  QualityName := 'screen';
    qlFull:    QualityName := 'full';
  else
    QualityName := '';
  end;

  try
    AssignFile(LogFile, LogName);
    if IsNew then
      Rewrite(LogFile)
    else
      Append(LogFile);
    try
      if IsNew then
      begin
        WriteLn(LogFile, 'sep=;');
        WriteLn(LogFile, 'time;file;width;height;file_kb;decode_ms;screen_copy_ms;'
          + 'latency_ms;paint_ms;source;result;simulated_delay_ms;quality');
      end;
      WriteLn(LogFile, Format('%s;"%s";%d;%d;%d;%d;%d;%d;%d;%s;%s;%d;%s',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
         FCurrentImage.Key.FileName,
         FCurrentImage.FullWidth,
         FCurrentImage.FullHeight,
         FCurrentImage.Key.FileSize div 1024,
         Round(FCurrentImage.DecodeMs),
         Round(FCurrentImage.PreviewMs),
         Round(ALatencyMs),
         Round(APaintMs),
         Source,
         Outcome,
         FConfig.DecodeDelayMs,
         QualityName]));
    finally
      CloseFile(LogFile);
    end;
  except
    { ignore: a locked or read-only file must not stop the viewer }
  end;
end;

{ Debugging aid: the best decoded version of the current image (as
  PNG, on a background thread) and a picture of the window, both into
  [Debug] SaveImageDirectory. }
procedure TMView.SaveCurrentImage;
var
  Img: IDecodedImage;
begin
  if Assigned(FSaveThread) then
  begin
    ShowStatus('still saving the previous image ...', 3000);
    Exit;
  end;
  if (FCurrentImage = nil) or FCurrentImage.IsError then
  begin
    ShowStatus('nothing to save', 3000);
    Exit;
  end;

  { The best version in memory: the full image if it is there. }
  Img := FCache.Get(FCurrentImage.Key);
  if (Img = nil) or Img.IsError or (Img.Quality < FCurrentImage.Quality) then
    Img := FCurrentImage;

  FSaveThread := TImageSaveThread.Create(Img,
    SavedImageFileName(FConfig.SaveDirectory, Img));
  FSavingPaste := False;
  FRenderer.RequestScreenshot(SavedViewFileName(FConfig.SaveDirectory, Img));
  ShowStatus('saving ' + ExtractFileName(FSaveThread.FileName) + ' ...', 0);
end;

procedure TMView.ShowStatus(const AText: string; ADurationMs: Double);
begin
  FStatusNote := AText;
  if ADurationMs > 0 then
    FStatusUntilMs := NowMs + ADurationMs
  else
    FStatusUntilMs := 0;
  UpdateInfo;
  Refresh;
end;

procedure TMView.PumpDeliveries;
var
  Shot: string;
begin
  { Debugging saves: report when done. }
  Shot := FRenderer.TakeScreenshotResult;
  if Shot <> '' then
  begin
    if Assigned(FSaveThread) then
    begin
      { The image is still being written: show both. }
      FViewNote := Shot;
      ShowStatus(Shot + '     saving image ...', 0);
    end
    else
      ShowStatus(Shot, 6000);
  end;
  if Assigned(FSaveThread) and FSaveThread.Finished then
  begin
    if FViewNote <> '' then
      ShowStatus(FSaveThread.ResultText + '     ' + FViewNote, 8000)
    else
      ShowStatus(FSaveThread.ResultText, 8000);
    FViewNote := '';
    { A pasted image: the info line says where it went. }
    if FSavingPaste and (Pos('saved', FSaveThread.ResultText) = 1) then
      FPasteSavedAs := FSaveThread.FileName;
    FSavingPaste := False;
    FreeAndNil(FSaveThread);
    UpdateInfo;
  end;
  if (FStatusNote <> '') and (FStatusUntilMs > 0) and (NowMs > FStatusUntilMs) then
    ShowStatus('', 0);

  { CheckSynchronize runs every queued call and reports whether there
    was one. Normally the queue is already empty here. }
  if CheckSynchronize(0) then
  begin
    Inc(FTimerPickups);
    UpdateDiagnostics;
    Refresh;
  end;

  { The window size has settled: quick views of other files are made
    again for it (the current one gets its full size soon anyway). }
  if FSizeChanged and (NowMs - FSizeChangedMs >= WindowSettleMs) then
  begin
    FSizeChanged := False;
    if Assigned(FCache) then
    begin
      FCache.DropQuality(qlScreen, FNavigator.CurrentFileName);
      if FNavigator.HasCurrentImage then
        UpdateWanted;
    end;
  end;

  { The zone's name has been shown long enough. }
  if (FRenderer.ZoneLabel <> '') and (NowMs > FZoneLabelUntilMs) then
  begin
    FRenderer.ZoneLabel := '';
    Refresh;
  end;

  { Skimming has stopped. }
  if FSkim and (NowMs - FLastNavMs >= FConfig.SkimExitMs) then
    LeaveSkim;

  { Reads that don't come back (Day 19). }
  if NowMs - FLastStuckCheckMs >= 500 then
  begin
    FLastStuckCheckMs := NowMs;
    CheckStuckReads;
  end;

  { The pause before the full-size decode is over. }
  if (not FFullAllowed) and (FShownFile <> '') and FNavigator.HasCurrentImage
    and (NowMs - FShownSinceMs >= FConfig.RefineDelayMs) then
    AllowFull;
end;

function TMView.IsDiskError(const AImage: IDecodedImage): Boolean;
begin
  Result := (AImage <> nil) and AImage.IsError
    and (Pos(DiskNotRespondingText, AImage.ErrorMessage) = 1);
end;

{ Workers stuck in a read are replaced by the scheduler; their files
  get an error placeholder, so the viewer moves on. }
procedure TMView.CheckStuckReads;
var
  Files: TStringArray;
  FileName: string;
  Key: TImageKey;
  Err: IDecodedImage;
  I: Integer;
begin
  Files := FScheduler.CheckStuck(StuckReadMs);
  for I := 0 to High(Files) do
  begin
    FileName := Files[I];
    if not FNavigator.ListedKey(FileName, Key) then
    begin
      Key.FileName := FileName;
      Key.FileSize := 0;
      Key.FileTime := 0;
    end;
    Err := TDecodedImage.CreateError(Key, Format('%s (no answer for %d s): %s',
      [DiskNotRespondingText, StuckReadMs div 1000, FileName]));
    FCache.Put(Err);
    ShowStatus('disk not responding: ' + ExtractFileName(FileName), 10000);

    if SameText(FileName, FNavigator.CurrentFileName) then
    begin
      FPendingFile := '';
      { Nothing shown for it yet, or only its thumbnail: show why. }
      if (not FShowingPaste) and ((FCurrentImage = nil)
        or not SameText(FCurrentImage.Key.FileName, FileName)
        or (FCurrentImage.Quality < qlScreen)) then
        Display(Err);
    end;
  end;
  if Length(Files) > 0 then
  begin
    UpdateWanted;
    UpdateDiagnostics;
    Refresh;
  end;

  if Assigned(FScanner) and (FScanner.LastAliveAgeMs > ScannerStuckMs)
    and not FScannerNoteShown then
  begin
    FScannerNoteShown := True;
    ShowStatus('reading folders: the disk is not responding', 0);
  end;
end;

procedure TMView.AllowFull;
begin
  if FFullAllowed then
    Exit;
  FFullAllowed := True;
  UpdateWanted;
  UpdateDiagnostics;
end;

procedure TMView.Refresh;
begin
  if Assigned(FSurface) then
    FSurface.Invalidate;
end;

end.
