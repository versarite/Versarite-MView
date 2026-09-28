unit uImageSaver;

{
  Unit: uImageSaver

  Purpose
  -------
  Saving images as PNG. Started as a debugging aid; since Phase F it
  is also the menu's "Save image" (the image, a crop or a pasted
  picture, into the save folder):
  - the current image exactly as MView holds it in memory (the decoded
    bitmap: quick view or full image, after EXIF rotation), as PNG, on
    a background thread, so the window doesn't freeze while a 100 MP
    image is written;
  - helpers for the renderers, which save a picture of the window
    (what is actually on screen) next to it.

  Owns
  ----
  - TImageSaveThread: a reference to the IDecodedImage being saved
    (keeps it alive until the file is written; the image is read only,
    so the renderer can keep drawing it meanwhile).
  - The TFPWriterPNG of each save, freed at once.

  Knows
  -----
  - The IDecodedImage handed in (uDecodedImage).

  Responsibilities
  ----------------
  - SavedImageFileName: a file name that says what was saved:
      <original name>_<quality>_<width>x<height>_<yyyymmdd-hhnnss>.png
  - SavedViewFileName: the file name for a picture of the window,
    matching the image (<original name>_view_<yyyymmdd-hhnnss>.png,
    "mview" if there is no image).
  - SaveBitmapAsPng: write a bitmap as an 8-bit PNG without alpha,
    fastest compression; creates the folder; raises on failure.
  - TImageSaveThread: write the file; report the outcome as text
    ("saved: ..." or "save failed: ...").

  Does NOT
  --------
  - Touch the GUI. The owner (TMView) polls Finished and reads
    ResultText on the UI thread, then frees the thread.
  - Take the picture of the window (the renderers do, uRenderer and
    uGLRenderer).

  Threads
  -------
  TImageSaveThread.Execute runs on its own save thread; it starts at
  once, is not FreeOnTerminate, and its results are read only after
  Finished (or after WaitFor at shutdown). The file-name helpers and
  the renderers' SaveBitmapAsPng calls run on the UI thread.

  Uses (MView units)
  ------------------
  interface:      uTypes, uDecodedImage
  Libraries:      Classes, SysUtils, FPWritePNG, ZStream, BGRABitmap,
                  BGRABitmapTypes

  Used by
  -------
  uGLRenderer, uMView, uRenderer
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  FPWritePNG,
  ZStream,
  BGRABitmap,
  BGRABitmapTypes,
  uTypes,
  uDecodedImage;

type

  TImageSaveThread = class(TThread)
  private
    FImage: IDecodedImage;
    FFileName: string;
    FResultText: string;
  protected
    procedure Execute; override;
  public
    { Starts at once. Not FreeOnTerminate: the owner frees it after
      Finished (or after WaitFor at shutdown). }
    constructor Create(const AImage: IDecodedImage; const AFileName: string);
    property FileName: string read FFileName;
    { "saved: ..." or "save failed: ...", valid once Finished. }
    property ResultText: string read FResultText;
  end;

function SavedImageFileName(const ADirectory: string; const AImage: IDecodedImage): string;

{ The file name for a picture of the window, matching the image. }
function SavedViewFileName(const ADirectory: string; const AImage: IDecodedImage): string;

{ Writes ABitmap as an 8-bit PNG (fast compression); creates the
  folder. Raises on failure. }
procedure SaveBitmapAsPng(ABitmap: TBGRABitmap; const AFileName: string);

implementation

function QualityName(AQuality: TQualityLevel): string;
begin
  case AQuality of
    qlPreview: Result := 'preview';
    qlScreen:  Result := 'screen';
    qlFull:    Result := 'full';
  else
    Result := 'none';
  end;
end;

function SavedImageFileName(const ADirectory: string; const AImage: IDecodedImage): string;
begin
  Result := IncludeTrailingPathDelimiter(ADirectory)
    + ChangeFileExt(ExtractFileName(AImage.Key.FileName), '')
    + Format('_%s_%dx%d_%s.png', [QualityName(AImage.Quality),
        AImage.Width, AImage.Height, FormatDateTime('yyyymmdd-hhnnss', Now)]);
end;

function SavedViewFileName(const ADirectory: string; const AImage: IDecodedImage): string;
var
  Base: string;
begin
  if AImage <> nil then
    Base := ChangeFileExt(ExtractFileName(AImage.Key.FileName), '')
  else
    Base := 'mview';
  Result := IncludeTrailingPathDelimiter(ADirectory)
    + Base + '_view_' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.png';
end;

procedure SaveBitmapAsPng(ABitmap: TBGRABitmap; const AFileName: string);
var
  Writer: TFPWriterPNG;
begin
  ForceDirectories(ExtractFileDir(AFileName));
  Writer := TFPWriterPNG.Create;
  try
    { Fast rather than small: it's a debugging copy. No alpha channel:
      MView's images are opaque. 8 bits per channel (the writer's
      default is 16). }
    Writer.CompressionLevel := clfastest;
    Writer.UseAlpha := False;
    Writer.WordSized := False;
    ABitmap.SaveToFileUTF8(AFileName, Writer);
  finally
    Writer.Free;
  end;
end;

{ TImageSaveThread }

constructor TImageSaveThread.Create(const AImage: IDecodedImage; const AFileName: string);
begin
  FImage := AImage;
  FFileName := AFileName;
  inherited Create(False);   { FreeOnTerminate stays False (default) }
end;

procedure TImageSaveThread.Execute;
begin
  try
    if (FImage = nil) or FImage.IsError or (FImage.Bitmap = nil) then
      raise Exception.Create('no decoded image');
    SaveBitmapAsPng(FImage.Bitmap, FFileName);
    FResultText := 'saved: ' + FFileName;
  except
    on E: Exception do
      FResultText := 'save failed: ' + E.Message;
  end;
  FImage := nil;
end;

end.
