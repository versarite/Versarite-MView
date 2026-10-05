unit uConfig;

{
  Unit: uConfig

  Purpose
  -------
  Reads and writes MView.ini and provides the settings as typed
  properties. Only TConfig reads and writes the settings (spec §14);
  the settings editor (uIniEditor) edits MView.ini as text, including
  the [Mouse] ZonesEnabled line.

  Owns
  ----
  Nothing but its own fields. (A TIniFile lives only inside Load,
  Save, SaveWindowBounds and SaveDirectory.)

  Knows
  -----
  - The ini file name: MView.ini next to MView.exe (ParamStr(0)).
  - The string conversions of the sort mode and wrap scope (uTypes).
  - Windows only: SHGetFolderPathW (shell32.dll) for the user's
    Documents folder.

  Responsibilities
  ----------------
  - Start from built-in defaults, then read MView.ini on top of them.
    A key missing from the ini keeps its default.
  - First run (no MView.ini): write a complete ini with the defaults.
  - Validate values.
  - Write the settings back on shutdown.
  - Write only the window place (SaveWindowBounds), and the save
    folder the first time it is chosen (SaveDirectory).
  - Name the mouse profile file (MouseProfileFileName).
  - One line of help per key for the settings editor (ConfigKeyHelp).

  Does NOT
  --------
  - Load media, navigate directories or render images.
  - Read the mouse profile file (TMView, uMousePage).
  - Edit the ini as text (uIniEditor).

  Threads
  -------
  UI thread only. No locking.

  Uses (MView units)
  ------------------
  interface:      uTypes
  Libraries:      Classes, SysUtils, Graphics, IniFiles

  Used by
  -------
  uIniEditor, uMView, uMainForm

  Notes
  -----
  MView.ini lives next to MView.exe. Keys that TConfig doesn't know are
  left alone when it saves, because TIniFile only rewrites the keys it
  writes.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Graphics,
  IniFiles,
  uTypes,
  uSortFolders;

type

  { The parts of the info line (status line), [InfoLine] (user, Day 24):
    each on (1) or off (0); shown in the order of their lines in the ini. }
  TInfoItem = (iiFileName, iiDimensions, iiFolder, iiPosition, iiVideos, iiSorting,
    iiZoom, iiState, iiAnimation, iiFilters, iiMessages);
  TInfoItems = array of TInfoItem;

const
  { Their keys in [InfoLine], in the default order. }
  InfoItemKeys: array[TInfoItem] of string = ('FileName', 'Dimensions', 'Folder',
    'Position', 'Videos', 'Sorting', 'Zoom', 'State', 'Animation', 'Filters', 'Messages');

type

  TConfig = class(TObject)
  private

    { Startup }

    FOpenLastSession : Boolean;
    FLastDirectory   : string;
    FLastFile        : string;
    FStartFullscreen : Boolean;
    FOnlyOneInstance : Boolean;

    { Window }

    FLeft            : Integer;
    FTop             : Integer;
    FWidth           : Integer;
    FHeight          : Integer;
    FTopMost         : Boolean;

    { View }

    FBackgroundColor : TColor;
    FFitMode         : TFitMode;
    FRememberZoom    : Boolean;
    FRememberRotation: Boolean;
    FShowInfo        : Boolean;
    FAutoRotate      : Boolean;
    FOverlaySolid    : Boolean;
    FOverlayColor    : string;

    { Navigation }

    FSortMode        : TSortMode;
    FRecursive       : Boolean;
    FWrapAround      : Boolean;
    FClimbUp         : Boolean;
    FRecurseFromRoot : Boolean;
    FWrapScope       : TWrapScope;
    FPlaceholderForBadImages: Boolean;

    { Performance }

    FPreloadCount    : Integer;
    FPreloadBehind   : Integer;
    FDecodeThreads   : Integer;
    FUseWic          : Boolean;
    FUseWicQuickView : Boolean;
    FRefineDelayMs   : Integer;
    FCacheSizeMB     : Integer;
    FBackgroundScan  : Boolean;
    FPreviewAhead    : Integer;
    FSkimEnterMs     : Integer;
    FSkimRate        : Integer;
    FSkimExitMs      : Integer;

    { Mouse }

    FMouseProfile    : string;
    FMouseHideTime   : Integer;
    FZonesEnabled    : Boolean;

    { Renderer }

    FInterpolation   : TInterpolationMode;
    FUseMipMaps      : Boolean;
    FUseGPU          : Boolean;
    FZoomStepPercent : Double;

    { Debug }

    FDecodeDelayMs   : Integer;
    FShowDiagnostics : Boolean;
    FTimingLog       : Boolean;
    FSaveImageDir    : string;

    { Internal }

    FIniFileName     : string;

    { Sort (Phase G) }

    FSortFolders     : TSortFolders;
    FSortEdgeDelayMs : Integer;
    FSortEdgeWidth   : Integer;
    FSortPinned      : Boolean;
    FDeletedFolder   : string;
    FIconFolder      : string;
    FTotalCommander  : string;
    FFollowTC        : Integer;

    { Filters (Phase H) }

    FFilterPinned    : Boolean;
    FAutoFilter      : Boolean;

    { Magnifier (Phase H) }

    FLensMagPercent  : Integer;
    FLensSize        : Integer;
    FLensSharpen     : Integer;

    { Info line (Day 24) }

    FInfoFont        : string;
    FInfoFontSize    : Integer;
    FInfoAll         : TInfoItems;           { every part, in the ini's order }
    FInfoOn          : array[TInfoItem] of Boolean;

    procedure LoadDefaults;
    procedure ReadInfoLine(AIni: TCustomIniFile);
    procedure WriteSort(AIni: TCustomIniFile);
    procedure Validate;

  public

    constructor Create;
    destructor Destroy; override;

    procedure Load;
    procedure Save;
    { Writes only [Window] Left/Top/Width/Height (other keys, and any
      unsaved text in the settings editor, stay as they are). }
    procedure SaveWindowBounds;

    { Full path of MView.ini (next to MView.exe). }
    property IniFileName: string read FIniFileName;

    { Startup }

    property OpenLastSession : Boolean read FOpenLastSession;
    property LastDirectory   : string  read FLastDirectory write FLastDirectory;
    property LastFile        : string  read FLastFile write FLastFile;
    property StartFullscreen : Boolean read FStartFullscreen;
    { A second MView hands its file or folder to the one running and ends
      (user, Day 23: opening from Total Commander). }
    property OnlyOneInstance : Boolean read FOnlyOneInstance;

    { Window }

    { The window's place when not fullscreen (settings editor and
      viewer); Width = 0: not stored yet. }
    property Left            : Integer read FLeft write FLeft;
    property Top             : Integer read FTop write FTop;
    property Width           : Integer read FWidth write FWidth;
    property Height          : Integer read FHeight write FHeight;
    property TopMost         : Boolean read FTopMost;

    { View }

    property BackgroundColor : TColor  read FBackgroundColor;
    property FitMode         : TFitMode  read FFitMode write FFitMode;
    property RememberZoom    : Boolean read FRememberZoom;
    property RememberRotation: Boolean read FRememberRotation;
    property ShowInfo        : Boolean read FShowInfo write FShowInfo;
    { Turn photos upright by their EXIF orientation tag. }
    property AutoRotate      : Boolean read FAutoRotate;
    { Info and diagnostics lines on a solid black bar instead of
      straight over the image. }
    property OverlaySolid    : Boolean read FOverlaySolid;
    { Colour of the texts over the image: White, Yellow or Red. }
    property OverlayColor    : string  read FOverlayColor;

    { Navigation }

    property SortMode        : TSortMode  read FSortMode write FSortMode;
    property Recursive       : Boolean    read FRecursive;
    property WrapAround      : Boolean    read FWrapAround;
    { Day 22 (user): at the end of the folder tree, browse on one level
      higher instead of wrapping around (up to one level below the
      drive). }
    property ClimbUp         : Boolean    read FClimbUp;
    { Day 24 (user): with Recursive, a drive root (C:\) is opened with its
      subfolders only if this is on; off = the root's own images only
      (a whole drive would be scanned otherwise). }
    property RecurseFromRoot : Boolean    read FRecurseFromRoot;
    property WrapScope       : TWrapScope read FWrapScope;
    property PlaceholderForBadImages: Boolean read FPlaceholderForBadImages;

    { Performance }

    { Images preloaded ahead in the direction of travel, and behind. }
    property PreloadCount    : Integer read FPreloadCount;
    property PreloadBehind   : Integer read FPreloadBehind;
    { Decode worker threads; 0 = automatic (cores - 1, 1..4). }
    property DecodeThreads   : Integer read FDecodeThreads;
    { Full-size JPEGs with the Windows Imaging Component. }
    property UseWic          : Boolean read FUseWic;
    { Quick views of JPEGs scaled inside the WIC codec. }
    property UseWicQuickView : Boolean read FUseWicQuickView;
    { The full-size version of the current image is decoded only after
      it has been shown this long (or at once on zoom in / 100 %).
      0 = at once. }
    property RefineDelayMs   : Integer read FRefineDelayMs;
    { Image cache budget; 0 = automatic (25 % of RAM, 256..4096 MB). }
    property CacheSizeMB     : Integer read FCacheSizeMB;
    property BackgroundScan  : Boolean read FBackgroundScan;
    { Embedded thumbnails (Preview quality) read ahead of the current
      image, in the direction of travel. 0 = none. }
    property PreviewAhead    : Integer read FPreviewAhead;
    { Skim mode (spec §6): an average of SkimRate images per second or
      more over the last SkimEnterMs switches to previews only;
      SkimExitMs without navigation switches back. }
    property SkimEnterMs     : Integer read FSkimEnterMs;
    property SkimRate        : Integer read FSkimRate;
    property SkimExitMs      : Integer read FSkimExitMs;

    { Mouse }

    property MouseProfile    : string  read FMouseProfile;
    property MouseHideTime   : Integer read FMouseHideTime;
    { The zones of the mouse profile; off = only [Anywhere] counts. }
    property ZonesEnabled    : Boolean read FZonesEnabled;

    { Renderer }

    property Interpolation   : TInterpolationMode  read FInterpolation write FInterpolation;
    property UseMipMaps      : Boolean read FUseMipMaps;
    { Draw with OpenGL (spec §8.5); 0 = always the CPU renderer. }
    property UseGPU          : Boolean read FUseGPU;
    property ZoomStepPercent : Double read FZoomStepPercent;

    { Debug }

    { Every decode waits this long first. Only for testing how MView
      behaves with slow files. 0 = off. }
    property DecodeDelayMs   : Integer read FDecodeDelayMs;

    { The diagnostics line (spec §12). Stored as ShowFPS. }
    property ShowDiagnostics : Boolean read FShowDiagnostics write FShowDiagnostics;

    { Append one line per displayed image to timing.csv next to
      MView.exe. }
    property TimingLog       : Boolean read FTimingLog;
    { Where "Save image" (context menu) writes its PNG files. '' = not
      chosen yet: SaveDirectory then picks the Documents folder. }
    property SaveImageDirectory: string read FSaveImageDir;

    { The folder for saved images, with a trailing delimiter. The first
      time nothing is set, the user's Documents folder, which is then
      written to MView.ini (only that key). }
    function SaveDirectory: string;
    { The mouse profile file: MouseProfile, next to MView.ini unless it
      has a folder of its own. }
    function MouseProfileFileName: string;

    { Sort (Phase G, [Sort]) }

    { The sort panel's folders (slots, recent folders). Changed by the
      viewer; SaveSort writes them. }
    property SortFolders     : TSortFolders read FSortFolders;
    { ms the mouse rests at the right edge until the sort panel opens;
      0 = never (the menu and the SortPanel command still open it). }
    property SortEdgeDelayMs : Integer read FSortEdgeDelayMs;
    { How close to the right edge the mouse must rest, in pixels at 96
      dpi (scaled for the screen). A window's edge is hard to hit
      exactly (user, Day 21): 12 by default. }
    property SortEdgeWidth   : Integer read FSortEdgeWidth;
    { The panel's pin: stays open after a copy / move. }
    property SortPinned      : Boolean read FSortPinned write FSortPinned;
    { Where "Delete" moves files. '' = <Documents>\MView deleted files. }
    property DeletedFolder   : string read FDeletedFolder;
    { Where the slot icons are. '' = the icons folder next to MView.exe. }
    property IconFolder      : string read FIconFolder;
    { TOTALCMD64.EXE for "side by side"; '' = find it (registry). }
    property TotalCommander  : string read FTotalCommander;
    { Follow Total Commander (Day 23): 0 = no, 1 = its active panel's
      folder, 2 = and the file under its cursor. }
    property FollowTotalCommander: Integer read FFollowTC write FFollowTC;

    { The folder "Delete" moves to, without trailing delimiter. }
    function DeletedFilesFolder: string;
    { The icon folder, with trailing delimiter. }
    function IconFilesFolder: string;
    { Writes only the [Sort] section (slots, recent folders, pin); other
      keys, and unsaved text in the settings editor, stay as they are. }
    procedure SaveSort;

    { Filters (Phase H, [Filters]) }

    { The filter panel's pin (left edge): stays open. }
    property FilterPinned    : Boolean read FFilterPinned write FFilterPinned;
    { Writes only [Filters] Pinned. }
    procedure SaveFilters;
    { Auto black / white point for every image from the start (user,
      Day 22: "incredible ... it could be a default setting"). }
    property AutoFilter      : Boolean read FAutoFilter;

    { Magnifier (Phase H, [Magnifier]): how it was left (written on
      exit). Magnification in percent of the screen (300 = 3 x), size =
      the lens' diameter in px, sharpen 0 off, 1 low, 2 high. }
    property LensMagPercent  : Integer read FLensMagPercent write FLensMagPercent;
    property LensSize        : Integer read FLensSize write FLensSize;
    property LensSharpen     : Integer read FLensSharpen write FLensSharpen;

    { Info line ([InfoLine], Day 24) }

    { The parts shown, in their order (the ini's lines; =0 left out). }
    function InfoItems: TInfoItems;
    { The info line's font: '' = the standard one; size in points, 0 =
      the standard size. }
    property InfoFont        : string read FInfoFont;
    property InfoFontSize    : Integer read FInfoFontSize;

  end;

{ One line of help for a key, for the settings editor. '' if the key
  is unknown. ASection without brackets. }
function ConfigKeyHelp(const ASection, AKey: string): string;

{ The user's Documents folder, with a trailing delimiter (also when it
  was moved). The fallback when the save folder can't be used. }
function UserDocumentsDirectory: string;

implementation

const
  CONFIG_FILE = 'MView.ini';

  { Sections }
  SEC_STARTUP     = 'Startup';
  SEC_WINDOW      = 'Window';
  SEC_VIEW        = 'View';
  SEC_NAVIGATION  = 'Navigation';
  SEC_PERFORMANCE = 'Performance';
  SEC_MOUSE       = 'Mouse';
  SEC_RENDERER    = 'Renderer';
  SEC_DEBUG       = 'Debug';

  { Keys }
  KEY_OPEN_LAST_SESSION = 'OpenLastSession';
  KEY_LAST_DIRECTORY    = 'LastDirectory';
  KEY_LAST_FILE         = 'LastFile';
  KEY_START_FULLSCREEN  = 'StartFullscreen';
  KEY_ONLY_ONE_INSTANCE = 'OnlyOneInstance';
  KEY_LEFT              = 'Left';
  KEY_TOP               = 'Top';
  KEY_WIDTH             = 'Width';
  KEY_HEIGHT            = 'Height';
  KEY_SHOW_INFO         = 'ShowInfo';
  KEY_AUTO_ROTATE       = 'AutoRotate';
  KEY_OVERLAY_SOLID     = 'OverlaySolid';
  KEY_OVERLAY_COLOR     = 'OverlayColor';
  KEY_ZONES_ENABLED     = 'ZonesEnabled';
  KEY_SORT_MODE         = 'SortMode';
  KEY_RECURSIVE         = 'Recursive';
  KEY_WRAP_AROUND       = 'WrapAround';
  KEY_WRAP_SCOPE        = 'WrapScope';
  KEY_PLACEHOLDER       = 'PlaceholderForBadImages';
  KEY_CLIMB_UP          = 'ClimbUp';
  KEY_RECURSE_FROM_ROOT = 'RecurseFromDriveRoot';
  KEY_PRELOAD_COUNT     = 'PreloadCount';
  KEY_PRELOAD_BEHIND    = 'PreloadBehind';
  KEY_DECODE_THREADS    = 'DecodeThreads';
  KEY_USE_WIC           = 'UseWIC';
  KEY_USE_WIC_QUICK     = 'UseWICQuickView';
  KEY_REFINE_DELAY      = 'RefineDelayMs';
  KEY_CACHE_SIZE_MB     = 'CacheSizeMB';
  KEY_BACKGROUND_SCAN   = 'BackgroundScan';
  KEY_PREVIEW_AHEAD     = 'PreviewAhead';
  KEY_SKIM_ENTER        = 'SkimEnterMs';
  KEY_SKIM_RATE         = 'SkimRate';
  KEY_SKIM_EXIT         = 'SkimExitMs';
  KEY_MOUSE_PROFILE     = 'Profile';
  KEY_MOUSE_HIDE_TIME   = 'MouseCursorHideTime';
  KEY_USE_MIPMAPS       = 'UseMipMaps';
  KEY_USE_GPU           = 'UseGPU';
  KEY_ZOOM_STEP         = 'ZoomStepPercent';
  KEY_DECODE_DELAY      = 'DecodeDelayMs';
  KEY_SHOW_FPS          = 'ShowFPS';
  KEY_TIMING_LOG        = 'TimingLog';
  KEY_SAVE_IMAGE_DIR    = 'SaveImageDirectory';

const
  KEY_SORT_EDGE_DELAY   = 'EdgeDelayMs';
  KEY_SORT_EDGE_WIDTH   = 'EdgeWidth';
  KEY_SORT_PINNED       = 'Pinned';
  KEY_DELETED_FOLDER    = 'DeletedFolder';
  KEY_ICON_FOLDER       = 'IconFolder';
  KEY_TOTAL_COMMANDER   = 'TotalCommander';
  KEY_FOLLOW_TC         = 'FollowTotalCommander';
  SEC_FILTERS           = 'Filters';
  KEY_FILTER_PINNED     = 'Pinned';
  KEY_AUTO_FILTER       = 'AutoFilter';
  SEC_INFOLINE          = 'InfoLine';
  KEY_INFO_FONT         = 'Font';
  KEY_INFO_FONT_SIZE    = 'FontSize';
  SEC_MAGNIFIER         = 'Magnifier';
  KEY_LENS_MAG          = 'MagnificationPercent';
  KEY_LENS_SIZE         = 'Size';
  KEY_LENS_SHARPEN      = 'Sharpen';

constructor TConfig.Create;
begin
  inherited Create;
  FIniFileName := ExtractFilePath(ParamStr(0)) + CONFIG_FILE;
  FSortFolders := TSortFolders.Create;
  LoadDefaults;
end;

destructor TConfig.Destroy;
begin
  FSortFolders.Free;
  inherited Destroy;
end;

procedure TConfig.LoadDefaults;
var
  It: TInfoItem;
begin
  FOpenLastSession := True;
  FLastDirectory   := '';
  FLastFile        := '';
  FStartFullscreen := False;
  FOnlyOneInstance := True;

  FLeft := 0;
  FTop := 0;
  FWidth := 0;       { not stored: the form's own size }
  FHeight := 0;

  FBackgroundColor := clBlack;
  FFitMode         := fmFitWindow;
  FShowInfo        := True;
  FAutoRotate      := True;
  FOverlaySolid    := False;
  FOverlayColor    := 'White';
  FZonesEnabled    := True;

  FSortMode        := smDateDescending;
  FRecursive       := True;
  FWrapAround      := True;
  FClimbUp         := False;
  FRecurseFromRoot := False;
  FWrapScope       := wsTree;
  FPlaceholderForBadImages := True;

  FPreloadCount    := 5;
  FPreloadBehind   := 2;
  FDecodeThreads   := 0;
  FUseWic          := True;
  FUseWicQuickView := True;
  FRefineDelayMs   := 250;
  FCacheSizeMB     := 0;
  FBackgroundScan  := True;
  FPreviewAhead    := 10;
  FSkimEnterMs     := 1500;
  FSkimRate        := 4;
  FSkimExitMs      := 250;

  FMouseProfile    := 'Default.mouse';
  FMouseHideTime   := 3000;

  FInterpolation   := imLinear;
  FUseMipMaps      := True;
  FUseGPU          := True;
  FZoomStepPercent := 20.0;

  FDecodeDelayMs   := 0;
  FShowDiagnostics := False;
  FTimingLog       := False;
  { Not chosen: the Documents folder at the first save (SaveDirectory). }
  FSaveImageDir    := '';

  FSortEdgeDelayMs := 500;     { user, Day 21: 0.5 s }
  FSortEdgeWidth   := 12;
  FSortPinned      := False;
  FDeletedFolder   := '';
  FIconFolder      := '';
  FTotalCommander  := '';
  FFollowTC        := 1;
  FFilterPinned    := False;
  FAutoFilter      := True;
  FLensMagPercent  := 300;
  FLensSize        := 300;
  FLensSharpen     := 0;      { user: off by default }
  FInfoFont        := '';
  FInfoFontSize    := 0;
  SetLength(FInfoAll, 0);
  for It := Low(TInfoItem) to High(TInfoItem) do
  begin
    SetLength(FInfoAll, Length(FInfoAll) + 1);
    FInfoAll[High(FInfoAll)] := It;
    FInfoOn[It] := True;
  end;
  { The slots are not defaults: an empty list. }
  FSortFolders.Clear;
end;

procedure TConfig.Load;
var
  Ini: TIniFile;
begin
  LoadDefaults;

  { First run: write a complete ini with the defaults. }
  if not FileExists(FIniFileName) then
  begin
    Save;
    Exit;
  end;

  Ini := TIniFile.Create(FIniFileName);
  try
    FOpenLastSession := Ini.ReadBool(SEC_STARTUP, KEY_OPEN_LAST_SESSION, FOpenLastSession);
    FLastDirectory   := Ini.ReadString(SEC_STARTUP, KEY_LAST_DIRECTORY, FLastDirectory);
    FLastFile        := Ini.ReadString(SEC_STARTUP, KEY_LAST_FILE, FLastFile);
    FStartFullscreen := Ini.ReadBool(SEC_STARTUP, KEY_START_FULLSCREEN, FStartFullscreen);
    FOnlyOneInstance := Ini.ReadBool(SEC_STARTUP, KEY_ONLY_ONE_INSTANCE, FOnlyOneInstance);

    FLeft   := Ini.ReadInteger(SEC_WINDOW, KEY_LEFT, FLeft);
    FTop    := Ini.ReadInteger(SEC_WINDOW, KEY_TOP, FTop);
    FWidth  := Ini.ReadInteger(SEC_WINDOW, KEY_WIDTH, FWidth);
    FHeight := Ini.ReadInteger(SEC_WINDOW, KEY_HEIGHT, FHeight);

    FShowInfo        := Ini.ReadBool(SEC_VIEW, KEY_SHOW_INFO, FShowInfo);
    FAutoRotate      := Ini.ReadBool(SEC_VIEW, KEY_AUTO_ROTATE, FAutoRotate);
    FOverlaySolid    := Ini.ReadBool(SEC_VIEW, KEY_OVERLAY_SOLID, FOverlaySolid);
    FOverlayColor    := Trim(Ini.ReadString(SEC_VIEW, KEY_OVERLAY_COLOR, FOverlayColor));

    FSortMode   := StringToSortMode(Ini.ReadString(SEC_NAVIGATION, KEY_SORT_MODE, ''), FSortMode);
    FRecursive  := Ini.ReadBool(SEC_NAVIGATION, KEY_RECURSIVE, FRecursive);
    FWrapAround := Ini.ReadBool(SEC_NAVIGATION, KEY_WRAP_AROUND, FWrapAround);
    FClimbUp    := Ini.ReadBool(SEC_NAVIGATION, KEY_CLIMB_UP, FClimbUp);
    FRecurseFromRoot := Ini.ReadBool(SEC_NAVIGATION, KEY_RECURSE_FROM_ROOT, FRecurseFromRoot);
    FWrapScope  := StringToWrapScope(Ini.ReadString(SEC_NAVIGATION, KEY_WRAP_SCOPE, ''), FWrapScope);
    FPlaceholderForBadImages := Ini.ReadBool(SEC_NAVIGATION, KEY_PLACEHOLDER, FPlaceholderForBadImages);

    FPreloadCount   := Ini.ReadInteger(SEC_PERFORMANCE, KEY_PRELOAD_COUNT, FPreloadCount);
    FPreloadBehind  := Ini.ReadInteger(SEC_PERFORMANCE, KEY_PRELOAD_BEHIND, FPreloadBehind);
    FDecodeThreads  := Ini.ReadInteger(SEC_PERFORMANCE, KEY_DECODE_THREADS, FDecodeThreads);
    FUseWic         := Ini.ReadBool(SEC_PERFORMANCE, KEY_USE_WIC, FUseWic);
    FUseWicQuickView := Ini.ReadBool(SEC_PERFORMANCE, KEY_USE_WIC_QUICK, FUseWicQuickView);
    FRefineDelayMs  := Ini.ReadInteger(SEC_PERFORMANCE, KEY_REFINE_DELAY, FRefineDelayMs);
    FCacheSizeMB    := Ini.ReadInteger(SEC_PERFORMANCE, KEY_CACHE_SIZE_MB, FCacheSizeMB);
    FBackgroundScan := Ini.ReadBool(SEC_PERFORMANCE, KEY_BACKGROUND_SCAN, FBackgroundScan);
    FPreviewAhead   := Ini.ReadInteger(SEC_PERFORMANCE, KEY_PREVIEW_AHEAD, FPreviewAhead);
    FSkimEnterMs    := Ini.ReadInteger(SEC_PERFORMANCE, KEY_SKIM_ENTER, FSkimEnterMs);
    FSkimRate       := Ini.ReadInteger(SEC_PERFORMANCE, KEY_SKIM_RATE, FSkimRate);
    FSkimExitMs     := Ini.ReadInteger(SEC_PERFORMANCE, KEY_SKIM_EXIT, FSkimExitMs);

    FMouseProfile  := Ini.ReadString(SEC_MOUSE, KEY_MOUSE_PROFILE, FMouseProfile);
    FMouseHideTime := Ini.ReadInteger(SEC_MOUSE, KEY_MOUSE_HIDE_TIME, FMouseHideTime);
    FZonesEnabled  := Ini.ReadBool(SEC_MOUSE, KEY_ZONES_ENABLED, FZonesEnabled);

    FUseMipMaps      := Ini.ReadBool(SEC_RENDERER, KEY_USE_MIPMAPS, FUseMipMaps);
    FUseGPU          := Ini.ReadBool(SEC_RENDERER, KEY_USE_GPU, FUseGPU);
    FZoomStepPercent := Ini.ReadInteger(SEC_RENDERER, KEY_ZOOM_STEP, Round(FZoomStepPercent));

    FDecodeDelayMs   := Ini.ReadInteger(SEC_DEBUG, KEY_DECODE_DELAY, FDecodeDelayMs);
    FShowDiagnostics := Ini.ReadBool(SEC_DEBUG, KEY_SHOW_FPS, FShowDiagnostics);
    FTimingLog       := Ini.ReadBool(SEC_DEBUG, KEY_TIMING_LOG, FTimingLog);
    FSaveImageDir    := Ini.ReadString(SEC_DEBUG, KEY_SAVE_IMAGE_DIR, FSaveImageDir);

    FSortEdgeDelayMs := Ini.ReadInteger(SortSection, KEY_SORT_EDGE_DELAY, FSortEdgeDelayMs);
    FSortEdgeWidth   := Ini.ReadInteger(SortSection, KEY_SORT_EDGE_WIDTH, FSortEdgeWidth);
    FSortPinned      := Ini.ReadBool(SortSection, KEY_SORT_PINNED, FSortPinned);
    FDeletedFolder   := Trim(Ini.ReadString(SortSection, KEY_DELETED_FOLDER, FDeletedFolder));
    FIconFolder      := Trim(Ini.ReadString(SortSection, KEY_ICON_FOLDER, FIconFolder));
    FTotalCommander  := Trim(Ini.ReadString(SortSection, KEY_TOTAL_COMMANDER, FTotalCommander));
    FFollowTC        := Ini.ReadInteger(SortSection, KEY_FOLLOW_TC, FFollowTC);
    if (FFollowTC < 0) or (FFollowTC > 2) then
      FFollowTC := 1;
    FSortFolders.LoadFromIni(Ini);

    FFilterPinned    := Ini.ReadBool(SEC_FILTERS, KEY_FILTER_PINNED, FFilterPinned);
    FAutoFilter      := Ini.ReadBool(SEC_FILTERS, KEY_AUTO_FILTER, FAutoFilter);

    FLensMagPercent  := Ini.ReadInteger(SEC_MAGNIFIER, KEY_LENS_MAG, FLensMagPercent);
    FLensSize        := Ini.ReadInteger(SEC_MAGNIFIER, KEY_LENS_SIZE, FLensSize);
    FLensSharpen     := Ini.ReadInteger(SEC_MAGNIFIER, KEY_LENS_SHARPEN, FLensSharpen);
    if (FLensMagPercent < 125) or (FLensMagPercent > 3200) then
      FLensMagPercent := 300;
    if (FLensSize < 80) or (FLensSize > 4000) then
      FLensSize := 300;
    if (FLensSharpen < 0) or (FLensSharpen > 2) then
      FLensSharpen := 0;

    ReadInfoLine(Ini);
  finally
    Ini.Free;
  end;

  Validate;
end;

procedure TConfig.Save;
var
  Ini: TIniFile;
  I: Integer;
begin
  Ini := TIniFile.Create(FIniFileName);
  try
    Ini.WriteBool(SEC_STARTUP, KEY_OPEN_LAST_SESSION, FOpenLastSession);
    Ini.WriteString(SEC_STARTUP, KEY_LAST_DIRECTORY, FLastDirectory);
    Ini.WriteString(SEC_STARTUP, KEY_LAST_FILE, FLastFile);
    Ini.WriteBool(SEC_STARTUP, KEY_START_FULLSCREEN, FStartFullscreen);
    Ini.WriteBool(SEC_STARTUP, KEY_ONLY_ONE_INSTANCE, FOnlyOneInstance);

    if FWidth > 0 then
    begin
      Ini.WriteInteger(SEC_WINDOW, KEY_LEFT, FLeft);
      Ini.WriteInteger(SEC_WINDOW, KEY_TOP, FTop);
      Ini.WriteInteger(SEC_WINDOW, KEY_WIDTH, FWidth);
      Ini.WriteInteger(SEC_WINDOW, KEY_HEIGHT, FHeight);
    end;

    Ini.WriteBool(SEC_VIEW, KEY_SHOW_INFO, FShowInfo);
    Ini.WriteBool(SEC_VIEW, KEY_AUTO_ROTATE, FAutoRotate);
    Ini.WriteBool(SEC_VIEW, KEY_OVERLAY_SOLID, FOverlaySolid);
    Ini.WriteString(SEC_VIEW, KEY_OVERLAY_COLOR, FOverlayColor);

    Ini.WriteString(SEC_NAVIGATION, KEY_SORT_MODE, SortModeToString(FSortMode));
    Ini.WriteBool(SEC_NAVIGATION, KEY_RECURSIVE, FRecursive);
    Ini.WriteBool(SEC_NAVIGATION, KEY_WRAP_AROUND, FWrapAround);
    Ini.WriteBool(SEC_NAVIGATION, KEY_CLIMB_UP, FClimbUp);
    Ini.WriteBool(SEC_NAVIGATION, KEY_RECURSE_FROM_ROOT, FRecurseFromRoot);
    Ini.WriteString(SEC_NAVIGATION, KEY_WRAP_SCOPE, WrapScopeToString(FWrapScope));
    Ini.WriteBool(SEC_NAVIGATION, KEY_PLACEHOLDER, FPlaceholderForBadImages);

    Ini.WriteInteger(SEC_PERFORMANCE, KEY_PRELOAD_COUNT, FPreloadCount);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_PRELOAD_BEHIND, FPreloadBehind);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_DECODE_THREADS, FDecodeThreads);
    Ini.WriteBool(SEC_PERFORMANCE, KEY_USE_WIC, FUseWic);
    Ini.WriteBool(SEC_PERFORMANCE, KEY_USE_WIC_QUICK, FUseWicQuickView);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_REFINE_DELAY, FRefineDelayMs);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_CACHE_SIZE_MB, FCacheSizeMB);
    Ini.WriteBool(SEC_PERFORMANCE, KEY_BACKGROUND_SCAN, FBackgroundScan);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_PREVIEW_AHEAD, FPreviewAhead);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_SKIM_ENTER, FSkimEnterMs);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_SKIM_RATE, FSkimRate);
    Ini.WriteInteger(SEC_PERFORMANCE, KEY_SKIM_EXIT, FSkimExitMs);

    Ini.WriteString(SEC_MOUSE, KEY_MOUSE_PROFILE, FMouseProfile);
    Ini.WriteInteger(SEC_MOUSE, KEY_MOUSE_HIDE_TIME, FMouseHideTime);
    Ini.WriteBool(SEC_MOUSE, KEY_ZONES_ENABLED, FZonesEnabled);

    Ini.WriteBool(SEC_RENDERER, KEY_USE_MIPMAPS, FUseMipMaps);
    Ini.WriteBool(SEC_RENDERER, KEY_USE_GPU, FUseGPU);
    Ini.WriteInteger(SEC_RENDERER, KEY_ZOOM_STEP, Round(FZoomStepPercent));

    Ini.WriteInteger(SEC_DEBUG, KEY_DECODE_DELAY, FDecodeDelayMs);
    Ini.WriteBool(SEC_DEBUG, KEY_SHOW_FPS, FShowDiagnostics);
    Ini.WriteBool(SEC_DEBUG, KEY_TIMING_LOG, FTimingLog);
    Ini.WriteString(SEC_DEBUG, KEY_SAVE_IMAGE_DIR, FSaveImageDir);

    WriteSort(Ini);
    Ini.WriteBool(SEC_FILTERS, KEY_FILTER_PINNED, FFilterPinned);
    Ini.WriteBool(SEC_FILTERS, KEY_AUTO_FILTER, FAutoFilter);

    Ini.WriteInteger(SEC_MAGNIFIER, KEY_LENS_MAG, FLensMagPercent);
    Ini.WriteInteger(SEC_MAGNIFIER, KEY_LENS_SIZE, FLensSize);
    Ini.WriteInteger(SEC_MAGNIFIER, KEY_LENS_SHARPEN, FLensSharpen);

    { The info line: a key already there keeps its place (the order is
      the user's); a new one goes at the end. }
    Ini.WriteString(SEC_INFOLINE, KEY_INFO_FONT, FInfoFont);
    Ini.WriteInteger(SEC_INFOLINE, KEY_INFO_FONT_SIZE, FInfoFontSize);
    for I := 0 to High(FInfoAll) do
      Ini.WriteBool(SEC_INFOLINE, InfoItemKeys[FInfoAll[I]], FInfoOn[FInfoAll[I]]);
  finally
    Ini.Free;
  end;
end;

{ [InfoLine]: the font, and the parts in the order of their lines (user,
  Day 24). A part whose line is missing is on, after the others. }
procedure TConfig.ReadInfoLine(AIni: TCustomIniFile);
var
  Keys: TStringList;
  Seen: array[TInfoItem] of Boolean;
  It: TInfoItem;
  I: Integer;

  procedure AddItem(AItem: TInfoItem);
  begin
    SetLength(FInfoAll, Length(FInfoAll) + 1);
    FInfoAll[High(FInfoAll)] := AItem;
    Seen[AItem] := True;
  end;

begin
  FInfoFont := Trim(AIni.ReadString(SEC_INFOLINE, KEY_INFO_FONT, FInfoFont));
  FInfoFontSize := AIni.ReadInteger(SEC_INFOLINE, KEY_INFO_FONT_SIZE, FInfoFontSize);
  if (FInfoFontSize < 0) or (FInfoFontSize > 72) then
    FInfoFontSize := 0;
  if (FInfoFontSize > 0) and (FInfoFontSize < 6) then
    FInfoFontSize := 6;
  for It := Low(TInfoItem) to High(TInfoItem) do
    Seen[It] := False;
  SetLength(FInfoAll, 0);
  Keys := TStringList.Create;
  try
    AIni.ReadSection(SEC_INFOLINE, Keys);
    for I := 0 to Keys.Count - 1 do
      for It := Low(TInfoItem) to High(TInfoItem) do
        if (not Seen[It]) and SameText(Trim(Keys[I]), InfoItemKeys[It]) then
        begin
          AddItem(It);
          FInfoOn[It] := AIni.ReadBool(SEC_INFOLINE, InfoItemKeys[It], True);
        end;
  finally
    Keys.Free;
  end;
  for It := Low(TInfoItem) to High(TInfoItem) do
    if not Seen[It] then
    begin
      AddItem(It);
      FInfoOn[It] := True;
    end;
end;

function TConfig.InfoItems: TInfoItems;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(FInfoAll) do
    if FInfoOn[FInfoAll[I]] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FInfoAll[I];
    end;
end;

procedure TConfig.WriteSort(AIni: TCustomIniFile);
begin
  AIni.WriteInteger(SortSection, KEY_SORT_EDGE_DELAY, FSortEdgeDelayMs);
  AIni.WriteInteger(SortSection, KEY_SORT_EDGE_WIDTH, FSortEdgeWidth);
  AIni.WriteBool(SortSection, KEY_SORT_PINNED, FSortPinned);
  AIni.WriteString(SortSection, KEY_DELETED_FOLDER, FDeletedFolder);
  AIni.WriteString(SortSection, KEY_ICON_FOLDER, FIconFolder);
  AIni.WriteString(SortSection, KEY_TOTAL_COMMANDER, FTotalCommander);
  AIni.WriteInteger(SortSection, KEY_FOLLOW_TC, FFollowTC);
  FSortFolders.SaveToIni(AIni);
end;

procedure TConfig.SaveSort;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(FIniFileName);
    try
      WriteSort(Ini);
    finally
      Ini.Free;
    end;
  except
    { A read-only folder: the slots hold for this session only. }
  end;
end;

procedure TConfig.SaveFilters;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(FIniFileName);
    try
      Ini.WriteBool(SEC_FILTERS, KEY_FILTER_PINNED, FFilterPinned);
    finally
      Ini.Free;
    end;
  except
    { A read-only folder: the pin holds for this session only. }
  end;
end;

function TConfig.DeletedFilesFolder: string;
begin
  if FDeletedFolder <> '' then
    Result := ExcludeTrailingPathDelimiter(FDeletedFolder)
  else
    Result := UserDocumentsDirectory + 'MView deleted files';
end;

function TConfig.IconFilesFolder: string;
begin
  if FIconFolder <> '' then
    Result := IncludeTrailingPathDelimiter(FIconFolder)
  else
    Result := ExtractFilePath(ParamStr(0)) + 'icons' + PathDelim;
end;

type
  TKeyHelp = record
    Section: string;
    Key: string;
    Text: string;
  end;

const
  KeyHelpTable: array[0..38] of TKeyHelp = (
    (Section: SEC_STARTUP; Key: KEY_OPEN_LAST_SESSION;
     Text: 'Not used any more: started without a file or folder, MView shows this editor; "View images" opens the last session.'),
    (Section: SEC_STARTUP; Key: KEY_LAST_DIRECTORY;
     Text: 'Folder of the last session (written by MView on exit).'),
    (Section: SEC_STARTUP; Key: KEY_LAST_FILE;
     Text: 'Image of the last session (written by MView on exit).'),
    (Section: SEC_STARTUP; Key: KEY_START_FULLSCREEN;
     Text: '1 = the viewer starts fullscreen (Enter switches).'),
    (Section: SEC_WINDOW; Key: KEY_LEFT;
     Text: 'Window position when not fullscreen (written by MView when the window is moved or closed).'),
    (Section: SEC_WINDOW; Key: KEY_TOP;
     Text: 'Window position when not fullscreen (written by MView).'),
    (Section: SEC_WINDOW; Key: KEY_WIDTH;
     Text: 'Window width when not fullscreen (written by MView when the window is resized or closed).'),
    (Section: SEC_WINDOW; Key: KEY_HEIGHT;
     Text: 'Window height when not fullscreen (written by MView).'),
    (Section: SEC_VIEW; Key: KEY_SHOW_INFO;
     Text: '1 = show the info bar (file name, size, zoom). The mouse profile command Info switches it.'),
    (Section: SEC_VIEW; Key: KEY_AUTO_ROTATE;
     Text: '1 = turn photos upright by their EXIF orientation.'),
    (Section: SEC_NAVIGATION; Key: KEY_SORT_MODE;
     Text: 'Order of the images in a folder. Values:' + LineEnding +
           '  DateDescending  newest first (default)' + LineEnding +
           '  DateAscending  oldest first' + LineEnding +
           '  FileNameAscending  by name, A to Z (Image2 before Image10)' + LineEnding +
           '  FileNameDescending  by name, Z to A' + LineEnding +
           'The zones of the mouse profile can browse in their own order (by date / by name).'),
    (Section: SEC_NAVIGATION; Key: KEY_RECURSIVE;
     Text: '1 = include the subfolders (the whole tree under the start folder).'),
    (Section: SEC_NAVIGATION; Key: KEY_WRAP_AROUND;
     Text: '1 = after the last image comes the first again.'),
    (Section: SEC_NAVIGATION; Key: KEY_WRAP_SCOPE;
     Text: 'What comes after the last image of a folder (with WrapAround=1). Values:' + LineEnding +
           '  Dir  the first image of the same folder: you stay in the folder;' + LineEnding +
           '       only the gestures, the tilt wheel and the Left / Right keys change folders' + LineEnding +
           '  Tree  the first image of the next folder with images (default)'),
    (Section: SEC_NAVIGATION; Key: KEY_CLIMB_UP;
     Text: '1 = at the end of the folder tree (next / previous folder, or next / previous image with' + LineEnding +
           '    WrapScope=Tree) MView browses on one level higher, into the neighbouring folders,' + LineEnding +
           '    instead of starting again at the beginning; again and again, up to one level below' + LineEnding +
           '    the drive. Also leaves a folder opened from the sort panel. Needs Recursive=1.' + LineEnding +
           '    0 = stay in the tree (default).'),
    (Section: SEC_NAVIGATION; Key: KEY_PLACEHOLDER;
     Text: '1 = show a message for images that can''t be read; 0 = skip them.'),
    (Section: SEC_PERFORMANCE; Key: KEY_PRELOAD_COUNT;
     Text: 'Images decoded ahead in the direction of travel (0..20).'),
    (Section: SEC_PERFORMANCE; Key: KEY_PRELOAD_BEHIND;
     Text: 'Images kept / decoded behind (0..10).'),
    (Section: SEC_PERFORMANCE; Key: KEY_DECODE_THREADS;
     Text: 'Decode threads; 0 = automatic (cores - 1, 1..4).'),
    (Section: SEC_PERFORMANCE; Key: KEY_USE_WIC;
     Text: '1 = full-size JPEGs with the Windows Imaging Component (fast); 0 = MView''s own decoder.'),
    (Section: SEC_PERFORMANCE; Key: KEY_USE_WIC_QUICK;
     Text: '1 = quick views of large JPEGs scaled by the Windows codec (fast); 0 = MView''s own decoder. Compare in timing.csv.'),
    (Section: SEC_PERFORMANCE; Key: KEY_REFINE_DELAY;
     Text: 'ms an image must be shown before its full size is decoded (at once when zooming). 0 = at once.'),
    (Section: SEC_PERFORMANCE; Key: KEY_CACHE_SIZE_MB;
     Text: 'Image cache in MB; 0 = automatic (25 % of RAM, 256..4096).'),
    (Section: SEC_PERFORMANCE; Key: KEY_BACKGROUND_SCAN;
     Text: 'Not used yet.'),
    (Section: SEC_PERFORMANCE; Key: KEY_PREVIEW_AHEAD;
     Text: 'Embedded thumbnails read ahead (tiny, instant; shown until the real image is there). 0 = none.'),
    (Section: SEC_PERFORMANCE; Key: KEY_SKIM_ENTER;
     Text: 'Skim mode (only thumbnails, no decoding) while the last this-many ms averaged SkimRate images per second or more. 0 = never skim.'),
    (Section: SEC_PERFORMANCE; Key: KEY_SKIM_RATE;
     Text: 'Average images per second (over SkimEnterMs) that count as fast browsing (1..50). With 4 and 1500 ms: 6 steps within 1.5 s.'),
    (Section: SEC_PERFORMANCE; Key: KEY_SKIM_EXIT;
     Text: 'ms without browsing that end Skim mode: then the real image is decoded.'),
    (Section: SEC_MOUSE; Key: KEY_MOUSE_PROFILE;
     Text: 'The mouse profile file, next to MView.ini: which button does what in which zone of the screen. Edit it on the "Mouse & keys" page.'),
    (Section: SEC_MOUSE; Key: KEY_MOUSE_HIDE_TIME;
     Text: 'ms without mouse movement until the cursor hides in the viewer; 0 = never.'),
    (Section: SEC_MOUSE; Key: KEY_ZONES_ENABLED;
     Text: '1 = the four zones of the mouse profile work (default).' + LineEnding
       + '0 = the zones are off: every button does its Anywhere command everywhere.'
       + LineEnding + 'Also the green / red button on the "Mouse & keys" page.'),
    (Section: SEC_VIEW; Key: KEY_OVERLAY_SOLID;
     Text: '0 = info and diagnostics lines straight over the image (default).' + LineEnding
       + '1 = on a solid black bar (easier to read on busy images).'),
    (Section: SEC_VIEW; Key: KEY_OVERLAY_COLOR;
     Text: 'Colour of the texts over the image:' + LineEnding
       + 'White   (default)' + LineEnding + 'Yellow' + LineEnding + 'Red'),
    (Section: SEC_RENDERER; Key: KEY_USE_MIPMAPS;
     Text: '1 = smooth reduced images on the GPU (mipmaps).'),
    (Section: SEC_RENDERER; Key: KEY_USE_GPU;
     Text: '1 = draw with OpenGL; 0 = always the CPU renderer.'),
    (Section: SEC_RENDERER; Key: KEY_ZOOM_STEP;
     Text: 'Zoom step per wheel notch (and of the ZoomIn / ZoomOut commands), in percent (1..200).'),
    (Section: SEC_DEBUG; Key: KEY_DECODE_DELAY;
     Text: 'Testing only: every decode waits this many ms first. 0 = off.'),
    (Section: SEC_DEBUG; Key: KEY_SHOW_FPS;
     Text: '1 = show the diagnostics line (key D switches).'),
    (Section: SEC_DEBUG; Key: KEY_TIMING_LOG;
     Text: '1 = one line per displayed image in timing.csv next to MView.exe.')
  );

function ConfigKeyHelp(const ASection, AKey: string): string;
var
  I: Integer;
  It: TInfoItem;
  IsPart: Boolean;
begin
  Result := '';
  if SameText(ASection, SEC_DEBUG) and SameText(AKey, KEY_SAVE_IMAGE_DIR) then
    Exit('Folder for "Save image" (context menu). Empty: your Documents folder, written here at the first save. '
      + 'If the folder can''t be used (wrong path, missing drive), the image goes to your Documents folder.');
  if SameText(ASection, SEC_FILTERS) and SameText(AKey, KEY_FILTER_PINNED) then
    Exit('1 = the filter panel (left edge) stays open (its pin). Written by MView. '
      + 'It opens when the mouse rests at the left edge ([Sort] EdgeDelayMs and EdgeWidth), '
      + 'or with the menu entry "Filters".');
  if SameText(ASection, SEC_STARTUP) and SameText(AKey, KEY_ONLY_ONE_INSTANCE) then
    Exit('1 = only one MView (default): an image or folder opened while MView runs (e.g. from '
      + 'Total Commander) opens in the running MView, which comes to the front. 0 = a new MView '
      + 'each time. Read when MView starts.');
  if SameText(ASection, SEC_NAVIGATION) and SameText(AKey, KEY_RECURSE_FROM_ROOT) then
    Exit('0 = a drive root (C:\, also a network share''s root) is opened without its subfolders, '
      + 'even with Recursive=1: only the images directly in it (default; a whole drive would '
      + 'otherwise be scanned for images). 1 = with its subfolders, like any other folder.');
  if SameText(ASection, SEC_INFOLINE) then
  begin
    IsPart := False;
    for It := Low(TInfoItem) to High(TInfoItem) do
      if SameText(AKey, InfoItemKeys[It]) then
        IsPart := True;
    if SameText(AKey, KEY_INFO_FONT) then
      Exit('The info line''s font, e.g. Segoe UI, Consolas, Arial. Empty = the standard font.');
    if SameText(AKey, KEY_INFO_FONT_SIZE) then
      Exit('The info line''s font size in points (6 .. 72). 0 = the standard size.');
    if IsPart then
      Exit('A part of the info line (bottom): 1 = shown, 0 = left out. The parts appear in the '
      + 'order of these lines: move a line up or down to change the order.' + LineEnding
      + 'FileName, Dimensions (W x H), Folder, Position (12 / 40), Videos (in the folder), '
      + 'Sorting (by date / by name), Zoom (52 % = size on screen, angle), State (loading, '
      + 'skimming, scanning), Animation (frames), Filters ([filtered, auto ...]), Messages '
      + '(what MView just did).');
  end;
  if SameText(ASection, SEC_MAGNIFIER) then
  begin
    if SameText(AKey, KEY_LENS_MAG) then
      Exit('The magnifier''s magnification, in percent of what the screen shows (300 = 3 x; '
        + '125 .. 3200). Left drag sideways changes it; written by MView on exit.');
    if SameText(AKey, KEY_LENS_SIZE) then
      Exit('The magnifier''s diameter in pixels (80 .. 4000). Left drag up / down changes it; '
        + 'written by MView on exit.');
    if SameText(AKey, KEY_LENS_SHARPEN) then
      Exit('The magnifier''s sharpening: 0 off (default), 1 low, 2 high. The wheel changes it; '
        + 'written by MView on exit.');
  end;
  if SameText(ASection, SEC_FILTERS) and SameText(AKey, KEY_AUTO_FILTER) then
    Exit('1 = Auto black / white point for every image from the start (default): each image is '
      + 'stretched to its own range, "[auto]" in the info line. 0 = off at the start. '
      + 'Double-click Auto on the filter panel switches it for the session.');
  if SameText(ASection, SortSection) then
  begin
    if SameText(AKey, KEY_SORT_EDGE_DELAY) then
      Exit('ms the mouse rests at the right edge of the window until the sort panel opens (default 500). '
        + '0 = never (the menu entry "Sort panel (side menu)" and the mouse profile command SortPanel '
        + 'still open it).');
    if SameText(AKey, KEY_SORT_EDGE_WIDTH) then
      Exit('How close to the right edge the mouse must rest to open the sort panel, in pixels '
        + '(default 12, scaled for the screen; 2..60). Larger = easier to hit in a window.');
    if SameText(AKey, KEY_SORT_PINNED) then
      Exit('1 = the sort panel stays open after a copy / move (its pin). Written by MView.');
    if SameText(AKey, KEY_DELETED_FOLDER) then
      Exit('Where "Delete current image" moves files (MView never really deletes). '
        + 'Empty = "MView deleted files" in your Documents folder.');
    if SameText(AKey, KEY_ICON_FOLDER) then
      Exit('Folder with .ico / .png icons for the sort panel. Empty = "icons" next to MView.exe.');
    if SameText(AKey, KEY_FOLLOW_TC) then
      Exit('Follow Total Commander: 0 = no; 1 = when its active panel changes folder, MView opens '
        + 'that folder (default); 2 = also the image under its cursor (MView as Total Commander''s '
        + 'viewer). Also in the right-click menu.');
    if SameText(AKey, KEY_TOTAL_COMMANDER) then
      Exit('Total Commander (TOTALCMD64.EXE) for "Side by side". Empty = found by MView.');
    if Pos('Slot', AKey) = 1 then
      Exit('A sort panel folder (Folder, Name, Color, Icon). Set on the panel: drop a folder on it, '
        + 'or its "..." menu. Colors: Green, Blue, Red, Yellow, Orange, Purple, Cyan, Grey.');
    if Pos('Recent', AKey) = 1 then
      Exit('A folder used recently for the sort panel (written by MView).');
  end;
  for I := Low(KeyHelpTable) to High(KeyHelpTable) do
    if SameText(KeyHelpTable[I].Section, ASection)
      and SameText(KeyHelpTable[I].Key, AKey) then
      Exit(KeyHelpTable[I].Text);
end;

{$IFDEF WINDOWS}
function MViewSHGetFolderPathW(hwnd: PtrUInt; csidl: LongInt; hToken: PtrUInt;
  dwFlags: LongWord; pszPath: PWideChar): LongInt; stdcall;
  external 'shell32.dll' name 'SHGetFolderPathW';
{$ENDIF}

{ The user's Documents folder (also when it was moved, e.g. to
  OneDrive), with a trailing delimiter. }
function UserDocumentsDirectory: string;
{$IFDEF WINDOWS}
const
  CSIDL_PERSONAL_FOLDER = 5;
var
  Buf: array[0..1023] of WideChar;
{$ENDIF}
begin
  Result := '';
  {$IFDEF WINDOWS}
  FillChar(Buf, SizeOf(Buf), 0);
  if MViewSHGetFolderPathW(0, CSIDL_PERSONAL_FOLDER, 0, 0, @Buf[0]) = 0 then
    Result := string(UTF8Encode(UnicodeString(PWideChar(@Buf[0]))));
  {$ENDIF}
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetUserDir) + 'Documents';
  Result := IncludeTrailingPathDelimiter(Result);
