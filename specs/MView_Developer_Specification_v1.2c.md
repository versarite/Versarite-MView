# MView Developer Specification v1.2

**Date:** 2026-09-25 (v1.2c: movie playback design added, §8.7, based on the Hamana analysis. v1.2b: review of v1.2a, Lazarus requirements added)
**Replaces:** v1.0 (Microscopy Image Viewer Developer Specification) and v1.1 (performance architecture)
**Platform:** Windows 64-bit. A 32-bit version, if needed, is a separate fork.
**Language:** Lazarus / Free Pascal, LCL GUI application

v1.2 merges v1.0 (features, modules) and v1.1 (performance philosophy) into one document and adds the part neither had: a concrete **threading model** in which **image loading always has preference** over every other kind of work.

Sections marked **[Decision]** are settled. Sections marked **[Open]** still need a decision, usually after a benchmark or a spike.

---

## 1. Purpose

MView is a native, fullscreen, mouse-driven image viewer for rapid inspection of scientific microscopy images and short GIF movies.

One objective drives every decision:

> **Minimize the time between "interesting image" and "next image".**

MView is a viewer. File management stays in Total Commander.

```
Total Commander → select experiment → mview.exe image.tif → rapid inspection → move interesting images → back to Total Commander
```

MView is also an educational project. The code should teach Object Pascal, threading and rendering, and every important decision is documented along with its reasons.

---

## 2. Principles

### 2.1 Performance philosophy (from v1.1, unchanged)

1. Never block the UI thread.
2. User interaction always has the highest priority.
3. Cancel obsolete work immediately.
4. Prefer immediate visual feedback over maximum image quality.
5. Optimize perceived responsiveness, not raw decoding speed.

### 2.2 The load-priority rule (new in v1.2) [Decision]

> **The image the user wants to see now beats everything else.**
> Nothing (preloading, directory scanning, thumbnails, GPU uploads of other images) may delay it.

In practice:

| Situation | Rule |
|---|---|
| Worker threads busy with preloads | One worker is always kept free for the current image (§5.4). |
| Only one worker exists | The lowest-priority running job is cancelled to make room. |
| Directory scanner is reading the disk | Scanner pauses while the current image is being read (§5.5, I/O gate). |
| Current image already being preloaded | The running job is **promoted**, not restarted. |
| GPU upload queue | Current image tiles are uploaded first; other textures only in idle time. |

### 2.3 Architecture principles (unchanged)

- Everything is a command. Input sources (wheel, gesture, keyboard, script) only produce commands.
- One responsibility per class. Each class documents *Purpose / Owns / Knows / Responsibilities / Does NOT*.
- The form is a thin shell. `TMView` never depends on the GUI.
- Ownership: whoever creates an object destroys it.
- Benchmark before optimizing. Every performance target in §12 must be verified by measurement.
- Every commit compiles.

### 2.4 Threading principles (new) [Decision]

1. **Share nothing mutable.** Threads exchange *immutable* objects (decoded images, directory listings). Once handed over, an object is never modified.
2. **Locks exist in exactly two places:** the job queue and the image cache. Nothing else is locked.
3. **Never hold one lock while taking the other.**
4. **Workers never touch the GUI, the navigator or OpenGL.** Results go to the UI thread with `TThread.Queue` (never `Synchronize`, which blocks the worker).
5. **No `Application.ProcessMessages`** as a way to "keep the UI alive". If it seems needed, the work is on the wrong thread.

---

## 3. Features

### 3.1 Version 1 (mandatory)

- Start from command line: `mview.exe image.tif` or `mview.exe C:\Experiment`.
- Fullscreen, no menu bar, no toolbar, no dialogs. The right-click menu initially contains only *Exit*.
- Formats: TIFF (highest priority), JPEG, PNG, BMP, GIF including animation.
- Recursive directory navigation with wrap-around for images and directories. No dead ends. Wrap-around scope set in the ini: per folder or per tree.
- Sort modes: date (newest → oldest, default) and natural filename.
- Fit-to-screen, original size (1:1), zoom, free pan, rotation in 90° steps or free angle.
- Background preloading in the direction of travel, crossing directory boundaries. The 2 previous images always stay in memory.
- Browse and Skim modes (§6).
- Screen-quadrant-based mouse control and gestures (§9).
- Unreadable files never stop navigation. A placeholder is shown only for files with an image extension that fail to decode (can be turned off in the ini). Other files are skipped silently.

### 3.2 Later versions

- Slide-in edge menu with buttons for favorite destination folders (Good / Interesting / Reject / …): one click moves or copies the current image, and browsing continues without interruption.
- Crop and rotate a region of interest, change brightness, contrast and dynamic range, and save the result to a repository folder, leaving the original untouched. Details to be specified later.
- Thumbnail cache on disk (no database), can be turned on and off. Storage method to be decided (safest option).
- Event-driven mouse scripting language.
- Magnifier, cursor-centered zoom, mirror.
- Additional formats (WebP, JPEG XL, AVIF). Movies with sound, designed in §8.7.

### 3.3 Out of scope

Image database (possibly reconsidered later), tagging, advanced editing, file management beyond move/copy.

---

## 4. Architecture

### 4.1 Ownership tree

