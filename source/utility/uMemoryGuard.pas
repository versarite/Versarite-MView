unit uMemoryGuard;

{
  Unit: uMemoryGuard

  Purpose
  -------
  Refuse decodes that can't fit. A corrupt image header can claim any
  size (a JPEG up to 65535 x 65535, which would be 17 GB of pixels).
  Trying to allocate that makes Windows page the whole machine to disk
  until nothing responds, not even Task Manager. So the loader asks
  first whether the bitmap it is about to make is plausible for this
  computer, and gives an error entry ("too large") instead.

  Owns
  ----
  - CachedPhysical: the physical memory size, asked once from Windows
    (GlobalMemoryStatusEx) and then kept.

  Knows
  -----
  Nothing else.

  Responsibilities
  ----------------
  - PhysicalMemoryBytes: physical memory of this computer in bytes
    (8 GB if unknown, and on systems other than Windows).
  - DecodeFits: True if a width x height BGRA bitmap (plus extra
    bytes, e.g. a screen copy) may be allocated; otherwise a reason
    text for the error placeholder. Also refuses sizes <= 0.
  - EImageTooLarge: the exception for decoders that find out the size
    only while decoding (the loader turns it into an error entry).

  Does NOT
  --------
  - Allocate anything or watch memory use while the program runs.
  - Make the error entry (uMediaLoader and the decoders do).

  Threads
  -------
  Stateless apart from the cache; called from decode workers
  (uMediaLoader, uTiffQuick, uWicDecoder, uGifDecoder) and the UI
  thread (uMView). CachedPhysical is written without a lock; every
  caller would write the same value.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      SysUtils

  Used by
  -------
  uGifDecoder, uMView, uMediaLoader, uTiffQuick, uWicDecoder

  Rule
  ----
  At most half of the physical memory for one bitmap, and never more
  than MaxDecodePixels (2 gigapixels = 8 GB as BGRA). Both are far
  above any real camera or scanner image the viewer is meant for;
  microscopy mosaics larger than that need a tiled viewer anyway.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type
  { Raised by decoders that find out the size only while decoding (the
    loader turns it into an error entry). Not EOutOfMemory: FPC keeps
    that one as a preallocated instance and doesn't free new ones. }
  EImageTooLarge = class(Exception);

const
  { 2 gigapixels = 8 GB as BGRA. }
  MaxDecodePixels = Int64(2000000000);

{ Physical memory of this computer in bytes (8 GB if unknown). }
function PhysicalMemoryBytes: Int64;

{ True if a AWidth x AHeight BGRA bitmap (plus AExtraBytes, e.g. a
  screen copy) may be allocated. Otherwise AReason says why, for the
  error placeholder. }
function DecodeFits(AWidth, AHeight: Int64; AExtraBytes: Int64; out AReason: string): Boolean;

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

function GuardGlobalMemoryStatusEx(var ABuffer: TMemStatusEx): LongBool; stdcall;
  external 'kernel32.dll' name 'GlobalMemoryStatusEx';
{$ENDIF}

var
  CachedPhysical: Int64 = 0;

function PhysicalMemoryBytes: Int64;
{$IFDEF WINDOWS}
var
  Status: TMemStatusEx;
{$ENDIF}
begin
  if CachedPhysical > 0 then
    Exit(CachedPhysical);
  Result := Int64(8) * 1024 * 1024 * 1024;
  {$IFDEF WINDOWS}
  FillChar(Status, SizeOf(Status), 0);
  Status.dwLength := SizeOf(Status);
  if GuardGlobalMemoryStatusEx(Status) and (Status.ullTotalPhys > 0) then
    Result := Int64(Status.ullTotalPhys);
  {$ENDIF}
  CachedPhysical := Result;
end;

function DecodeFits(AWidth, AHeight: Int64; AExtraBytes: Int64; out AReason: string): Boolean;
var
  Pixels, Bytes, Limit: Int64;
begin
  AReason := '';
  if (AWidth <= 0) or (AHeight <= 0) then
  begin
    AReason := Format('invalid image size %d x %d', [AWidth, AHeight]);
    Exit(False);
  end;
  Pixels := AWidth * AHeight;
  Bytes := Pixels * 4 + AExtraBytes;
  Limit := PhysicalMemoryBytes div 2;
  if (Pixels > MaxDecodePixels) or (Bytes > Limit) then
  begin
    AReason := Format('image too large for this computer: %d x %d would need %d MB (limit %d MB)',
      [AWidth, AHeight, Bytes div (1024 * 1024), Limit div (1024 * 1024)]);
    Exit(False);
  end;
  Result := True;
end;

end.
