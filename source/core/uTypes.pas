unit uTypes;

{
  Unit: uTypes

  Purpose
  -------
  Small types shared by several subsystems, plus their conversion to
  and from the names used in MView.ini.

  Owns
  ----
  - Nothing: types, name tables and stateless routines.

  Knows
  -----
  - Nothing else.

  Responsibilities
  ----------------
  - Declare TSortMode, TFitMode, TInterpolationMode, TWrapScope,
    TQualityLevel, TImageKey and TCancelCheck.
  - Compare two image keys (SameImageKey: file name ignoring case,
    size and time).
  - Convert TSortMode and TWrapScope to and from their MView.ini
    names. An unknown name gives the caller's default. For the wrap
    scope, "Folder" and "Directory" are read as wsFolder too.

  Does NOT
  --------
  - Contain logic beyond those conversions.
  - Read or write MView.ini (uConfig).

  Threads
  -------
  No state; the routines are safe on any thread. A TCancelCheck must
  be safe to call from any thread (see its comment).

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      SysUtils

  Used by
  -------
  uConfig, uDecodedImage, uDirectoryImages, uDirectoryTree,
  uGifDecoder, uIOGate, uImageCache, uImageSaver, uJobQueue,
  uJobScheduler, uJpegDecoder, uMView, uMediaLoader, uNavigator,
  uTiffQuick, uWicDecoder
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type

  {
    TSortMode

    Defines the ordering of media items inside a directory.
    File names are always compared naturally (Image2 < Image10).
    Images with the same date are ordered by name.

    Default: smDateDescending (newest first).
  }

  TSortMode = (
    smDateDescending,
    smDateAscending,
    smFileNameAscending,
    smFileNameDescending
  );

  TFitMode = (
    fmOriginal,
    fmFitWindow,
    fmFitWidth,
    fmFitHeight
  );

  TInterpolationMode = (
    imNearest,
    imLinear,
    imCubic,
    imLanczos
  );

  {
    TWrapScope (spec §3.1, §14)

    wsTree    Last image of a folder -> first image of the next folder
              that has images. Last folder -> first folder.
    wsFolder  Last image of a folder -> first image of the same folder.
              Only the directory commands (and gestures) change
              folders. Written as "Dir" in MView.ini; "Folder" and
              "Directory" are read too.
  }

  TWrapScope = (
    wsFolder,
    wsTree
  );

  { Image quality levels (spec §7.1). Ordinal = quality. }
  TQualityLevel = (
    qlNone,
    qlPreview,
    qlScreen,
    qlFull
  );

  {
    TImageKey (spec §5.6)

    Identifies one version of one file. If the file is replaced, its
    size or time changes, and so does the key.
  }

  TImageKey = record
    FileName: string;
    FileSize: Int64;
    FileTime: TDateTime;
  end;

  {
    TCancelCheck

    Asked regularly by long-running work (decoding, directory scans).
    Returns True when the work is no longer wanted and should stop.
    Must be safe to call from any thread.
  }

  TCancelCheck = function: Boolean of object;

function SameImageKey(const A, B: TImageKey): Boolean;

function SortModeToString(AMode: TSortMode): string;
function StringToSortMode(const AText: string; ADefault: TSortMode): TSortMode;

function WrapScopeToString(AScope: TWrapScope): string;
function StringToWrapScope(const AText: string; ADefault: TWrapScope): TWrapScope;

implementation

const
  SortModeNames: array[TSortMode] of string = (
    'DateDescending',
    'DateAscending',
    'FileNameAscending',
    'FileNameDescending'
  );

  WrapScopeNames: array[TWrapScope] of string = (
    'Dir',
    'Tree'
  );

function SameImageKey(const A, B: TImageKey): Boolean;
begin
  Result := SameText(A.FileName, B.FileName)
    and (A.FileSize = B.FileSize)
    and (A.FileTime = B.FileTime);
end;

function SortModeToString(AMode: TSortMode): string;
begin
  Result := SortModeNames[AMode];
end;

function StringToSortMode(const AText: string; ADefault: TSortMode): TSortMode;
var
  Mode: TSortMode;
begin
  for Mode := Low(TSortMode) to High(TSortMode) do
    if SameText(AText, SortModeNames[Mode]) then
      Exit(Mode);
  Result := ADefault;
end;

function WrapScopeToString(AScope: TWrapScope): string;
begin
  Result := WrapScopeNames[AScope];
end;

function StringToWrapScope(const AText: string; ADefault: TWrapScope): TWrapScope;
var
  Scope: TWrapScope;
begin
  for Scope := Low(TWrapScope) to High(TWrapScope) do
    if SameText(AText, WrapScopeNames[Scope]) then
      Exit(Scope);
  { Other names for the same thing (older ini files, spec v1.2c). }
  if SameText(AText, 'Folder') or SameText(AText, 'Directory') then
    Exit(wsFolder);
  Result := ADefault;
end;

end.