```
TMainForm                         (presentation, thin shell)
 ├── TMediaView                   drawing surface + raw input
 └── TMView                       application coordinator
      ├── TConfig                 MView.ini
      ├── TCommandDispatcher      command → action
      ├── TMouseEngine            raw mouse → commands
      ├── TNavigator              navigation state (UI thread only)
      │    ├── TDirectoryTree     directory list (snapshot)
      │    └── TDirectoryImages   image list per directory (snapshot)
      ├── TJobScheduler           priorities, wanted set, cancellation, modes
      │    ├── TJobQueue          thread-safe priority queue   [lock]
      │    └── TDecodeWorker ×N   worker threads
      ├── TDirectoryScanner       scanner thread
      ├── TMediaLoader            decoders (called by workers, stateless)
      ├── TImageCache             immutable decoded images     [lock]
      └── TRenderer               GPU renderer (CPU renderer as fallback)
           └── TTextureCache      GPU textures (UI thread only)
```

### 4.2 Responsibilities

| Class | Responsibilities | Does NOT |
|---|---|---|
| `TMView` | Create/destroy subsystems, route commands, connect scheduler results to renderer. | Decode, draw, scan, handle raw input. |
| `TNavigator` | Current directory and image index, next/previous, wrap-around, answer "which file is at offset *k*?". | Access the filesystem (it receives listings from the scanner). |
| `TDirectoryScanner` | List directories on its own thread, build the tree, deliver immutable snapshots. | Decide what the user sees. |
| `TJobScheduler` | Turn navigation into a *wanted set* of jobs, prioritize, cancel, switch Browse/Skim. | Decode anything itself. |
| `TMediaLoader` | Decode a file at a requested quality, report progress, honor cancellation. | Schedule, cache, or know about threads. |
| `TImageCache` | Own decoded images, replace lower quality with higher, evict by distance from current image. | Decide what to load. |
| `TRenderer` | Upload textures, draw the current image using the view transform. | Open files, decode, navigate. |
| `TMouseEngine` | Quadrants, wheel, gestures → commands. | Contain any viewer logic. |
| `TMediaView` | Surface for painting, forward input to the mouse engine / dispatcher. | Call renderer zoom methods directly. |

### 4.3 Data flow

```
 input ──► TMouseEngine ──► Command ──► TMView ──► TNavigator (new position)
                                          │
                                          ▼
                                   TJobScheduler.Reconcile(wanted set)
                                          │
                          ┌───────────────┴───────────────┐
                          ▼                               ▼
                   TDecodeWorker ×N                TDirectoryScanner
                   (TMediaLoader)                  (listings)
                          │ TThread.Queue                 │ TThread.Queue
                          ▼                               ▼
                    TImageCache ──► TRenderer        TNavigator snapshot swap
                                       │
                                       ▼
                                 GPU → screen
```

---

## 5. Threading model [Decision]

### 5.1 Threads

| Thread | Count | Owns / does |
|---|---|---|
| **UI thread** | 1 | Window, input, commands, navigator, scheduler decisions, OpenGL context, texture uploads, painting, GIF timer. |
| **Decode workers** | N (default: CPU cores − 1, min 1, max 4) | Read file + decode + convert to display pixel format. |
| **Scanner** | 1 | Directory listing, recursive tree, later thumbnails. |

No other threads. GIF playback uses a UI-thread timer. Its frames are decoded by a worker. (Movies, in a later version, add their own threads; see §8.7.)

Early phases may run with **N = 1**. The architecture does not change when N grows.

### 5.2 Priorities

Lower number = more urgent.

| Priority | Job | Runs on | Browse | Skim |
|---|---|---|---|---|
| **P0 Display** | Current image, best quality obtainable quickly | worker | ✓ | ✓ (preview quality) |
| **P1 Refine** | Current image, full quality | worker | ✓ | — |
| **P2 Ahead** | Next images in the direction of travel, nearest first | worker | ✓ | — |
| **P3 Behind** | Images behind the current one | worker | ✓ | — |
| **S1 List** | Current directory, then neighbor directories | scanner | ✓ | ✓ |
| **S2 Tree** | Recursive tree | scanner | ✓ | paused |
| **S3 Thumbs** | Thumbnails (later) | scanner | idle only | — |

Worker jobs and scanner jobs run on different threads, so they do not compete for CPU. They compete only for the disk, which the I/O gate (§5.5) resolves.

### 5.3 The wanted set: declarative scheduling

The scheduler is not told "load this, then that". After every navigation it is told **what should exist**, and it reconciles:

```
OnNavigate(position, direction):
  Epoch := Epoch + 1
  Wanted := [ current @ P0 ]
  if Mode = Browse then
    Wanted += [ current @ P1 (full) ]
    Wanted += next PreloadAhead images in direction @ P2
    Wanted += PreloadBehind images @ P3
  Scheduler.Reconcile(Wanted)

Reconcile(Wanted):
  for each queued job   not in Wanted  → remove from queue
  for each running job  not in Wanted  → Cancel
  for each wanted item already in cache at ≥ required quality → skip
  for each wanted item already running  → change its priority (do NOT restart)
  otherwise → enqueue
```

