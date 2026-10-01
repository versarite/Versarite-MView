program MView;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms,
  SysUtils,
  uSingleInstance,
  uTypes, uCommands, uNaturalSort, uStopwatch, uIOGate, uMemoryGuard, uWatchdog, uImageSaver, uImageFormats,
  uDirectoryImages, uDirectoryTree, uNavigator,
  uDecodedImage, uJpegDecoder, uExifOrientation, uJpegHeader, uTiffQuick, uImageScaling, uWicDecoder,
  uMediaLoader, uRenderer, uGLRenderer, uGLMediaView, uInputHandler,
  uJobQueue, uJobScheduler, uImageCache, uDirectoryScanner,
  uConfig, uIniEditor, uMediaView, uMView, uMainForm;

{$R *.res}

{ [Startup] OnlyOneInstance (default 1): another MView running takes the
  file or folder (full path: this process's folder may differ) and comes
  to the front; this one ends before it makes a window. }
function HandedOver: Boolean;
var
  Config: TConfig;
  Path: string;
  OnlyOne: Boolean;
begin
  Result := False;
  OnlyOne := True;
  Config := TConfig.Create;
  try
    try
      Config.Load;
      OnlyOne := Config.OnlyOneInstance;
    except
      { Unreadable ini: the default. }
    end;
  finally
    Config.Free;
  end;
  if not OnlyOne then
    Exit;
  Path := '';
  if ParamCount >= 1 then
    Path := ExpandFileName(ParamStr(1));
  Result := HandOverToRunningInstance(Path);
end;

begin
  RequireDerivedFormResource:=True;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar:=True;
  {$POP}
  Application.Initialize;
  if HandedOver then
  begin
    { Ending before anything else started (Day 23): the I/O gate, made
      at start-up and normally left for the end of the process (a stuck
      read may still use it), is freed here: no thread exists yet. Else
      a debug build's leak report (heaptrc) shows a dialog each time. }
    FreeAndNil(IOGate);
    Exit;
  end;
  Application.CreateForm(TMainForm, MainForm);
  { The next MViews' files and folders come here (only one instance). }
  StartInstanceListener(@MainForm.HandleHandedOver);
  Application.Run;
end.

