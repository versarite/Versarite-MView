unit uSortIcons;

{
  Unit: uSortIcons

  Purpose
  -------
  Icons for the sort panel's buttons (Phase G, G1 stage 2), and the
  check which sort folders are missing. The files are read on a thread
  of their own (an icon folder or a sort folder on a network drive that
  doesn't answer must not freeze the window); the pictures are made on
  the window thread from the bytes in memory, scaled to the size the
  button asks for, and kept.

  Owns
  ----
  - The loader thread (TSortIconThread) while it runs; one that hangs in
    the file system at shutdown is left alone (never freed).
  - FFiles: every icon file read (full path -> its bytes, TIconData).
  - FScaled: the pictures made from them, per file and size
    (TBGRABitmap), until the files are read again or there are many.
  - FFolderFiles: the names of the .ico / .png files in the icon folder
    (for the slot menu), FMissing: sort folders that were not found.

  Knows
  -----
  - OnChanged: the owner (TMView), told on the UI thread when a load
    has been delivered.

  Responsibilities
  ----------------
  - Load (UI thread): hands the thread the icon folder, extra icon files
    (full paths outside it) and the sort folders to check; a load asked
    for while one runs is done after it, with the newest request.
  - The thread lists the icon folder (*.ico, *.png; up to 300 files of
    up to 2 MB each), reads them and the extra files, and checks every
    sort folder with DirectoryExists.
  - Bitmap(path, size): the icon as a size x size picture (transparent
    around it if not square): for an .ico the smallest picture at least
    that size (uIconFile.ChooseIconEntry), PNG entries and .png files
    through BGRABitmap, old-style entries through DecodeIconDib; scaled
    with a fine filter. nil if the file wasn't found or can't be read.

  Does NOT
  --------
  - Decide which icon a slot uses (TMView: the slot's own, or the one
    named like its folder).
  - Draw the panel (uSortPanel), write icon files (uFileMover, faWrite).

  Threads
  -------
  Load, Bitmap, Has, FolderMissing and Destroy on the UI thread. The
  loader thread only touches its own request and result, under its
  lock; the result is handed over through TThread.Queue and, if that
  wake-up is late, found by the owner's CheckSynchronize.

  Uses (MView units)
  ------------------
  implementation: uIconFile
  Libraries:      Classes, SysUtils, SyncObjs, Math, BGRABitmap,
                  BGRABitmapTypes

  Used by
  -------
  uMView (and the form, for the slot menu's icon list, through TMView)
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  BGRABitmap,
  BGRABitmapTypes;

type
  TSortIcons = class;

  { A load request, and what came of it. }
  TIconLoadResult = class
  public
    IconFolder: string;
    Files: TStringList;          { full path (as listed) -> TIconData }
    FolderFiles: TStringList;    { names in the icon folder }
    Missing: TStringList;        { sort folders not found }
    constructor Create;
    destructor Destroy; override;
  end;

  TSortIconThread = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FOwner: TSortIcons;          { nil once the owner has gone }
    FIconFolder: string;
    FExtra, FFolders: TStringList;
    FRequested: Boolean;
    FResult: TIconLoadResult;
    procedure Deliver;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TSortIcons);
    destructor Destroy; override;
    procedure Request(const AIconFolder: string; AExtra, AFolders: TStrings);
    { The owner goes: nothing is delivered any more. }
    procedure Detach;
  end;

  TSortIcons = class(TObject)
  private
    FThread: TSortIconThread;
    FFiles: TStringList;         { sorted, case-insensitive: path -> TIconData }
    FScaled: TStringList;        { 'path|size' -> TBGRABitmap }
    FFolderFiles: TStringList;
    FMissing: TStringList;
    FIconFolder: string;
    FLoaded: Boolean;
    FLoadedMs: Double;
    FOnChanged: TNotifyEvent;
    procedure TakeResult(AResult: TIconLoadResult);
    procedure ClearScaled;
    function MakeBitmap(const APath: string; ASize: Integer): TBGRABitmap;
  public
    constructor Create;
    destructor Destroy; override;
    { Read the icon folder (and AExtra files) and check AFolders, on the
      loader thread. ANowMs: now, for LoadedAgoMs. }
    procedure Load(const AIconFolder: string; AExtra, AFolders: TStrings; ANowMs: Double);
    { The icon file APath (full path) as a ASize x ASize picture; nil if
      it wasn't found or can't be read. Kept: don't free it. }
    function Bitmap(const APath: string; ASize: Integer): TBGRABitmap;
    { APath was found (and read) by the last load. }
    function Has(const APath: string): Boolean;
    { AFolder was not found by the last load. }
    function FolderMissing(const AFolder: string): Boolean;
    { ms since the last load was asked for; a large number if never. }
    function LoadedAgoMs(ANowMs: Double): Double;
    { The .ico / .png files in the icon folder, by name (sorted). }
    property FolderFiles: TStringList read FFolderFiles;
    property IconFolder: string read FIconFolder;
    property Loaded: Boolean read FLoaded;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  Math,
  uIconFile;

const
  MaxIconFiles = 300;
  MaxIconBytes = 2 * 1024 * 1024;
  MaxScaled = 400;

type
  TIconData = class
  public
    Bytes: TBytes;
    Failed: Boolean;             { could not be made into a picture }
  end;

function ReadAll(const AFileName: string; out ABytes: TBytes): Boolean;
var
  Stream: TFileStream;
  Size: Int64;
begin
  ABytes := nil;
  Result := False;
  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      Size := Stream.Size;
      if (Size <= 0) or (Size > MaxIconBytes) then
        Exit;
      SetLength(ABytes, Size);
      Stream.ReadBuffer(ABytes[0], Size);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    ABytes := nil;
    Result := False;
  end;
end;

function IsIconName(const AName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AName));
  Result := (Ext = '.ico') or (Ext = '.png');
end;

{ TIconLoadResult }

constructor TIconLoadResult.Create;
begin
  inherited Create;
  Files := TStringList.Create;
  Files.OwnsObjects := True;
  Files.CaseSensitive := False;
  FolderFiles := TStringList.Create;
  FolderFiles.CaseSensitive := False;
  FolderFiles.Sorted := True;
  FolderFiles.Duplicates := dupIgnore;
  Missing := TStringList.Create;
  Missing.CaseSensitive := False;
end;

destructor TIconLoadResult.Destroy;
begin
  Files.Free;
  FolderFiles.Free;
  Missing.Free;
  inherited Destroy;
end;

{ TSortIconThread }

constructor TSortIconThread.Create(AOwner: TSortIcons);
begin
  FOwner := AOwner;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FExtra := TStringList.Create;
  FFolders := TStringList.Create;
  inherited Create(False);
end;

destructor TSortIconThread.Destroy;
begin
  FResult.Free;
  FExtra.Free;
  FFolders.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TSortIconThread.Request(const AIconFolder: string; AExtra, AFolders: TStrings);
begin
  FLock.Acquire;
  try
    FIconFolder := AIconFolder;
    FExtra.Clear;
    if AExtra <> nil then
      FExtra.AddStrings(AExtra);
    FFolders.Clear;
    if AFolders <> nil then
      FFolders.AddStrings(AFolders);
    FRequested := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TSortIconThread.Detach;
begin
  FLock.Acquire;
  try
    FOwner := nil;
  finally
    FLock.Release;
  end;
  Terminate;
  FWake.SetEvent;
end;

procedure TSortIconThread.Execute;
var
  Folder: string;
  Extra, Folders: TStringList;
  R: TIconLoadResult;
  Info: TSearchRec;
  Data: TIconData;
  Bytes: TBytes;
  I: Integer;
begin
  Extra := TStringList.Create;
  Folders := TStringList.Create;
  try
    while not Terminated do
    begin
      FWake.WaitFor(1000);
      if Terminated then
        Break;
      FLock.Acquire;
      try
        if not FRequested then
          Continue;
        FRequested := False;
        Folder := FIconFolder;
        Extra.Assign(FExtra);
        Folders.Assign(FFolders);
      finally
        FLock.Release;
      end;

      R := TIconLoadResult.Create;
      try
        R.IconFolder := Folder;
        { The icon folder. }
        if (Folder <> '') and (FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, Info) = 0) then
        begin
          try
            repeat
              if ((Info.Attr and faDirectory) = 0) and IsIconName(Info.Name) then
                R.FolderFiles.Add(Info.Name);
            until (FindNext(Info) <> 0) or (R.FolderFiles.Count >= MaxIconFiles) or Terminated;
          finally
            FindClose(Info);
          end;
        end;
        for I := 0 to R.FolderFiles.Count - 1 do
        begin
          if Terminated then
            Break;
          if ReadAll(IncludeTrailingPathDelimiter(Folder) + R.FolderFiles[I], Bytes) then
          begin
            Data := TIconData.Create;
            Data.Bytes := Bytes;
            R.Files.AddObject(IncludeTrailingPathDelimiter(Folder) + R.FolderFiles[I], Data);
          end;
        end;
        { Icons elsewhere (a full path in the slot). }
        for I := 0 to Extra.Count - 1 do
        begin
          if Terminated then
            Break;
          if (R.Files.IndexOf(Extra[I]) < 0) and ReadAll(Extra[I], Bytes) then
          begin
            Data := TIconData.Create;
            Data.Bytes := Bytes;
            R.Files.AddObject(Extra[I], Data);
          end;
        end;
        { The sort folders (a network drive may take its time here). }
        for I := 0 to Folders.Count - 1 do
        begin
          if Terminated then
            Break;
          if not DirectoryExists(Folders[I]) then
            R.Missing.Add(Folders[I]);
        end;
      except
        { A result as far as it got. }
      end;

      FLock.Acquire;
      try
        FResult.Free;
        FResult := R;
      finally
        FLock.Release;
      end;
      if not Terminated then
        Queue(@Deliver);
    end;
  finally
    Extra.Free;
    Folders.Free;
  end;
end;

{ UI thread. }
procedure TSortIconThread.Deliver;
var
  R: TIconLoadResult;
  Owner: TSortIcons;
begin
  FLock.Acquire;
  try
    R := FResult;
    FResult := nil;
    Owner := FOwner;
  finally
    FLock.Release;
  end;
  if (R = nil) or (Owner = nil) then
  begin
    R.Free;
    Exit;
  end;
  Owner.TakeResult(R);
end;

{ TSortIcons }

constructor TSortIcons.Create;
begin
  inherited Create;
  FFiles := TStringList.Create;
  FFiles.OwnsObjects := True;
  FFiles.CaseSensitive := False;
  FFiles.Sorted := True;
  FFiles.Duplicates := dupIgnore;
  FScaled := TStringList.Create;
  FScaled.OwnsObjects := True;
  FScaled.CaseSensitive := False;
  FScaled.Sorted := True;
  FFolderFiles := TStringList.Create;
  FFolderFiles.CaseSensitive := False;
  FFolderFiles.Sorted := True;
  FMissing := TStringList.Create;
  FMissing.CaseSensitive := False;
  FMissing.Sorted := True;
end;

destructor TSortIcons.Destroy;
var
  I: Integer;
begin
  if Assigned(FThread) then
  begin
    FThread.Detach;
    { A read that hangs (a network drive): don't wait for it; the thread
      is left alone, it delivers nothing any more. }
    for I := 1 to 50 do
    begin
      if FThread.Finished then
        Break;
      Sleep(20);
    end;
    if FThread.Finished then
    begin
      FThread.WaitFor;
      TThread.RemoveQueuedEvents(FThread);
      FThread.Free;
    end;
    FThread := nil;
  end;
  ClearScaled;
  FScaled.Free;
  FFiles.Free;
  FFolderFiles.Free;
  FMissing.Free;
  inherited Destroy;
end;

procedure TSortIcons.ClearScaled;
begin
  FScaled.Clear;   { owns the bitmaps }
end;

procedure TSortIcons.Load(const AIconFolder: string; AExtra, AFolders: TStrings; ANowMs: Double);
begin
  FLoadedMs := ANowMs;
  if FThread = nil then
    FThread := TSortIconThread.Create(Self);
  FThread.Request(ExcludeTrailingPathDelimiter(AIconFolder), AExtra, AFolders);
end;

function TSortIcons.LoadedAgoMs(ANowMs: Double): Double;
begin
  if FLoadedMs <= 0 then
    Result := MaxInt
  else
    Result := ANowMs - FLoadedMs;
end;

{ UI thread: the new files replace the old ones. }
procedure TSortIcons.TakeResult(AResult: TIconLoadResult);
var
  I: Integer;
begin
  try
    ClearScaled;
    FFiles.Clear;
    AResult.Files.OwnsObjects := False;   { handed over (or freed here) }
    for I := 0 to AResult.Files.Count - 1 do
      if FFiles.IndexOf(AResult.Files[I]) >= 0 then
        AResult.Files.Objects[I].Free     { the same file twice }
      else
        FFiles.AddObject(AResult.Files[I], AResult.Files.Objects[I]);
    FFolderFiles.Assign(AResult.FolderFiles);
    FMissing.Assign(AResult.Missing);
    FIconFolder := AResult.IconFolder;
    FLoaded := True;
  finally
    AResult.Free;
  end;
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TSortIcons.Has(const APath: string): Boolean;
begin
  Result := FFiles.IndexOf(APath) >= 0;
end;

function TSortIcons.FolderMissing(const AFolder: string): Boolean;
begin
  Result := FMissing.IndexOf(ExcludeTrailingPathDelimiter(AFolder)) >= 0;
end;

function TSortIcons.Bitmap(const APath: string; ASize: Integer): TBGRABitmap;
var
  Key: string;
  Idx: Integer;
begin
  Result := nil;
  if (APath = '') or (ASize <= 0) then
    Exit;
  Key := APath + '|' + IntToStr(ASize);
  Idx := FScaled.IndexOf(Key);
  if Idx >= 0 then
    Exit(TBGRABitmap(FScaled.Objects[Idx]));
  Result := MakeBitmap(APath, ASize);
  if Result = nil then
    Exit;
  if FScaled.Count >= MaxScaled then
    ClearScaled;
  FScaled.AddObject(Key, Result);
end;

{ The picture in the file, not yet scaled; nil if it can't be read. }
function DecodeIcon(const ABytes: TBytes; const APath: string; ASize: Integer): TBGRABitmap;
var
  Entries: TIconEntries;
  Idx, X, Y: Integer;
  Stream: TMemoryStream;
  Pixels: TIconPixels;
  P: PBGRAPixel;
  C: LongWord;
begin
  Result := nil;
  Stream := nil;
  try
    try
      if ReadIconDirectory(ABytes, Entries) then
      begin
        Idx := ChooseIconEntry(Entries, ASize);
        if Idx < 0 then
          Exit;
        if Entries[Idx].IsPng then
        begin
          Stream := TMemoryStream.Create;
          Stream.WriteBuffer(ABytes[Entries[Idx].Offset], Entries[Idx].Size);
          Stream.Position := 0;
          Result := TBGRABitmap.Create;
          Result.LoadFromStream(Stream);
        end
        else if DecodeIconDib(ABytes, Entries[Idx], Pixels) then
        begin
          Result := TBGRABitmap.Create(Pixels.Width, Pixels.Height);
          for Y := 0 to Pixels.Height - 1 do
          begin
            P := Result.ScanLine[Y];
            for X := 0 to Pixels.Width - 1 do
            begin
              C := Pixels.Data[Y * Pixels.Width + X];
              P^ := BGRA((C shr 16) and $FF, (C shr 8) and $FF, C and $FF, C shr 24);
              Inc(P);
            end;
          end;
          Result.InvalidateBitmap;
        end;
      end
      else if LowerCase(ExtractFileExt(APath)) <> '.ico' then
      begin
        { A .png (or anything BGRABitmap reads). }
        Stream := TMemoryStream.Create;
        if Length(ABytes) > 0 then
          Stream.WriteBuffer(ABytes[0], Length(ABytes));
        Stream.Position := 0;
        Result := TBGRABitmap.Create;
        Result.LoadFromStream(Stream);
      end;
    except
      FreeAndNil(Result);
    end;
  finally
    Stream.Free;
  end;
  if (Result <> nil) and ((Result.Width <= 0) or (Result.Height <= 0)) then
    FreeAndNil(Result);
end;

function TSortIcons.MakeBitmap(const APath: string; ASize: Integer): TBGRABitmap;
var
  Idx, W, H: Integer;
  Data: TIconData;
  Src, Scaled: TBGRABitmap;
begin
  Result := nil;
  Idx := FFiles.IndexOf(APath);
  if Idx < 0 then
    Exit;
  Data := TIconData(FFiles.Objects[Idx]);
  if Data.Failed then
    Exit;
  Src := DecodeIcon(Data.Bytes, APath, ASize);
  if Src = nil then
  begin
    Data.Failed := True;
    Exit;
  end;
  try
    { Fit into ASize x ASize, keeping its shape, centred. }
    if Src.Width >= Src.Height then
    begin
      W := ASize;
      H := Max(1, Round(ASize * Src.Height / Src.Width));
    end
    else
    begin
      H := ASize;
      W := Max(1, Round(ASize * Src.Width / Src.Height));
    end;
    if (W = Src.Width) and (H = Src.Height) then
      Scaled := Src.Duplicate as TBGRABitmap
    else
      Scaled := Src.Resample(W, H, rmFineResample) as TBGRABitmap;
    try
      Result := TBGRABitmap.Create(ASize, ASize, BGRAPixelTransparent);
      Result.PutImage((ASize - W) div 2, (ASize - H) div 2, Scaled, dmSet);
    finally
      Scaled.Free;
    end;
  finally
    Src.Free;
  end;
end;

end.
