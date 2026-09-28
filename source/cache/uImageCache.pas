unit uImageCache;

{
  Unit: uImageCache

  Purpose
  -------
  Keeps decoded images so that going back to one, or on to a
  preloaded one, doesn't decode it again (spec §4.2, §13). The cache
  is guarded by a lock (spec §2.4), though today only the UI thread
  calls it.

  Owns
  ----
  - References to IDecodedImage (shared; the image itself is freed
    when its last reference goes), in FEntries.
  - Its lock, FLock (TCriticalSection).
  - The preload window, FWindow (file names).

  Knows
  -----
  - Nothing else.

  Responsibilities
  ----------------
  - Store and find images by file key (name, size, time), so a file
    that was replaced on disk is not served from the cache.
  - Find the best image for a file by name only, whatever version
    (GetByName: no disk access for a key, Day 19).
  - Hold up to one entry per file and quality level: a JPEG can have a
    small Screen version and a large Full version at the same time.
    Get returns the best one.
  - Keep error entries (a failed attempt), and give or drop them.
  - Stay within a memory budget, evicting by distance from the current
    image (spec §13). AutomaticCacheSizeMB: 25 % of physical memory,
    at least 256 MB, at most 4096 MB.
  - Drop one quality level when the window size changed (DropQuality).

  Does NOT
  --------
  - Decide what to load.
  - Decode or read files; keys come from the caller.

  Threads
  -------
  Every public method takes FLock, so the cache is safe from any
  thread. Today only the UI thread (TMView) calls it. The private
  helpers expect the caller to hold the lock.

  Uses (MView units)
  ------------------
  interface:      uTypes, uDecodedImage
  Libraries:      Classes, SysUtils, SyncObjs

  Used by
  -------
  uMView

  Eviction order (spec §13)
  -------------------------
  The owner describes the preload window with SetWindow: the current
  file first, then the others in order of importance. When over
  budget, entries go in this order:
    1. files outside the window, Full before smaller levels, oldest
       first;
    2. files inside the window, Full before smaller levels, least
       important first.
  Entries of the current file are never evicted. So the big Full
  versions of neighbours go first, and their small Screen versions
  stay as long as there is room.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  uTypes,
  uDecodedImage;

type

  TCacheEntry = record
    Image: IDecodedImage;
    LastUse: QWord;
  end;

  TImageCache = class(TObject)
  private
    FLock: TCriticalSection;
    FEntries: array of TCacheEntry;
    FCount: Integer;
    FBudgetBytes: Int64;
    FUseCounter: QWord;
    FWindow: array of string;    { [0] = current file }

    function IndexOf(const AFileName: string; AQuality: TQualityLevel): Integer;
    procedure DeleteAt(AIndex: Integer);
    function WindowRank(const AFileName: string): Integer;
    procedure EvictToBudget;
    function GetBudgetMB: Integer;
  public
    constructor Create(ABudgetMB: Integer);
    destructor Destroy; override;

    { The best cached image for exactly this file version, or nil.
      Entries for an older version of the file are dropped. }
    function Get(const AKey: TImageKey): IDecodedImage;

    { The best cached image for this file, whatever version (no disk
      access for a key: the UI thread uses this, Day 19). An error
      entry only if there is nothing else. nil if none. }
    function GetByName(const AFileName: string): IDecodedImage;

    { The best quality cached for this file (qlNone if nothing, or only
      an error entry). Doesn't check the file version. }
    function BestQuality(const AFileName: string): TQualityLevel;

    { True if there is any entry for this file, error entries included. }
    function Contains(const AFileName: string): Boolean;

    { True if an attempt for this file failed (an error entry). }
    function HasError(const AFileName: string): Boolean;
    { That error entry, or nil. (Get prefers any image, even a
      thumbnail, over an error.) }
    function ErrorOf(const AFileName: string): IDecodedImage;
    { Removes this file's error entry, if any. }
    procedure DropError(const AFileName: string);

    { Memory used by this file's entries. }
    function BytesOf(const AFileName: string): Int64;

    { Adds or replaces the entry for the image's file and quality, then
      evicts to budget. False if the image itself had to go again at
      once (it didn't fit next to more important ones). }
    function Put(const AImage: IDecodedImage): Boolean;

    { The preload window: current file first, then by importance. }
    procedure SetWindow(const AFiles: array of string);

    { Drops every entry of quality AQuality except those of AKeepFile
      (the window size changed: quick views made for the old size). }
    procedure DropQuality(AQuality: TQualityLevel; const AKeepFile: string);

    procedure Clear;
    function UsedBytes: Int64;
    function Count: Integer;
    property BudgetMB: Integer read GetBudgetMB;
    property BudgetBytes: Int64 read FBudgetBytes;
  end;

{ The automatic budget (CacheSizeMB = 0): 25 % of physical memory,
  at least 256 MB, at most 4096 MB (spec §13). }
function AutomaticCacheSizeMB: Integer;

implementation

{$IFDEF WINDOWS}
type
  TMemStatusEx = record
    dwLength: LongWord;
    dwMemoryLoad: LongWord;
    ullTotalPhys: QWord;
    ullAvailPhys: QWord;
    ullTotalPageFile: QWord;
    ullAvailPageFile: QWord;
    ullTotalVirtual: QWord;
    ullAvailVirtual: QWord;
    ullAvailExtendedVirtual: QWord;
  end;

function MViewGlobalMemoryStatusEx(var ABuffer: TMemStatusEx): LongBool; stdcall;
  external 'kernel32.dll' name 'GlobalMemoryStatusEx';
{$ENDIF}

function AutomaticCacheSizeMB: Integer;
{$IFDEF WINDOWS}
var
  Status: TMemStatusEx;
  TotalMB: QWord;
{$ENDIF}
begin
  Result := 1024;
  {$IFDEF WINDOWS}
  FillChar(Status, SizeOf(Status), 0);
  Status.dwLength := SizeOf(Status);
  if MViewGlobalMemoryStatusEx(Status) then
  begin
    TotalMB := Status.ullTotalPhys div (1024 * 1024);
    Result := Integer(TotalMB div 4);
  end;
  {$ENDIF}
  if Result < 256 then
    Result := 256;
  if Result > 4096 then
    Result := 4096;
end;

constructor TImageCache.Create(ABudgetMB: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  if ABudgetMB < 1 then
    ABudgetMB := 1;
  FBudgetBytes := Int64(ABudgetMB) * 1024 * 1024;
  FCount := 0;
  FUseCounter := 0;
  FWindow := nil;
end;

destructor TImageCache.Destroy;
begin
  Clear;
  FLock.Free;
  inherited Destroy;
end;

function TImageCache.GetBudgetMB: Integer;
begin
  Result := Integer(FBudgetBytes div (1024 * 1024));
end;

function TImageCache.IndexOf(const AFileName: string; AQuality: TQualityLevel): Integer;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if (FEntries[I].Image.Quality = AQuality)
      and SameText(FEntries[I].Image.Key.FileName, AFileName) then
      Exit(I);
  Result := -1;
end;

procedure TImageCache.DeleteAt(AIndex: Integer);
var
  I: Integer;
begin
  { Plain assignments, so the interface references are counted
    correctly (no Move of managed data). }
  for I := AIndex to FCount - 2 do
    FEntries[I] := FEntries[I + 1];
  FEntries[FCount - 1].Image := nil;
  Dec(FCount);
end;

{ Position in the window, or -1 if outside. Caller holds the lock. }
function TImageCache.WindowRank(const AFileName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FWindow) do
    if SameText(FWindow[I], AFileName) then
      Exit(I);
  Result := -1;
end;

function TImageCache.Get(const AKey: TImageKey): IDecodedImage;
var
  I, Best: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    Best := -1;
    I := 0;
    while I < FCount do
    begin
      if SameText(FEntries[I].Image.Key.FileName, AKey.FileName) then
      begin
        if not SameImageKey(FEntries[I].Image.Key, AKey) then
        begin
          DeleteAt(I);   { the file changed on disk }
          if (Best > I) then
            Dec(Best);
          Continue;
        end;
        if (Best < 0) or (FEntries[I].Image.Quality > FEntries[Best].Image.Quality) then
          Best := I;
      end;
      Inc(I);
    end;

    if Best >= 0 then
    begin
      Inc(FUseCounter);
      FEntries[Best].LastUse := FUseCounter;
      Result := FEntries[Best].Image;
    end;
  finally
    FLock.Release;
  end;
end;

function TImageCache.GetByName(const AFileName: string): IDecodedImage;
var
  I, Best: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    Best := -1;
    for I := 0 to FCount - 1 do
      if SameText(FEntries[I].Image.Key.FileName, AFileName)
        and ((Best < 0) or (FEntries[I].Image.Quality > FEntries[Best].Image.Quality)) then
        Best := I;
    if Best >= 0 then
    begin
      Inc(FUseCounter);
      FEntries[Best].LastUse := FUseCounter;
      Result := FEntries[Best].Image;
    end;
  finally
    FLock.Release;
  end;
end;

function TImageCache.BestQuality(const AFileName: string): TQualityLevel;
var
  I: Integer;
begin
  Result := qlNone;
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      if SameText(FEntries[I].Image.Key.FileName, AFileName)
        and (FEntries[I].Image.Quality > Result) then
        Result := FEntries[I].Image.Quality;
  finally
    FLock.Release;
  end;
end;

function TImageCache.Contains(const AFileName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      if SameText(FEntries[I].Image.Key.FileName, AFileName) then
        Exit(True);
  finally
    FLock.Release;
  end;
end;

function TImageCache.HasError(const AFileName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      if FEntries[I].Image.IsError
        and SameText(FEntries[I].Image.Key.FileName, AFileName) then
        Exit(True);
  finally
    FLock.Release;
  end;
end;

function TImageCache.ErrorOf(const AFileName: string): IDecodedImage;
var
  I: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      if FEntries[I].Image.IsError
        and SameText(FEntries[I].Image.Key.FileName, AFileName) then
        Exit(FEntries[I].Image);
  finally
    FLock.Release;
  end;
end;

procedure TImageCache.DropError(const AFileName: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := FCount - 1 downto 0 do
      if FEntries[I].Image.IsError
        and SameText(FEntries[I].Image.Key.FileName, AFileName) then
        DeleteAt(I);
  finally
    FLock.Release;
  end;
end;

function TImageCache.BytesOf(const AFileName: string): Int64;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      if SameText(FEntries[I].Image.Key.FileName, AFileName) then
        Inc(Result, FEntries[I].Image.SizeInBytes);
  finally
    FLock.Release;
  end;
end;

function TImageCache.Put(const AImage: IDecodedImage): Boolean;
var
  Idx: Integer;
begin
  Result := False;
  if AImage = nil then
    Exit;

  FLock.Acquire;
  try
    Inc(FUseCounter);
    Idx := IndexOf(AImage.Key.FileName, AImage.Quality);
    if Idx < 0 then
    begin
      if FCount = Length(FEntries) then
        SetLength(FEntries, 8 + 2 * Length(FEntries));
      Idx := FCount;
      Inc(FCount);
    end;
    FEntries[Idx].Image := AImage;
    FEntries[Idx].LastUse := FUseCounter;

    EvictToBudget;
    Result := IndexOf(AImage.Key.FileName, AImage.Quality) >= 0;
  finally
    FLock.Release;
  end;
end;

procedure TImageCache.SetWindow(const AFiles: array of string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    SetLength(FWindow, Length(AFiles));
    for I := 0 to High(AFiles) do
      FWindow[I] := AFiles[I];
    EvictToBudget;
  finally
    FLock.Release;
  end;
end;

procedure TImageCache.DropQuality(AQuality: TQualityLevel; const AKeepFile: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    I := 0;
    while I < FCount do
      if (FEntries[I].Image.Quality = AQuality)
        and not SameText(FEntries[I].Image.Key.FileName, AKeepFile) then
        DeleteAt(I)
      else
        Inc(I);
  finally
    FLock.Release;
  end;
end;

{ Caller holds the lock. See "Eviction order" above. }
procedure TImageCache.EvictToBudget;
var
  I, Victim, Rank, VictimRank: Integer;
  Used: Int64;
  Current: string;

  { True if entry A should go before entry B. }
  function GoesFirst(A, RankA, B, RankB: Integer): Boolean;
  var
    OutA, OutB: Boolean;
    QA, QB: TQualityLevel;
  begin
    OutA := RankA < 0;
    OutB := RankB < 0;
    if OutA <> OutB then
      Exit(OutA);                   { outside the window first }
    QA := FEntries[A].Image.Quality;
    QB := FEntries[B].Image.Quality;
    if QA <> QB then
      Exit(QA > QB);                { bigger versions first }
    if OutA then
      Result := FEntries[A].LastUse < FEntries[B].LastUse   { oldest first }
    else
      Result := RankA > RankB;      { least important first }
  end;

begin
  if Length(FWindow) > 0 then
    Current := FWindow[0]
  else
    Current := '';

  repeat
    Used := 0;
    for I := 0 to FCount - 1 do
      Inc(Used, FEntries[I].Image.SizeInBytes);
    if Used <= FBudgetBytes then
      Exit;

    Victim := -1;
    VictimRank := -1;
    for I := 0 to FCount - 1 do
    begin
      if (Current <> '') and SameText(FEntries[I].Image.Key.FileName, Current) then
        Continue;   { the current image is never evicted }
      Rank := WindowRank(FEntries[I].Image.Key.FileName);
      if (Victim < 0) or GoesFirst(I, Rank, Victim, VictimRank) then
      begin
        Victim := I;
        VictimRank := Rank;
      end;
    end;

    if Victim < 0 then
      Exit;   { only the current image is left }
    DeleteAt(Victim);
  until False;
end;

procedure TImageCache.Clear;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      FEntries[I].Image := nil;
    FEntries := nil;
    FCount := 0;
  finally
    FLock.Release;
  end;
end;

function TImageCache.UsedBytes: Int64;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to FCount - 1 do
      Inc(Result, FEntries[I].Image.SizeInBytes);
  finally
    FLock.Release;
  end;
end;

function TImageCache.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FCount;
  finally
    FLock.Release;
  end;
end;

end.