end;

function TConfig.SaveDirectory: string;
var
  Ini: TIniFile;
begin
  if Trim(FSaveImageDir) <> '' then
    Exit(IncludeTrailingPathDelimiter(Trim(FSaveImageDir)));
  FSaveImageDir := UserDocumentsDirectory;
  Result := FSaveImageDir;
  try
    Ini := TIniFile.Create(FIniFileName);
    try
      Ini.WriteString(SEC_DEBUG, KEY_SAVE_IMAGE_DIR, FSaveImageDir);
    finally
      Ini.Free;
    end;
  except
    { Read-only folder: used for this session only. }
  end;
end;

function TConfig.MouseProfileFileName: string;
var
  Name: string;
begin
  Name := Trim(FMouseProfile);
  if Name = '' then
    Name := 'Default.mouse';
  if ExtractFilePath(Name) = '' then
    Result := ExtractFilePath(FIniFileName) + Name
  else
    Result := Name;
end;

procedure TConfig.SaveWindowBounds;
var
  Ini: TIniFile;
begin
  if FWidth <= 0 then
    Exit;
  try
    Ini := TIniFile.Create(FIniFileName);
    try
      Ini.WriteInteger(SEC_WINDOW, KEY_LEFT, FLeft);
      Ini.WriteInteger(SEC_WINDOW, KEY_TOP, FTop);
      Ini.WriteInteger(SEC_WINDOW, KEY_WIDTH, FWidth);
      Ini.WriteInteger(SEC_WINDOW, KEY_HEIGHT, FHeight);
    finally
      Ini.Free;
    end;
  except
    { A read-only folder: the window just opens at its default place. }
  end;
