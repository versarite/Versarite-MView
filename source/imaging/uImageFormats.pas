unit uImageFormats;

{
  Unit: uImageFormats

  Purpose
  -------
  The one list of file formats MView can display (spec §16 #10).
  Directory listing and the loader both use it, so a file that shows
  up in navigation is always a file the loader will try to decode.

  Owns
  ----
  - Nothing: a constant list (SupportedImageExtensions) and one
    stateless routine.

  Knows
  -----
  - Nothing else.

  Responsibilities
  ----------------
  - Know which file extensions are supported: .tif .tiff .jpg .jpeg
    .jpe .png .bmp .gif.
  - IsSupportedImageFile: True if a file name ends in one of them
    (case does not matter).

  Does NOT
  --------
  - Decode anything (uMediaLoader).
  - Check file contents. (Movies, later, are detected by content; see
    spec §8.7.)

  Threads
  -------
  Any thread: a constant and a pure function, no shared state. Used
  while directories are listed (uDirectoryTree, uDirectoryImages) and
  on the decode workers (uMediaLoader).

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      SysUtils

  Used by
  -------
  uDirectoryImages, uDirectoryTree, uMediaLoader

  Notes
  -----
  Only formats that v1 decodes are listed (spec §3.1). Add a format
  here only together with the decoder for it.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

const
  SupportedImageExtensions: array[0..7] of string = (
    '.tif', '.tiff',
    '.jpg', '.jpeg', '.jpe',
    '.png',
    '.bmp',
    '.gif'
  );

function IsSupportedImageFile(const AFileName: string): Boolean;

implementation

function IsSupportedImageFile(const AFileName: string): Boolean;
var
  Ext: string;
  I: Integer;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  for I := Low(SupportedImageExtensions) to High(SupportedImageExtensions) do
    if Ext = SupportedImageExtensions[I] then
      Exit(True);
  Result := False;
end;

end.