Why declarative: fast navigation then needs no special handling. Ten wheel clicks produce ten reconciles, and each one discards what the previous one wanted. Obsolete work disappears by construction.

### 5.4 Keeping a worker free for the current image [Decision]

- With **N ≥ 2**: a worker may take a P2/P3 job only if at least one *other* worker is idle. So one worker is always free for P0, and no cancellation is needed.
- With **N = 1**: when a P0 job arrives and the worker is busy with a P2/P3 job for a *different* image, that job is cancelled.
- If the P0 image is the one already being decoded, its job is promoted to P0 and allowed to finish.

### 5.5 I/O gate [Decision]

On a hard disk or network share, a directory scan can slow the read of the current image a lot.

- A P0 job raises the gate (`TEvent` reset) before reading the file and lowers it after the file data is read (not after decoding).
- The scanner checks the gate between directory entries and waits while it is raised.
- Preload jobs (P2/P3) do not raise the gate.

### 5.6 Jobs and cancellation

```pascal
type
  TJobPriority = (jpDisplay, jpRefine, jpAhead, jpBehind);   { ordinal = urgency }
  TQualityLevel = (qlNone, qlPreview, qlScreen, qlFull);

  TImageKey = record
    FileName: string;
    FileSize: Int64;
    FileTime: TDateTime;      { key changes if the file is replaced }
  end;

  TDecodeJob = class
  private
    FKey: TImageKey;
    FQuality: TQualityLevel;
    FPriority: TJobPriority;
    FEpoch: Cardinal;
    FCancelled: LongInt;      { 0 or 1, accessed with Interlocked* }
    FResult: IDecodedImage;   { set by the worker }
    FError: string;
  public
    procedure Cancel;         { InterlockedExchange(FCancelled, 1) }
    function IsCancelled: Boolean;
    procedure Deliver;        { runs on the UI thread via TThread.Queue }
  end;
```

Cancellation rules:
- Cancellation is **cooperative**. The decoder checks `IsCancelled` regularly. For FPImage readers, the `OnProgress` event exposes a `Continue` flag that can stop a decode. Check per format that each reader actually calls it; formats that don't can only be checked between read and decode.
- Setting `Cancel` is cheap and safe from any thread. A cancelled job's result is discarded, never partially shown.
- `Deliver` checks that the result still matches something wanted (key + quality). A late result for a still-wanted image goes into the cache even if it came from an older epoch.

### 5.7 Delivering results to the UI thread

- Worker finishes → `TThread.Queue(nil, @Job.Deliver)`.
- `Deliver` (UI thread): put the image into `TImageCache`. If it is the current image, pass it to the renderer and `Invalidate`.
- Never use `TThread.Synchronize` from workers. It makes the worker wait for the UI thread.

### 5.8 Shutdown order

1. Stop accepting commands.
2. Cancel all jobs, signal the scanner to stop, lower the I/O gate.
3. `WaitFor` all threads.
4. Remove pending queued deliveries (`TThread.RemoveQueuedEvents`).
5. Free cache, renderer (textures), then the remaining subsystems in reverse creation order.

Missing any of these steps usually shows up as a crash on exit, when a queued `Deliver` runs against a freed object.

---

## 6. Browse and Skim modes [Decision]

| | Browse | Skim |
|---|---|---|
| Goal | Best quality, smooth browsing | Lowest latency while flicking through |
| Preloading | Aggressive | Suspended |
| Current image | Preview → full | Preview / screen quality only |
| Recursive scan | Runs | Paused |

**Entering Skim:** fast navigation has lasted for `SkimEnterMs` (default **1500 ms**, range 1–2 s). "Fast" means each new navigation command arrives before the current image is displayed, or more than `SkimRate` image changes per second (default 4).

**Leaving Skim:** no navigation for `SkimExitMs` (default **250 ms**), much shorter than entering, so full quality returns almost as soon as scrolling stops. The next reconcile runs in Browse mode, so refinement and preloading restart automatically.

Only the scheduler knows the mode. The renderer and loader never see it.

**[Decision]** Both times are ini settings (§14). Defaults to be tuned on real data.

---

## 7. Image pipeline

### 7.1 Quality levels

```
Unknown → Preview → Screen → Full
```

| Level | How it is obtained (where the format allows) |
|---|---|
| Preview | Embedded thumbnail (TIFF reduced-resolution subfile, EXIF thumbnail) or JPEG scaled decode (1/8 or 1/4). |
| Screen | Decode, then downsample on the worker to about the screen size. |
| Full | Full decode. Needed for zoom beyond fit. |

The cache always holds the best level available. The renderer always draws the best level in the cache. It does not know which level it is.

If a format has no cheap preview, P0 goes straight to Full, and the Preview level is skipped for that file.

### 7.2 Decoded image

```pascal
type
  IDecodedImage = interface
    function Key: TImageKey;
    function Quality: TQualityLevel;
    function Width: Integer;
    function Height: Integer;
    function Pixels: PBGRAPixel;     { 32-bit BGRA, immutable after creation }
    function SizeInBytes: Int64;
    function FrameCount: Integer;    { > 1 for animated GIF }
    function FrameDelayMs(AIndex: Integer): Integer;
  end;
```

Using a reference-counted interface means the cache, the renderer and a pending `Deliver` can all hold the same image safely. It is freed when the last reference goes. FPC's interface reference counting is thread-safe.

