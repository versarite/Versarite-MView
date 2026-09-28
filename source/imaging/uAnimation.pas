unit uAnimation;

{
  Unit: uAnimation

  Purpose
  -------
  Animated images (spec §8.7, v1: animated GIF) in three parts, so that
  movies can reuse the timing later (rule M6):

  - TAnimation: the frames, made by a decode worker and read only
    afterwards. Shared like IDecodedImage (which owns it).
  - TAnimationCursor: turns the frames into whole pictures, one after
    the other, on the UI thread. (A GIF frame usually changes only part
    of the picture; the cursor keeps the picture built so far.)
  - TFrameClock: which frame is due when. It knows nothing about GIF:
    it asks for each frame's display time through a function, so a
    movie without sound can drive it the same way.

  Owns
  ----
  - Nothing concrete: TAnimation and TAnimationCursor are abstract
    (uGifDecoder implements them). TFrameClock holds only counters
    and times.

  Knows
  -----
  - TFrameClock: the delay function handed to its constructor
    (TFrameDelayFunc, e.g. TMView's AnimationDelay).

  Responsibilities
  ----------------
  - TAnimation: picture size, frame count, each frame's delay (always
    > 0), memory held (for the cache budget), a Note on why frames are
    missing, how often to play (PlayCount, 0 = forever), and new
    cursors.
  - TAnimationCursor: a new bitmap of frame N (the caller owns it);
    forward is cheap, going back starts again at frame 0.
  - TFrameClock: frames due at fixed times from Start; overdue frames
    are skipped; after a stall of more than FrameClockMaxLagMs
    (1000 ms) it starts over from the current frame; delays below
    MinFrameDelayMs (10 ms) count as 10 ms, so Advance can't loop
    forever; after APlayCount plays it stays on the last frame
    (Finished). Counts frames shown and skipped (diagnostics).

  Does NOT
  --------
  - Decode files (uGifDecoder), draw, or own a timer (TMView does).

  Threads
  -------
  A TAnimation is made on a decode worker and read only afterwards,
  so any thread may read it without a lock. A TAnimationCursor
  belongs to one thread: TMView's runs on the UI thread (the loader
  also uses one briefly on the worker, for frame 0). TFrameClock has
  no lock; TMView uses it on the UI thread only.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      Classes, SysUtils, BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uDecodedImage, uGifDecoder, uMView, uMediaLoader
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  BGRABitmap,
  BGRABitmapTypes;

