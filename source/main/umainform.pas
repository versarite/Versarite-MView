unit uMainForm;

{
  Unit: uMainForm

  Purpose
  -------
  The main window. A thin shell (spec §2.3): it creates TMView and the
  drawing surface, passes commands on, and does the few things only a
  window can do (close, fullscreen).

  Two faces (spec §11, v1.2d):
  - Started with a file or folder: the viewer, at once.
  - Started without: the settings editor (TIniEditor, MView.ini).
    "View images" there starts the viewer with the last session;
    TMView is only created then, so it reads the settings just saved.

  Owns
  ----
  TMView (once the viewer runs), and through the LCL component tree:
  the drawing surface, the right-click menu, the settings editor.
  In detail:
  - FMView (TMView): created by CreateViewer, freed when going back
    to the settings editor (Esc) or in FormDestroy.
  - The drawing surface: FCpuView (TMediaView) or FGLView
    (TGLMediaView). The renderer made for it (TCpuRenderer or
    TGLRenderer) is handed to TMView (AttachView), which owns it.
  - FPopupMenu (the right-click menu), FDeliveryTimer (TTimer, 50 ms),
    FEditor (TIniEditor, made once and kept hidden while viewing).
  - A short-lived TConfig when no viewer runs (ShowEditor,
    RememberBounds).

  Knows
  -----
  - The watchdog (uWatchdog): started here (StartWatchdog), armed
    with ExitDeadlineMs when the viewer or MView shuts down.
  - The surface's mouse engine (ViewInput): gets TMView's mouse
    profile and [Mouse] ZonesEnabled; Tick, FocusLost, cursor hiding.
  - TMView.Config: window place, UseGPU, UseMipMaps, StartFullscreen,
    MouseHideTime.

  Responsibilities
  ----------------
  - Choose the GPU surface if OpenGL works and UseGPU=1, otherwise the
    CPU one (spec §8.5); the reason is shown in the diagnostics line.
  - Pass the surface's commands to TMView.Execute; show the menu
    itself (cmdShowMenu), including "About MView" (the dedication to
    Hamana, AboutText).
  - Fullscreen, exit, and going back to the settings editor (Esc in
    the viewer, run later through QueueAsyncCall).
  - Esc on the settings screen: like the editor's Exit (unless the
    "Try it here" area or an open list has the focus).
  - Drag and drop: a dropped file or folder is opened.
  - Remember the window place in MView.ini (1 s after the last move /
    resize in the viewer; on close; before switching faces), and put
    the window there at start if it is still on a monitor.
  - On its timer: TMView.PumpDeliveries, the mouse engine's Tick,
    cursor hiding ([Mouse] MouseCursorHideTime).

  Does NOT
  --------
  - Contain viewer logic.
  - Show dialogs (spec §3.1).

  Threads
  -------
  UI thread only (LCL events, a TTimer, one QueueAsyncCall). The
  worker threads are TMView's; the watchdog runs its own thread
  (uWatchdog).

  Uses (MView units)
  ------------------
  interface:      uCommands, uMouseEngine, uRenderer, uMView,
                  uMediaView, uGLRenderer, uGLMediaView, uConfig,
                  uIniEditor, uStopwatch, uWatchdog
  implementation: uMousePage
  Libraries:      Classes, SysUtils, Forms, Controls, Graphics, Menus,
                  ExtCtrls, LCLType, LCLIntf, StdCtrls

  Used by
  -------
  MView.lpr (program)
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Menus,
  ExtCtrls,
  uCommands,
  uMouseEngine,
  uRenderer,
  uMView,
  uMediaView,
  uGLRenderer,
  uGLMediaView,
  uConfig,
  uIniEditor,
  uStopwatch,
  uWatchdog;