All conversion to display format (palette, 16-bit, CMYK, orientation) happens **on the worker**, never at paint time.

### 7.3 TIFF specifics [Open]

- 16-bit and 32-bit float microscopy TIFFs need a mapping to 8-bit for display. Proposal for v1: linear min/max stretch computed on the worker. Later: adjustable window (brightness/contrast) as a shader.
- Multi-page TIFF (z-stacks, time series): v1 shows page 1. Later: page navigation as a separate command pair.
- Decoder: FPC's `FPReadTiff` first. If compressions used in your real data are unsupported, a libtiff DLL behind the same `TMediaLoader` interface.
- **Action:** collect 10–20 real TIFFs from the microscopes (bit depth, compression, size, page count) into `test\images\tiff\`. This decides the questions above.

### 7.4 Errors

- Unreadable, corrupt or vanished file → cache stores an error entry, the renderer draws a placeholder (dark screen, file name, short reason), and navigation continues normally.
- Never a modal dialog. Errors go to the log if logging is enabled.

---

## 8. Rendering

### 8.1 Transform-based rendering [Decision]

This is the "game mapping" technique: the image is uploaded once as GPU texture(s). Pan, zoom and rotation change only the transform. Pixels are never resampled on the CPU for display.

```
IDecodedImage ──upload once──► texture(s) + mipmaps
                                     │
ViewState (Zoom, PanX, PanY, Rotation) ──► transform ──► GPU draws quads ──► screen
```

- `ActualScale = FitScale × Zoom` (from Day 9). `ZoomIn = Zoom × step`, `ZoomOut = Zoom ÷ step` (reversible).
- Zoom is centered on the screen. Cursor-centered zoom comes later.
- Pan is unrestricted. The view resets to centered/fit on image change.
- Rotation in 90° steps for v1. Arbitrary angles come for free with the transform later.

### 8.2 Textures, tiles and mipmaps

- Query `GL_MAX_TEXTURE_SIZE` at startup. Images larger than that are split into **tiles** (proposal: 2048 × 2048) drawn as adjacent quads.
- Generate **mipmaps** per texture so zoomed-out views are smooth and not aliased (`UseMipMaps=1` in the ini).
- Magnification filter: linear by default. **Nearest** as an option when zoomed beyond 1:1, so individual pixels can be inspected.
- Tiles overlap by a 1-pixel border and use clamp-to-edge. Otherwise linear filtering shows visible seams at high zoom. Hamana used 64×64 tiles by default and its manual warns about exactly these seams.
- At exactly 1:1, place the image on whole pixels and use nearest filtering, so original size is really pixel-exact. Hamana's manual admits its 1:1 view "may be slightly blurred depending on the video card".

### 8.3 Uploading without blocking

- An OpenGL context belongs to one thread, the UI thread here. Uploads happen there.
- Uploading a large image in one go can take long enough to cause a visible hitch. So uploads are **time-sliced**: each frame uploads tiles for at most a fixed budget (proposal: 4 ms). Current-image tiles go first; preloaded images' tiles are uploaded in `Application.OnIdle`.
- While tiles are missing, the renderer draws what is there, for example the preview texture scaled up underneath.
- Later: pixel buffer objects (PBOs) for asynchronous upload, if measurement shows the need.

### 8.4 GPU memory

`TTextureCache` keeps textures for the current image and the nearest preloaded images within a VRAM budget (proposal: 512 MB, configurable). A texture with mipmaps needs about 1.33 × width × height × 4 bytes.

### 8.5 Technology choice [Decision]

| Option | For | Against |
|---|---|---|
| **A. `TOpenGLControl` (LazOpenGLContext) + own texture class** | Full control over tiles, mipmaps, upload. Most educational. | More code to write. |
| B. BGRABitmap `BGRAOpenGL` (`TBGLVirtualScreen`) | Already using BGRABitmap, quick start. | Less control over tiling and upload timing. |
| C. Direct3D 9/11 via headers | Closest to Hamana. | Windows-only, most work, fewest Lazarus examples. |

Decision: **A (`TOpenGLControl`)**, unless another option clearly outperforms it in the spike. The spike must pass the Day 9 key test: *a large image at high magnification pans with no delay.*

### 8.6 Renderer interface

Both GPU and CPU renderers implement the same interface. The existing BGRABitmap code becomes the CPU fallback and reference implementation.

```pascal
  IRenderer = interface
    procedure SetImage(const AImage: IDecodedImage);   { nil = nothing / placeholder }
    procedure SetViewState(const AState: TViewState);
    procedure Paint;
    procedure UploadStep(ABudgetMs: Integer);          { called per frame / on idle }
  end;
