unit uGifDecoder;

{$mode ObjFPC}{$H+}
{ Decoding speed matters (every frame of an animation), whatever the
  project's optimisation level. }
{$OPTIMIZATION ON}

{
  Unit: uGifDecoder

  Purpose
  -------
  GIF, still and animated (spec §3, §8.7). Own decoder instead of
  BGRABitmap's reader, because MView needs:
  - the first frame alone, quickly (the Screen quality level: browsing
    and preloading never decode whole animations);
  - cancellation and a memory limit, like every other decoder;
  - damaged files that still show what they contain (a GIF cut off
    while copying plays the frames that are there);
  - frames kept small: 8-bit indices plus a palette per frame, a
    quarter of BGRA pixels (126 frames of 800 x 704: 70 MB, not 284).

  Owns
  ----
  - TGifAnimation: its TGifFrame objects (rectangle, palette indices,
    palette, delay, disposal), freed with it.
  - TGifCursor: its canvas (TBGRABitmap, the picture built so far)
    and the pixels saved under a disposal-3 frame (FSaved).
  - DecodeGif, per call: the compressed-data and interlace buffers.
    The TGifAnimation it returns goes to the caller.

  Knows
  -----
  - The file data handed to DecodeGif (the caller's memory).
  - The cancel callback handed in.
  - TGifCursor: its TGifAnimation, which must outlive it.
  - uMemoryGuard.DecodeFits, for the size checks.

  Responsibilities
  ----------------
  - IsGifData: the data starts like a GIF.
  - DecodeGif: the blocks, each frame's LZW data, graphic control
    (disposal, delay, transparency) and loop count. On request only
    the first frame (AMore says whether more follow). A memory limit
    for the frames (the first is always kept; the Note says "only the
    first N frames"). The picture must pass DecodeFits; a frame far
    larger than the picture (more than 4 times, and more than 16 M
    pixels) counts as damage. Cancel is checked before each frame and
    every 262144 pixels of LZW output (EGifCancelled).
  - GifLzwDecode: the LZW decoder alone, for the tests.
  - TGifCursor: whole frames from the stored ones.

  Does NOT
  --------
  - Read files (uMediaLoader reads the bytes, in parts).
  - Time or play the frames (TFrameClock in uAnimation, driven by
    TMView).
  - Draw (the renderers; they draw transparent pixels black).

  Threads
  -------
  DecodeGif runs on a decode worker; no shared state. A finished
  TGifAnimation is read only, so any thread may read it. A TGifCursor
  belongs to one thread: TMView's on the UI thread; the loader also
  uses one briefly on the worker to get frame 0.

  Uses (MView units)
  ------------------
  interface:      uTypes, uAnimation, uMemoryGuard
  Libraries:      Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uMediaLoader

  Parts
  -----
  - DecodeGif (worker): reads the blocks, decodes each frame's LZW
    data into palette indices. Gives a TGifAnimation.
  - TGifCursor (UI thread, uAnimation): builds the whole picture frame
    by frame (a frame usually changes only a rectangle), following the
    frame's disposal method.

  Behaviour
  ---------
  Where the GIF format leaves room (as web browsers do):
  - The picture starts transparent; transparent pixels are drawn black
    by the renderers. Disposal 2 ("background") clears to transparent.
  - A delay of 0 or 1 (1/100 s) plays as 100 ms.
  - The picture is the logical screen size; frames are clipped to it
    (as the GIF test suite in test\images\gif\frames expects). Only a
    logical screen of 0 x 0 takes the first frame's size.
  - A frame whose LZW data is damaged or cut off is drawn as far as it
    was decoded; the rest of its rectangle stays as it was.
  - Unknown blocks end the file (what came before is kept).
  - Loop count (NETSCAPE2.0 / ANIMEXTS1.0 extension): 0 = forever,
    n = n repeats after the first play; without the extension the
    animation plays once and stops on its last frame.

  Verification
  ------------
  Checked against Pillow, frame by frame, on real and synthetic GIFs
  (disposal 1/2/3, transparency, interlaced, local palettes, frames
  outside the logical screen, cut off): identical (Day 19).
}

interface

uses
  Classes,
  SysUtils,
  Math,
  BGRABitmap,
  BGRABitmapTypes,
  uTypes,
  uAnimation,
  uMemoryGuard;

type

  EGifCancelled = class(Exception);

  TGifPalette = array[0..255] of TBGRAPixel;

  { One frame as stored in the file: a rectangle of palette indices. }
  TGifFrame = class(TObject)
  public
    X, Y, W, H: Integer;         { rectangle on the picture }
    Interlaced: Boolean;         { as stored; Indices are in row order }
    Produced: Integer;           { pixels decoded, in the file's order }
    Transparent: Integer;        { palette index, or -1 }
    Disposal: Integer;           { 0..3; others act like 0 }
    DelayMs: Integer;
    Palette: TGifPalette;        { alpha 255 everywhere }
    Indices: TBytes;             { W * H, top row first }
    { How many pixels at the start of row ARow (0 = the frame's top
      row) were decoded: W, fewer, or 0. }
    function DecodedInRow(ARow: Integer): Integer;
  end;

  TGifAnimation = class(TAnimation)
  private
    FWidth: Integer;
    FHeight: Integer;
    FFrames: array of TGifFrame;
    FCount: Integer;
    FBytes: Int64;
    FNote: string;
    FPlayCount: Integer;
    procedure AddFrame(AFrame: TGifFrame);
  public
    destructor Destroy; override;
    function Width: Integer; override;
    function Height: Integer; override;
    function FrameCount: Integer; override;
    function FrameDelayMs(AIndex: Integer): Integer; override;
    function SizeInBytes: Int64; override;
    function Note: string; override;
    function PlayCount: Integer; override;
    function CreateCursor: TAnimationCursor; override;
    function Frames(AIndex: Integer): TGifFrame;
  end;

  TGifCursor = class(TAnimationCursor)
  private
    FAnim: TGifAnimation;
    FCanvas: TBGRABitmap;
    FCurrent: Integer;           { frame drawn on FCanvas; -1 = none }
    FSaved: array of TBGRAPixel; { under the current frame (disposal 3) }
    procedure Reset;
    function ClipRect(AFrame: TGifFrame; out X0, Y0, X1, Y1: Integer): Boolean;
    procedure SaveUnder(AFrame: TGifFrame);
    procedure ApplyDisposal(AFrame: TGifFrame);
    procedure DrawFrame(AFrame: TGifFrame);
  public
    constructor Create(AAnim: TGifAnimation);
    destructor Destroy; override;
    { Builds up to frame AIndex without copying (the picture so far is
      Canvas). }
    procedure StepTo(AIndex: Integer);
    function Frame(AIndex: Integer): TBGRABitmap; override;
    property Canvas: TBGRABitmap read FCanvas;
  end;

{ True if the data starts like a GIF file. }
function IsGifData(AData: PByte; ASize: Int64): Boolean;

{ Reads a GIF held in memory.
  AComplete: AData is the whole file (False: only its start was read).
  AFirstOnly: stop after the first frame. AMore then says whether
  another frame follows (also True if the data ended first and
  AComplete is False).
  AMaxBytes: memory for the frames; frames after that are left out and
  the animation's Note says so (the first frame is always kept).
  AIncomplete: the data ended inside a frame (a cut-off file, or only
  the start of it was read).
  Returns nil and AError if there is no frame to show. Raises
  EGifCancelled when ACancel asks. }
function DecodeGif(AData: PByte; ASize: Int64; AComplete, AFirstOnly: Boolean;
  AMaxBytes: Int64; ACancel: TCancelCheck;
  out AMore, AIncomplete: Boolean; out AError: string): TGifAnimation;

{ The decoder alone (for the tests). Decodes GIF LZW data into up to
  ACount indices; returns how many were decoded. }
function GifLzwDecode(AData: PByte; ASize: Integer; AMinCodeSize: Integer;
  AOut: PByte; ACount: Integer; ACancel: TCancelCheck): Integer;

implementation

const
  MaxLzwCodes = 4096;
  LzwCheckEvery = 262144;        { pixels between cancel checks }
  DefaultDelayMs = 100;
  { Frames up to this size are allowed whatever the picture size. }
  MinFrameLimitPixels = 16 * 1024 * 1024;

{ Position of row ARow in the file for an interlaced frame of AHeight
  rows: pass 1 every 8th row from 0, pass 2 every 8th from 4, pass 3
  every 4th from 2, pass 4 every 2nd from 1. }
function InterlacedRank(ARow, AHeight: Integer): Integer;
var
  N1, N2, N3: Integer;
begin
  N1 := (AHeight + 7) div 8;
  N2 := (AHeight + 3) div 8;
  N3 := (AHeight + 1) div 4;
  if ARow mod 8 = 0 then
    Result := ARow div 8
  else if ARow mod 8 = 4 then
    Result := N1 + (ARow - 4) div 8
  else if ARow mod 4 = 2 then
    Result := N1 + N2 + (ARow - 2) div 4
  else
    Result := N1 + N2 + N3 + (ARow - 1) div 2;
end;

{ TGifFrame }

function TGifFrame.DecodedInRow(ARow: Integer): Integer;
var
  Rank, FullRows: Integer;
begin
  Result := 0;
  if (W <= 0) or (ARow < 0) or (ARow >= H) then
    Exit;
  if Interlaced then
    Rank := InterlacedRank(ARow, H)
  else
    Rank := ARow;
  FullRows := Produced div W;
  if Rank < FullRows then
    Result := W
  else if Rank = FullRows then
    Result := Produced mod W;
end;

{ TGifAnimation }

destructor TGifAnimation.Destroy;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    FFrames[I].Free;
  FFrames := nil;
  inherited Destroy;
end;

procedure TGifAnimation.AddFrame(AFrame: TGifFrame);
begin
  if FCount = Length(FFrames) then
    SetLength(FFrames, 16 + 2 * Length(FFrames));
  FFrames[FCount] := AFrame;
  Inc(FCount);
  Inc(FBytes, Int64(Length(AFrame.Indices)) + AFrame.InstanceSize);
end;

function TGifAnimation.Width: Integer;
begin
  Result := FWidth;
end;

function TGifAnimation.Height: Integer;
begin
  Result := FHeight;
end;

function TGifAnimation.FrameCount: Integer;
begin
  Result := FCount;
end;

function TGifAnimation.FrameDelayMs(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex < FCount) then
    Result := FFrames[AIndex].DelayMs
  else
    Result := DefaultDelayMs;
end;

function TGifAnimation.SizeInBytes: Int64;
begin
  Result := FBytes;
end;

function TGifAnimation.Note: string;
begin
  Result := FNote;
end;

function TGifAnimation.PlayCount: Integer;
begin
  Result := FPlayCount;
end;

function TGifAnimation.CreateCursor: TAnimationCursor;
begin
  Result := TGifCursor.Create(Self);
end;

function TGifAnimation.Frames(AIndex: Integer): TGifFrame;
begin
  Result := FFrames[AIndex];
end;

{ TGifCursor }

constructor TGifCursor.Create(AAnim: TGifAnimation);
begin
  inherited Create;
  FAnim := AAnim;
  FCanvas := TBGRABitmap.Create(AAnim.Width, AAnim.Height);
  Reset;
end;

destructor TGifCursor.Destroy;
begin
  FCanvas.Free;
  inherited Destroy;
end;

procedure TGifCursor.Reset;
begin
  { Transparent: all four bytes 0. }
  FillChar(FCanvas.Data^, Int64(FCanvas.NbPixels) * SizeOf(TBGRAPixel), 0);
  FCurrent := -1;
  FSaved := nil;
end;

{ The part of the frame's rectangle on the picture. False if none. }
function TGifCursor.ClipRect(AFrame: TGifFrame; out X0, Y0, X1, Y1: Integer): Boolean;
begin
  X0 := AFrame.X;
  Y0 := AFrame.Y;
  X1 := Min(Int64(AFrame.X) + AFrame.W, Int64(FCanvas.Width));
  Y1 := Min(Int64(AFrame.Y) + AFrame.H, Int64(FCanvas.Height));
  Result := (X0 < X1) and (Y0 < Y1);
end;

procedure TGifCursor.SaveUnder(AFrame: TGifFrame);
var
  X0, Y0, X1, Y1, Row, RowW: Integer;
begin
  FSaved := nil;
  if not ClipRect(AFrame, X0, Y0, X1, Y1) then
    Exit;
  RowW := X1 - X0;
  SetLength(FSaved, Int64(RowW) * (Y1 - Y0));
  for Row := Y0 to Y1 - 1 do
    Move((FCanvas.ScanLine[Row] + X0)^, FSaved[Int64(Row - Y0) * RowW],
      RowW * SizeOf(TBGRAPixel));
end;

procedure TGifCursor.ApplyDisposal(AFrame: TGifFrame);
var
  X0, Y0, X1, Y1, Row, RowW: Integer;
begin
  if not ClipRect(AFrame, X0, Y0, X1, Y1) then
    Exit;
  RowW := X1 - X0;
  case AFrame.Disposal of
    2:
      for Row := Y0 to Y1 - 1 do
        FillChar((FCanvas.ScanLine[Row] + X0)^, RowW * SizeOf(TBGRAPixel), 0);
    3:
      if Length(FSaved) = Int64(RowW) * (Y1 - Y0) then
        for Row := Y0 to Y1 - 1 do
          Move(FSaved[Int64(Row - Y0) * RowW], (FCanvas.ScanLine[Row] + X0)^,
            RowW * SizeOf(TBGRAPixel));
  end;
end;

procedure TGifCursor.DrawFrame(AFrame: TGifFrame);
var
  X0, Y0, X1, Y1, Row, N, I, T: Integer;
  Src: PByte;
  Dst: PBGRAPixel;
  Idx: Byte;
begin
  if not ClipRect(AFrame, X0, Y0, X1, Y1) then
    Exit;
  T := AFrame.Transparent;
  for Row := 0 to Y1 - Y0 - 1 do
  begin
    N := AFrame.DecodedInRow(Row);
    if N > X1 - X0 then
      N := X1 - X0;
    if N <= 0 then
      Continue;
    Src := @AFrame.Indices[Int64(Row) * AFrame.W];
    Dst := FCanvas.ScanLine[Y0 + Row] + X0;
    if T < 0 then
      for I := 0 to N - 1 do
        Dst[I] := AFrame.Palette[Src[I]]
    else
      for I := 0 to N - 1 do
      begin
        Idx := Src[I];
        if Idx <> T then
          Dst[I] := AFrame.Palette[Idx];
      end;
  end;
end;

procedure TGifCursor.StepTo(AIndex: Integer);
var
  F: TGifFrame;
begin
  if FAnim.FrameCount = 0 then
    Exit;
  if AIndex < 0 then
    AIndex := 0;
  if AIndex >= FAnim.FrameCount then
    AIndex := FAnim.FrameCount - 1;
  if AIndex < FCurrent then
    Reset;
  while FCurrent < AIndex do
  begin
    if FCurrent >= 0 then
      ApplyDisposal(FAnim.Frames(FCurrent));
    Inc(FCurrent);
    F := FAnim.Frames(FCurrent);
    if F.Disposal = 3 then
      SaveUnder(F)
    else
      FSaved := nil;
    DrawFrame(F);
  end;
  FCanvas.InvalidateBitmap;
end;

function TGifCursor.Frame(AIndex: Integer): TBGRABitmap;
begin
  StepTo(AIndex);
  Result := TBGRABitmap.Create(FCanvas.Width, FCanvas.Height);
  Move(FCanvas.Data^, Result.Data^, Int64(FCanvas.NbPixels) * SizeOf(TBGRAPixel));
  Result.InvalidateBitmap;
end;

{ LZW }

function GifLzwDecode(AData: PByte; ASize: Integer; AMinCodeSize: Integer;
  AOut: PByte; ACount: Integer; ACancel: TCancelCheck): Integer;
var
  { Every table entry is a string already in the output: where it
    starts and how long it is. Decoding a code is a short copy. }
  EntryPos: array[0..MaxLzwCodes - 1] of Integer;
  EntryLen: array[0..MaxLzwCodes - 1] of Integer;
  ClearCode, EndCode, CodeSize, CodeMask, NextCode, Code: Integer;
  HavePrev: Boolean;
  PrevPos, PrevLen, CurPos, CurLen, L, K, Produced, NextCheck: Integer;
  InPos: Integer;
  BitBuf: Cardinal;
  BitCount: Integer;
  Src, Dst: PByte;
begin
  Result := 0;
  if (AMinCodeSize < 1) or (AMinCodeSize > 11) or (ACount <= 0) or (AData = nil) then
    Exit;
  ClearCode := 1 shl AMinCodeSize;
  EndCode := ClearCode + 1;
  CodeSize := AMinCodeSize + 1;
  CodeMask := (1 shl CodeSize) - 1;
  NextCode := EndCode + 1;
  HavePrev := False;
  PrevPos := 0;
  PrevLen := 0;
  BitBuf := 0;
  BitCount := 0;
  InPos := 0;
  Produced := 0;
  NextCheck := LzwCheckEvery;

  while Produced < ACount do
  begin
    { Codes are packed least significant bit first. }
    while BitCount < CodeSize do
    begin
      if InPos >= ASize then
        Exit(Produced);
      BitBuf := BitBuf or (Cardinal(AData[InPos]) shl BitCount);
      Inc(BitCount, 8);
      Inc(InPos);
    end;
    Code := Integer(BitBuf and Cardinal(CodeMask));
    BitBuf := BitBuf shr CodeSize;
    Dec(BitCount, CodeSize);

    if Code = ClearCode then
    begin
      CodeSize := AMinCodeSize + 1;
      CodeMask := (1 shl CodeSize) - 1;
      NextCode := EndCode + 1;
      HavePrev := False;
      Continue;
    end;
    if Code = EndCode then
      Break;

    CurPos := Produced;
    if Code < ClearCode then
    begin
      AOut[Produced] := Byte(Code);
      Inc(Produced);
      CurLen := 1;
    end
    else if (Code > EndCode) and (Code < NextCode) then
    begin
      CurLen := EntryLen[Code];
      L := CurLen;
      if L > ACount - Produced then
        L := ACount - Produced;
      { The entry lies wholly before Produced: no overlap. }
      Src := AOut + EntryPos[Code];
      Dst := AOut + Produced;
      if L <= 8 then
        for K := 0 to L - 1 do
          Dst[K] := Src[K]
      else
        Move(Src^, Dst^, L);
      Inc(Produced, L);
    end
    else if (Code = NextCode) and HavePrev then
    begin
      { The code being defined: the previous string plus its own first
        byte. }
      CurLen := PrevLen + 1;
      L := PrevLen;
      if L > ACount - Produced then
        L := ACount - Produced;
      Src := AOut + PrevPos;
      Dst := AOut + Produced;
      if L <= 8 then
        for K := 0 to L - 1 do
          Dst[K] := Src[K]
      else
        Move(Src^, Dst^, L);
      Inc(Produced, L);
      if Produced < ACount then
      begin
        AOut[Produced] := AOut[PrevPos];
        Inc(Produced);
      end;
    end
    else
      Break;                     { damaged data: keep what we have }

    { New entry: the previous string plus the first byte of this one,
      which follows it directly in the output. A full table stays as
      it is until the next clear code (GIF has no early change). }
    if HavePrev and (NextCode < MaxLzwCodes) then
    begin
      EntryPos[NextCode] := PrevPos;
      EntryLen[NextCode] := PrevLen + 1;
      Inc(NextCode);
      if (NextCode = (1 shl CodeSize)) and (CodeSize < 12) then
      begin
        Inc(CodeSize);
        CodeMask := (1 shl CodeSize) - 1;
      end;
    end;
    HavePrev := True;
    PrevPos := CurPos;
    PrevLen := CurLen;

    if Produced >= NextCheck then
    begin
      NextCheck := Produced + LzwCheckEvery;
      if Assigned(ACancel) and ACancel() then
        raise EGifCancelled.Create('Cancelled');
    end;
  end;
  Result := Produced;
end;

{ Reading the file }

function IsGifData(AData: PByte; ASize: Int64): Boolean;
begin
  Result := (ASize >= 6) and (AData[0] = Ord('G')) and (AData[1] = Ord('I'))
    and (AData[2] = Ord('F')) and (AData[3] = Ord('8'));
end;

procedure DefaultPalette(out APal: TGifPalette);
var
  I: Integer;
begin
  for I := 0 to 255 do
    APal[I] := BGRA(0, 0, 0, 255);
  APal[1] := BGRA(255, 255, 255, 255);
end;

{ Reads ACount RGB entries at AP; entries past the data stay black. }
procedure ReadPalette(AData: PByte; ASize: Int64; var AP: Int64; ACount: Integer;
  out APal: TGifPalette);
var
  I: Integer;
begin
  for I := 0 to 255 do
    APal[I] := BGRA(0, 0, 0, 255);
  for I := 0 to ACount - 1 do
  begin
    if AP + 3 > ASize then
    begin
      AP := ASize;
      Exit;
    end;
    APal[I] := BGRA(AData[AP], AData[AP + 1], AData[AP + 2], 255);
    Inc(AP, 3);
  end;
end;

function Word16(AData: PByte; AP: Int64): Integer;
begin
  Result := AData[AP] or (Integer(AData[AP + 1]) shl 8);
end;

function DecodeGif(AData: PByte; ASize: Int64; AComplete, AFirstOnly: Boolean;
  AMaxBytes: Int64; ACancel: TCancelCheck;
  out AMore, AIncomplete: Boolean; out AError: string): TGifAnimation;
var
  Anim: TGifAnimation;
  P: Int64;
  LogW, LogH, Flags, BlockType, BlockLabel, Size: Integer;
  GlobalPal: TGifPalette;
  HasGlobal, FirstSub, EndedInside, Stop, SawTrailer, LoopApp, Fits: Boolean;
  Disposal, DelayCs, Transparent: Integer;
  FX, FY, FW, FH, FFlags, MinCodeSize: Integer;
  Pixels, FrameBytes: Int64;
  Compressed: TBytes;
  CompressedLen: Int64;
  Linear: TBytes;
  Frame: TGifFrame;
  Row, Rank: Integer;
  Reason: string;
begin
  Result := nil;
  AMore := False;
  AIncomplete := False;
  AError := '';
  if not IsGifData(AData, ASize) or (ASize < 13) then
  begin
    AError := 'not a GIF file';
    Exit;
  end;

  Anim := TGifAnimation.Create;
  try
    LogW := Word16(AData, 6);
    LogH := Word16(AData, 8);
    Flags := AData[10];
    P := 13;
    HasGlobal := (Flags and $80) <> 0;
    if HasGlobal then
      ReadPalette(AData, ASize, P, 1 shl ((Flags and 7) + 1), GlobalPal)
    else
      DefaultPalette(GlobalPal);

    Disposal := 0;
    DelayCs := 0;
    Transparent := -1;
    Compressed := nil;
    Linear := nil;
    Stop := False;
    SawTrailer := False;
    { No loop extension: play once. }
    Anim.FPlayCount := 1;

    while (not Stop) and (P < ASize) do
    begin
      BlockType := AData[P];
      Inc(P);

      if BlockType = $3B then         { trailer }
      begin
        SawTrailer := True;
        Break;
      end;

      if BlockType = $21 then         { extension }
      begin
        if P >= ASize then
          Break;
        BlockLabel := AData[P];
        Inc(P);
        FirstSub := True;
        LoopApp := False;
        while True do
        begin
          if P >= ASize then
          begin
            Stop := True;             { cut off }
            Break;
          end;
          Size := AData[P];
          Inc(P);
          if Size = 0 then
            Break;
          if P + Size > ASize then
          begin
            P := ASize;
            Stop := True;
            Break;
          end;
          { Graphic control: disposal, delay and transparency of the
            next image. }
          if (BlockLabel = $F9) and FirstSub and (Size >= 4) then
          begin
            Disposal := (AData[P] shr 2) and 7;
            DelayCs := Word16(AData, P + 1);
            if (AData[P] and 1) <> 0 then
              Transparent := AData[P + 3]
            else
              Transparent := -1;
          end;
          { Application extension: the loop count. }
          if (BlockLabel = $FF) and FirstSub and (Size = 11) then
            LoopApp := CompareMem(@AData[P], PAnsiChar('NETSCAPE2.0'), 11)
              or CompareMem(@AData[P], PAnsiChar('ANIMEXTS1.0'), 11);
          if (BlockLabel = $FF) and LoopApp and (not FirstSub) and (Size >= 3)
            and (AData[P] = 1) then
          begin
            if Word16(AData, P + 1) = 0 then
              Anim.FPlayCount := 0                          { forever }
            else
              Anim.FPlayCount := Word16(AData, P + 1) + 1;
          end;
          Inc(P, Size);
          FirstSub := False;
        end;
        Continue;
      end;

      if BlockType <> $2C then        { unknown: the file ends here }
        Break;

      { An image. }
      if AFirstOnly and (Anim.FCount > 0) then
      begin
        AMore := True;
        Break;
      end;
      if Assigned(ACancel) and ACancel() then
        raise EGifCancelled.Create('Cancelled');
      if P + 9 > ASize then
      begin
        AIncomplete := True;
        Break;
      end;
      FX := Word16(AData, P);
      FY := Word16(AData, P + 2);
      FW := Word16(AData, P + 4);
      FH := Word16(AData, P + 6);
      FFlags := AData[P + 8];
      Inc(P, 9);
      Pixels := Int64(FW) * FH;

      if Anim.FCount = 0 then
      begin
        { The picture: the logical screen (frames are clipped to it),
          or the first frame's extent if the screen is 0 x 0. }
        Anim.FWidth := LogW;
        Anim.FHeight := LogH;
        if (LogW = 0) or (LogH = 0) then
        begin
          Anim.FWidth := FX + FW;
          Anim.FHeight := FY + FH;
        end;
        if (Anim.FWidth <= 0) or (Anim.FHeight <= 0) then
        begin
          AError := 'the file contains no image';
          Break;
        end;
        { The cursor's picture and the copy it hands out. }
        if not DecodeFits(Anim.FWidth, Anim.FHeight,
          Int64(Anim.FWidth) * Anim.FHeight * 4, Reason) then
        begin
          AError := Reason;
          Break;
        end;
      end;
      { The frame's indices (and the interlace buffer): a damaged header
        can claim 65535 x 65535. Counted as 4 bytes per pixel, so the
        same limits as for any bitmap apply. And a frame far larger than
        the picture it is clipped to is damaged too (real files: at most
        a little larger); it would only allocate memory for pixels never
        shown. For the first frame that is an error, later the file
        simply ends there. }
      if Pixels > 0 then
      begin
        Fits := DecodeFits(FW, FH, 0, Reason);
        if Fits and (Pixels > Max(4 * Int64(Anim.FWidth) * Anim.FHeight, Int64(MinFrameLimitPixels))) then
        begin
          Fits := False;
          Reason := Format('damaged file: a frame of %d x %d in a picture of %d x %d',
            [FW, FH, Anim.FWidth, Anim.FHeight]);
        end;
        if not Fits then
        begin
          if Anim.FCount = 0 then
            AError := Reason;
          Break;
        end;
      end;

      FrameBytes := Pixels + TGifFrame.InstanceSize;
      if (Anim.FCount > 0) and (Anim.FBytes + FrameBytes > AMaxBytes) then
      begin
        if AMaxBytes >= 1024 * 1024 then
          Anim.FNote := Format('only the first %d frames (memory limit %d MB)',
            [Anim.FCount, AMaxBytes div (1024 * 1024)])
        else
          Anim.FNote := Format('only the first %d frames (memory limit %d KB)',
            [Anim.FCount, AMaxBytes div 1024]);
        Break;
      end;

      Frame := TGifFrame.Create;
      try
        Frame.X := FX;
        Frame.Y := FY;
        Frame.W := FW;
        Frame.H := FH;
        Frame.Interlaced := (FFlags and $40) <> 0;
        Frame.Disposal := Disposal;
        Frame.Transparent := Transparent;
        if DelayCs <= 1 then
          Frame.DelayMs := DefaultDelayMs
        else
          Frame.DelayMs := DelayCs * 10;
        if (FFlags and $80) <> 0 then
          ReadPalette(AData, ASize, P, 1 shl ((FFlags and 7) + 1), Frame.Palette)
        else
          Frame.Palette := GlobalPal;
        { The graphic control applies to this image only. }
        Disposal := 0;
        DelayCs := 0;
        Transparent := -1;

        { The LZW data: a code size byte, then sub-blocks. }
        EndedInside := True;
        CompressedLen := 0;
        MinCodeSize := 0;
        if P < ASize then
        begin
          MinCodeSize := AData[P];
          Inc(P);
          while P < ASize do
          begin
            Size := AData[P];
            Inc(P);
            if Size = 0 then
            begin
              EndedInside := False;
              Break;
            end;
            if P + Size > ASize then
              Size := Integer(ASize - P);  { cut off: take what is there }
            if Size <= 0 then
              Break;
            if CompressedLen + Size > Length(Compressed) then
              SetLength(Compressed, Max(CompressedLen + Size, 2 * Length(Compressed) + 65536));
            Move(AData[P], Compressed[CompressedLen], Size);
            Inc(CompressedLen, Size);
            Inc(P, Size);
          end;
        end;

        SetLength(Frame.Indices, Pixels);
        Frame.Produced := 0;
        if (Pixels > 0) and (CompressedLen > 0) then
        begin
          if not Frame.Interlaced then
            Frame.Produced := GifLzwDecode(@Compressed[0], Integer(CompressedLen),
              MinCodeSize, @Frame.Indices[0], Integer(Pixels), ACancel)
          else
          begin
            { Decode in the file's row order, then put the rows in
              place. Rows not decoded stay 0 (DecodedInRow skips them). }
            if Length(Linear) < Pixels then
              SetLength(Linear, Pixels);
            Frame.Produced := GifLzwDecode(@Compressed[0], Integer(CompressedLen),
              MinCodeSize, @Linear[0], Integer(Pixels), ACancel);
            for Row := 0 to FH - 1 do
            begin
              Rank := InterlacedRank(Row, FH);
              Move(Linear[Int64(Rank) * FW], Frame.Indices[Int64(Row) * FW], FW);
            end;
          end;
        end;

        if EndedInside then
          AIncomplete := True;
        { Cut off before any of its pixels: nothing to show. }
        if EndedInside and (Frame.Produced = 0) and (Pixels > 0) then
          FreeAndNil(Frame)
        else
        begin
          Anim.AddFrame(Frame);
          Frame := nil;
        end;
      finally
        Frame.Free;
      end;

      if EndedInside then
        Break;
    end;

    { The start of a file only: whether another frame comes is not
      known yet. }
    if AFirstOnly and (not AComplete) and (not SawTrailer) and (P >= ASize)
      and (Anim.FCount > 0) then
      AMore := True;

    if Anim.FCount = 0 then
    begin
      if AError = '' then
        AError := 'the file contains no image';
      FreeAndNil(Anim);
    end;
    Result := Anim;
  except
    Anim.Free;
    raise;
  end;
end;

end.
