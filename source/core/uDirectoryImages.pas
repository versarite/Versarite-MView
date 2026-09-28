unit uDirectoryImages;

{
  Unit: uDirectoryImages

  Purpose
  -------
  The list of image files in one directory, in the current sort order.

  Owns
  ----
  - Its list of entries, FEntries (plain records, no objects).

  Knows
  -----
  - uImageFormats (IsSupportedImageFile) to tell image files apart.
  - uNaturalSort for comparing file names.

  Responsibilities
  ----------------
  - Scan one directory (not recursively) for supported image files
    (uImageFormats).
  - Be filled from outside instead (BeginFill, AddEntry, EndFill):
    the tree scan collects every folder's images this way.
  - Copy another list (Assign), sorted in this list's own mode.
  - Keep them in the current TSortMode order. File names compare
    naturally (Image2 < Image10); equal dates are ordered by name, so
    the order is always the same. Setting SortMode re-sorts at once.
  - Look up entries by index and by file name.

  Does NOT
  --------
  - Recurse into subdirectories. That is TDirectoryTree's job.
  - Decode or load image content.

  Threads
  -------
  No lock: one thread at a time uses a list. The scanner thread fills
  lists (TDirectoryTree.Build, TScanStart.Listing) and hands them to
  the UI thread, where TNavigator uses them. With ReadsDisk = True
  the UI thread also scans folders itself.

  Uses (MView units)
  ------------------
  interface:      uTypes, uImageFormats, uNaturalSort
  Libraries:      Classes, SysUtils, DateUtils

  Used by
  -------
  uDirectoryScanner, uDirectoryTree, uNavigator
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  DateUtils,
  uTypes,
  uImageFormats,
  uNaturalSort;

type

  TImageEntry = record
    FileName: string;     { full path }
    Size: Int64;
    Modified: TDateTime;
  end;

  TDirectoryImages = class(TObject)
  private
    FDirectory: string;
    FEntries: array of TImageEntry;
    FCount: Integer;
    FSortMode: TSortMode;

    procedure SetSortMode(AMode: TSortMode);
    function CompareEntries(const A, B: TImageEntry): Integer;
    procedure QuickSort(ALo, AHi: Integer);
    procedure Sort;
  public
    constructor Create;

    procedure Scan(const ADirectory: string);
    procedure Clear;

    { Filling from outside (the tree scan collects the images of every
      folder while it lists the folders): BeginFill, AddEntry for each
      image, EndFill sorts. }
    procedure BeginFill(const ADirectory: string);
    procedure AddEntry(const AFileName: string; ASize: Int64; AModified: TDateTime);
    procedure EndFill;

    { A copy of ASource (directory and entries), sorted in this list's
      own sort mode. }
    procedure Assign(ASource: TDirectoryImages);

    function Count: Integer;
    function FileName(AIndex: Integer): string;
    function FileSize(AIndex: Integer): Int64;
    function DateModified(AIndex: Integer): TDateTime;
    function IndexOfFile(const AFileName: string): Integer;

    property Directory: string read FDirectory;
    { Setting the sort mode re-sorts the list at once. }
    property SortMode: TSortMode read FSortMode write SetSortMode;
  end;

implementation

{ TDirectoryImages }

constructor TDirectoryImages.Create;
begin
  inherited Create;
  FSortMode := smDateDescending;
  FCount := 0;
end;

procedure TDirectoryImages.Clear;
begin
  FDirectory := '';
  FEntries := nil;
  FCount := 0;
end;

procedure TDirectoryImages.Scan(const ADirectory: string);
var
  SearchRec: TSearchRec;
  Prefix: string;
begin
  Clear;
  FDirectory := ExcludeTrailingPathDelimiter(ADirectory);
  if FDirectory = '' then
    Exit;

  Prefix := IncludeTrailingPathDelimiter(FDirectory);
  if FindFirst(Prefix + '*', faAnyFile, SearchRec) = 0 then
  begin
    try
      repeat
        if ((SearchRec.Attr and faDirectory) = 0)
          and IsSupportedImageFile(SearchRec.Name) then
        begin
          { Grow in steps, not by one, so large folders stay fast. }
          if FCount = Length(FEntries) then
            SetLength(FEntries, 16 + 2 * Length(FEntries));

          FEntries[FCount].FileName := Prefix + SearchRec.Name;
          FEntries[FCount].Size := SearchRec.Size;
          FEntries[FCount].Modified := FileDateToDateTime(SearchRec.Time);
          Inc(FCount);
        end;
      until FindNext(SearchRec) <> 0;
    finally
      FindClose(SearchRec);
    end;
  end;

  Sort;
end;

procedure TDirectoryImages.BeginFill(const ADirectory: string);
begin
  Clear;
  FDirectory := ExcludeTrailingPathDelimiter(ADirectory);
end;

procedure TDirectoryImages.AddEntry(const AFileName: string; ASize: Int64;
  AModified: TDateTime);
begin
  if FCount = Length(FEntries) then
    SetLength(FEntries, 16 + 2 * Length(FEntries));
  FEntries[FCount].FileName := AFileName;
  FEntries[FCount].Size := ASize;
  FEntries[FCount].Modified := AModified;
  Inc(FCount);
end;

procedure TDirectoryImages.EndFill;
begin
  Sort;
end;

procedure TDirectoryImages.Assign(ASource: TDirectoryImages);
var
  I: Integer;
begin
  Clear;
  if ASource = nil then
    Exit;
  FDirectory := ASource.FDirectory;
  SetLength(FEntries, ASource.FCount);
  for I := 0 to ASource.FCount - 1 do
    FEntries[I] := ASource.FEntries[I];
  FCount := ASource.FCount;
  if ASource.FSortMode <> FSortMode then
    Sort;
end;

procedure TDirectoryImages.SetSortMode(AMode: TSortMode);
begin
  if AMode = FSortMode then
    Exit;
  FSortMode := AMode;
  Sort;
end;

function TDirectoryImages.CompareEntries(const A, B: TImageEntry): Integer;
begin
  case FSortMode of
    smFileNameAscending:
      Result := NaturalCompareText(A.FileName, B.FileName);
    smFileNameDescending:
      Result := NaturalCompareText(B.FileName, A.FileName);
    smDateAscending:
      begin
        Result := CompareDateTime(A.Modified, B.Modified);
        if Result = 0 then
          Result := NaturalCompareText(A.FileName, B.FileName);
      end;
  else
    { smDateDescending, the default: newest first. }
    begin
      Result := CompareDateTime(B.Modified, A.Modified);
      if Result = 0 then
        Result := NaturalCompareText(A.FileName, B.FileName);
    end;
  end;
end;

{ Classic Hoare quicksort. The pivot is copied, so swapping entries
  can't move it. The comparison is a total order (ties are broken by
  name), so the result doesn't depend on the input order. }
procedure TDirectoryImages.QuickSort(ALo, AHi: Integer);
var
  I, J: Integer;
  Pivot, Tmp: TImageEntry;
begin
  I := ALo;
  J := AHi;
  Pivot := FEntries[(ALo + AHi) div 2];
  repeat
    while CompareEntries(FEntries[I], Pivot) < 0 do
      Inc(I);
    while CompareEntries(FEntries[J], Pivot) > 0 do
      Dec(J);
    if I <= J then
    begin
      Tmp := FEntries[I];
      FEntries[I] := FEntries[J];
      FEntries[J] := Tmp;
      Inc(I);
      Dec(J);
    end;
  until I > J;

  if ALo < J then
    QuickSort(ALo, J);
  if I < AHi then
    QuickSort(I, AHi);
end;

procedure TDirectoryImages.Sort;
begin
  if FCount > 1 then
    QuickSort(0, FCount - 1);
end;

function TDirectoryImages.Count: Integer;
begin
  Result := FCount;
end;

function TDirectoryImages.FileName(AIndex: Integer): string;
begin
  Result := FEntries[AIndex].FileName;
end;

function TDirectoryImages.FileSize(AIndex: Integer): Int64;
begin
  Result := FEntries[AIndex].Size;
end;

function TDirectoryImages.DateModified(AIndex: Integer): TDateTime;
begin
  Result := FEntries[AIndex].Modified;
end;

function TDirectoryImages.IndexOfFile(const AFileName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if SameText(FEntries[I].FileName, AFileName) then
      Exit(I);
  Result := -1;
end;

end.