type

  { TMainForm }

  TMainForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FMView: TMView;
    FView: TWinControl;          { the drawing surface, CPU or GPU }
    FCpuView: TMediaView;        { one of these two is used }
    FGLView: TGLMediaView;
    FPopupMenu: TPopupMenu;
    FCropItem: TMenuItem;
    FStarted: Boolean;
    FFullscreen: Boolean;
    FNormalBounds: TRect;
    FDeliveryTimer: TTimer;
    FEditor: TIniEditor;
    FBoundsApplied: Boolean;     { the stored window place was used }
    FBoundsDirty: Boolean;       { moved / resized since last saved }
    FBoundsChangedTick: QWord;
    FCursorHidden: Boolean;
    FMenuOpen: Boolean;          { the cursor stays while the menu is open }
    FViewerEnded: Boolean;       { a viewer was closed with Esc before }
    FEscHeld: Boolean;           { the Esc that left the viewer is still down }
    FWindowCreatedMs: Double;    { start-up: ms after the process started }

    procedure CreateViewer;
    { AApplyBounds: put the window where it was last time (not when
      coming back from the viewer). }
    procedure ShowEditor(AApplyBounds: Boolean = True);
    procedure HandleSettingsRequest(Sender: TObject);
    procedure ReturnToEditor(AData: PtrInt);
    procedure HandleFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleFormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleEditorViewImages(Sender: TObject);
    procedure StartViewerFromEditor(const APath: string);
    procedure HandleDropFiles(Sender: TObject; const FileNames: array of string);
    procedure HandleFormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure HandleEditorExit(Sender: TObject);
    procedure CreateView;
    function TryCreateGLView(out AReason: string): Boolean;
    function ViewInput: TMouseEngine;
    procedure UpdateCursor;
    procedure HandleDeactivate(Sender: TObject);
    procedure HandleCommand(Sender: TObject; ACommand: TCommand; const AArgs: TCommandArgs);
    procedure HandleExitRequest(Sender: TObject);
    procedure HandleToggleFullscreen(Sender: TObject);
    procedure HandleExitMenuClick(Sender: TObject);
    procedure HandleAboutMenuClick(Sender: TObject);
    procedure HandleSaveMenuClick(Sender: TObject);
    procedure HandleSaveDebugMenuClick(Sender: TObject);
    procedure HandlePasteMenuClick(Sender: TObject);
    procedure HandleCropMenuClick(Sender: TObject);
    procedure HandleDeliveryTimer(Sender: TObject);
    procedure HandleFormResize(Sender: TObject);
    procedure SetFullscreen(AValue: Boolean);
    procedure ApplySavedBounds(AConfig: TConfig);
    function CurrentNormalBounds(out ARect: TRect): Boolean;
    procedure RememberBounds;
    procedure HandleChangeBounds(Sender: TObject);
  end;

var
  MainForm: TMainForm;

implementation

uses
  LCLType,
  LCLIntf,
  StdCtrls,
  uMousePage;

{$R *.lfm}

const
  { The About box: what MView is, and where it comes from. }
  AboutText =
    'Versarite MView 0.19.0-alpha' + LineEnding +
    'A microscopy image viewer, driven by the mouse.' + LineEnding +
    LineEnding +
    'Written with support from Claude/Opus 5.5 and ChatGPT' + LineEnding +
    LineEnding +
    'Dedicated by DL1BWA/KD1AEV to Makito Miyano, creator of Hamana (last version 2006) ,' + LineEnding +
    'the viewer that pioneered how browsing images should feel:' + LineEnding +
    'FAST first, MOUSE first, no frills, never in the way.' + LineEnding +
    LineEnding +
    'Built with Free Pascal and Lazarus.' + LineEnding +
    'Free software under the GNU GPL v3.' + LineEnding +
    'Kryptonite, if MView ever hangs: ' + EmergencyExitKeyText + '.';

  { Time for a normal shutdown (threads stopped, settings saved). }
  ExitDeadlineMs = 4000;

  { A stored window smaller than this is ignored. }
  MinWindowWidth = 200;
  MinWindowHeight = 150;
  { The window place is saved this long after the last move / resize
    (viewer; the settings editor saves it on close). }
  BoundsSaveDelayMs = 1000;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FWindowCreatedMs := ProcessAgeMs;
  Caption := 'MView';
  Color := clBlack;

  { Failsafe (uWatchdog): Ctrl+Alt+Shift+Q ends MView even when it is
    frozen, and a close that doesn't finish within ExitDeadlineMs
    ends the process. }
  StartWatchdog;
  OnClose := @HandleFormClose;
  OnChangeBounds := @HandleChangeBounds;

  { Safety net for results from the worker threads (see TMView,
    "Delivery safety net"). Runs once the viewer exists. }
  FDeliveryTimer := TTimer.Create(Self);
  FDeliveryTimer.Enabled := False;
  FDeliveryTimer.Interval := 50;
  FDeliveryTimer.OnTimer := @HandleDeliveryTimer;
  OnDeactivate := @HandleDeactivate;

  { Drag and drop: a file or folder dropped on the window opens it,
    like a command line argument (in the settings editor too). }
  AllowDropFiles := True;
  OnDropFiles := @HandleDropFiles;

  { Esc on the settings screen ends MView (the viewer's Esc goes back
    to it). The form sees keys first. }
  KeyPreview := True;
  OnKeyDown := @HandleFormKeyDown;
  OnKeyUp := @HandleFormKeyUp;

  if ParamCount >= 1 then
    CreateViewer
  else
    ShowEditor;