type

  TAnimationCursor = class;

  { The frames of an animation. Read only once made, so any thread may
    read it; TDecodedImage owns it. }
  TAnimation = class(TObject)
  public
    { Size of the whole picture (every frame is this size). }
    function Width: Integer; virtual; abstract;
    function Height: Integer; virtual; abstract;
    function FrameCount: Integer; virtual; abstract;
    { How long frame AIndex stays on screen. Always > 0. }
    function FrameDelayMs(AIndex: Integer): Integer; virtual; abstract;
    { Memory held by the frames, for the cache budget. }
    function SizeInBytes: Int64; virtual; abstract;
    { Why not all frames of the file are here (e.g. memory), or ''. }
    function Note: string; virtual;
    { How often to play it: 0 = forever. }
    function PlayCount: Integer; virtual;
    { A new cursor; the caller owns it. The animation must live longer
      than the cursor. }
    function CreateCursor: TAnimationCursor; virtual; abstract;
  end;

  { Makes whole frames. One thread only. }
  TAnimationCursor = class(TObject)
  public
    { A new bitmap (the caller owns it) showing frame AIndex. Forward
      is cheap (skipped frames are built but not copied); going back
      starts again at frame 0. }
    function Frame(AIndex: Integer): TBGRABitmap; virtual; abstract;
  end;

  TFrameDelayFunc = function(AIndex: Integer): Integer of object;

  { Which frame is due. Times are NowMs values. Frames are due at fixed
    times from the start (each after the previous one's delay), not
    "delay after it was shown", so a late frame doesn't slow the whole
    animation down. A frame that is due while an older one hasn't been
    shown yet is skipped. After a long stall (more than a second behind,
    e.g. the window was dragged) the clock starts over from the current
    frame instead of racing through the skipped ones (FrameClockMaxLagMs).
    Plays APlayCount times (0 = forever), then stays on the last frame
    (Finished). }
  TFrameClock = class(TObject)
  private
    FFrameCount: Integer;
    FDelay: TFrameDelayFunc;
    FPlayCount: Integer;
    FPlays: Integer;         { plays completed }
    FFinished: Boolean;
    FIndex: Integer;
    FNextDueMs: Double;      { when frame FIndex + 1 is due }
    FSkipped: Integer;
    FShown: Integer;
    function NextIndex(AIndex: Integer): Integer;
    function DelayOf(AIndex: Integer): Integer;
  public
    constructor Create(AFrameCount: Integer; ADelay: TFrameDelayFunc;
      APlayCount: Integer = 0);
    { Frame 0 is on screen now. }
    procedure Start(ANowMs: Double);
    { Moves to the frame due at ANowMs. True if that is another frame
      than before (then show Index). }
    function Advance(ANowMs: Double): Boolean;
    { Milliseconds until the next frame is due (0 if overdue; a day
      once Finished). }
    function MsUntilNext(ANowMs: Double): Double;
    property Index: Integer read FIndex;
    property FrameCount: Integer read FFrameCount;
    { Played as often as asked: stays on the last frame. }
    property Finished: Boolean read FFinished;
    { Frames shown / skipped since Start (diagnostics). }
    property Shown: Integer read FShown;
    property Skipped: Integer read FSkipped;
  end;

const
  FrameClockMaxLagMs = 1000;
  { A delay function that returns 0 must not make Advance loop forever. }
  MinFrameDelayMs = 10;

implementation

{ TAnimation }

function TAnimation.Note: string;
begin
  Result := '';
end;

function TAnimation.PlayCount: Integer;
begin
  Result := 0;
end;

{ TFrameClock }

constructor TFrameClock.Create(AFrameCount: Integer; ADelay: TFrameDelayFunc;
  APlayCount: Integer);
begin
  inherited Create;
  FFrameCount := AFrameCount;
  FDelay := ADelay;
  FPlayCount := APlayCount;
  FIndex := 0;
  FNextDueMs := 0;
end;

function TFrameClock.NextIndex(AIndex: Integer): Integer;
begin
  Result := AIndex + 1;
  if Result >= FFrameCount then
    Result := 0;
end;

function TFrameClock.DelayOf(AIndex: Integer): Integer;
begin
  Result := FDelay(AIndex);
  if Result < MinFrameDelayMs then
    Result := MinFrameDelayMs;
end;

procedure TFrameClock.Start(ANowMs: Double);
begin
  FIndex := 0;
  FSkipped := 0;
  FShown := 1;
  FPlays := 0;
  FFinished := False;
  FNextDueMs := ANowMs + DelayOf(0);
end;

function TFrameClock.Advance(ANowMs: Double): Boolean;
var
  Steps: Integer;
begin
  Result := False;
  if (FFrameCount <= 1) or FFinished then
    Exit;

  { Stalled for long: go on from the next frame, from now. }
  if ANowMs - FNextDueMs > FrameClockMaxLagMs then
    FNextDueMs := ANowMs;

  Steps := 0;
  while ANowMs >= FNextDueMs do
  begin
    { The last frame of the last play: stay. }
    if (FIndex = FFrameCount - 1) and (FPlayCount > 0) and (FPlays + 1 >= FPlayCount) then
    begin
      FFinished := True;
      Break;
    end;
    if FIndex = FFrameCount - 1 then
      Inc(FPlays);
    FIndex := NextIndex(FIndex);
    FNextDueMs := FNextDueMs + DelayOf(FIndex);
    Inc(Steps);
  end;
  if Steps > 0 then
  begin
    Inc(FShown);
    Inc(FSkipped, Steps - 1);
    Result := True;
  end;
end;

function TFrameClock.MsUntilNext(ANowMs: Double): Double;
begin
  if FFinished then
    Exit(86400000);
  Result := FNextDueMs - ANowMs;
  if Result < 0 then
    Result := 0;
end;

end.