```

Painting is event-driven (`Invalidate`). Continuous redraw happens only while something animates (GIF, smooth zoom).

### 8.7 Movies (later versions) [Decision]

v1 plays only animated GIF. Movies come later, but the design is fixed now, so that nothing in v1 blocks it.

**Why: what went wrong in Hamana.** Hamana played movies with sound on Windows 2000/XP, and that stopped working on Windows 7 and later. The analysis of `Hamana.exe` (see `docs\Hamana_Research.md` and `docs\Hamana_Commands.md`) found three separate causes:

1. **System codecs.** Hamana decoded through DirectShow, so it could only play what the system had registered as **32-bit** DirectShow decoders. On XP, codec packs provided them. Today they are usually missing: other players bring their own decoders (VLC, mpv, MPC-HC), and Windows' own players use Media Foundation, which DirectShow programs can't use.
2. **A fixed extension list.** Hamana treats a file as a movie only if its extension is on a built-in list (`.avi .wmv .mpg .mpa .mpeg .vob .rm .asf .m2p`). `.mp4`, `.mkv` and `.mov` aren't on it.
3. **A foreign renderer inside the viewer's GPU device (the fatal one).** Hamana let the Windows video renderer (VMR9, with a custom allocator) write frames directly into Hamana's own Direct3D 9 device. On Windows 7+, starting a movie fails with `ResetDevice: hr = 8876086c` (`D3DERR_INVALIDCALL`): the device reset is refused because the video renderer still holds video surfaces on it. This was reproduced on 2026-09-25 with LAV Filters installed, so codecs alone don't explain it. It can't be fixed from outside the program.

**Rules for MView:**

| # | Rule | Avoids |
|-----|------------------------------------------------------------|---------|
| M1 | **Bundle the decoder.** Movies are decoded by FFmpeg libraries shipped next to `MView.exe` (LGPL build, dynamically linked). MView never depends on codecs registered in the system (DirectShow, Media Foundation). | Cause 1 |
| M2 | **Detect by content.** Whether a file is a movie is decided by probing the file (FFmpeg can identify the container), not by a fixed extension list. The extension list only pre-filters, and it is the one shared list from §16 #10. | Cause 2 |
| M3 | **Nothing outside MView touches its GPU context.** Movie frames are decoded on a worker into ordinary frames (the same pixel format as `IDecodedImage`) and uploaded by the renderer like any other texture (§8.3). No system video renderer, overlay or shared surface is ever attached to MView's OpenGL context. OpenGL also has no device-reset step that could fail this way. | Cause 3 |
| M4 | **One view, one transform.** Zoom, pan, rotation and mirror apply to movies exactly as to still images, because a movie frame is just a texture. (Hamana did achieve this, and it is worth keeping.) | — |
| M5 | **Stream, don't preload.** A movie keeps a small bounded queue of decoded frames (a few frames ahead), not a whole file in memory. The queue counts toward the cache budget (§13). Seeking or leaving the movie cancels queued work under the normal cancellation rules (§5.6). | Memory blow-up |
| M6 | **Audio is the clock.** When a movie has sound, the audio output sets the playback time, and video frames are shown to match it. Without sound, a UI-thread timer is the clock, the same as for animated GIF. GIF playback in v1 is written so that movies can later reuse its frame-timing code. | A/V drift |

**Threads.** Movies add one demux/decode thread per playing movie and one audio output thread. This extends §5.1, which describes v1. Movie decoding never uses the image decode workers, so a playing movie can't delay the current still image (§2.2).

**[Open]** Audio output library (options: WASAPI directly, or a small wrapper such as miniaudio), and whether hardware video decoding is worth its complexity. Decide when movies are scheduled.

---

## 9. Input and commands

### 9.1 Commands

All actions are `TCommand` values dispatched by `TCommandDispatcher`. Current set (uCommands.pas) plus v1.2 additions:

```
NextImage  PreviousImage  NextDirectory  PreviousDirectory
ZoomIn  ZoomOut  FitToScreen  OriginalSize  RotateLeft  RotateRight
PanBy(dx, dy)   ToggleSortMode   Rescan   Magnifier   Exit
Later: MoveTo(folder)  CopyTo(folder)  NextPage  PreviousPage
```

`TMediaView` must not call `TRenderer.ZoomIn` directly (it does today). It produces commands.

### 9.2 Mouse engine

- The screen is divided into four quadrants. Each quadrant has its own command map. Quadrants represent workflow contexts:

| Quadrant | Default role |
|---|---|
| Bottom left | Primary browsing, sorted by date (newest → oldest) |
| Top right | Secondary browsing, sorted by natural filename |
| Bottom right | Inspection: wheel = zoom |
| Top left | Reserved |

- Gestures (right button held + move): left = previous directory, right = next directory, down = exit.
- Mouse cursor hides after `MouseCursorHideTime`.
- Mappings live in a separate mouse profile file (`Default.mouse`), not in MView.ini. v1 format is INI-style. The scripting language comes later and replaces it without changing commands.

### 9.3 Keyboard

Minimal: arrows, PgUp/PgDn, Home/End, Esc = exit. Keys also produce commands.

---

## 10. Navigation

- `TNavigator` lives on the UI thread and holds **snapshots** (`TDirectoryTree`, `TDirectoryImages`) produced by the scanner. A rescan produces a new snapshot that is swapped in. Snapshots are never modified in place.
- Navigation is index manipulation only. It never touches the disk.
- **Wrap-around:** last image → first image, also when there is only one directory. Last directory → first directory.
- Directories without images are skipped.
- **Peek:** `Navigator.FileAtOffset(k)` returns the file *k* steps away in either direction, crossing directory boundaries, or "unknown" if that directory has not been listed yet. The scheduler uses it for preloading. "Unknown" makes the scanner list that neighbor directory at S1.
- **Sorting:** date (newest → oldest default, oldest → newest optional) or **natural filename** (digit runs compare numerically, case-insensitive: `Image2 < Image10`). Changing sort mode re-sorts only the current directory's list and triggers a reconcile. Directories are always alphabetical (natural).
- Files moved or deleted externally are detected when they fail to open. They are removed from the snapshot, and navigation continues. There is no file watcher in v1.

---

## 11. Startup sequence [Decision]

The first image has priority over everything, including knowing what directory it is in.

| Phase | Work | Thread |
|---|---|---|
| 0 | Parse command line. Create window (black). | UI |
| 1 | If a **file** was given: P0 decode job immediately, before any scanning. | worker |
| 2 | List the file's directory → navigator snapshot → select the file → reconcile (preloading starts). | scanner → UI |
| 3 | List neighbor directories (for cross-directory preload). | scanner |
| 4 | Recursive tree, if enabled. | scanner |

If a **directory** was given: phase 2 first, then P0 for its first image in the active sort order.

If **nothing** was given: `LastDirectory` from the ini. If that is missing: a blank screen with the configuration editor. **[Decision]**

---

## 12. Performance targets [proposals, verify by benchmark]

| Measure | Target |
|---|---|
| Pan / zoom / rotate at any magnification | every frame ≤ 16 ms (60 fps), zero CPU resampling |
| Next image, already preloaded | visible in the next frame after the command |
| Next image, not preloaded | preview visible within ~50 ms where the format has a preview |
| Launch to first image (typical 4–8 MP JPEG, local SSD) | ≤ 250 ms |
| UI thread work per message | ≤ 8 ms; anything longer moves to a worker |
| Holding the wheel (Skim) | no queued-up lag: when the wheel stops, the image under the current position appears within one decode time |

A **diagnostics overlay** (`ShowFPS=1`) shows: frame time, decode time and upload time of the current image, queue depth per priority, cache MB, texture MB, mode (Browse/Skim). This is the main tool for verifying the targets.

---

## 13. Memory

- `TImageCache` budget in MB (`CacheSizeMB`). Eviction by **distance from the current image** (sliding window), not LRU. The current image is never evicted.
- The effective preload count = min(`PreloadCount`, what fits in the budget). Example: 24 MP images are about 96 MB each at BGRA 8-bit, so 512 MB holds only 5.
- **[Open]** default budget: proposal 25 % of physical RAM (capped at 4 GB).
- **[Decision]** 64-bit is the target. A 32-bit version, if ever needed, is a fork with reduced budgets (a 32-bit process has only 2–4 GB of address space).

---

## 14. Configuration

`MView.ini` sections (existing): Startup, Window, View, Navigation, Performance, Mouse, Renderer, Debug. Additions for v1.2:

```ini
[Navigation]
WrapScope=Tree          ; Folder | Tree
PlaceholderForBadImages=1