end;

{ Everything the viewer needs; FormShow (or the editor) starts it. }
procedure TMainForm.CreateViewer;
var
  Item: TMenuItem;
  ViewStartMs: Double;
begin
  FMView := TMView.Create;
  FMView.Initialize;
  { The window's place from last time (unless the settings editor
    already put it there). Before fullscreen, which keeps it as the
    place to return to. }
  if not FBoundsApplied then
    ApplySavedBounds(FMView.Config);
  { Large images get a copy of about this size, made on the worker. }
  FMView.SetDisplaySize(Screen.Width, Screen.Height);
  { From now on the window's own size: quick views are made to fit it
    exactly, so they are drawn without scaling. }
  OnResize := @HandleFormResize;
  FMView.OnExitRequest := @HandleExitRequest;
  FMView.OnToggleFullscreen := @HandleToggleFullscreen;
  FMView.OnSettingsRequest := @HandleSettingsRequest;

  { The menu (spec §3.1), opened by the mouse profile's Menu command
    (right click by default). }
  FPopupMenu := TPopupMenu.Create(Self);
  Item := TMenuItem.Create(FPopupMenu);
  Item.Caption := 'Paste image     (Ctrl+V)';
  Item.OnClick := @HandlePasteMenuClick;
  FPopupMenu.Items.Add(Item);
  { Edit mode: the selected area becomes the image (enabled when there
    is a selection). }
  FCropItem := TMenuItem.Create(FPopupMenu);
  FCropItem.Caption := 'Crop selection';
  FCropItem.OnClick := @HandleCropMenuClick;
  FPopupMenu.Items.Add(FCropItem);
  Item := TMenuItem.Create(FPopupMenu);
  Item.Caption := 'Save image';
  Item.OnClick := @HandleSaveMenuClick;
  FPopupMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPopupMenu);
  Item.Caption := 'Save image and view (debugging)';
  Item.OnClick := @HandleSaveDebugMenuClick;
  FPopupMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPopupMenu);
  Item.Caption := '-';
  FPopupMenu.Items.Add(Item);
  { The homage to Hamana (docs\From_Hamana_to_MView.md). }
  Item := TMenuItem.Create(FPopupMenu);
  Item.Caption := 'About Versarite MView';
  Item.OnClick := @HandleAboutMenuClick;
  FPopupMenu.Items.Add(Item);
  Item := TMenuItem.Create(FPopupMenu);
  Item.Caption := 'Exit     (if MView ever hangs: ' + EmergencyExitKeyText + ')';
  Item.OnClick := @HandleExitMenuClick;
  FPopupMenu.Items.Add(Item);

  ViewStartMs := NowMs;
  CreateView;
  FMView.NoteStartup(FWindowCreatedMs, ProcessAgeMs, NowMs - ViewStartMs);
  if FViewerEnded then
    FMView.SkipStartupLog;
  { The mouse language: the surface gets the profile. }
  if Assigned(ViewInput) then
  begin
    ViewInput.SetProfile(FMView.MouseProfile);
    ViewInput.ZonesEnabled := FMView.Config.ZonesEnabled;
  end;
  FDeliveryTimer.Enabled := True;

  if FMView.Config.StartFullscreen then
    SetFullscreen(True);
