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
  uTypes, uCommands, uNaturalSort, uStopwatch, uIOGate, uMemoryGuard, uWatchdog, uImageSaver, uImageFormats,
  uDirectoryImages, uDirectoryTree, uNavigator,
  uDecodedImage, uJpegDecoder, uExifOrientation, uJpegHeader, uTiffQuick, uImageScaling, uWicDecoder,
  uMediaLoader, uRenderer, uGLRenderer, uGLMediaView, uInputHandler,
  uJobQueue, uJobScheduler, uImageCache, uDirectoryScanner,
  uConfig, uIniEditor, uMediaView, uMView, uMainForm;

{$R *.res}

begin
  RequireDerivedFormResource:=True;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar:=True;
  {$POP}
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.

