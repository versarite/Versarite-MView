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
  - Sorting (Phase G): FPanel (TSortPanel, the panel at the right
    edge), FMover (TFileMover, its worker thread; made at the first
    copy / move / delete), the undo list FUndo (up to 50 entries) and
    FMoves (moves under way). The file sorting.log next to MView.exe
    (the mover appends to it).
  - Stage 2: FIcons (TSortIcons: the buttons' icons and the missing-
    folder check, read on its own thread when the panel opens), the
    making of an icon from the image (MakeIconFromImage, written by the
    mover), sorting a pasted or cropped image (saved into the folder by
    the save thread), a swipe / wheel click into a slot's folder, and
    the paste from the settings screen (StartWithPaste).
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
  - TConfig.SortFolders (the slots, changed by the form's slot menu or
    a drop), SortEdgeDelayMs, SortPinned, DeletedFilesFolder.
  - OnSortMenu: the form's slot menu.

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
  - Sorting (Phase G, G1): the panel's mouse (hover, edge opening, the
    wheel scrolls, left click on a button = copy, right click = move,
    pin, bottom line = undo); copy / move / delete on the mover's
    thread; a moved or deleted image leaves the lists at once and the
    next one shows (back if the move fails); a copy or move into a
    browsed folder shows up there; Undo (a copy goes into the
    deleted-files folder, a moved or deleted file back to its folder).
    Nothing is ever really deleted and nothing overwritten (_1).
  - Keep the settings that change while viewing (info line,
    diagnostics line, sort mode, last folder and file) and save them
    first on shutdown.

  Does NOT
  --------
  - Draw, decode or scan directories itself.
  - Handle raw input.
  - Depend on the form. Window actions (exit, fullscreen) are
    requested through events that the form connects.
  - Show the menu (the main form does, on cmdShowMenu), nor the slot
    menu or folder dialogs (the form, through OnSortMenu).
  - Touch the disk for sorting on the window thread (the mover does;
    only SortStartFolder checks a few folders, when a dialog opens).

  Threads
  -------
  UI thread. Results from the decode workers (HandleImageReady) and
  the scanner thread (HandleStartReady, HandleTreeReady) arrive
  through TThread.Queue and so also run on the UI thread;
  PumpDeliveries (the form's 50 ms timer) picks up any that wait
  (CheckSynchronize). The save thread only writes its file; its
  result is read in PumpDeliveries once it has finished. The
  animation runs on a UI-thread TTimer. The file mover's results
  arrive through TThread.Queue as well (HandleFileJobDone). No locks of
  its own.

  Uses (MView units)
  ------------------
  interface:      uTypes, uCommands, uConfig, uDirectoryTree,
                  uNavigator, uDecodedImage, uMediaLoader,
                  uImageCache, uJobScheduler, uDirectoryScanner,
                  uRenderer, uAnimation, uMouseProfile, uJobQueue,
                  uIOGate, uMemoryGuard, uImageSaver, uStopwatch,
                  uSortFolders, uSortPanel, uFileMover
  Libraries:      Classes, SysUtils, Math, Controls, ExtCtrls,
                  Graphics, Clipbrd, BGRABitmap, BGRABitmapTypes,
                  Forms (implementation: Screen, for the DPI)

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
  uStopwatch,
  uSortFolders,
  uSortPanel,
  uSortIcons,
  uFileMover;

type

  { Sorting (Phase G): one copy / move / delete that can be taken back. }
  TUndoEntry = record
    Id: Integer;
    Kind: TFileJobKind;      { fjSort or fjDelete }
    Action: TFileAction;     { faCopy: a copy was made; faMove: the file went }
    Original: string;        { where the file was (is, for a copy) }
    Placed: string;          { the copy, or where the file went }
    Caption: string;         { the slot's name, or 'deleted files' }
    Pending: Boolean;        { its undo is under way }
  end;

  { A move under way: the file left the lists at once; if the move
    fails it comes back. }
  TMoveUnderWay = record
    JobId: Integer;
    Source: string;
    Key: TImageKey;          { its size and date, as listed }
    FollowedBy: string;      { the file current after it left }
  end;

  { The panel's "..." corner of slot ASlot, or its "+" (ASlot = -1):
    the form shows the folder menu / dialog at AScreen. }
  TSortMenuEvent = procedure(ASlot: Integer; const AScreen: TPoint) of object;


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
    FSaveAsDir: string;          { "Save image as": the folder last chosen (session) }

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

    { Sorting (Phase G, G1): the panel at the right edge, the file mover
      (made at the first copy / move / delete: nothing at start-up), the
      undo list (newest last) and the moves under way. }
    FPanel: TSortPanel;
    FMover: TFileMover;
    FUndo: array of TUndoEntry;
    FNextUndoId: Integer;
    FNextJobId: Integer;
    FJobsInFlight: Integer;      { copies / moves / deletes not reported yet }
    FMoves: array of TMoveUnderWay;
    FPanelPress: TPanelHit;      { where a button went down on the panel }
    FPanelPressX, FPanelPressY: Integer;
    { Copy / move need a double click on a button (user, Day 21: single
      clicks sorted too easily): the first click of the pair. }
    FSlotClickSlot: Integer;     { -1 = none }
    FSlotClickButton: TOverlayButton;
    FSlotClickMs: Double;
    FSlotClickX, FSlotClickY: Integer;
    FDoubleClickMs: Integer;
    { A pasted or cropped image being saved into a sort folder (Day 21):
      its slot (-1 = none) and whether it was a "move". }
    FSortSaveSlot: Integer;
    FSortSaveImage: IDecodedImage;   { ... the image (shown again if a "move" failed) }
    FSortSaveTitle, FSortSavePrefix: string;
    FSortSaveMove: Boolean;
    { Pasted from the settings screen: the last session opens behind it
      without replacing it. }
    FKeepScratch: Boolean;
    FPanelPressButton: TOverlayButton;
    FPanelViewW, FPanelViewH: Integer;
    FPanelScale: Double;
    FOnSortMenu: TSortMenuEvent;
    { Stage 2: the buttons' icons and the missing-folder check (read on
      their own thread), and whether the panel was open at the last
      UpdatePanel (opening reads the icon folder again). }
    FIcons: TSortIcons;
    FPanelWasVisible: Boolean;

    procedure ShowCurrent;
    procedure UpdateWanted;
    procedure SaveCurrentImage;
    procedure SaveImageOnly;
    function ImageToSave: IDecodedImage;
    procedure StartSave(const AImage: IDecodedImage; const AFileName, AFallbackDir: string);
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
    { Sorting }
    function Mover: TFileMover;
    procedure SyncPanelLayout;
    procedure UpdatePanel;
    procedure PanelClick(const AHit: TPanelHit; AButton: TOverlayButton);
    function CanSortCurrent(out AFileName: string): Boolean;
    procedure SortScratch(ASlot: Integer; AMove: Boolean);
    procedure SortScratchSaved;
    procedure OpenSlotFolder(ASlot: Integer);
    function SecondSlotClick(ASlot: Integer; AButton: TOverlayButton): Boolean;
    procedure QueueJob(var AJob: TFileJob);
    procedure StartMove(var AJob: TFileJob);
    procedure HandleFileJobDone(const AResult: TFileJobResult);
    procedure AddUndo(const AJob: TFileJob; const APlaced: string);
    function UndoIndex(AId: Integer): Integer;
    function LastUndo: Integer;
    procedure DeleteUndo(AIndex: Integer);
    procedure SortNote(const AStatus, AFooter: string; ADurationMs: Double);
    { Icons (stage 2). }
    procedure RequestIcons(AForce: Boolean);
    procedure HandleIconsChanged(Sender: TObject);
    function PanelSlotIcon(ASlot, ASize: Integer): TBGRABitmap;
    function PanelSlotMissing(ASlot: Integer): Boolean;
    procedure HandleIconWritten(const AResult: TFileJobResult);
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

    { "Save image as" (menu, Phase F): the form asks for a file name with
      a save dialog. CanSaveImage: there is something to save (and no
      save running). SaveAsSuggestion: the folder to start in and a file
      name. SaveImageAs: writes the PNG (".png" is added if missing). }
    function CanSaveImage: Boolean;
    procedure SaveAsSuggestion(out ADirectory, AFileName: string);
    procedure SaveImageAs(const AFileName: string);

    { Sorting (Phase G, G1, spec §15). The surfaces offer every mouse
      event to HandleOverlayMouse first (their OnOverlayMouse); True =
      the panel took it. }
    function HandleOverlayMouse(AKind: TOverlayMouseKind; AButton: TOverlayButton;
      AX, AY, AWheel: Integer; AButtonDown, ADouble: Boolean): Boolean;
    { Copy (AMove False) or move the current image into slot ASlot. }
    procedure SortCurrent(ASlot: Integer; AMove: Boolean);
    { Moves the current image into the deleted-files folder. MView never
      really deletes. }
    procedure DeleteCurrent;
    { Takes back the newest copy / move / delete not yet taken back. }
    procedure UndoLast;
    { The menu's text for Undo; '' = nothing to take back. }
    function UndoCaption: string;
    { The panel opened by the menu or a key (stays until the mouse has
      been on it), or closed. }
    procedure ShowSortPanel(AShow: Boolean);
    function SortPanelVisible: Boolean;
    { The slots changed (the form's folder menu, a drop): save [Sort]
      and redraw the panel. }
    procedure SortFoldersChanged;
    { The part of the panel at a point of the view (a drop). }
    function SortPanelHit(AX, AY: Integer): TPanelHit;
    { The window lost the focus / the mouse left: no hover, no edge timer. }
    procedure SortPanelMouseGone;
    { A note in the info line (the main form's window actions). }
    procedure ShowNote(const AText: string; ADurationMs: Double);
    { The settings screen's Ctrl+V with an image in the clipboard: the
      viewer starts with it (the last session opens behind it). }
    procedure StartWithPaste;
    { Browse slot ASlot's folder (a swipe to the right over its button,
      a wheel click on it, or its "..." menu). }
    procedure OpenSortFolder(ASlot: Integer);
    { A copy, move or delete (or undo) is waiting or running: shutting
      down waits for the one running (the form allows it more time). }
    function FileJobsBusy: Boolean;
    { The folder a new slot's dialog starts in (slot folder, else the
      parent of the last folder chosen, else the image's folder's parent,
      else Documents). ASlot -1: a new slot. }
    function SortStartFolder(ASlot: Integer): string;
    property OnSortMenu: TSortMenuEvent read FOnSortMenu write FOnSortMenu;

    { Icons (stage 2, spec §9.7). SlotIconFile: the icon file slot ASlot
      uses: its own (Slot<n>Icon, a name in the icon folder or a full
      path), else the one named like its folder (Good.ico / Good.png for
      ...\Good) if the icon folder has it; '' = none (the coloured
      folder; Slot<n>Icon=- asks for that). }
    function SlotIconFile(ASlot: Integer): string;
    { The icons read (the form's slot menu shows the icon folder's). }
    property SortIcons: TSortIcons read FIcons;
    { Read the icon folder again (after the form changed it). }
    procedure ReloadIcons;
    { "Make icon from this image": the edit-mode selection, else the
      middle of what is on screen, as a square; 16 .. 256 px PNG
      pictures in one .ico named after the current image's folder, into
      the icon folder (an older one becomes <name>_previous.ico). }
    function CanMakeIcon: Boolean;
    procedure MakeIconFromImage;
  end;

implementation

uses
  Forms,
  FPWritePNG,
  uMouseEngine,
  uIconFile;

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

  { Sort panel: a swipe to the right over a button opens its folder; at
    least this far (px at 96 dpi). }
  SwipePx = 40;

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
  FPanel.Free;
  FIcons.Free;
  FConfig.Free;
  inherited Destroy;
end;

procedure TMView.Shutdown;
begin
  StopAnimation;

  { The waits below run queued calls: an icon load delivered now must
    not reach the panel (the view may be gone already). }
  if Assigned(FIcons) then
    FIcons.OnChanged := nil;

  { A copy or move being done is finished (never half a file); those
    not started yet are dropped: the files stay where they are. }
  if Assigned(FMover) then
  begin
    FMover.OnDone := nil;
    FreeAndNil(FMover);
  end;

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

  { The sort panel (Phase G): drawn only when it is open. }
  FPanel := TSortPanel.Create(FConfig.SortFolders);
  FPanel.EdgeDelayMs := FConfig.SortEdgeDelayMs;
  FPanel.EdgeWidth := FConfig.SortEdgeWidth;
  FPanel.Pinned := FConfig.SortPinned;
  FPanel.FooterText := 'double-click:' + LineEnding + 'left = copy,  right = move';
  FPanelPress.Part := ppNone;
  FPanelPress.Slot := -1;
  FSortSaveSlot := -1;
  FSlotClickSlot := -1;
  FDoubleClickMs := SystemDoubleClickMs;
  { Icons: read when the panel first opens, not at start-up. }
  FIcons := TSortIcons.Create;
  FIcons.OnChanged := @HandleIconsChanged;
  FPanel.OnSlotIcon := @PanelSlotIcon;
  FPanel.OnSlotMissing := @PanelSlotMissing;
  if FPanel.Pinned then
    FPanel.Show;
end;

procedure TMView.AttachView(ASurface: TWinControl; ARenderer: TRenderer);
begin
  FSurface := ASurface;
  FPanelViewW := 0;    { the panel's layout follows the new surface }
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
  UpdatePanel;
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
  FKeepScratch := False;   { StartWithPaste sets it again, after this }
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
var
  I: Integer;
begin
  try
    if AStart.Generation <> FScanGeneration then
      Exit;   { from an older request }
    ShowStatus('', 0);
    if not AStart.Found then
    begin
      if FKeepScratch and FShowingPaste then
        ShowStatus('not found: ' + AStart.RequestedPath, 6000)
      else
        ShowMessageText('Not found:   ' + AStart.RequestedPath);
      FKeepScratch := False;
      Exit;
    end;

    FNavigator.OpenListed(AStart.Root, AStart.TargetDirectory, AStart.Listing,
      AStart.TargetFile);
    { Moves still under way (sorting): listed before they happened. }
    for I := 0 to High(FMoves) do
      FNavigator.RemoveFile(FMoves[I].Source);
    FConfig.LastDirectory := FNavigator.RootDirectory;
    FLastStep := cmdNextImage;
    FSkipCount := 0;
    FSkipStartFile := FNavigator.CurrentFileName;
    { Pasted on the settings screen: the image stays; the files are
      there for the next step. }
    if FKeepScratch and FShowingPaste then
    begin
      FKeepScratch := False;
      UpdateWanted;
      UpdateInfo;
      Refresh;
    end
    else
    begin
      FKeepScratch := False;
      ShowCurrent;
    end;
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

  { The scanner may have chosen another root. A pasted or cropped image
    on screen stays. }
  if FNavigator.SetTree(ATree) and not FShowingPaste then
  begin
    FConfig.LastDirectory := FNavigator.RootDirectory;
    ShowCurrent;                { an empty start folder moved on }
  end
  else if (not FNavigator.HasCurrentImage) and not FShowingPaste then
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

    cmdSortPanel:
      ShowSortPanel(not SortPanelVisible);
    cmdDeleteImage:
      begin
        DeleteCurrent;
        Exit;
      end;
    cmdUndo:
      begin
        UndoLast;
        Exit;
      end;
    cmdSideBySide:
      ;   { the main form does it (windows are its business) }

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

{ The size in the file (the full image), not of a quick view. }
function ImageWidth(const AImage: IDecodedImage): Integer;
begin
  Result := AImage.FullWidth;
  if Result <= 0 then
    Result := AImage.Width;
end;

function ImageHeight(const AImage: IDecodedImage): Integer;
begin
  Result := AImage.FullHeight;
  if Result <= 0 then
    Result := AImage.Height;
end;

procedure TMView.UpdateInfo;
var
  Text, FileName: string;
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

  { Name, size (once the image is there), folder, then the rest
    (user, Phase F). }
  FileName := FNavigator.CurrentFileName;
  Text := ExtractFileName(FileName);
  if Assigned(FCurrentImage) and not FCurrentImage.IsError
    and SameText(FCurrentImage.Key.FileName, FileName) then
    Text := Text + Format('     %d x %d', [ImageWidth(FCurrentImage), ImageHeight(FCurrentImage)]);
  Text := Text + '     ' + ExtractFileDir(FileName);
  Text := Text + Format('     %d / %d', [FNavigator.CurrentIndex + 1, FNavigator.ImageCount]);

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

{ Esc (Back), hard-wired (user, 2026-09-27): an open sort panel closes
  first (Phase G), then edit mode ends;
  otherwise back to the settings editor (the start screen). Only there
  does Esc end MView. (A zoom / rotate mode is ended by the engine.) }
procedure TMView.GoBack;
begin
  if Assigned(FPanel) and FPanel.Visible then
    ShowSortPanel(False)
  else if FEditMode then
    SetEditMode(False)
  else if Assigned(FOnSettingsRequest) then
    FOnSettingsRequest(Self)
  else if Assigned(FOnExitRequest) then
    FOnExitRequest(Self);
end;

{ "Save image": the image as PNG into the save folder (Documents the
  first time, see TConfig.SaveDirectory). If that folder can't be used
  (a wrong path in MView.ini, a missing drive), the file goes to the
  Documents folder instead and the status line says so (Day 20). }
procedure TMView.SaveImageOnly;
var
  Img: IDecodedImage;
  FileName: string;
begin
  if Assigned(FSaveThread) then
  begin
    ShowStatus('still saving the previous image ...', 3000);
    Exit;
  end;
  Img := ImageToSave;
  if Img = nil then
  begin
    ShowStatus('nothing to save', 3000);
    Exit;
  end;
  if FShowingPaste then
    FileName := FConfig.SaveDirectory + FScratchPrefix + '_'
      + FormatDateTime('yyyymmdd-hhnnss', Now) + '.png'
  else
    FileName := SavedImageFileName(FConfig.SaveDirectory, Img);
  StartSave(Img, FileName, UserDocumentsDirectory);
end;

{ The best version in memory of what is shown: the full image if it is
  there; a pasted or cropped image as it is. nil: nothing to save. }
function TMView.ImageToSave: IDecodedImage;
begin
  Result := nil;
  if (FCurrentImage = nil) or FCurrentImage.IsError then
    Exit;
  if FShowingPaste then
    Exit(FCurrentImage);
  Result := FCache.Get(FCurrentImage.Key);
  if (Result = nil) or Result.IsError or (Result.Quality < FCurrentImage.Quality) then
    Result := FCurrentImage;
end;

{ AFallbackDir: where the file goes if its folder can't be used; '' =
  nowhere (Save as: the user chose that folder, so say it failed). }
procedure TMView.StartSave(const AImage: IDecodedImage; const AFileName, AFallbackDir: string);
begin
  FSavingPaste := FShowingPaste;
  FSaveThread := TImageSaveThread.Create(AImage, AFileName, AFallbackDir);
  ShowStatus('saving ' + ExtractFileName(AFileName) + ' ...', 0);
end;

function TMView.CanSaveImage: Boolean;
begin
  Result := (FSaveThread = nil) and (ImageToSave <> nil);
end;

procedure TMView.SaveAsSuggestion(out ADirectory, AFileName: string);
begin
  { Not FConfig.SaveDirectory: that writes MView.ini the first time,
    and a dialog that is cancelled should change nothing. }
  if FSaveAsDir <> '' then
    ADirectory := FSaveAsDir
  else if Trim(FConfig.SaveImageDirectory) <> '' then
    ADirectory := IncludeTrailingPathDelimiter(Trim(FConfig.SaveImageDirectory))
  else
    ADirectory := UserDocumentsDirectory;
  if FShowingPaste then
    AFileName := FScratchPrefix + '_' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.png'
  else if Assigned(FCurrentImage) then
    AFileName := ChangeFileExt(ExtractFileName(FCurrentImage.Key.FileName), '.png')
  else
    AFileName := 'image.png';
end;

procedure TMView.SaveImageAs(const AFileName: string);
var
  Img: IDecodedImage;
  FileName, Ext: string;
begin
  if Assigned(FSaveThread) then
  begin
    ShowStatus('still saving the previous image ...', 3000);
    Exit;
  end;
  Img := ImageToSave;
  if (Img = nil) or (Trim(AFileName) = '') then
  begin
    ShowStatus('nothing to save', 3000);
    Exit;
  end;
  { MView writes PNG only: the name says so ("cell.jpg" -> "cell.png";
    another ending, e.g. "cell.v2", is kept: "cell.v2.png"). }
  FileName := AFileName;
  Ext := LowerCase(ExtractFileExt(FileName));
  if (Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.jpe') or (Ext = '.tif')
    or (Ext = '.tiff') or (Ext = '.bmp') or (Ext = '.gif') then
    FileName := ChangeFileExt(FileName, '.png')
  else if Ext <> '.png' then
    FileName := FileName + '.png';
  FSaveAsDir := IncludeTrailingPathDelimiter(ExtractFileDir(FileName));
  StartSave(Img, FileName, '');
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
    SavedImageFileName(FConfig.SaveDirectory, Img), UserDocumentsDirectory);
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
    if FSavingPaste and (FSaveThread.SavedFileName <> '') then
      FPasteSavedAs := FSaveThread.SavedFileName;
    FSavingPaste := False;
    if FSortSaveSlot >= 0 then
      SortScratchSaved;
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

  { The sort panel: follows the view's size; opens at the edge, closes
    when the mouse has left it (unpinned). }
  if Assigned(FPanel) then
  begin
    SyncPanelLayout;
    if FPanel.Tick(NowMs) then
      UpdatePanel;
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

{ ---- Sorting (Phase G, G1) ------------------------------------------- }

const
  MaxUndoEntries = 50;
  SortNoteMs = 5000;

function TMView.Mover: TFileMover;
begin
  if FMover = nil then
  begin
    FMover := TFileMover.Create(ExtractFilePath(ParamStr(0)) + 'sorting.log');
    FMover.OnDone := @HandleFileJobDone;
  end;
  Result := FMover;
end;

{ The panel's layout follows the view (elastic): checked on the timer
  and before mouse events, laid out again only when the size changed. }
procedure TMView.SyncPanelLayout;
var
  W, H: Integer;
  Scale: Double;
begin
  if (FPanel = nil) or (FSurface = nil) then
    Exit;
  W := FSurface.ClientWidth;
  H := FSurface.ClientHeight;
  Scale := Screen.PixelsPerInch / 96;
  if (W = FPanelViewW) and (H = FPanelViewH) and (Scale = FPanelScale) then
    Exit;
  FPanelViewW := W;
  FPanelViewH := H;
  FPanelScale := Scale;
  FPanel.SetViewSize(W, H, Scale);
  UpdatePanel;
end;

{ Hands the panel's picture (or none, while closed) to the renderer. }
procedure TMView.UpdatePanel;
var
  Bmp: TBGRABitmap;
begin
  if FPanel = nil then
    Exit;
  { The panel has just opened: the icon folder and the sort folders are
    looked at again (a new icon, a folder made meanwhile). }
  if FPanel.Visible and not FPanelWasVisible then
    RequestIcons(False);
  FPanelWasVisible := FPanel.Visible;
  Bmp := FPanel.Bitmap;
  if Bmp = nil then
    FRenderer.SetPanel(nil, 0, 0, 0)
  else
    FRenderer.SetPanel(Bmp, FPanel.Left, FPanel.Top, FPanel.Version);
  Refresh;
end;

function TMView.HandleOverlayMouse(AKind: TOverlayMouseKind; AButton: TOverlayButton;
  AX, AY, AWheel: Integer; AButtonDown, ADouble: Boolean): Boolean;
var
  Hit: TPanelHit;
  Notches: Integer;
begin
  Result := False;
  if FPanel = nil then
    Exit;
  SyncPanelLayout;
  case AKind of
    omMove:
      if FPanel.NoteMouse(AX, AY, AButtonDown, NowMs) then
        UpdatePanel;

    omLeave:
      begin
        FPanel.MouseGone(NowMs);
        if FPanel.Visible then
          UpdatePanel;
      end;

    omWheel:
      if FPanel.Contains(AX, AY) then
      begin
        Result := True;
        Notches := AWheel div 120;
        if Notches = 0 then
          Notches := Sign(AWheel);
        if FPanel.Scroll(Notches) then
          UpdatePanel;
      end;

    omDown:
      if FPanel.Contains(AX, AY) then
      begin
        Result := True;
        FPanelPress := FPanel.HitTest(AX, AY);
        FPanelPressButton := AButton;
        FPanelPressX := AX;
        FPanelPressY := AY;
      end;

    omUp:
      begin
        Result := True;
        { A swipe to the right over a button: into its folder (Day 21,
          user). Else it acts on release, where it was pressed (like a
          button). }
        Hit := FPanel.HitTest(AX, AY);
        if (FPanelPress.Part in [ppSlot, ppSlotMenu])
          and (AX - FPanelPressX >= Round(SwipePx * Max(1.0, FPanelScale)))
          and (Abs(AY - FPanelPressY) < AX - FPanelPressX) then
          OpenSlotFolder(FPanelPress.Slot)
        else if (FPanelPress.Part <> ppNone) and (Hit.Part = FPanelPress.Part)
          and (Hit.Slot = FPanelPress.Slot) then
          PanelClick(Hit, FPanelPressButton);
        FPanelPress.Part := ppNone;
        FPanelPress.Slot := -1;
      end;
  end;
end;

procedure TMView.PanelClick(const AHit: TPanelHit; AButton: TOverlayButton);
var
  P: TPoint;
begin
  case AHit.Part of
    ppSlot:
      if AButton = obMiddle then
        OpenSlotFolder(AHit.Slot)          { wheel click: into the folder }
      else if (AButton in [obLeft, obRight]) and not SecondSlotClick(AHit.Slot, AButton) then
      begin
        { The first click only says what a double click does. }
        FPanel.FooterText := 'double-click:' + LineEnding + 'left = copy,  right = move';
        UpdatePanel;
      end
      else if AButton in [obLeft, obRight] then
      begin
        SortCurrent(AHit.Slot, AButton = obRight);
        { Unpinned: closes after each action (user), once its flash has
          been seen. }
        FPanel.CloseAfterAction(NowMs);
        UpdatePanel;
      end;

    ppSlotMenu, ppAdd:
      if Assigned(FOnSortMenu) and Assigned(FSurface) then
      begin
        P := FSurface.ClientToScreen(Point(FPanel.Left, 0));
        P.Y := Mouse.CursorPos.Y;
        if AHit.Part = ppAdd then
          FOnSortMenu(-1, P)
        else
          FOnSortMenu(AHit.Slot, P);
      end;

    ppPin:
      begin
        FPanel.Pinned := not FPanel.Pinned;
        FConfig.SortPinned := FPanel.Pinned;
        FConfig.SaveSort;
        UpdatePanel;
      end;

    ppFooter:
      UndoLast;
  end;
end;

{ The file shown can be sorted: a file (not a pasted or cropped image). }
{ A click on a button (released there): True if it is the second of a
  double click (same button, same mouse button, within the system's
  double-click time, hardly moved); then the pair is used up. Otherwise
  it is remembered as a first click. }
function TMView.SecondSlotClick(ASlot: Integer; AButton: TOverlayButton): Boolean;
var
  NowTime: Double;
  Near: Integer;
begin
  NowTime := NowMs;
  Near := Round(6 * Max(1.0, FPanelScale));
  Result := (FSlotClickSlot = ASlot) and (FSlotClickButton = AButton)
    and (NowTime - FSlotClickMs <= FDoubleClickMs)
    and (Abs(FPanelPressX - FSlotClickX) <= Near) and (Abs(FPanelPressY - FSlotClickY) <= Near);
  if Result then
    FSlotClickSlot := -1
  else
  begin
    FSlotClickSlot := ASlot;
    FSlotClickButton := AButton;
    FSlotClickMs := NowTime;
    FSlotClickX := FPanelPressX;
    FSlotClickY := FPanelPressY;
  end;
end;

{ Into slot ASlot's folder, from the panel (closes it, unpinned). }
procedure TMView.OpenSlotFolder(ASlot: Integer);
begin
  OpenSortFolder(ASlot);
  if Assigned(FPanel) then
  begin
    FPanel.CloseAfterAction(NowMs);
    UpdatePanel;
  end;
end;

procedure TMView.OpenSortFolder(ASlot: Integer);
var
  Slot: TSortSlot;
begin
  if (ASlot < 0) or (ASlot >= FConfig.SortFolders.Count) then
    Exit;
  Slot := FConfig.SortFolders.Slot(ASlot);
  if Assigned(FPanel) then
  begin
    { A folder known to be missing: red, nothing opened. }
    if PanelSlotMissing(ASlot) then
    begin
      FPanel.Flash(ASlot, False, NowMs);
      SortNote('folder not found: ' + Slot.Folder, 'folder not found', SortNoteMs);
      Exit;
    end;
    FPanel.Flash(ASlot, True, NowMs);
  end;
  { The scanner says "Not found" if it has gone meanwhile. }
  OpenMedia(Slot.Folder);
  if FShowingPaste and (FPasteSavedAs = '') then
    SortNote('opening ' + Slot.Folder + ' ...   (the pasted / cropped image was not saved)',
      'opened ' + Slot.Name, 8000)
  else
    SortNote('opening ' + Slot.Folder + ' ...', 'opened ' + Slot.Name, SortNoteMs);
end;

function TMView.CanSortCurrent(out AFileName: string): Boolean;
begin
  AFileName := '';
  if FShowingPaste then
  begin
    ShowStatus('a pasted or cropped image is not a file yet: save it first', 5000);
    Exit(False);
  end;
  if not FNavigator.HasCurrentImage then
  begin
    ShowStatus('no image to sort', 3000);
    Exit(False);
  end;
  AFileName := FNavigator.CurrentFileName;
  Result := True;
end;

{ Status line and panel footer together. }
procedure TMView.SortNote(const AStatus, AFooter: string; ADurationMs: Double);
begin
  if Assigned(FPanel) then
  begin
    FPanel.FooterText := AFooter;
    FPanel.Busy := Assigned(FMover) and FMover.Busy;
  end;
  ShowStatus(AStatus, ADurationMs);
  UpdatePanel;
end;

{ A move: the file leaves the lists at once and the next image shows
  (no waiting for the disk); it comes back if the move fails. }
{ Every job gets a number (to match its result); copies, moves and
  deletes are counted until reported (Undo waits for them). }
procedure TMView.QueueJob(var AJob: TFileJob);
begin
  Inc(FNextJobId);
  AJob.Id := FNextJobId;
  if AJob.Kind in [fjSort, fjDelete] then
    Inc(FJobsInFlight);
  Mover.Add(AJob);
end;

procedure TMView.StartMove(var AJob: TFileJob);
var
  M: TMoveUnderWay;
begin
  M.Source := AJob.Source;
  if not FNavigator.ListedKey(AJob.Source, M.Key) then
  begin
    M.Key.FileName := AJob.Source;
    M.Key.FileSize := 0;
    M.Key.FileTime := 0;
  end;
  StopAnimation;
  FNavigator.RemoveFile(AJob.Source);
  FCache.DropFile(AJob.Source);
  M.FollowedBy := FNavigator.CurrentFileName;
  QueueJob(AJob);
  M.JobId := AJob.Id;
  SetLength(FMoves, Length(FMoves) + 1);
  FMoves[High(FMoves)] := M;
  ShowCurrent;
end;

procedure TMView.SortCurrent(ASlot: Integer; AMove: Boolean);
var
  FileName, Verb: string;
  Slot: TSortSlot;
  Job: TFileJob;
begin
  if (FPanel = nil) or (ASlot < 0) or (ASlot >= FConfig.SortFolders.Count) then
    Exit;
  { A pasted or cropped image: saved into the folder (Day 21, user). }
  if FShowingPaste then
  begin
    SortScratch(ASlot, AMove);
    Exit;
  end;
  if not CanSortCurrent(FileName) then
  begin
    FPanel.Flash(ASlot, False, NowMs);
    UpdatePanel;
    Exit;
  end;
  Slot := FConfig.SortFolders.Slot(ASlot);
  if SameText(ExcludeTrailingPathDelimiter(ExtractFileDir(FileName)), Slot.Folder) then
  begin
    FPanel.Flash(ASlot, False, NowMs);
    SortNote(ExtractFileName(FileName) + ' is already in ' + Slot.Name,
      'already in ' + Slot.Name, SortNoteMs);
    Exit;
  end;

  Job := Default(TFileJob);
  if AMove then
    Job.Action := faMove
  else
    Job.Action := faCopy;
  Job.Kind := fjSort;
  Job.Source := FileName;
  Job.TargetDir := Slot.Folder;
  Job.CreateTarget := False;   { a missing folder is reported, not made }
  Job.Slot := ASlot;
  Job.Caption := Slot.Name;
  Job.UndoOf := -1;

  FPanel.JobStarted(ASlot);
  if AMove then
  begin
    Verb := 'moving';
    StartMove(Job);
  end
  else
  begin
    Verb := 'copying';
    QueueJob(Job);
  end;
  SortNote(Verb + ' ' + ExtractFileName(FileName) + ' to ' + Slot.Name + ' ...',
    Verb + ' to ' + Slot.Name + ' ...', 0);
end;

procedure TMView.DeleteCurrent;
var
  FileName: string;
  Job: TFileJob;
begin
  { A pasted or cropped image is no file: "deleting" it closes it. }
  if FShowingPaste then
  begin
    ShowStatus('closed the pasted / cropped image (it was not saved)', 5000);
    ShowCurrent;
    Exit;
  end;
  if not CanSortCurrent(FileName) then
    Exit;
  if SameText(ExcludeTrailingPathDelimiter(ExtractFileDir(FileName)),
    ExcludeTrailingPathDelimiter(FConfig.DeletedFilesFolder)) then
  begin
    SortNote(ExtractFileName(FileName) + ' is in the deleted-files folder already',
      'already deleted', SortNoteMs);
    Exit;
  end;
  Job := Default(TFileJob);
  Job.Action := faMove;
  Job.Kind := fjDelete;
  Job.Source := FileName;
  Job.TargetDir := FConfig.DeletedFilesFolder;
  Job.CreateTarget := True;
  Job.Slot := -1;
  Job.Caption := FolderDisplayName(Job.TargetDir);
  Job.UndoOf := -1;
  StartMove(Job);
  SortNote('deleting ' + ExtractFileName(FileName) + ' ...', 'deleting ...', 0);
end;

function TMView.UndoIndex(AId: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FUndo) do
    if FUndo[I].Id = AId then
      Exit(I);
  Result := -1;
end;

{ The newest entry whose undo is not already under way; -1 = none. }
function TMView.LastUndo: Integer;
var
  I: Integer;
begin
  for I := High(FUndo) downto 0 do
    if not FUndo[I].Pending then
      Exit(I);
  Result := -1;
end;

procedure TMView.DeleteUndo(AIndex: Integer);
var
  I: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FUndo)) then
    Exit;
  for I := AIndex to High(FUndo) - 1 do
    FUndo[I] := FUndo[I + 1];
  SetLength(FUndo, Length(FUndo) - 1);
end;

procedure TMView.AddUndo(const AJob: TFileJob; const APlaced: string);
var
  E: TUndoEntry;
begin
  Inc(FNextUndoId);
  E.Id := FNextUndoId;
  E.Kind := AJob.Kind;
  E.Action := AJob.Action;
  E.Original := AJob.Source;
  E.Placed := APlaced;
  E.Caption := AJob.Caption;
  E.Pending := False;
  if Length(FUndo) >= MaxUndoEntries then
    DeleteUndo(0);
  SetLength(FUndo, Length(FUndo) + 1);
  FUndo[High(FUndo)] := E;
end;

function TMView.UndoCaption: string;
var
  I: Integer;
begin
  Result := '';
  I := LastUndo;
  if I < 0 then
    Exit;
  case FUndo[I].Kind of
    fjDelete: Result := 'Undo delete of ' + ExtractFileName(FUndo[I].Original);
  else
    if FUndo[I].Action = faCopy then
      Result := 'Undo copy of ' + ExtractFileName(FUndo[I].Original) + ' to ' + FUndo[I].Caption
    else
      Result := 'Undo move of ' + ExtractFileName(FUndo[I].Original) + ' to ' + FUndo[I].Caption;
  end;
end;

{ Undo, never a real delete: a copy goes into the deleted-files folder;
  a moved or deleted file goes back to its folder (under its old name,
  or with _1 if that is taken now). }
procedure TMView.UndoLast;
var
  I: Integer;
  Job: TFileJob;
begin
  { A copy / move still under way would be the one to take back: wait
    for it. }
  if FJobsInFlight > 0 then
  begin
    SortNote('still copying / moving: undo when it is done', 'still working ...', 3000);
    Exit;
  end;
  I := LastUndo;
  if I < 0 then
  begin
    SortNote('nothing to undo', 'nothing to undo', 3000);
    Exit;
  end;
  Job := Default(TFileJob);
  Job.Action := faMove;
  Job.Kind := fjUndo;
  Job.Source := FUndo[I].Placed;
  Job.Slot := -1;
  Job.Caption := FUndo[I].Caption;
  Job.UndoOf := FUndo[I].Id;
  Job.CreateTarget := True;
  if FUndo[I].Action = faCopy then
    Job.TargetDir := FConfig.DeletedFilesFolder
  else
  begin
    Job.TargetDir := ExtractFileDir(FUndo[I].Original);
    Job.TargetName := ExtractFileName(FUndo[I].Original);
  end;
  FUndo[I].Pending := True;
  QueueJob(Job);
  SortNote('undoing ...', 'undoing ...', 0);
end;

{ UI thread: a job of the mover is done. }
procedure TMView.HandleFileJobDone(const AResult: TFileJobResult);
var
  J, AsCopy: TFileJob;
  Name, Status, Footer, NewName, DeletedDir: string;
  I, U: Integer;
  M: TMoveUnderWay;
  Entry: TUndoEntry;
  HadMove, Changed, BackHome: Boolean;
begin
  J := AResult.Job;
  if J.Kind = fjIcon then
  begin
    HandleIconWritten(AResult);
    Exit;
  end;
  Name := ExtractFileName(J.Source);
  Changed := False;
  if (J.Kind in [fjSort, fjDelete]) and (FJobsInFlight > 0) then
    Dec(FJobsInFlight);

  { This job's move under way (matched by its number): done now. }
  HadMove := False;
  M := Default(TMoveUnderWay);
  for I := 0 to High(FMoves) do
    if FMoves[I].JobId = J.Id then
    begin
      M := FMoves[I];
      HadMove := True;
      for U := I to High(FMoves) - 1 do
        FMoves[U] := FMoves[U + 1];
      SetLength(FMoves, Length(FMoves) - 1);
      Break;
    end;

  NewName := '';
  if AResult.OK and not SameText(ExtractFileName(AResult.ResultFile), Name)
    and (J.Kind <> fjUndo) then
    NewName := ' as ' + ExtractFileName(AResult.ResultFile);

  if J.Kind in [fjSort, fjDelete] then
  begin
    if AResult.OK then
      { Into a folder that is browsed too: it shows up there. }
      FNavigator.AddFile(AResult.ResultFile, AResult.Size, AResult.Modified);

    if AResult.OK and AResult.KeptSource and (J.Kind = fjDelete) then
    begin
      { A delete that only copied: the file is still there (in use).
        Nothing to undo; the extra copy in the deleted-files folder is
        harmless. }
      if HadMove then
      begin
        FNavigator.AddFile(M.Key.FileName, M.Key.FileSize, M.Key.FileTime);
        if SameText(FNavigator.CurrentFileName, M.FollowedBy)
          and FNavigator.SelectFile(M.Key.FileName) then
          Changed := True;
      end;
      Status := 'could not delete ' + Name + ': it is in use (a copy went into '
        + J.TargetDir + ')';
      Footer := 'not deleted:' + LineEnding + 'in use';
    end
    else if AResult.OK and AResult.KeptSource then
    begin
      { Moved to another drive, but the original was in use and stays:
        it is a copy. The original is listed again. }
      if HadMove then
      begin
        FNavigator.AddFile(M.Key.FileName, M.Key.FileSize, M.Key.FileTime);
        if SameText(FNavigator.CurrentFileName, M.FollowedBy)
          and FNavigator.SelectFile(M.Key.FileName) then
          Changed := True;
      end;
      AsCopy := J;
      AsCopy.Action := faCopy;
      AddUndo(AsCopy, AResult.ResultFile);
      Status := 'copied ' + Name + ' to ' + J.Caption + NewName
        + ', but the original could not be removed (in use)';
      Footer := 'copied only (in use)' + LineEnding + 'click here: undo';
    end
    else if AResult.OK then
    begin
      AddUndo(J, AResult.ResultFile);
      if J.Kind = fjDelete then
      begin
        Status := 'deleted ' + Name + ' (moved to ' + J.TargetDir + ')';
        Footer := 'deleted ' + Name;
      end
      else if J.Action = faCopy then
      begin
        Status := 'copied ' + Name + ' to ' + J.Caption + NewName;
        Footer := 'copied to ' + J.Caption;
      end
      else
      begin
        Status := 'moved ' + Name + ' to ' + J.Caption + NewName;
        Footer := 'moved to ' + J.Caption;
      end;
      Footer := Footer + LineEnding + 'click here: undo';
    end
    else
    begin
      { The move failed: the file is back in the lists; still where it
        was if the user hasn't gone on. }
      if HadMove then
      begin
        FNavigator.AddFile(M.Key.FileName, M.Key.FileSize, M.Key.FileTime);
        if SameText(FNavigator.CurrentFileName, M.FollowedBy)
          and FNavigator.SelectFile(M.Key.FileName) then
          Changed := True;
      end;
      if J.Kind = fjDelete then
        Status := 'could not delete ' + Name + ': ' + AResult.Message
      else if J.Action = faCopy then
        Status := 'could not copy ' + Name + ' to ' + J.Caption + ': ' + AResult.Message
      else
        Status := 'could not move ' + Name + ' to ' + J.Caption + ': ' + AResult.Message;
      Footer := 'failed:' + LineEnding + AResult.Message;
    end;
  end
  else
  begin
    { Undo. What was taken back decides what follows: a copy went into
      the deleted-files folder, a moved or deleted file is back home. }
    U := UndoIndex(J.UndoOf);
    BackHome := True;
    if U >= 0 then
    begin
      Entry := FUndo[U];
      BackHome := Entry.Action = faMove;
    end;
    if AResult.OK then
    begin
      if U >= 0 then
        DeleteUndo(U);
      { The copy / the moved file left its place ... }
      if FNavigator.RemoveFile(J.Source) then
        Changed := True;
      FCache.DropFile(J.Source);
      { ... and is where it goes now (shown again if that is the folder
        being browsed). }
      FNavigator.AddFile(AResult.ResultFile, AResult.Size, AResult.Modified);
      if BackHome and FNavigator.SelectFile(AResult.ResultFile) then
        Changed := True;
      if BackHome then
        Status := 'undone: ' + ExtractFileName(AResult.ResultFile) + ' is back in '
          + ExtractFileDir(AResult.ResultFile)
      else
      begin
        DeletedDir := ExtractFileDir(AResult.ResultFile);
        Status := 'undone: the copy ' + Name + ' went into ' + DeletedDir;
      end;
      if AResult.KeptSource then
        Status := Status + ' (the other one could not be removed: in use)';
      Footer := 'undone';
    end
    else
    begin
      if U >= 0 then
        FUndo[U].Pending := False;
      Status := 'could not undo: ' + AResult.Message;
      Footer := 'undo failed:' + LineEnding + AResult.Message;
    end;
  end;

  { The confirmation: the button flashes in its colour (red: failed);
    delete and undo: the bottom line. }
  if Assigned(FPanel) then
  begin
    if J.Kind = fjSort then
      FPanel.JobDone(J.Slot, AResult.OK, NowMs)
    else
      FPanel.JobDone(-1, AResult.OK and not ((J.Kind = fjDelete) and AResult.KeptSource), NowMs);
  end;

  if Changed then
    ShowCurrent
  else
    UpdateInfo;
  if AResult.OK then
    SortNote(Status, Footer, SortNoteMs)
  else
    SortNote(Status, Footer, 10000);
end;

procedure TMView.ShowSortPanel(AShow: Boolean);
begin
  if FPanel = nil then
    Exit;
  SyncPanelLayout;
  if AShow then
    FPanel.Show(True)
  else
    FPanel.Hide;
  UpdatePanel;
end;

function TMView.SortPanelVisible: Boolean;
begin
  Result := Assigned(FPanel) and FPanel.Visible;
end;

procedure TMView.SortFoldersChanged;
begin
  FConfig.SaveSort;
  RequestIcons(True);
  if Assigned(FPanel) then
  begin
    FPanel.Changed;
    UpdatePanel;
  end;
end;

function TMView.SortPanelHit(AX, AY: Integer): TPanelHit;
begin
  if FPanel = nil then
  begin
    Result.Part := ppNone;
    Result.Slot := -1;
    Exit;
  end;
  SyncPanelLayout;
  Result := FPanel.HitTest(AX, AY);
end;

procedure TMView.SortPanelMouseGone;
begin
  if FPanel = nil then
    Exit;
  FPanel.MouseGone(NowMs);
  if FPanel.Visible then
    UpdatePanel;
end;

procedure TMView.ShowNote(const AText: string; ADurationMs: Double);
begin
  ShowStatus(AText, ADurationMs);
end;

function TMView.FileJobsBusy: Boolean;
begin
  Result := Assigned(FMover) and FMover.Busy;
end;

function TMView.SortStartFolder(ASlot: Integer): string;
var
  Candidate: string;
begin
  Result := '';
  if (ASlot >= 0) and (ASlot < FConfig.SortFolders.Count) then
  begin
    Candidate := FConfig.SortFolders.Slot(ASlot).Folder;
    if DirectoryExists(Candidate) then
      Exit(Candidate);
  end;
  { Sort folders are usually side by side: next to the last one chosen. }
  if FConfig.SortFolders.Recent.Count > 0 then
  begin
    Candidate := ExtractFileDir(ExcludeTrailingPathDelimiter(FConfig.SortFolders.Recent[0]));
    if (Candidate <> '') and DirectoryExists(Candidate) then
      Exit(Candidate);
  end;
  if FNavigator.HasCurrentImage then
  begin
    Candidate := ExtractFileDir(ExcludeTrailingPathDelimiter(FNavigator.CurrentDirectory));
    if (Candidate <> '') and DirectoryExists(Candidate) then
      Exit(Candidate);
  end;
  Result := ExcludeTrailingPathDelimiter(UserDocumentsDirectory);
end;

{ ---- Icons (Phase G, G1 stage 2) ---------------------------------------- }

const
  IconReloadMs = 3000;           { opening the panel reads the icon folder again after this }
  IconSizes: array[0..6] of Integer = (16, 24, 32, 48, 64, 128, 256);

function IsFullPath(const APath: string): Boolean;
begin
  Result := ExtractFileDrive(APath) <> '';
end;

function TMView.SlotIconFile(ASlot: Integer): string;
var
  Slot: TSortSlot;
  Base: string;
begin
  Result := '';
  if (ASlot < 0) or (ASlot >= FConfig.SortFolders.Count) then
    Exit;
  Slot := FConfig.SortFolders.Slot(ASlot);
  if Slot.Icon = '-' then
    Exit;
  if Slot.Icon <> '' then
  begin
    if IsFullPath(Slot.Icon) then
      Result := Slot.Icon
    else
      Result := FConfig.IconFilesFolder + Slot.Icon;
    Exit;
  end;
  { By name: Good.ico (or .png) for ...\Good. }
  Base := FConfig.IconFilesFolder + IconBaseName(Slot.Folder);
  if FIcons.Has(Base + '.ico') then
    Result := Base + '.ico'
  else if FIcons.Has(Base + '.png') then
    Result := Base + '.png';
end;

procedure TMView.RequestIcons(AForce: Boolean);
var
  Extra, Folders: TStringList;
  I: Integer;
  Slot: TSortSlot;
begin
  if FIcons = nil then
    Exit;
  if (not AForce) and FIcons.Loaded and (FIcons.LoadedAgoMs(NowMs) < IconReloadMs) then
    Exit;
  Extra := TStringList.Create;
  Folders := TStringList.Create;
  try
    for I := 0 to FConfig.SortFolders.Count - 1 do
    begin
      Slot := FConfig.SortFolders.Slot(I);
      Folders.Add(Slot.Folder);
      if (Slot.Icon <> '') and (Slot.Icon <> '-') and IsFullPath(Slot.Icon) then
        Extra.Add(Slot.Icon);
    end;
    FIcons.Load(FConfig.IconFilesFolder, Extra, Folders, NowMs);
  finally
    Extra.Free;
    Folders.Free;
  end;
end;

procedure TMView.ReloadIcons;
begin
  RequestIcons(True);
end;

procedure TMView.HandleIconsChanged(Sender: TObject);
begin
  if FPanel = nil then
    Exit;
  FPanel.Changed;
  UpdatePanel;
end;

function TMView.PanelSlotIcon(ASlot, ASize: Integer): TBGRABitmap;
begin
  Result := nil;
  if (FIcons = nil) or not FIcons.Loaded then
    Exit;
  Result := FIcons.Bitmap(SlotIconFile(ASlot), ASize);
end;

function TMView.PanelSlotMissing(ASlot: Integer): Boolean;
begin
  Result := Assigned(FIcons) and (ASlot >= 0) and (ASlot < FConfig.SortFolders.Count)
    and FIcons.FolderMissing(FConfig.SortFolders.Slot(ASlot).Folder);
end;

function TMView.CanMakeIcon: Boolean;
begin
  Result := ImageToSave <> nil;
end;

procedure TMView.MakeIconFromImage;
var
  Img: IDecodedImage;
  Src, Square, Sized: TBGRABitmap;
  FullW, FullH, ViewW, ViewH, BX, BY, BS, I: Integer;
  CX, CY, Side, X1, Y1, Scale, FX, FY: Double;
  Sel: TImageRect;
  Pngs: array of TBytes;
  Mem, Ico: TMemoryStream;
  Writer: TFPWriterPNG;
  Job: TFileJob;
  Name, FromWhere: string;
begin
  Img := ImageToSave;
  if (Img = nil) or (Img.Bitmap = nil) or (Img.Bitmap.Width <= 0) then
  begin
    ShowStatus('make icon: no image to make it from', 4000);
    Exit;
  end;
  Src := Img.Bitmap;
  FullW := Img.FullWidth;
  FullH := Img.FullHeight;
  if (FullW <= 0) or (FullH <= 0) then
  begin
    FullW := Src.Width;
    FullH := Src.Height;
  end;

  { The square, in original pixels: the selection's middle, or the
    middle of the view; as large as the selection's shorter side, or the
    view's. }
  if CanCrop then
  begin
    Sel := FRenderer.Selection;
    CX := (Sel.X0 + Sel.X1) / 2;
    CY := (Sel.Y0 + Sel.Y1) / 2;
    Side := Min(Sel.X1 - Sel.X0, Sel.Y1 - Sel.Y0);
    FromWhere := 'the selection';
  end
  else
  begin
    ViewW := FPreviewWidth;
    ViewH := FPreviewHeight;
    if Assigned(FSurface) and (FSurface.ClientWidth > 0) and (FSurface.ClientHeight > 0) then
    begin
      ViewW := FSurface.ClientWidth;
      ViewH := FSurface.ClientHeight;
    end;
    if FRenderer.ScreenToImage(ViewW / 2, ViewH / 2, CX, CY)
      and FRenderer.ScreenToImage(ViewW / 2 + 100, ViewH / 2, X1, Y1) then
    begin
      Scale := Hypot(X1 - CX, Y1 - CY) / 100;    { original pixels per screen pixel }
      Side := Min(ViewW, ViewH) * Scale;
    end
    else
    begin
      CX := FullW / 2;
      CY := FullH / 2;
      Side := Min(FullW, FullH);
    end;
    FromWhere := 'the middle of the screen';
  end;
  if (Side < 1) or (Side > Min(FullW, FullH)) then
    Side := Min(FullW, FullH);
  CX := EnsureRange(CX, Side / 2, FullW - Side / 2);
  CY := EnsureRange(CY, Side / 2, FullH - Side / 2);

  { Original pixels -> pixels of the bitmap in memory (a quick view is
    smaller). }
  FX := Src.Width / FullW;
  FY := Src.Height / FullH;
  BS := Max(1, Min(Round(Side * Min(FX, FY)), Min(Src.Width, Src.Height)));
  BX := EnsureRange(Round((CX - Side / 2) * FX), 0, Src.Width - BS);
  BY := EnsureRange(Round((CY - Side / 2) * FY), 0, Src.Height - BS);

  Square := nil;
  Mem := nil;
  Ico := nil;
  Writer := TFPWriterPNG.Create;
  try
    Writer.UseAlpha := True;
    Writer.WordSized := False;
    Square := Src.GetPart(Rect(BX, BY, BX + BS, BY + BS)) as TBGRABitmap;
    SetLength(Pngs, Length(IconSizes));
    Mem := TMemoryStream.Create;
    for I := 0 to High(IconSizes) do
    begin
      Sized := Square.Resample(IconSizes[I], IconSizes[I], rmFineResample) as TBGRABitmap;
      try
        Mem.Clear;
        Sized.SaveToStream(Mem, Writer);
        SetLength(Pngs[I], Mem.Size);
        if Mem.Size > 0 then
          Move(Mem.Memory^, Pngs[I][0], Mem.Size);
      finally
        Sized.Free;
      end;
    end;
    Ico := TMemoryStream.Create;
    WriteIconFile(Ico, Pngs, IconSizes);

    if FNavigator.HasCurrentImage then
      Name := IconBaseName(ExcludeTrailingPathDelimiter(FNavigator.CurrentDirectory))
    else
      Name := 'icon';
    Job := Default(TFileJob);
    Job.Action := faWrite;
    Job.Kind := fjIcon;
    Job.TargetDir := ExcludeTrailingPathDelimiter(FConfig.IconFilesFolder);
    Job.TargetName := Name + '.ico';
    Job.CreateTarget := True;
    Job.Slot := -1;
    Job.Caption := Name;
    Job.UndoOf := -1;
    SetLength(Job.Data, Ico.Size);
    if Ico.Size > 0 then
      Move(Ico.Memory^, Job.Data[0], Ico.Size);
    QueueJob(Job);
    if Img.Quality < qlFull then
      FromWhere := FromWhere + ', from the quick view (the full image wasn''t loaded yet)';
    ShowStatus('making icon ' + Job.TargetName + ' from ' + FromWhere + ' ...', 0);
  except
    on E: Exception do
      ShowStatus('make icon: ' + E.Message, 8000);
  end;
  Writer.Free;
  Square.Free;
  Mem.Free;
  Ico.Free;
end;

{ UI thread: the icon file is written. }
procedure TMView.HandleIconWritten(const AResult: TFileJobResult);
var
  Status: string;
  I: Integer;
begin
  if not AResult.OK then
  begin
    ShowStatus('could not make the icon: ' + AResult.Message, 10000);
    Exit;
  end;
  Status := 'icon made: ' + AResult.ResultFile;
  if AResult.RenamedTo <> '' then
    Status := Status + '   (the one before is now ' + ExtractFileName(AResult.RenamedTo) + ')';
  ShowStatus(Status, 8000);
  RequestIcons(True);
  { The buttons that take it by name light up once it is read. }
  if Assigned(FPanel) then
    for I := 0 to FConfig.SortFolders.Count - 1 do
      if (FConfig.SortFolders.Slot(I).Icon = '')
        and SameText(IconBaseName(FConfig.SortFolders.Slot(I).Folder), AResult.Job.Caption) then
        FPanel.Flash(I, True, NowMs);
  UpdatePanel;
end;

{ ---- Sorting pasted / cropped images, paste from the settings screen (Day 21) ---- }

{ The pasted or cropped image is saved into the slot's folder as PNG
  (never over another file: _1 ...). Left click: it stays on screen;
  right click ("move"): the file shown before comes back at once. }
procedure TMView.SortScratch(ASlot: Integer; AMove: Boolean);
var
  Img: IDecodedImage;
  Slot: TSortSlot;
  FileName: string;
begin
  Slot := FConfig.SortFolders.Slot(ASlot);
  if Assigned(FSaveThread) then
  begin
    FPanel.Flash(ASlot, False, NowMs);
    SortNote('still saving the previous image ...', 'still saving ...', 3000);
    Exit;
  end;
  Img := ImageToSave;
  if Img = nil then
  begin
    FPanel.Flash(ASlot, False, NowMs);
    SortNote('nothing to save', 'nothing to save', 3000);
    Exit;
  end;
  FileName := IncludeTrailingPathDelimiter(Slot.Folder) + FScratchPrefix + '_'
    + FormatDateTime('yyyymmdd-hhnnss', Now) + '.png';
  if PanelSlotMissing(ASlot) then
  begin
    FPanel.Flash(ASlot, False, NowMs);
    SortNote('folder not found: ' + Slot.Folder, 'folder not found', SortNoteMs);
    Exit;
  end;
  FSavingPaste := True;
  FSortSaveSlot := ASlot;
  FSortSaveImage := Img;
  FSortSaveTitle := FScratchTitle;
  FSortSavePrefix := FScratchPrefix;
  FSortSaveMove := AMove;
  FSaveThread := TImageSaveThread.Create(Img, FileName, '', True);
  Inc(FJobsInFlight);        { Undo waits for it }
  FPanel.JobStarted(ASlot);
  if AMove then
  begin
    SortNote('saving the image into ' + Slot.Name + ' ...',
      'saving into ' + Slot.Name + ' ...', 0);
    { The thread holds the image: the file comes back on screen now. }
    if FNavigator.HasCurrentImage then
      ShowCurrent;
  end
  else
    SortNote('saving into ' + Slot.Name + ' ...', 'saving into ' + Slot.Name + ' ...', 0);
end;

{ PumpDeliveries: the save for a sort folder has finished. }
procedure TMView.SortScratchSaved;
var
  Slot, SavedName: string;
  E: TFileJob;
begin
  if (FSortSaveSlot >= 0) and (FSortSaveSlot < FConfig.SortFolders.Count) then
    Slot := FConfig.SortFolders.Slot(FSortSaveSlot).Name
  else
    Slot := '';
  SavedName := FSaveThread.SavedFileName;
  if FJobsInFlight > 0 then
    Dec(FJobsInFlight);
  if Assigned(FPanel) then
    FPanel.JobDone(FSortSaveSlot, SavedName <> '', NowMs);
  if SavedName <> '' then
  begin
    { Shows up if that folder is browsed; Undo moves it into the
      deleted-files folder, as for a copy. }
    FNavigator.AddFile(SavedName, 0, Now);
    E := Default(TFileJob);
    E.Action := faCopy;
    E.Kind := fjSort;
    E.Source := SavedName;
    E.Caption := Slot;
    E.Slot := FSortSaveSlot;
    AddUndo(E, SavedName);
    SortNote('saved into ' + Slot + ': ' + ExtractFileName(SavedName),
      'saved into ' + Slot + LineEnding + 'click here: undo', SortNoteMs);
  end
  else
  begin
    { A "move" that failed: the image is not lost, it comes back. }
    if FSortSaveMove and Assigned(FSortSaveImage) and not FShowingPaste then
      ShowScratch(FSortSaveImage, FSortSaveTitle, FSortSavePrefix);
    SortNote(FSaveThread.ResultText, 'failed:' + LineEnding + FSaveThread.ResultText, 10000);
  end;
  FSortSaveSlot := -1;
  FSortSaveImage := nil;
end;

procedure TMView.StartWithPaste;
begin
  { The last session behind it (opening shows "Opening ..." until the
    image is on screen). }
  if FConfig.LastDirectory <> '' then
  begin
    OpenMedia(FConfig.LastDirectory, FConfig.LastFile);
    FKeepScratch := True;
  end;
  PasteFromClipboard;
  if not FShowingPaste then
  begin
    { No image after all: the last session as usual. }
    FKeepScratch := False;
    if FConfig.LastDirectory = '' then
      ShowMessageText(NoStartMessage);
    Exit;
  end;
  FRenderer.SetMessage('');
  Refresh;
end;

end.