[Performance]
PreloadCount=5          ; ahead
PreloadBehind=2         ; always keep 2 previous images
CacheSizeMB=0           ; 0 = automatic (see §13)
TextureCacheMB=512
DecodeThreads=0         ; 0 = automatic (cores − 1, max 4)
SkimEnterMs=1500        ; fast scrolling must last this long before Skim starts
SkimRate=4              ; images per second that count as fast scrolling
SkimExitMs=250          ; Skim ends this soon after scrolling stops

[Renderer]
Renderer=GPU            ; GPU | CPU
UseMipMaps=1
MagnifyFilter=Linear    ; Linear | Nearest
TileSize=2048
UploadBudgetMs=4
ZoomStepPercent=20
```

Rules (unchanged): the command line overrides the ini; only `TConfig` reads and writes it; typed properties, no strings passed around.

---

## 15. Testing and benchmarks

- **Navigation tests** (`test\TestNavigation.lpr`, exists): extend with wrap-around in a single directory, natural sort, directory skipping, `FileAtOffset` across directories.
- **Scheduler tests:** a fake loader that sleeps for a configurable time makes the scheduler deterministic to test. Checks: P0 always starts within one job slot, obsolete jobs are cancelled, running jobs are promoted not restarted, the wanted set is respected.
- **Benchmarks** (`benchmarks\`): decode time per format and size, directory scan time on a large tree (local and network), upload time per texture size, frame time while panning at 1600 %.
- **Test data:** the existing ~100 images plus the real TIFF set from §7.3.

---

## 16. Current code vs. this spec

Found in the mview3 source (2026-09-24). These are the first things to address.

| # | Where | Now | Spec |
|---|---|---|---|
| 1 | `TRenderer.Render` | `FBitmap.LoadFromFile` decodes on the UI thread inside the renderer. | Decoding in `TMediaLoader` on a worker. Renderer receives `IDecodedImage`. |
| 2 | `TMediaLoader.Load` | Returns a `TMedia` holding only the file name. | Returns decoded pixels (§7.2). |
| 3 | `TNavigator.OpenPath` / `TDirectoryTree.Build` | Directory listing and recursive scan run synchronously on the UI thread. | Scanner thread + snapshots (§10, §11). |
| 4 | `TMainForm.FormShow` | Ignores command line; opens `SelectDirectory` dialog. | Command line start, no dialogs (§11). |
| 5 | `TDirectoryImages.Compare` | Filename sort uses `CompareText` (`Image10` before `Image2`). | Natural sort. |
| 6 | `TNavigator.NextImage` | With a single directory, at the last image `SeekDirectoryWithImages` finds nothing and there's no wrap. | Always wrap (§10). |
| 7 | `TRenderer.CalculateFit` | Divides by `FBitmap.Width/Height`. With an empty folder, these are 0 → floating-point exception at paint. | Guard: no image → placeholder. |
| 8 | `TMediaView.KeyDown` | Calls `FRenderer.ZoomIn/ZoomOut` directly. | Produce commands (§9.1). |
| 9 | `TRenderer` | `FZoomStepPercent` hard-coded, `FConfig` never assigned. | From `TConfig` (`ZoomStepPercent`). |
| 10 | `ImageExtensions` | Lists `.webp`, `.avif`, `.pcx`, `.tga`, `.ico`, `.xpm`, which v1 does not decode. | Only formats `TMediaLoader` can decode, taken from one shared list. |
| 11 | Source tree | `backup\` folders, `*.bak`, `*.old`, `___old__uMediaLoader.pas`. | Exclude via `.gitignore`. Remove dead units. |
| 12 | `MView.lpi` | BGRABitmap is compiled from a source folder added to the unit path (`c:\Users\Administrator\Documents\src2\bgrabitmap\...`). Target and unit output use absolute `c:\projects\mview\...` paths. | `BGRABitmapPack` as a required package. Relative paths (§19.4). |
| 13 | `mview.lpk` + `mview.pas` | A package also named "MView" in the project root, requiring only FCL, not used by the project. | Remove, unless it has a purpose (§19.4). |
| 14 | `uRenderer.pas`, `uCommands.pas` | No `{$mode ObjFPC}{$H+}` line, so they rely on the project default. | Same header in every unit (coding standard). |

---

## 17. Implementation roadmap

Each phase ends with a compiling, usable viewer and a session log entry.

| Phase | Content | Done when |
|---|---|---|
| **A. Clean foundation** | Project setup from §19.4, items 1–2 and 4–14 from §16 (still synchronous), `IDecodedImage`, command dispatch through `TMView`. | Command-line start works, no dialogs, no crash on empty folder, natural sort, wrap works. |
| **B. Threading core** | `TJobQueue`, 1 decode worker, `TThread.Queue` delivery, cancellation, `TImageCache`, scanner thread for the current directory (item 3), clean shutdown. | Opening a huge TIFF never freezes the window. Esc during a decode exits immediately. |
| **C. Preloading** | Wanted set + reconcile, directional window, `FileAtOffset` across directories, N workers with the reserved-worker rule, I/O gate. | Next image is instant when preloaded. The current image is never delayed by preloads (verified with the overlay). |
| **D. GPU renderer** | Spike (§8.5), then textures, tiles, mipmaps, transform, time-sliced upload, CPU fallback. | Pan at 1600 % on the largest test TIFF stays at 60 fps. |
| **E. Skim & quality levels** | Preview decode, Skim detection, refinement. | Holding the wheel never builds up lag. |
| **F. Mouse engine** | Quadrants, gestures, mouse profile file, cursor hide. | Daily browsing without keyboard. |
| **G. Later** | Edge move/copy menu, GIF animation, 16-bit windowing, multi-page TIFF, thumbnail cache, scripting. | — |

The GPU spike in phase D is independent of B and C, because the renderer only ever receives `IDecodedImage`. It can be done earlier if you want to settle the technology question first.

---

## 18. Decisions and open questions

| # | Question | Status |
|---|---|---|
| 1 | GPU technology | **Decided:** `TOpenGLControl`, unless another option clearly outperforms it (§8.5). |
| 2 | TIFF decoder, bit depths, compressions | Decided after the TIFF analysis (§7.3). |
| 3 | 16-bit display mapping for v1 | Decided after the TIFF analysis (§7.3). |
| 4 | 32/64-bit | **Decided:** 64-bit is the target, 32-bit would be a fork (§13). Default cache budget still open. |
| 5 | Skim thresholds | **Decided:** enter after 1–2 s of fast scrolling, leave quickly (~250 ms), both in the ini (§6, §14). |
| 6 | Start without arguments and no `LastDirectory` | **Decided:** blank screen with the configuration editor (§11). |
| 7 | Default decode thread count | Open (§5.1). |
| 8 | Thumbnail cache storage | Open: safest option, can be turned on and off (§3.2). |
| 9 | Movie playback | **Decided:** bundled FFmpeg decoder, detection by content, frames rendered as ordinary textures, no system video renderer (§8.7). Audio output library still open. |

---

## 19. Development environment and Lazarus packages

### 19.1 Tools

| Item | Requirement |
|---|---|
| Lazarus IDE | Current stable release, **64-bit Windows installer** (4.x at the time of writing), with the Free Pascal compiler bundled with it. |
| Compiler target | `x86_64-win64`. The 32-bit fork, if it ever exists, needs the separate win32 cross-compiler add-on installer. |
| Debugger | FpDebug (the default in current Lazarus) with DWARF 3 debug info (already set in `MView.lpi`). |
| Version control | Git, with the `.gitignore` from §19.5. |

### 19.2 Required packages

| Package | Provides | Where it comes from | Install in IDE? | Needed from |
|---|---|---|---|---|
| **LCL** | Forms, controls, `TCustomControl` for `TMediaView`, `TThread.Queue` integration with the message loop | Ships with Lazarus | Already installed | Now |
| **FCL** (incl. fcl-image) | `Classes` (`TThread`), `SyncObjs` (`TEvent`, `TCriticalSection`), `IniFiles`, image readers `FPReadJPEG`, `FPReadPNG`, `FPReadTiff`, `FPReadGif`, `FPReadBMP` | Ships with FPC | No, available by default | Now |
| **BGRABitmapPack** | `TBGRABitmap`, `TBGRAPixel`, resampling for the CPU renderer | **Online Package Manager** (*Package → Online Package Manager → BGRABitmap*) | Not required. Adding it as a project requirement is enough, since MView creates no BGRA components at design time. | Now (replaces the source path, §16 #12) |
| **LazOpenGLContext** | `TOpenGLControl` (unit `OpenGLContext`), the GPU surface for `TMediaView` | Ships with Lazarus (`components\opengl`) | Not required. MView creates the control in code. | Phase D |
| **FPCUnitConsoleRunner** (or FPCUnitTestRunner for a GUI runner) | FPCUnit tests for navigation and scheduler (§15) | Ships with Lazarus | No | Phase B (test projects only) |

How to add a requirement: *Project → Project Inspector → Add → New Requirement*, then choose the package. It is stored in `MView.lpi` under `RequiredPackages`, so every PC that opens the project knows what it needs.

### 19.3 Units and libraries without a package

| Unit / library | Use | Note |
|---|---|---|
| `GL`, `GLext` (FPC `packages\opengl`) | OpenGL calls: textures, `GL_MAX_TEXTURE_SIZE`, mipmaps | Functions newer than OpenGL 1.1 must be loaded at runtime with the `Load_GL_version_x_y` functions in `GLext`, after the context exists. |
| `Math` → `SetExceptionMask` | Mask floating-point exceptions before creating the OpenGL context | Many OpenGL drivers trigger floating-point exceptions that FPC programs treat as errors by default. Mask them at startup of the GPU renderer. |
| `cthreads` | Thread support on Unix | Already in `MView.lpr` behind `{$IFDEF UNIX}`. Windows needs nothing. |
| libtiff DLL (optional) | Fallback TIFF decoder | Only if the TIFF analysis shows `FPReadTiff` is not enough (§7.3). Shipped next to `MView.exe`. |
| FFmpeg DLLs (later) | Movie decoding (§8.7) | LGPL build, dynamically linked, shipped next to `MView.exe`. Not needed for v1. |

No other third-party packages are planned. Every new package must be justified in the decision log, because each one adds setup work for every developer.

### 19.4 Project setup changes (Phase A)

1. **BGRABitmap as a package.** Install BGRABitmap from the Online Package Manager, add `BGRABitmapPack` as a requirement, and remove `c:\Users\Administrator\Documents\src2\bgrabitmap\bgrabitmap\` from *Other unit files*. The project then builds on any PC, and BGRABitmap updates go through the package manager.
2. **Relative paths.** *Target file name* `build\MView` and *Unit output directory* `build\units\$(TargetCPU)-$(TargetOS)`, not `c:\projects\mview\...`.
3. **Remove `mview.lpk` and `mview.pas`**, unless they have a purpose. A package with the same name as the project is confusing, and the project doesn't use it.
4. **Two build modes** (*Project Options → Build modes*):

| Setting | Debug | Release |
|---|---|---|
| Optimization | `-O1` | `-O2` |
| Checks | Range, overflow, I/O, object checks (`-Criot`), assertions (`-Sa`) | Off |
| Debug info | DWARF 3, line info (`-gl`) | None, or external debug file (`-Xg`) |
| Memory leak check | HeapTrc (`-gh`) | Off |
| Smart linking | Off | On (`-CX -XX`) |
| Defines | `DEBUG` (enables the diagnostics overlay by default) | — |

5. **Unit header.** Every unit starts with `{$mode ObjFPC}{$H+}`.

### 19.5 `.gitignore`

```
build/
lib/
backup/
*.lps
*.bak
*.old
*.compiled
*.ppu
*.o
*.or
*.res.bak
*.exe
*.dbg
```

`MView.lps` is the IDE's personal session file (open tabs, cursor positions). It stays out of the repository. `MView.res` stays in, because it holds the icon and version info.

### 19.6 Target PC requirements

- Windows 10 or 11, 64-bit.
- GPU with OpenGL **2.1** as the minimum (textures of any size) and **3.0** recommended (mipmap generation on the GPU). Nearly every GPU of the last 10 years qualifies.
- **The GPU vendor's driver must be installed.** Without it, Windows offers only an OpenGL 1.1 software fallback. MView detects this at startup, logs it, and switches to the CPU renderer (`Renderer=CPU`).
- RAM: 8 GB minimum, 16 GB or more recommended for large microscopy TIFFs (§13).