end;

{ Started without a file or folder: MView.ini in an editor. }
procedure TMainForm.ShowEditor(AApplyBounds: Boolean);
var
  Config: TConfig;
begin
  { Complete the file first: a new installation gets one with all
    defaults, an older one gets the keys added since (existing values,
    comments and unknown keys stay). }
  Config := TConfig.Create;
  try
    try
      Config.Load;
      Config.Save;
    except
      { Read-only folder or the like: the editor shows what is there. }
    end;
    if AApplyBounds then
      ApplySavedBounds(Config);
    { Coming back from the viewer: the editor made at the start is still
      there (hidden); it reads the files again (the viewer may have
      written them). }
    if FEditor = nil then
    begin
      FEditor := TIniEditor.Create(Self);
      FEditor.Parent := Self;
      FEditor.Align := alClient;
      FEditor.OnViewImages := @HandleEditorViewImages;
      FEditor.OnExitRequest := @HandleEditorExit;
    end;
    FEditor.Visible := True;
    FEditor.LoadFile(Config.IniFileName);
    FEditor.LoadMouseProfile(Config.MouseProfileFileName);
  finally
    Config.Free;
  end;
  Caption := 'MView - settings';
end;

{ "View images": the viewer with the settings just saved, and the last
  session. The editor stays hidden (it is freed with the form; freeing
  it here, inside its own button click, would not be safe). }
procedure TMainForm.HandleEditorViewImages(Sender: TObject);
begin
  StartViewerFromEditor('');
end;

{ APath: a file or folder to open; '' = the last session. }
procedure TMainForm.StartViewerFromEditor(const APath: string);
begin
  { The window's place into the file first: the viewer reads it (and
    writes it back on exit). }
  RememberBounds;
  FEditor.Visible := False;
  Caption := 'MView';
  CreateViewer;
  { The window is already on screen and won't be resized now (unless
    StartFullscreen): give the viewer its real size. }
  HandleFormResize(Self);
  FStarted := True;
  if FView.CanFocus then
    FView.SetFocus;
  FMView.Start(APath);
end;

{ The first dropped file or folder is opened: its folder becomes the
  browsing root, as with a command line start. Several dropped files:
  only the first counts. }
procedure TMainForm.HandleDropFiles(Sender: TObject; const FileNames: array of string);
var
  Path: string;