end;

procedure TConfig.Validate;
begin
  if FSortEdgeDelayMs < 0 then
    FSortEdgeDelayMs := 0;
  if (FSortEdgeDelayMs > 0) and (FSortEdgeDelayMs < 200) then
    FSortEdgeDelayMs := 200;
  if FSortEdgeWidth < 2 then
    FSortEdgeWidth := 2;
  if FSortEdgeWidth > 60 then
    FSortEdgeWidth := 60;
  if FPreloadCount < 0 then
    FPreloadCount := 0;
  if FPreloadCount > 20 then
    FPreloadCount := 20;
  if FPreloadBehind < 0 then
    FPreloadBehind := 0;
  if FPreloadBehind > 10 then
    FPreloadBehind := 10;

  if (FDecodeThreads < 0) or (FDecodeThreads > 16) then
    FDecodeThreads := 0;
  if FRefineDelayMs < 0 then
    FRefineDelayMs := 0;
  if FRefineDelayMs > 60000 then
    FRefineDelayMs := 60000;

  { 0 = automatic; otherwise at least 32 MB. }
  if FCacheSizeMB < 0 then
    FCacheSizeMB := 0;
  if (FCacheSizeMB > 0) and (FCacheSizeMB < 32) then
    FCacheSizeMB := 32;

  if FPreviewAhead < 0 then
    FPreviewAhead := 0;
  if FPreviewAhead > 50 then
    FPreviewAhead := 50;
  { 0 = never skim. }
  if FSkimEnterMs < 0 then
    FSkimEnterMs := 0;
  if FSkimEnterMs > 60000 then
    FSkimEnterMs := 60000;
  if (FSkimRate < 1) or (FSkimRate > 50) then
    FSkimRate := 4;
  if (FSkimExitMs < 50) or (FSkimExitMs > 10000) then
    FSkimExitMs := 250;

  if FMouseHideTime < 0 then
    FMouseHideTime := 0;

  if (FZoomStepPercent < 1) or (FZoomStepPercent > 200) then
    FZoomStepPercent := 20;

  if FDecodeDelayMs < 0 then
    FDecodeDelayMs := 0;
  if FDecodeDelayMs > 60000 then
    FDecodeDelayMs := 60000;
end;

end.
