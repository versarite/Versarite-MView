unit uDirectoryTree;

{
  Unit: uDirectoryTree

  Purpose
  -------
  The folders under the navigation root, held in memory as a tree,
  and the order in which "next / previous directory" visits them.

  Owns
  ----
  - The TDirectoryNode objects (FRoot and all its descendants).
  - Each node's TDirectoryImages, when built with ACollectImages.
  - FFlatOrder (TFPList, the nodes in depth-first pre-order) and
    FPathIndex (sorted TStringList, path -> index into FFlatOrder).

  Knows
  -----
  - The TCancelCheck handed to Build, only while Build runs.
  - uImageFormats (which files are images) and uNaturalSort (folder
    order).

  Responsibilities
  ----------------
  - Build: read the folders under a root, recursively or not, at most
    MaxScanDepth (32) levels deep. Skip links and junctions, and
    folders that are both hidden and system.
  - With ACollectImages, list every folder's images while it is read
    anyway (Day 19).
  - Stop early when the TCancelCheck asks; Build then returns False
    and the tree is incomplete.
  - Look up a folder by index or by path (case-insensitive), and give
    its images (Images, ImagesOf).
  - Give the folder before or after a given one, in depth-first
    pre-order, subfolders in natural order.

  Does NOT
  --------
  - Sort or serve image lists (TDirectoryImages).
  - Wrap around: NextDirectory / PreviousDirectory return '' at the
    ends. TNavigator decides about wrapping.
  - Watch the filesystem for changes.
  - Start a thread (TDirectoryScanner runs Build on its thread).

  Threads
  -------
  Build runs on the calling thread: the scanner thread
  (TDirectoryScanner), or the UI thread when TNavigator.OpenPath
  builds the tree itself. No lock: a finished tree is handed to the
  UI thread and the scanner never touches it again. From then on only
  the UI thread uses it (TNavigator may re-sort the image lists).

  Uses (MView units)
  ------------------
  interface:      uTypes, uImageFormats, uDirectoryImages,
                  uNaturalSort
  Libraries:      Classes, SysUtils

  Used by
  -------
  uDirectoryScanner, uMView, uNavigator
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  uTypes,
  uImageFormats,
  uDirectoryImages,
  uNaturalSort;

type

  {
    TDirectoryNode

    A single directory within the tree. Keeps track of its parent
    and its immediate child directories.

    Owned and destroyed by TDirectoryTree; nothing else should
    free a TDirectoryNode.
  }

  TDirectoryNode = class(TObject)
  private
    FPath: string;
    FParent: TDirectoryNode;
    FChildren: TFPList;
    FImages: TDirectoryImages;   { nil unless the build collected images }

    function GetChild(AIndex: Integer): TDirectoryNode;
    function GetChildCount: Integer;
  public
    constructor Create(const APath: string; AParent: TDirectoryNode);
    destructor Destroy; override;

    property Path: string read FPath;
    property Parent: TDirectoryNode read FParent;
    property ChildCount: Integer read GetChildCount;
    property Children[AIndex: Integer]: TDirectoryNode read GetChild;
    { The folder's images, if the tree was built with ACollectImages.
      Owned by the node. }
    property Images: TDirectoryImages read FImages;
  end;

  {
    TDirectoryTree

    Establishes the directory structure in memory.

    Responsibilities

    - Recurse the directory tree rooted at a given path and keep
      it in memory.
    - Know parent/child relationships between directories.
    - Provide the directory that comes before/after a given one,
      in depth-first order, so a viewer can keep browsing across
      folder boundaries.

    Does NOT

    - Know about image files, except that Build(..., ACollectImages)
      fills a TDirectoryImages per folder while it reads the folder
      anyway (TDirectoryImages sorts and serves them).
    - Watch the filesystem for changes.
    - Run on a background thread (see the spec's roadmap - that
      comes later as TDirectoryScanner).

    Notes

    "Next"/"Previous" walk the tree in depth-first pre-order: a
    directory's own subdirectories come immediately after it,
    before its next sibling. The root itself is included as the
    first entry. Subdirectories are ordered naturally (Day2 before
    Day10), as the spec requires for directories (§10).

    Skipped while scanning: links and junctions (reparse points,
    which can point back up the tree and loop forever), folders that
    are both hidden and system (e.g. "System Volume Information"),
    and anything deeper than MaxScanDepth levels.

    Build runs on whatever thread calls it. TDirectoryScanner calls it
    on the scanner thread and hands the finished tree to the UI thread
    as a snapshot, which is never changed afterwards (spec §10). A
    TCancelCheck lets an obsolete scan stop early.
  }

  TDirectoryTree = class(TObject)
  private
    FRoot: TDirectoryNode;
    FRecursive: Boolean;
    FFlatOrder: TFPList;      // TDirectoryNode, in depth-first pre-order
    FPathIndex: TStringList;  // sorted path -> index into FFlatOrder
    FCancel: TCancelCheck;
    FCancelled: Boolean;
    FCollectImages: Boolean;

    procedure ScanNode(ANode: TDirectoryNode; ADepth: Integer);
    procedure Flatten(ANode: TDirectoryNode);
  public
    constructor Create;
    destructor Destroy; override;

    { Returns False if ACancel stopped the scan; the tree is then
      incomplete and should be thrown away.
      ACollectImages: also list the images of every folder while it is
      read anyway (Day 19: the viewer then never has to read a folder
      itself, so a slow or hung disk can't freeze the window). }
    function Build(const ARootPath: string; ARecursive: Boolean;
      ACancel: TCancelCheck = nil; ACollectImages: Boolean = False): Boolean;
    procedure Clear;

    function Count: Integer;
    function Directory(AIndex: Integer): string;
    function IndexOf(const APath: string): Integer;
    { The images of folder AIndex / APath, nil if not collected (or not
      in the tree). Owned by the tree. }
    function Images(AIndex: Integer): TDirectoryImages;
    function ImagesOf(const APath: string): TDirectoryImages;

    function NextDirectory(const ACurrentPath: string): string;
    function PreviousDirectory(const ACurrentPath: string): string;

    property Root: TDirectoryNode read FRoot;
  end;

implementation

const
  MaxScanDepth = 32;

{ TDirectoryNode }

constructor TDirectoryNode.Create(const APath: string; AParent: TDirectoryNode);
begin
  inherited Create;
  FPath := APath;
  FParent := AParent;
  FChildren := TFPList.Create;
end;

destructor TDirectoryNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to FChildren.Count - 1 do
    TDirectoryNode(FChildren[i]).Free;
  FChildren.Free;
  FImages.Free;
  inherited Destroy;
end;

function TDirectoryNode.GetChild(AIndex: Integer): TDirectoryNode;
begin
  Result := TDirectoryNode(FChildren[AIndex]);
end;

function TDirectoryNode.GetChildCount: Integer;
begin
  Result := FChildren.Count;
end;

{ TDirectoryTree }

constructor TDirectoryTree.Create;
begin
  inherited Create;
  FRoot := nil;
  FFlatOrder := TFPList.Create;
  FPathIndex := TStringList.Create;
  FPathIndex.CaseSensitive := False;
  FPathIndex.Sorted := True;
  FPathIndex.Duplicates := dupIgnore;
end;

destructor TDirectoryTree.Destroy;
begin
  Clear;
  FFlatOrder.Free;
  FPathIndex.Free;
  inherited Destroy;
end;

procedure TDirectoryTree.Clear;
begin
  FreeAndNil(FRoot);
  FFlatOrder.Clear;
  FPathIndex.Clear;
end;

{ faSymLink, faHidden and faSysFile are Windows file attributes, and
  FPC warns that they are "not portable". MView is a Windows program,
  so the warning is switched off for this one procedure. }
{$PUSH}{$WARN SYMBOL_PLATFORM OFF}

{ Recursively discovers subdirectories of ANode and attaches them as
  children, in natural name order. Does nothing if the tree was built
  as non-recursive. }
procedure TDirectoryTree.ScanNode(ANode: TDirectoryNode; ADepth: Integer);
var
  SearchRec: TSearchRec;
  Names: TStringList;
  i: Integer;
  ChildPath, Prefix: string;
  Child: TDirectoryNode;
  Descend: Boolean;
begin
  if FCancelled then
    Exit;
  Descend := FRecursive and (ADepth < MaxScanDepth);
  if not (Descend or FCollectImages) then
    Exit;

  if Assigned(FCancel) and FCancel() then
  begin
    FCancelled := True;
    Exit;
  end;

  Prefix := IncludeTrailingPathDelimiter(ANode.Path);
  if FCollectImages then
  begin
    ANode.FImages := TDirectoryImages.Create;
    ANode.FImages.BeginFill(ANode.Path);
  end;

  Names := TStringList.Create;
  try
    if FindFirst(Prefix + '*', faAnyFile, SearchRec) = 0 then
    begin
      try
        repeat
          if (SearchRec.Attr and faDirectory) <> 0 then
          begin
            if Descend
              and ((SearchRec.Attr and faSymLink) = 0)
              and ((SearchRec.Attr and (faHidden or faSysFile)) <> (faHidden or faSysFile))
              and (SearchRec.Name <> '.')
              and (SearchRec.Name <> '..') then
              Names.Add(SearchRec.Name);
          end
          else if FCollectImages and IsSupportedImageFile(SearchRec.Name) then
            { The same fields TDirectoryImages.Scan takes, so a key
              made from them matches MakeImageKey on the worker. }
            ANode.FImages.AddEntry(Prefix + SearchRec.Name, SearchRec.Size,
              FileDateToDateTime(SearchRec.Time));
        until FindNext(SearchRec) <> 0;
      finally
        FindClose(SearchRec);
      end;
    end;

    if FCollectImages then
      ANode.FImages.EndFill;

    Names.CustomSort(@NaturalCompareStringList);

    for i := 0 to Names.Count - 1 do
    begin
      ChildPath := IncludeTrailingPathDelimiter(ANode.Path) + Names[i];
      Child := TDirectoryNode.Create(ChildPath, ANode);
      ANode.FChildren.Add(Child);
      ScanNode(Child, ADepth + 1);
    end;
  finally
    Names.Free;
  end;
end;
{$POP}

{ Appends ANode and all of its descendants (pre-order) to FFlatOrder,
  and records their position in FPathIndex for fast lookup. }
procedure TDirectoryTree.Flatten(ANode: TDirectoryNode);
var
  i: Integer;
begin
  FPathIndex.AddObject(ANode.Path, TObject(PtrInt(FFlatOrder.Count)));
  FFlatOrder.Add(ANode);

  for i := 0 to ANode.ChildCount - 1 do
    Flatten(ANode.Children[i]);
end;

function TDirectoryTree.Build(const ARootPath: string; ARecursive: Boolean;
  ACancel: TCancelCheck; ACollectImages: Boolean): Boolean;
var
  NormalizedRoot: string;
begin
  Clear;

  FCollectImages := ACollectImages;
  FRecursive := ARecursive;
  FCancel := ACancel;
  FCancelled := False;
  NormalizedRoot := ExcludeTrailingPathDelimiter(ARootPath);

  if NormalizedRoot <> '' then
  begin
    FRoot := TDirectoryNode.Create(NormalizedRoot, nil);
    ScanNode(FRoot, 0);
    Flatten(FRoot);
  end;

  FCancel := nil;
  Result := not FCancelled;
end;

function TDirectoryTree.Count: Integer;
begin
  Result := FFlatOrder.Count;
end;

function TDirectoryTree.Directory(AIndex: Integer): string;
begin
  Result := TDirectoryNode(FFlatOrder[AIndex]).Path;
end;

function TDirectoryTree.IndexOf(const APath: string): Integer;
var
  ListIndex: Integer;
  NormalizedPath: string;
begin
  NormalizedPath := ExcludeTrailingPathDelimiter(APath);
  ListIndex := FPathIndex.IndexOf(NormalizedPath);
  if ListIndex < 0 then
    Result := -1
  else
    Result := PtrInt(FPathIndex.Objects[ListIndex]);
end;

function TDirectoryTree.Images(AIndex: Integer): TDirectoryImages;
begin
  if (AIndex < 0) or (AIndex >= FFlatOrder.Count) then
    Exit(nil);
  Result := TDirectoryNode(FFlatOrder[AIndex]).Images;
end;

function TDirectoryTree.ImagesOf(const APath: string): TDirectoryImages;
begin
  Result := Images(IndexOf(APath));
end;

function TDirectoryTree.NextDirectory(const ACurrentPath: string): string;
var
  Idx: Integer;
begin
  Result := '';
  Idx := IndexOf(ACurrentPath);
  if (Idx >= 0) and (Idx + 1 < FFlatOrder.Count) then
    Result := Directory(Idx + 1);
end;

function TDirectoryTree.PreviousDirectory(const ACurrentPath: string): string;
var
  Idx: Integer;
begin
  Result := '';
  Idx := IndexOf(ACurrentPath);
  if Idx > 0 then
    Result := Directory(Idx - 1);
end;

end.