begin
  if Length(FileNames) = 0 then
    Exit;
  { Not checked here: that would read the disk on the window thread.
    The scanner reports "Not found" (Day 19). }
  Path := FileNames[0];

  if FMView = nil then
    StartViewerFromEditor(Path)   { dropped on the settings editor }
  else
    FMView.OpenMedia(Path);

  { The window usually isn't active after a drop from Explorer. }
  Application.BringToFront;
  if Assigned(FView) and FView.CanFocus then
    FView.SetFocus;
end;

{ Esc in the viewer (no mode on): back to the settings screen. Not
  here: this runs inside the view's key handler, and the view goes. }
procedure TMainForm.HandleSettingsRequest(Sender: TObject);
begin
  Application.QueueAsyncCall(@ReturnToEditor, 0);
end;

{ The viewer ends (threads stopped, settings saved, as on exit) and the
  settings editor shows, as after a start without an image. }
procedure TMainForm.ReturnToEditor(AData: PtrInt);
begin
  if FMView = nil then
    Exit;
  if FFullscreen then
    SetFullscreen(False);
  RememberBounds;

  FDeliveryTimer.Enabled := False;
  OnResize := nil;
  if Assigned(FCpuView) then
  begin
    FCpuView.SetRenderer(nil);
    FCpuView.OnCommand := nil;
  end;
  if Assigned(FGLView) then
  begin
    FGLView.Renderer := nil;
    FGLView.OnCommand := nil;
  end;
  { The views first (they reach TMView's renderer), then the viewer.
    Its shutdown waits for the worker threads: as on exit, a worker
    stuck in a read must not freeze the window for good (the settings
    are saved before the wait). }
  if Assigned(Watchdog) then
    Watchdog.ArmExitDeadline(ExitDeadlineMs);
  FView := nil;
  FreeAndNil(FCpuView);
  FreeAndNil(FGLView);
  FreeAndNil(FMView);
  if Assigned(Watchdog) then
    Watchdog.DisarmExitDeadline;
  FreeAndNil(FPopupMenu);
  FViewerEnded := True;
  { The Esc that got here (or its key repeat) must not also end MView
    on the settings screen: wait until it is released (if it still is
    down; a quick press may be up already). }
  FEscHeld := GetKeyState(VK_ESCAPE) < 0;
  FCropItem := nil;
  FStarted := False;
  FCursorHidden := False;
  FMenuOpen := False;

  ShowEditor(False);
  Caption := 'MView - settings';
  FEditor.FocusEditor;
end;

procedure TMainForm.HandleFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  { Only the settings screen: the viewer's keys go to the mouse engine. }
  if (Key <> VK_ESCAPE) or (Shift <> []) or Assigned(FMView)
    or (FEditor = nil) or not FEditor.Visible then
    Exit;
  if FEscHeld then
  begin
    Key := 0;
    Exit;
  end;
  { The "Try it here" area tries Esc out; an open list closes with it. }
  if (ActiveControl is TTryArea)
    or ((ActiveControl is TComboBox) and TComboBox(ActiveControl).DroppedDown) then
    Exit;
  Key := 0;
  FEditor.RequestExit;
end;

procedure TMainForm.HandleFormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
    FEscHeld := False;
end;

procedure TMainForm.HandleEditorExit(Sender: TObject);
begin
  Close;
end;

{ Every way of closing ends here (Esc, gesture, menu, window button,
  editor). The shutdown that follows waits for the worker threads; if
  one is stuck in a decode, the watchdog ends the process after the
  deadline instead of leaving it running without a window. }
procedure TMainForm.HandleFormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  RememberBounds;
  if Assigned(Watchdog) then
    Watchdog.ArmExitDeadline(ExitDeadlineMs);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  { The view is freed after this, together with the form's other
    components; make sure it can't paint with a freed renderer. }
  { A return to the settings screen (Esc) may still be waiting. }
  Application.RemoveAsyncCalls(Self);
  OnResize := nil;
  FDeliveryTimer.Enabled := False;
  FDeliveryTimer.OnTimer := nil;
  OnDeactivate := nil;
  { The renderer belongs to TMView and goes with it. }
  if Assigned(FCpuView) then
  begin
    FCpuView.SetRenderer(nil);
    FCpuView.OnCommand := nil;
  end;
  if Assigned(FGLView) then
  begin
    FGLView.Renderer := nil;
    FGLView.OnCommand := nil;
  end;
  FreeAndNil(FMView);
end;

procedure TMainForm.FormShow(Sender: TObject);
begin
  if FMView = nil then
  begin
    { The settings editor. }
    if Assigned(FEditor) and FEditor.Visible then
      FEditor.FocusEditor;
    Exit;
  end;

  if FView.CanFocus then
    FView.SetFocus;

  { OnShow can fire again (e.g. after the window style changes);
    start only once. }
  if FStarted then
    Exit;
  FStarted := True;

  { Spec §11: a file or folder on the command line. (Without one the
    editor came first, and its "View images" started the viewer.) }
  FMView.Start(ParamStr(1));
end;

{ Spec §8.5: the GPU renderer if OpenGL is usable (and [Renderer]
  UseGPU=1), otherwise the CPU renderer. The reason for a fallback is
  shown in the diagnostics line (D). }
procedure TMainForm.CreateView;
var
  Reason: string;
  Cpu: TCpuRenderer;
begin
  Reason := 'GPU switched off (UseGPU=0)';
  if FMView.Config.UseGPU and TryCreateGLView(Reason) then
    Exit;

  FCpuView := TMediaView.Create(Self);
  FCpuView.Parent := Self;
  FCpuView.Align := alClient;
  FCpuView.OnCommand := @HandleCommand;
  FView := FCpuView;

  Cpu := TCpuRenderer.Create;
  Cpu.Note := Reason;
  FCpuView.SetRenderer(Cpu);
  FMView.AttachView(FCpuView, Cpu);
end;

function TMainForm.TryCreateGLView(out AReason: string): Boolean;
var
  GLView: TGLMediaView;
  GLRenderer: TGLRenderer;
begin
  Result := False;
  AReason := '';
  GLView := nil;
  try
    GLView := TGLMediaView.Create(Self);
    GLView.Parent := Self;
    GLView.Align := alClient;
    { Creates the window and the OpenGL context now, so a failure
      shows here and not at the first paint. }
    GLView.HandleNeeded;
    GLRenderer := TGLRenderer.Create(GLView, FMView.Config.UseMipMaps);
  except
    on E: Exception do
    begin
      AReason := 'GPU not used: ' + E.Message;
      FreeAndNil(GLView);
      Exit;
    end;
  end;

  GLView.OnCommand := @HandleCommand;
  GLView.Renderer := GLRenderer;
  FGLView := GLView;
  FView := GLView;
  FMView.AttachView(GLView, GLRenderer);
  Result := True;
end;

function TMainForm.ViewInput: TMouseEngine;
begin
  if Assigned(FGLView) then
    Result := FGLView.Input
  else if Assigned(FCpuView) then
    Result := FCpuView.Input
  else
    Result := nil;
end;

{ Another program got the focus: no key or side button stays held. }
procedure TMainForm.HandleDeactivate(Sender: TObject);
begin
  FEscHeld := False;   { its release would go to the other program }
  if Assigned(ViewInput) then
    ViewInput.FocusLost;
end;

procedure TMainForm.HandleCommand(Sender: TObject; ACommand: TCommand;
  const AArgs: TCommandArgs);
var
  P: TPoint;
begin
  { The menu is the window's business; X, Y are surface pixels. }
  if ACommand = cmdShowMenu then
  begin
    if Assigned(FView) and Assigned(FPopupMenu) then
    begin
      if FCursorHidden then
      begin
        FCursorHidden := False;
        FView.Cursor := crDefault;
      end;
      P := FView.ClientToScreen(Point(Round(AArgs.X), Round(AArgs.Y)));
      FCropItem.Visible := FMView.EditMode;
      FCropItem.Enabled := FMView.CanCrop;
      FMenuOpen := True;
      try
        FPopupMenu.PopUp(P.X, P.Y);
      finally
        FMenuOpen := False;
        { Time in the menu doesn't count towards hiding the cursor. }
        if Assigned(ViewInput) then
          ViewInput.NoteActivity(GetTickCount64);
      end;
    end;
    Exit;
  end;
  FMView.Execute(ACommand, AArgs);
end;

{ Exit feels immediate: the window disappears at once. Stopping the
  threads (which may have to wait for a decode that can't be
  interrupted) happens afterwards, while the window is already gone. }
procedure TMainForm.HandleExitRequest(Sender: TObject);
begin
  Hide;
  Close;
end;

procedure TMainForm.HandleSaveMenuClick(Sender: TObject);
begin
  FMView.Execute(cmdSaveImage);
end;

procedure TMainForm.HandleSaveDebugMenuClick(Sender: TObject);
begin
  FMView.Execute(cmdSaveDebug);
end;

procedure TMainForm.HandleCropMenuClick(Sender: TObject);
begin
  FMView.Execute(cmdCropSelection);
end;

procedure TMainForm.HandlePasteMenuClick(Sender: TObject);
begin
  FMView.Execute(cmdPaste);
end;

{ [Mouse] MouseCursorHideTime: the cursor hides after that long without
  input, and comes back with the next movement. }
procedure TMainForm.UpdateCursor;
var
  HideMs: Integer;
  HideNow: Boolean;
begin
  if (FView = nil) or (ViewInput = nil) or (FMView = nil) or FMenuOpen then
    Exit;
  HideMs := FMView.Config.MouseHideTime;
  HideNow := (HideMs > 0) and (ViewInput.LastActivityMs > 0)
    and (GetTickCount64 - ViewInput.LastActivityMs >= QWord(HideMs));
  if HideNow = FCursorHidden then
    Exit;
  FCursorHidden := HideNow;
  if HideNow then
    FView.Cursor := crNone
  else
    FView.Cursor := crDefault;
end;

procedure TMainForm.HandleExitMenuClick(Sender: TObject);
begin
  Hide;
  Close;
end;

{ The dedication (docs\From_Hamana_to_MView.md). }
procedure TMainForm.HandleAboutMenuClick(Sender: TObject);
begin
  Application.MessageBox(PChar(AboutText), 'About Versarite MView', MB_OK or MB_ICONINFORMATION);
  { Time spent reading doesn't count towards hiding the cursor. }
  if Assigned(ViewInput) then
    ViewInput.NoteActivity(GetTickCount64);
end;

procedure TMainForm.HandleFormResize(Sender: TObject);
begin
  if Assigned(FMView) then
    FMView.SetDisplaySize(ClientWidth, ClientHeight);
end;

procedure TMainForm.HandleDeliveryTimer(Sender: TObject);
begin
  if Assigned(FMView) then
    FMView.PumpDeliveries;
  { Mouse language: clicks that waited for a double-click; the cursor. }
  if Assigned(ViewInput) then
  begin
    ViewInput.Tick(GetTickCount64);
    UpdateCursor;
  end;
  { Viewer: the window's place, once it has stopped moving. }
  if FBoundsDirty and Assigned(FMView)
    and (GetTickCount64 - FBoundsChangedTick >= BoundsSaveDelayMs) then
    RememberBounds;
end;

{ The window's place from MView.ini, if it is still on a monitor (one
  may have been unplugged since). }
procedure TMainForm.ApplySavedBounds(AConfig: TConfig);
var
  R: TRect;
begin
  FBoundsApplied := True;
  if (AConfig.Width < MinWindowWidth) or (AConfig.Height < MinWindowHeight) then
    Exit;
  R := Rect(AConfig.Left, AConfig.Top, AConfig.Left + AConfig.Width,
    AConfig.Top + AConfig.Height);
  if Screen.MonitorFromRect(R, mdNull) = nil then
    Exit;
  BoundsRect := R;
end;

{ The place to remember: the normal window, or the one fullscreen
  returns to. Not while maximised or minimised. }
function TMainForm.CurrentNormalBounds(out ARect: TRect): Boolean;
begin
  Result := False;
  if FFullscreen then
    ARect := FNormalBounds
  else if WindowState = wsNormal then
    ARect := BoundsRect
  else
    Exit;
  Result := (ARect.Right - ARect.Left >= MinWindowWidth)
    and (ARect.Bottom - ARect.Top >= MinWindowHeight);
end;

{ Writes [Window] Left/Top/Width/Height (only those keys). }
procedure TMainForm.RememberBounds;
var
  R: TRect;
  Config: TConfig;
  OwnConfig: Boolean;
begin
  FBoundsDirty := False;
  if not CurrentNormalBounds(R) then
    Exit;
  OwnConfig := FMView = nil;     { the settings editor: no viewer config }
  if OwnConfig then
    Config := TConfig.Create
  else
    Config := FMView.Config;
  try
    Config.Left := R.Left;
    Config.Top := R.Top;
    Config.Width := R.Right - R.Left;
    Config.Height := R.Bottom - R.Top;
    Config.SaveWindowBounds;
  finally
    if OwnConfig then
      Config.Free;
  end;
end;

procedure TMainForm.HandleChangeBounds(Sender: TObject);
begin
  FBoundsDirty := True;
  FBoundsChangedTick := GetTickCount64;
end;

procedure TMainForm.HandleToggleFullscreen(Sender: TObject);
begin
  SetFullscreen(not FFullscreen);
end;

procedure TMainForm.SetFullscreen(AValue: Boolean);
begin
  if AValue = FFullscreen then
    Exit;
  FFullscreen := AValue;

  if AValue then
  begin
    FNormalBounds := BoundsRect;
    BorderStyle := bsNone;
    WindowState := wsFullScreen;
  end
  else
  begin
    WindowState := wsNormal;
    BorderStyle := bsSizeable;
    BoundsRect := FNormalBounds;
  end;
end;

end.
