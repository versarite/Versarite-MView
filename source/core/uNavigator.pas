unit uNavigator;

{
  Unit: uNavigator

  Purpose
  -------
  Navigation state: which directory and which image are current, and
  what "next" and "previous" mean.

  Owns
  ----
  - FTree: TDirectoryTree (the directories under the root). SetTree
    frees the old tree and takes ownership of the one handed in.
  - FImages: TDirectoryImages (the images of the current directory,
    a copy).
  - FListings: up to MaxCachedListings (64) TDirectoryImages of other
    folders, read from disk for FilesAhead (only when ReadsDisk).

  Knows
  -----
  - The tree's per-folder image lists (owned by the tree).
  - The listing handed to OpenListed (copied, not kept).

  Responsibilities
  ----------------
  - Open a file or a directory and choose the navigation root
    (OpenPath), or take what the scanner resolved (OpenListed).
  - Take a finished tree from the scanner (SetTree).
  - Next / previous image, crossing into the next or previous folder
    that has images. Folders without images are skipped (spec §10).
  - Next / previous directory.
  - Wrap-around, per folder or per tree (TWrapScope).
  - Apply and change the sort mode without losing the current image.
  - FilesAhead: the files that next / previous would reach, without
    moving, for preloading (spec §5.3, "FileAtOffset across
    directories"). Neighbour folder listings are kept in a small cache
    so this stays cheap when it is asked after every step.
  - ListedKey: a file's size and date as listed, without disk access.

  Does NOT
  --------
  - Display, load or decode images.
  - Handle input.
  - Run a thread. The background scan is TDirectoryScanner's.

  Threads
  -------
  UI thread only (TMView); no lock. ChooseRoot and IsInside are class
  functions without state; the scanner thread calls them too.

  Uses (MView units)
  ------------------
  interface:      uTypes, uDirectoryTree, uDirectoryImages
  Libraries:      Classes, SysUtils, Math

  Used by
  -------
  uDirectoryScanner, uMView

  Rules
  -----
  Navigation root (the part of the disk that "next directory" can
  reach):
    - a directory was opened  -> that directory
    - a file was opened       -> the parent of the file's directory,
                                 so sibling folders are reachable
                                 (C:\Exp\Day1\a.tif -> root C:\Exp)
      Exceptions: if that parent is a drive root, or Recursive is off,
      the file's own directory is the root. Scanning a whole drive on
      the UI thread would freeze the window (the scan now runs on
      the scanner thread, uDirectoryScanner).

  Landing position:
    - next image / next directory / previous directory -> first image
    - previous image across a folder boundary          -> last image
    - opening a folder without images -> the first folder after it
      that has images ("no dead ends", spec §3.1)

  Wrap-around with only one folder that has images: the last image
  wraps to the first image of the same folder (spec §16 #6).

  The tree comes with each open (built by the scanner, handed over
  with SetTree). Moving between directories only switches to the image
  list of the target directory, never rebuilds the tree.

  No disk access (Day 19, ReadsDisk = False)
  ------------------------------------------
  The viewer sets ReadsDisk := False: then the navigator never reads a
  folder. The start folder's list comes from the scanner (OpenListed),
  all others from the tree, which the scanner builds with every
  folder's images (TDirectoryTree.Build(..., ACollectImages)). A slow
  or hung disk can then only delay the scanner, never the window.
  With ReadsDisk = True (the default; the tests use it) folders are
  listed on demand as before.

  Background tree (Phase B)
  -------------------------
  OpenPath(..., ADeferTree = True) lists only the target folder and
  leaves the tree empty, so the first image can be shown at once. The
  scanner thread builds the tree and SetTree swaps it in (spec §10,
  §11). Until then, browsing works inside the current folder, and
  moving to other folders reports "no change".
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  uTypes,
  uDirectoryTree,
  uDirectoryImages;

type

  TNavigator = class(TObject)
  private
    FTree: TDirectoryTree;
    FImages: TDirectoryImages;
    FCurrentIndex: Integer;
    FSortMode: TSortMode;
    FRecursive: Boolean;
    FWrapAround: Boolean;
    FWrapScope: TWrapScope;
    FRootDirectory: string;
    FTreeReady: Boolean;
    FListings: TFPList;          { TDirectoryImages of other folders }
    FReadsDisk: Boolean;

    function GetCurrentDirectory: string;
    function Listing(const ADirectory: string): TDirectoryImages;
    function NeighborWithImages(const AFromDirectory: string; ADirection: Integer): TDirectoryImages;
    procedure ClearListings;
    procedure ScanImages(const ADirectory: string);
    function SeekDirectory(ADirection: Integer; ALandOnLast: Boolean): Boolean;
    function TreeImages(const ADirectory: string): TDirectoryImages;
  public
    { The navigation root for a file in ADirectory (see "Rules"). }
    class function ChooseRoot(const ADirectory: string; ARecursive: Boolean): string;
    class function IsInside(const ADirectory, ARoot: string): Boolean;

    constructor Create;
    destructor Destroy; override;

    { Opens an image file or a directory. For a directory, ASelectFile
      can name an image inside the tree to start on (used to resume
      the last session). ADeferTree: don't scan the tree now; it will
      come from SetTree. }
    procedure OpenPath(const AFileOrDirectory: string; const ASelectFile: string = '';
      ADeferTree: Boolean = False);

    { Opens what the scanner resolved (no disk access): ARoot is the
      navigation root, AListing the images of ATargetDirectory (copied;
      nil = none), ATargetFile the file to start on ('' = the first).
      The tree follows later through SetTree. }
    procedure OpenListed(const ARoot, ATargetDirectory: string;
      AListing: TDirectoryImages; const ATargetFile: string);

    { Takes ownership of a finished tree for the current root. Returns
      True if the current image changed (an empty start folder moved on
      to the first folder with images, or the current file is gone). }
    function SetTree(ATree: TDirectoryTree): Boolean;

    { The size and date of AFileName as listed (no disk access). False
      if the file is in none of the lists held. }
    function ListedKey(const AFileName: string; out AKey: TImageKey): Boolean;

    procedure SetSortMode(AMode: TSortMode);
    { Switches between date (newest first) and file name order. }
    procedure ToggleSortMode;

    function HasCurrentImage: Boolean;
    function CurrentFileName: string;
    function ImageCount: Integer;

    { Each returns True if the current image changed. }
    function NextImage: Boolean;
    function PreviousImage: Boolean;
    function NextDirectory: Boolean;
    function PreviousDirectory: Boolean;

    { Up to ACount files that NextImage (ADirection = 1) or
      PreviousImage (-1) would reach one after another, nearest first,
      following the same rules (folders without images skipped, wrap).
      Doesn't move. Stops early at the end of the tree, or when it
      would come back to the current file. }
    function FilesAhead(ACount, ADirection: Integer): TStringArray;

    property RootDirectory: string read FRootDirectory;
    property TreeReady: Boolean read FTreeReady;
    property CurrentDirectory: string read GetCurrentDirectory;
    property CurrentIndex: Integer read FCurrentIndex;
    property SortMode: TSortMode read FSortMode;
    property Recursive: Boolean read FRecursive write FRecursive;
    property WrapAround: Boolean read FWrapAround write FWrapAround;
    property WrapScope: TWrapScope read FWrapScope write FWrapScope;
    { False: never read a folder (see "No disk access"). }
    property ReadsDisk: Boolean read FReadsDisk write FReadsDisk;
  end;

implementation

constructor TNavigator.Create;
begin
  inherited Create;
  FTree := TDirectoryTree.Create;
  FImages := TDirectoryImages.Create;
  FCurrentIndex := -1;
  FSortMode := smDateDescending;
  FRecursive := True;
  FWrapAround := True;
  FWrapScope := wsTree;
  FTreeReady := False;
  FListings := TFPList.Create;
  FReadsDisk := True;
end;

destructor TNavigator.Destroy;
begin
  ClearListings;
  FListings.Free;
  FTree.Free;
  FImages.Free;
  inherited Destroy;
end;

const
  { Listings of other folders kept for FilesAhead. Empty folders are
    listed too (that's how they are skipped), so allow a fair number. }
  MaxCachedListings = 64;
  { FilesAhead gives up after crossing this many folders, and after
    trying this many folders in one search for a folder with images. }
  MaxFolderHops = 8;
  MaxFoldersTried = 64;

procedure TNavigator.ClearListings;
var
  I: Integer;
begin
  for I := 0 to FListings.Count - 1 do
    TDirectoryImages(FListings[I]).Free;
  FListings.Clear;
end;

{ The tree's list of ADirectory, in the current sort order; nil if the
  tree has none (not ready, or built without images). }
function TNavigator.TreeImages(const ADirectory: string): TDirectoryImages;
begin
  Result := nil;
  if not FTreeReady then
    Exit;
  Result := FTree.ImagesOf(ADirectory);
  if (Result <> nil) and (Result.SortMode <> FSortMode) then
    Result.SortMode := FSortMode;   { sorted when first needed }
end;

{ The image list of ADirectory: the current one, the tree's, a cached
  one, or a fresh listing (which is then cached). nil if it is not
  known and ReadsDisk is off. }
function TNavigator.Listing(const ADirectory: string): TDirectoryImages;
var
  I: Integer;
begin
  if SameText(ADirectory, FImages.Directory) then
    Exit(FImages);

  Result := TreeImages(ADirectory);
  if Result <> nil then
    Exit;

  for I := 0 to FListings.Count - 1 do
    if SameText(TDirectoryImages(FListings[I]).Directory, ADirectory) then
    begin
      { Most recently used goes to the end, so it is freed last. }
      Result := TDirectoryImages(FListings[I]);
      FListings.Move(I, FListings.Count - 1);
      Exit;
    end;

  if not FReadsDisk then
    Exit(nil);

  Result := TDirectoryImages.Create;
  Result.SortMode := FSortMode;
  Result.Scan(ADirectory);

  if FListings.Count >= MaxCachedListings then
  begin
    TDirectoryImages(FListings[0]).Free;
    FListings.Delete(0);
  end;
  FListings.Add(Result);
end;

{ The same walk as SeekDirectory, but without moving: the first folder
  after AFromDirectory (in ADirection) that has images, or nil. }
function TNavigator.NeighborWithImages(const AFromDirectory: string;
  ADirection: Integer): TDirectoryImages;
var
  StartPos, Steps, Step, Pos, Total: Integer;
  List: TDirectoryImages;
begin
  Result := nil;
  Total := FTree.Count;
  if Total = 0 then
    Exit;

  StartPos := FTree.IndexOf(AFromDirectory);
  if StartPos >= 0 then
    Steps := Total - 1
  else
  begin
    if ADirection > 0 then
      StartPos := -1
    else
      StartPos := Total;
    Steps := Total;
  end;
  if Steps > MaxFoldersTried then
    Steps := MaxFoldersTried;

  for Step := 1 to Steps do
  begin
    Pos := StartPos + ADirection * Step;
    if (Pos < 0) or (Pos >= Total) then
    begin
      if not FWrapAround then
        Break;
      Pos := ((Pos mod Total) + Total) mod Total;
    end;

    List := Listing(FTree.Directory(Pos));
    if List = nil then
      Exit;      { not known (no disk access): can't look further }
    if List.Count > 0 then
      Exit(List);
  end;
end;

function TNavigator.FilesAhead(ACount, ADirection: Integer): TStringArray;
var
  List, Next: TDirectoryImages;
  Idx, Found, Hops, ListCount: Integer;
  StartFile, Name: string;
begin
  Result := nil;
  if (ACount <= 0) or not HasCurrentImage then
    Exit;
  if ADirection >= 0 then
    ADirection := 1
  else
    ADirection := -1;

  SetLength(Result, ACount);
  Found := 0;
  StartFile := CurrentFileName;
  List := FImages;
  Idx := FCurrentIndex;
  Hops := 0;

  while Found < ACount do
  begin
    Inc(Idx, ADirection);
    if (Idx < 0) or (Idx >= List.Count) then
    begin
      if FWrapScope = wsFolder then
      begin
        if not FWrapAround or (List.Count <= 1) then
          Break;
      end
      else
      begin
        Inc(Hops);
        if Hops > MaxFolderHops then
          Break;
        { NeighborWithImages may drop old cached listings, possibly
          List itself; read what we need from it first. }
        ListCount := List.Count;
        Next := NeighborWithImages(List.Directory, ADirection);
        if Next <> nil then
          List := Next
        else if not (FTreeReady and FWrapAround and (ListCount > 1)) then
          Break
        else if List <> FImages then
          Break;   { can't happen in practice; don't risk a freed list }
        { else: the only folder with images, wrap inside it }
      end;
      if ADirection > 0 then
        Idx := 0
      else
        Idx := List.Count - 1;
    end;

    Name := List.FileName(Idx);
    if SameText(Name, StartFile) then
      Break;   { all the way round }
    Result[Found] := Name;
    Inc(Found);
  end;

  SetLength(Result, Found);
end;

function TNavigator.GetCurrentDirectory: string;
begin
  Result := FImages.Directory;
end;

{ Lists the images of ADirectory and selects the first one, or none
  (-1) if there are no images. Never touches the tree. }
procedure TNavigator.ScanImages(const ADirectory: string);
var
  Source: TDirectoryImages;
begin
  FImages.SortMode := FSortMode;
  Source := TreeImages(ADirectory);
  if Source <> nil then
    FImages.Assign(Source)
  else if FReadsDisk then
    FImages.Scan(ADirectory)
  else
  begin
    FImages.BeginFill(ADirectory);   { not known: empty }
    FImages.EndFill;
  end;
  if FImages.Count > 0 then
    FCurrentIndex := 0
  else
    FCurrentIndex := -1;
end;

class function TNavigator.ChooseRoot(const ADirectory: string; ARecursive: Boolean): string;
var
  Parent: string;
begin
  Result := ADirectory;
  if not ARecursive then
    Exit;

  Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(ADirectory));
  { Parent missing, the same as the directory, or a drive root
    ("C:" after removing the backslash, or "" for "/")? Then stay. }
  if (Length(Parent) <= 2) or SameText(Parent, ADirectory) then
    Exit;

  Result := Parent;
end;

class function TNavigator.IsInside(const ADirectory, ARoot: string): Boolean;
var
  RootPrefix: string;
begin
  RootPrefix := IncludeTrailingPathDelimiter(ARoot);
  Result := SameText(ADirectory, ARoot)
    or SameText(Copy(ADirectory, 1, Length(RootPrefix)), RootPrefix);
end;

procedure TNavigator.OpenPath(const AFileOrDirectory: string; const ASelectFile: string;
  ADeferTree: Boolean);
var
  Path, TargetDirectory, TargetFile, SelectPath, SelectDirectory: string;
  Idx: Integer;
  OpenedFile: Boolean;
begin
  ClearListings;
  Path := ExpandFileName(AFileOrDirectory);
  TargetFile := '';
  OpenedFile := not DirectoryExists(Path);

  if not OpenedFile then
  begin
    TargetDirectory := ExcludeTrailingPathDelimiter(Path);
    FRootDirectory := TargetDirectory;

    { Resume on a given file, if it lies inside this folder's tree. }
    if ASelectFile <> '' then
    begin
      SelectPath := ExpandFileName(ASelectFile);
      SelectDirectory := ExcludeTrailingPathDelimiter(ExtractFileDir(SelectPath));
      if FileExists(SelectPath) and IsInside(SelectDirectory, FRootDirectory) then
      begin
        TargetFile := SelectPath;
        TargetDirectory := SelectDirectory;
      end;
    end;
  end
  else
  begin
    { A file (or a path that no longer exists: then nothing is found
      and the viewer shows a message). }
    TargetFile := Path;
    TargetDirectory := ExcludeTrailingPathDelimiter(ExtractFileDir(Path));
    FRootDirectory := ChooseRoot(TargetDirectory, FRecursive);
  end;

  if ADeferTree then
  begin
    FTree.Clear;
    FTreeReady := False;
  end
  else
  begin
    FTree.Build(FRootDirectory, FRecursive);

    { An opened file can sit in a folder the scan skips (a link or a
      system folder). It must still work: use its own folder as the
      root. }
    if OpenedFile and (FTree.IndexOf(TargetDirectory) < 0) then
    begin
      FRootDirectory := TargetDirectory;
      FTree.Build(FRootDirectory, FRecursive);
    end;
    FTreeReady := True;
  end;

  ScanImages(TargetDirectory);

  if TargetFile <> '' then
  begin
    Idx := FImages.IndexOfFile(TargetFile);
    if Idx >= 0 then
      FCurrentIndex := Idx;
  end;

  { No dead ends: an empty start folder moves on to the next folder
    with images. With a deferred tree, SetTree does this later. }
  if FTreeReady and not HasCurrentImage then
    SeekDirectory(1, False);
end;

procedure TNavigator.OpenListed(const ARoot, ATargetDirectory: string;
  AListing: TDirectoryImages; const ATargetFile: string);
var
  Idx: Integer;
begin
  ClearListings;
  FRootDirectory := ExcludeTrailingPathDelimiter(ARoot);
  FTree.Clear;
  FTreeReady := False;

  FImages.SortMode := FSortMode;
  if AListing <> nil then
    FImages.Assign(AListing)
  else
  begin
    FImages.BeginFill(ATargetDirectory);
    FImages.EndFill;
  end;

  if FImages.Count > 0 then
    FCurrentIndex := 0
  else
    FCurrentIndex := -1;
  if ATargetFile <> '' then
  begin
    Idx := FImages.IndexOfFile(ATargetFile);
    if Idx >= 0 then
      FCurrentIndex := Idx;
  end;
end;

function TNavigator.SetTree(ATree: TDirectoryTree): Boolean;
var
  OldFile: string;
  OldIndex: Integer;
  Source: TDirectoryImages;
begin
  OldFile := CurrentFileName;
  OldIndex := FCurrentIndex;
  FTree.Free;
  FTree := ATree;
  FTreeReady := True;
  ClearListings;
  { The scanner may have chosen another root (an opened file in a
    folder its scan skips). }
  if (FTree.Root <> nil) and not SameText(FTree.Root.Path, FRootDirectory) then
    FRootDirectory := FTree.Root.Path;

  { The tree's list of the current folder is the newer one. }
  Source := TreeImages(FImages.Directory);
  if Source <> nil then
  begin
    FImages.Assign(Source);
    FCurrentIndex := -1;
    if OldFile <> '' then
      FCurrentIndex := FImages.IndexOfFile(OldFile);
    { The current file is gone meanwhile: stay near its place. }
    if (FCurrentIndex < 0) and (OldIndex >= 0) and (FImages.Count > 0) then
      FCurrentIndex := Min(OldIndex, FImages.Count - 1);
  end;

  if not HasCurrentImage then
    SeekDirectory(1, False);
  Result := not SameText(OldFile, CurrentFileName);
end;

function TNavigator.ListedKey(const AFileName: string; out AKey: TImageKey): Boolean;
var
  List: TDirectoryImages;
  Idx: Integer;
begin
  Result := False;
  AKey.FileName := AFileName;
  AKey.FileSize := 0;
  AKey.FileTime := 0;

  List := FImages;
  Idx := List.IndexOfFile(AFileName);
  if Idx < 0 then
  begin
    List := TreeImages(ExcludeTrailingPathDelimiter(ExtractFileDir(AFileName)));
    if List = nil then
      Exit;
    Idx := List.IndexOfFile(AFileName);
    if Idx < 0 then
      Exit;
  end;
  AKey.FileSize := List.FileSize(Idx);
  AKey.FileTime := List.DateModified(Idx);
  Result := True;
end;

procedure TNavigator.SetSortMode(AMode: TSortMode);
var
  Current: string;
begin
  Current := CurrentFileName;
  ClearListings;
  FSortMode := AMode;
  FImages.SortMode := AMode;   { re-sorts the current list }
  if Current <> '' then
    FCurrentIndex := FImages.IndexOfFile(Current);
end;

procedure TNavigator.ToggleSortMode;
begin
  if FSortMode in [smFileNameAscending, smFileNameDescending] then
    SetSortMode(smDateDescending)
  else
    SetSortMode(smFileNameAscending);
end;

function TNavigator.HasCurrentImage: Boolean;
begin
  Result := (FCurrentIndex >= 0) and (FCurrentIndex < FImages.Count);
end;

function TNavigator.CurrentFileName: string;
begin
  if HasCurrentImage then
    Result := FImages.FileName(FCurrentIndex)
  else
    Result := '';
end;

function TNavigator.ImageCount: Integer;
begin
  Result := FImages.Count;
end;

function TNavigator.NextImage: Boolean;
begin
  if not HasCurrentImage then
    Exit(SeekDirectory(1, False));

  if FCurrentIndex + 1 < FImages.Count then
  begin
    Inc(FCurrentIndex);
    Exit(True);
  end;

  { At the last image of this folder. }
  if FWrapScope = wsFolder then
  begin
    Result := FWrapAround and (FImages.Count > 1);
    if Result then
      FCurrentIndex := 0;
    Exit;
  end;

  Result := SeekDirectory(1, False);

  { The only folder with images: wrap inside it. (Not while the tree
    is still being scanned: other folders may have images.) }
  if (not Result) and FTreeReady and FWrapAround and (FImages.Count > 1) then
  begin
    FCurrentIndex := 0;
    Result := True;
  end;
end;

function TNavigator.PreviousImage: Boolean;
begin
  if not HasCurrentImage then
    Exit(SeekDirectory(-1, True));

  if FCurrentIndex > 0 then
  begin
    Dec(FCurrentIndex);
    Exit(True);
  end;

  { At the first image of this folder. }
  if FWrapScope = wsFolder then
  begin
    Result := FWrapAround and (FImages.Count > 1);
    if Result then
      FCurrentIndex := FImages.Count - 1;
    Exit;
  end;

  Result := SeekDirectory(-1, True);

  if (not Result) and FTreeReady and FWrapAround and (FImages.Count > 1) then
  begin
    FCurrentIndex := FImages.Count - 1;
    Result := True;
  end;
end;

function TNavigator.NextDirectory: Boolean;
begin
  Result := SeekDirectory(1, False);
end;

function TNavigator.PreviousDirectory: Boolean;
begin
  Result := SeekDirectory(-1, False);
end;

{ Walks the directory list from the current directory in ADirection
  (+1 / -1) and stops at the first directory that has images. With
  WrapAround the walk continues at the other end of the list, and
  every other directory is tried exactly once. Lands on the first
  image, or the last one if ALandOnLast.

  If no directory qualifies, the directory and image that were current
  before are restored, and the result is False. }
function TNavigator.SeekDirectory(ADirection: Integer; ALandOnLast: Boolean): Boolean;
var
  StartDirectory: string;
  OriginalIndex, StartPos, Steps, Step, Pos, Total: Integer;
begin
  Result := False;
  Total := FTree.Count;
  if Total = 0 then
    Exit;

  StartDirectory := FImages.Directory;
  OriginalIndex := FCurrentIndex;

  StartPos := FTree.IndexOf(StartDirectory);
  if StartPos >= 0 then
    Steps := Total - 1           { every directory except the current one }
  else
  begin
    { The current directory isn't in the tree: start just outside it. }
    if ADirection > 0 then
      StartPos := -1
    else
      StartPos := Total;
    Steps := Total;
  end;

  for Step := 1 to Steps do
  begin
    Pos := StartPos + ADirection * Step;
    if (Pos < 0) or (Pos >= Total) then
    begin
      if not FWrapAround then
        Break;
      Pos := ((Pos mod Total) + Total) mod Total;
    end;

    ScanImages(FTree.Directory(Pos));
    if FImages.Count > 0 then
    begin
      if ALandOnLast then
        FCurrentIndex := FImages.Count - 1
      else
        FCurrentIndex := 0;
      Exit(True);
    end;
  end;

  { Nothing found: put everything back. }
  if FImages.Directory <> StartDirectory then
    ScanImages(StartDirectory);
  FCurrentIndex := OriginalIndex;
end;

end.
