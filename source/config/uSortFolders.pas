unit uSortFolders;

{
  Unit: uSortFolders

  Purpose
  -------
  The folders of the sort panel (Phase G, G1): the slots the user sorts
  images into (left click on the panel = copy, right click = move), and
  the folders used recently. Only the list and its place in MView.ini;
  no drawing, no file work.

  Owns
  ----
  - FSlots: the slots (folder, name, colour, icon file), in panel order.
  - FRecent: the recently assigned folders, newest first, at most
    MaxRecentFolders.

  Knows
  -----
  - The TCustomIniFile handed to LoadFromIni / SaveToIni (TConfig's).

  Responsibilities
  ----------------
  - Slots: add (a folder dropped on "+"), replace a slot's folder, set
    its colour or icon, remove it. A new slot gets the folder's own name
    ("D:\Sorted\Good" -> "Good") and the first colour not in use.
  - Recent folders: every folder assigned to a slot goes to the front of
    the list (no duplicates).
  - Read and write the [Sort] keys Slot<n>Folder / Name / Color / Icon
    and Recent<n>: one key per value, so any folder name is safe. Old
    keys of removed slots are deleted when writing.
  - Slot colours by name (Green, Blue, Red, Yellow, Orange, Purple,
    Cyan, Grey) and as RGB for drawing.

  Does NOT
  --------
  - Check whether a folder exists (that reads the disk: the file mover
    does it on its thread).
  - Draw the panel, copy or move files, or read the other [Sort] keys
    (TConfig: EdgeDelayMs, Pinned, DeletedFolder, IconFolder,
    TotalCommander).

  Threads
  -------
  UI thread only.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      Classes, SysUtils, IniFiles

  Used by
  -------
  uConfig, uMView, uSortPanel, umainform
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  IniFiles;

const
  SortSection = 'Sort';
  MaxSortSlots = 64;
  MaxRecentFolders = 8;

type

  TSlotColor = (scGreen, scBlue, scRed, scYellow, scOrange, scPurple, scCyan, scGrey);

  TSortSlot = record
    Folder: string;     { full path, without trailing delimiter }
    Name: string;       { shown on the panel }
    Color: TSlotColor;
    Icon: string;       { icon file (name in the icon folder, or a full path); '' = none }
  end;

  TSortFolders = class(TObject)
  private
    FSlots: array of TSortSlot;
    FRecent: TStringList;
    function FirstFreeColor: TSlotColor;
  public
    constructor Create;
    destructor Destroy; override;

    function Count: Integer;
    function Slot(AIndex: Integer): TSortSlot;

    { AIndex = Count adds a slot (when there is room); otherwise the
      slot's folder is replaced (its name follows the new folder, its
      colour and icon stay). Returns the slot's index, -1 if not done. }
    function SetFolder(AIndex: Integer; const AFolder: string): Integer;
    procedure SetColor(AIndex: Integer; AColor: TSlotColor);
    procedure SetIcon(AIndex: Integer; const AIcon: string);
    procedure SetName(AIndex: Integer; const AName: string);
    procedure Remove(AIndex: Integer);
    procedure Move(AFrom, ATo: Integer);

    procedure AddRecent(const AFolder: string);
    function Recent: TStrings;

    procedure Assign(ASource: TSortFolders);
    { No slots, no recent folders. }
    procedure Clear;
    procedure LoadFromIni(AIni: TCustomIniFile);
    procedure SaveToIni(AIni: TCustomIniFile);
  end;

function SlotColorName(AColor: TSlotColor): string;
function ParseSlotColor(const AName: string; ADefault: TSlotColor): TSlotColor;
{ $00BBGGRR, as TColor. }
function SlotColorValue(AColor: TSlotColor): LongWord;
{ The last part of a folder: "D:\Sorted\Good" -> "Good" ("D:\" -> "D:"). }
function FolderDisplayName(const AFolder: string): string;
{ The icon name a slot finds by itself (stage 2): its folder's last part
  without characters a file name can't have ("D:\" -> "D"); 'icon' if
  nothing is left. "D:\Sorted\Good" -> "Good" (Good.ico / Good.png). }
function IconBaseName(const AFolder: string): string;

implementation

const
  ColorNames: array[TSlotColor] of string =
    ('Green', 'Blue', 'Red', 'Yellow', 'Orange', 'Purple', 'Cyan', 'Grey');
  { $00BBGGRR }
  ColorValues: array[TSlotColor] of LongWord =
    ($0040A040, $00D07030, $003838D0, $0020C8E0, $002090F0, $00B04890, $00C0B030, $00909090);

function SlotColorName(AColor: TSlotColor): string;
begin
  Result := ColorNames[AColor];
end;

function ParseSlotColor(const AName: string; ADefault: TSlotColor): TSlotColor;
var
  C: TSlotColor;
begin
  for C := Low(TSlotColor) to High(TSlotColor) do
    if SameText(Trim(AName), ColorNames[C]) then
      Exit(C);
  Result := ADefault;
end;

function SlotColorValue(AColor: TSlotColor): LongWord;
begin
  Result := ColorValues[AColor];
end;

function FolderDisplayName(const AFolder: string): string;
var
  F: string;
begin
  F := ExcludeTrailingPathDelimiter(Trim(AFolder));
  Result := ExtractFileName(F);
  if Result = '' then
    Result := F;
end;

{ TSortFolders }

constructor TSortFolders.Create;
begin
  inherited Create;
  FRecent := TStringList.Create;
end;

destructor TSortFolders.Destroy;
begin
  FRecent.Free;
  inherited Destroy;
end;

function TSortFolders.Count: Integer;
begin
  Result := Length(FSlots);
end;

function TSortFolders.Slot(AIndex: Integer): TSortSlot;
begin
  Result := FSlots[AIndex];
end;

function TSortFolders.FirstFreeColor: TSlotColor;
var
  C: TSlotColor;
  I: Integer;
  Used: Boolean;
begin
  for C := Low(TSlotColor) to High(TSlotColor) do
  begin
    Used := False;
    for I := 0 to High(FSlots) do
      if FSlots[I].Color = C then
        Used := True;
    if not Used then
      Exit(C);
  end;
  { All in use: go round. }
  Result := TSlotColor(Length(FSlots) mod (Ord(High(TSlotColor)) + 1));
end;

function TSortFolders.SetFolder(AIndex: Integer; const AFolder: string): Integer;
var
  F: string;
begin
  Result := -1;
  F := ExcludeTrailingPathDelimiter(Trim(AFolder));
  if F = '' then
    Exit;
  if (AIndex = Length(FSlots)) and (Length(FSlots) < MaxSortSlots) then
  begin
    SetLength(FSlots, Length(FSlots) + 1);
    FSlots[AIndex].Color := FirstFreeColor;
    FSlots[AIndex].Icon := '';
  end
  else if (AIndex < 0) or (AIndex >= Length(FSlots)) then
    Exit;
  FSlots[AIndex].Folder := F;
  FSlots[AIndex].Name := FolderDisplayName(F);
  AddRecent(F);
  Result := AIndex;
end;

procedure TSortFolders.SetColor(AIndex: Integer; AColor: TSlotColor);
begin
  if (AIndex >= 0) and (AIndex < Length(FSlots)) then
    FSlots[AIndex].Color := AColor;
end;

procedure TSortFolders.SetIcon(AIndex: Integer; const AIcon: string);
begin
  if (AIndex >= 0) and (AIndex < Length(FSlots)) then
    FSlots[AIndex].Icon := Trim(AIcon);
end;

procedure TSortFolders.SetName(AIndex: Integer; const AName: string);
begin
  if (AIndex >= 0) and (AIndex < Length(FSlots)) and (Trim(AName) <> '') then
    FSlots[AIndex].Name := Trim(AName);
end;

procedure TSortFolders.Remove(AIndex: Integer);
var
  I: Integer;
begin
  if (AIndex < 0) or (AIndex >= Length(FSlots)) then
    Exit;
  for I := AIndex to High(FSlots) - 1 do
    FSlots[I] := FSlots[I + 1];
  SetLength(FSlots, Length(FSlots) - 1);
end;

procedure TSortFolders.Move(AFrom, ATo: Integer);
var
  S: TSortSlot;
  I: Integer;
begin
  if (AFrom < 0) or (AFrom >= Length(FSlots)) or (ATo < 0) or (ATo >= Length(FSlots))
    or (AFrom = ATo) then
    Exit;
  S := FSlots[AFrom];
  if AFrom < ATo then
    for I := AFrom to ATo - 1 do
      FSlots[I] := FSlots[I + 1]
  else
    for I := AFrom downto ATo + 1 do
      FSlots[I] := FSlots[I - 1];
  FSlots[ATo] := S;
end;

procedure TSortFolders.AddRecent(const AFolder: string);
var
  F: string;
  I: Integer;
begin
  F := ExcludeTrailingPathDelimiter(Trim(AFolder));
  if F = '' then
    Exit;
  for I := FRecent.Count - 1 downto 0 do
    if SameText(FRecent[I], F) then
      FRecent.Delete(I);
  FRecent.Insert(0, F);
  while FRecent.Count > MaxRecentFolders do
    FRecent.Delete(FRecent.Count - 1);
end;

function TSortFolders.Recent: TStrings;
begin
  Result := FRecent;
end;

procedure TSortFolders.Assign(ASource: TSortFolders);
var
  I: Integer;
begin
  SetLength(FSlots, Length(ASource.FSlots));
  for I := 0 to High(FSlots) do
    FSlots[I] := ASource.FSlots[I];
  FRecent.Assign(ASource.FRecent);
end;

procedure TSortFolders.Clear;
begin
  SetLength(FSlots, 0);
  FRecent.Clear;
end;

procedure TSortFolders.LoadFromIni(AIni: TCustomIniFile);
var
  I: Integer;
  F, Key: string;
begin
  SetLength(FSlots, 0);
  FRecent.Clear;
  { Slots are numbered 1..n without gaps when MView writes them; a gap
    left by hand is skipped over. }
  for I := 1 to MaxSortSlots do
  begin
    Key := 'Slot' + IntToStr(I);
    F := ExcludeTrailingPathDelimiter(Trim(AIni.ReadString(SortSection, Key + 'Folder', '')));
    if F = '' then
      Continue;
    SetLength(FSlots, Length(FSlots) + 1);
    with FSlots[High(FSlots)] do
    begin
      Folder := F;
      Name := Trim(AIni.ReadString(SortSection, Key + 'Name', ''));
      if Name = '' then
        Name := FolderDisplayName(F);
      Color := ParseSlotColor(AIni.ReadString(SortSection, Key + 'Color', ''),
        TSlotColor((Length(FSlots) - 1) mod (Ord(High(TSlotColor)) + 1)));
      Icon := Trim(AIni.ReadString(SortSection, Key + 'Icon', ''));
    end;
  end;
  for I := 1 to MaxRecentFolders do
  begin
    F := ExcludeTrailingPathDelimiter(Trim(AIni.ReadString(SortSection, 'Recent' + IntToStr(I), '')));
    if (F <> '') and (FRecent.IndexOf(F) < 0) then
      FRecent.Add(F);
  end;
end;

procedure TSortFolders.SaveToIni(AIni: TCustomIniFile);
var
  I: Integer;
  Key: string;
begin
  { Keys of slots that no longer exist go. }
  for I := Length(FSlots) + 1 to MaxSortSlots do
  begin
    Key := 'Slot' + IntToStr(I);
    if AIni.ValueExists(SortSection, Key + 'Folder') then
    begin
      AIni.DeleteKey(SortSection, Key + 'Folder');
      AIni.DeleteKey(SortSection, Key + 'Name');
      AIni.DeleteKey(SortSection, Key + 'Color');
      AIni.DeleteKey(SortSection, Key + 'Icon');
    end;
  end;
  for I := 0 to High(FSlots) do
  begin
    Key := 'Slot' + IntToStr(I + 1);
    AIni.WriteString(SortSection, Key + 'Folder', FSlots[I].Folder);
    AIni.WriteString(SortSection, Key + 'Name', FSlots[I].Name);
    AIni.WriteString(SortSection, Key + 'Color', ColorNames[FSlots[I].Color]);
    AIni.WriteString(SortSection, Key + 'Icon', FSlots[I].Icon);
  end;
  for I := 1 to MaxRecentFolders do
    if I <= FRecent.Count then
      AIni.WriteString(SortSection, 'Recent' + IntToStr(I), FRecent[I - 1])
    else if AIni.ValueExists(SortSection, 'Recent' + IntToStr(I)) then
      AIni.DeleteKey(SortSection, 'Recent' + IntToStr(I));
end;

function IconBaseName(const AFolder: string): string;
var
  I: Integer;
begin
  Result := FolderDisplayName(AFolder);
  for I := Length(Result) downto 1 do
    if Result[I] in ['\', '/', ':', '*', '?', '"', '<', '>', '|'] then
      Delete(Result, I, 1);
  Result := Trim(Result);
  if Result = '' then
    Result := 'icon';
end;

end.
