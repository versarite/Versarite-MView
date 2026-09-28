# MView Developer Specification v1.3

**Date:** 2026-09-27 (v1.3: Phases E and F and the work of Days 18–19 written back: previews and Skim, own TIFF and GIF decoders, PNG / BMP through WIC, the failsafe against lockups, the mouse language, edit mode with select and crop. v1.2d: decisions and measurements of Phases A–D written back; start without arguments opens the settings editor; interim mouse profile and gestures. v1.2c: movie playback design added, §8.7, based on the Hamana analysis. v1.2b: review of v1.2a, Lazarus requirements added)

**Status (v1.3):** Phases A–E are done. Phase F (mouse engine) is built and in testing. GIF animation, a Phase G item, was pulled forward and is done. Edit mode with select and crop (Phase G) is started. Still open: the Phase D pan test on the largest TIFF (now possible with the NASA images, §12), and real microscopy TIFFs (16-bit, multi-page, tiled, §7.3); the user says they are not super-sized. The day-by-day details are in `docs\day010.log` … `day019.log`. Passages marked *(v1.2d)* describe what was built and measured up to Day 17; passages marked *(v1.3)* describe what was built and measured on Days 18–19.
**Replaces:** v1.0 (Microscopy Image Viewer Developer Specification) and v1.1 (performance architecture)
**Platform:** Windows 64-bit. A 32-bit version, if needed, is a separate fork.
**Language:** Lazarus / Free Pascal, LCL GUI application

v1.2 merges v1.0 (features, modules) and v1.1 (performance philosophy) into one document and adds the part neither had: a concrete **threading model** in which **image loading always has preference** over every other kind of work.

Sections marked **[Decision]** are settled. Sections marked **[Open]** still need a decision, usually after a benchmark or a spike.

### Changes in v1.3

- §5: preloads also give way at the I/O gate; the watchdog thread (emergency exit, exit deadline); stuck reads detected and replaced; the window thread never reads the disk; the scanner delivers the start listing first, then the tree.
- §6: Skim mode built, with a sliding-window rate.
- §7: Preview level (EXIF thumbnails); own readers for uncompressed and LZW TIFF; PNG and BMP through WIC in bands; own GIF decoder; memory guard and plausibility checks; empty and damaged files.
- §8: GIF playback as designed in §8.7; two-line diagnostics, zone label, gesture preview, selection frame, overlay options.
- §9: the mouse language as built (zones, profile file, commands by name, default profile); keyboard reduced to Space / Enter / D (programmable), Esc (fixed: modes off, else the settings screen, which it exits), the arrow keys and Ctrl+V; edit mode with select and crop; context menu, paste and save.
- §10, §11: opening through the scanner; drag and drop; "Mouse & keys" page in the settings editor; window place remembered; `startup.csv`.
- §12, §13, §14, §15: Day 18–19 measurements, memory limits, new ini keys, new tests.
- §17, §18: phase table and decisions updated.
- §1.1, §2.0 (Day 19, night): the homage to Hamana and the first principle; the Hamana mouse profile; the architecture pictures in `docs\architecture\`.

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

### 1.1 A homage to Hamana *(v1.3)*

MView is dedicated to **Hamana** by Makito Miyano (last version 1.48, 2006): a GPU viewer years before that was common, with read-ahead so the next image never waited, and a mouse that did the work. Its source was never published, so its bugs could never be fixed; MView carries its ideas forward in open, documented code. The homage is in the ideas, the credit (readme, the About box in the menu) and the Hamana mouse profile (`mouse\Hamana.mouse`, §9.2), never in copied code, formats or artwork. What MView kept, what it changed and why: `docs\From_Hamana_to_MView.md`.

---

## 2. Principles

### 2.0 The first principle *(v1.3)* [Decision]

> **Fast first, mouse first, never in the way.**

What made Hamana worth twenty years, and the test for every feature, the microscopy ones included: does it make the next image come sooner, can it be done with the mouse, and does it stay out of the way when it is not needed?

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
| Preload decodes reading the disk *(v1.3)* | They wait at the I/O gate too, before reading and between bands (§5.5). |
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
6. *(v1.3)* **The window thread never reads the disk** for images or folders (§10). A failing or hung disk can then only stall a worker or the scanner, never the window.

---

## 3. Features

### 3.1 Version 1 (mandatory)

- Start from command line: `mview.exe image.tif` or `mview.exe C:\Experiment`. Started without arguments, MView shows its settings editor (§11). *(v1.3: a file or folder dropped on the window opens it the same way.)*
- Fullscreen, no menu bar, no toolbar, no dialogs. *(v1.3: the right-click menu contains Paste image, Crop selection (edit mode only), Save image, Save image and view (debugging) and Exit, §9.6.)*
- Formats: TIFF (highest priority), JPEG, PNG, BMP, GIF including animation. *(v1.3: GIF animation is done, §8.7.)*
- Recursive directory navigation with wrap-around for images and directories. No dead ends. Wrap-around scope set in the ini: per folder or per tree.
- Sort modes: date (newest → oldest, default) and natural filename.
- Fit-to-screen, original size (1:1), zoom, free pan, rotation in 90° steps or free angle.
- Background preloading in the direction of travel, crossing directory boundaries. The 2 previous images always stay in memory.
- Browse and Skim modes (§6).
- Screen-zone-based mouse control and gestures (§9). *(v1.3: built, with a profile file.)*
- Unreadable files never stop navigation. A placeholder is shown only for files with an image extension that fail to decode (can be turned off in the ini). Other files are skipped silently.

### 3.2 Later versions

- Slide-in edge menu with buttons for favorite destination folders (Good / Interesting / Reject / …): one click moves or copies the current image, and browsing continues without interruption.
- Crop and rotate a region of interest, change brightness, contrast and dynamic range, and save the result to a repository folder, leaving the original untouched. Details to be specified later. *(v1.3: started: edit mode with select, crop and save, §9.5.)*
- *(v1.3)* Image filters and measurement tools derived from Fiji (planned by the user; to be specified later).
- Thumbnail cache on disk (no database), can be turned on and off. Storage method to be decided (safest option).
- Event-driven mouse scripting language. *(v1.3: the profile file of §9.2 is the first step.)*
- Magnifier, cursor-centered zoom, mirror. *(v1.2d: wheel zoom keeps the point under the mouse, §8.1.)*
- Additional formats (WebP, JPEG XL, AVIF). Movies with sound, designed in §8.7 (on the back burner, §18 #9).

### 3.3 Out of scope

Image database (possibly reconsidered later), tagging, advanced editing, file management beyond move/copy.

---

## 4. Architecture

### 4.1 Ownership tree

```
TMainForm                         (presentation, thin shell)
 ├── TIniEditor                   settings editor, only when started without arguments (§11)
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

**As built (v1.2d, updated v1.3).** Where the code differs from the tree above:

| Spec | Code | Note |
|---|---|---|
| `TCommandDispatcher` | `TMView.Execute(ACommand, AArgs)` | A separate class wasn't needed. |
| `TMouseEngine` | *(v1.3)* `TMouseEngine` (`source\mouse\uMouseEngine.pas`) with `TMouseProfile` (`uMouseProfile.pas`) | Phase F (§9.2). The interim `TInputHandler` of v1.2d is no longer used. The engine uses no LCL; the drawing surfaces pass it their raw input. |
| `TMediaView` | `TMediaView` (CPU) or `TGLMediaView` (GPU, a `TOpenGLControl`) | One of the two, chosen at startup (§8.5). |
| `TRenderer` | abstract `TRenderer` (view model) with `TGLRenderer` and `TCpuRenderer` | §8.6. |
| `TTextureCache` | none yet: `TGLRenderer` holds the textures of the current image only | §8.4. |
| — | `TIOGate` | §5.5. |
| — | *(v1.3)* `TWatchdog` (`source\utility\uWatchdog.pas`) | Its own thread: emergency exit and exit deadline (§5.8). Runs until the process ends, never freed. |
| — | *(v1.3)* `uMemoryGuard` | Size check before every large allocation (§7.5). |
| — | *(v1.3)* `uTiffQuick`, `uGifDecoder`, `uJpegHeader` | Own readers for uncompressed and LZW TIFF, GIF, and the start of a JPEG (§7). |
| — | *(v1.3)* `TAnimation`, `TAnimationCursor`, `TFrameClock` (`uAnimation`) | Animation frames, picture building and timing (§8.7). |
| — | *(v1.3)* `TMouseProfilePage` (`source\config\uMousePage.pas`) | "Mouse & keys" page of the settings editor (§11). |

### 4.2 Responsibilities

| Class | Responsibilities | Does NOT |
|---|---|---|
| `TMView` | Create/destroy subsystems, route commands, connect scheduler results to renderer. *(v1.3: also plays animations, holds edit mode and the selection.)* | Decode, draw, scan, handle raw input. |
| `TNavigator` | Current directory and image index, next/previous, wrap-around, answer "which file is at offset *k*?". | Access the filesystem (it receives listings from the scanner). |
| `TDirectoryScanner` | List directories on its own thread, build the tree, deliver immutable snapshots. *(v1.3: also resolves what to open, §10.)* | Decide what the user sees. |
| `TJobScheduler` | Turn navigation into a *wanted set* of jobs, prioritize, cancel, switch Browse/Skim. *(v1.3: detects and replaces stuck workers, §5.6.)* | Decode anything itself. |
| `TMediaLoader` | Decode a file at a requested quality, report progress, honor cancellation. | Schedule, cache, or know about threads. |
| `TImageCache` | Own decoded images, replace lower quality with higher, evict by distance from current image. | Decide what to load. |
| `TRenderer` | Upload textures, draw the current image using the view transform. | Open files, decode, navigate. |
| `TMouseEngine` | Zones, wheel, clicks, gestures, keys → commands, following the mouse profile. | Contain any viewer logic, use the LCL. |
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
| **Watchdog** *(v1.3)* | 1 | Emergency exit hotkey and exit deadline (§5.8). Touches nothing else. |
| **LZW helpers** *(v1.3)* | 0 … 3 (cores − 1), only during a display job's LZW TIFF decode | Decode every n-th strip with their own file handle and buffers (§7.3). |

*(v1.2d)* The worker count is `DecodeThreads` (0 = automatic: cores − 1, 1..4). Each worker initialises COM (multithreaded) for WIC (§7.1).

*(v1.3)* A stuck worker is replaced by a new one (at most 4 replacements per session), and a stuck scanner by a new scanner when the user opens something else (at most 4), §5.6.

No other threads. GIF playback uses a UI-thread timer. Its frames are decoded by a worker. (Movies, in a later version, add their own threads; see §8.7.)

Early phases may run with **N = 1**. The architecture does not change when N grows.

### 5.2 Priorities

Lower number = more urgent.

| Priority | Job | Runs on | Browse | Skim |
|---|---|---|---|---|
| **P0 Display** | Current image, best quality obtainable quickly | worker | ✓ | ✓ (preview quality) |
| **P1 Refine** | Current image, full quality | worker | ✓ | — |
| **P2 Ahead** | Next images in the direction of travel, nearest first | worker | ✓ | previews only *(v1.3)* |
| **P3 Behind** | Images behind the current one | worker | ✓ | — |
| **S1 List** | Current directory, then neighbor directories | scanner | ✓ | ✓ |
| **S2 Tree** | Recursive tree | scanner | ✓ | paused (planned; *v1.3: not paused, not needed so far*) |
| **S3 Thumbs** | Thumbnails (later) | scanner | idle only | — |

Worker jobs and scanner jobs run on different threads, so they do not compete for CPU. They compete only for the disk, which the I/O gate (§5.5) resolves.

### 5.3 The wanted set: declarative scheduling

The scheduler is not told "load this, then that". After every navigation it is told **what should exist**, and it reconciles:

```
OnNavigate(position, direction):
  Epoch := Epoch + 1
  Wanted := [ current @ P0 ]               { v1.3: Preview and Screen, both P0, if nothing is cached }
  if Mode = Browse then
    Wanted += [ current @ P1 (full) ]      { v1.2d: only after RefineDelayMs on the image, or at once on zoom }
    Wanted += previews of the next PreviewAhead images @ P2   { v1.3 }
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

*(v1.3)* As built in Phase E:
- Current image, nothing cached: Preview and Screen, both P0. The thumbnail shows within a few ms and is replaced by the quick view without changing the view (Preview → Screen → Full).
- Previews of the next `PreviewAhead` images (default 10) come first among the preloads: each costs only a header read.
- Screen preloads as before. A cached thumbnail doesn't count as preloaded.
- The same list, current first, is the cache's eviction window (§13).

### 5.4 Keeping a worker free for the current image [Decision]

- With **N ≥ 2**: a worker may take a P2/P3 job only if at least one *other* worker is idle. So one worker is always free for P0, and no cancellation is needed.
- With **N = 1**: when a P0 job arrives and the worker is busy with a P2/P3 job for a *different* image, that job is cancelled.
- If the P0 image is the one already being decoded, its job is promoted to P0 and allowed to finish.

### 5.5 I/O gate [Decision]

On a hard disk or network share, a directory scan can slow the read of the current image a lot.

- A P0 job raises the gate (`TEvent` reset) before reading the file and lowers it after the file data is read (not after decoding).
- The scanner checks the gate between directory entries and waits while it is raised.
- Preload jobs (P2/P3) do not raise the gate.
- *(v1.3)* **Preloads wait at the gate too** (`IOGate.YieldToDisplay`): before reading a JPEG or other file, between the WIC bands of a TIFF / PNG / BMP, and every 32 output rows of the own TIFF readers. While waiting they check for cancel every 50 ms, and they give up waiting after 5 s, so nothing can hang. Reason: on Day 18 three preloads read other 324 MB TIFFs from the same disk while the current one loaded ("jobs 3 waiting, 3 of 4 workers busy").

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
  *(v1.2d)* FPC 3.2.2's JPEG reader never calls it (its progress hook is an empty stub) and is slow (per-pixel virtual calls). MView therefore has its own JPEG decoder on pasjpeg (`uJpegDecoder`): cancel checked every 16 rows and while a progressive JPEG is read in; a cancelled decode returns nil instead of raising. WIC decodes are copied out in bands of about 8 MB with a cancel check between bands.
  *(v1.3)* The own TIFF and GIF readers check per band, every 16–32 rows or per file part. PNG and BMP now go through WIC in bands too (§7.1), so they are cancellable.
- Setting `Cancel` is cheap and safe from any thread. A cancelled job's result is discarded, never partially shown.
- `Deliver` checks that the result still matches something wanted (key + quality). A late result for a still-wanted image goes into the cache even if it came from an older epoch.

*(v1.3)* **Stuck reads** [Decision]. A thread waiting in a read that Windows can't interrupt (a bad sector being retried, a hung USB or network drive) keeps the whole process alive until the read returns. No program can end it, Task Manager included. MView can't prevent that, but it doesn't wait for it:
- Every decoder's cancel check also records "alive" (`TDecodeJob.WorkerCancelCheck`). A job not alive for **20 s** (`StuckReadMs`) is taken as stuck (`TJobScheduler.CheckStuck`, twice a second). The file gets the placeholder "Disk not responding (no answer for 20 s)", the job is cancelled, Windows is asked to cancel the read (`CancelSynchronousIo`, where the driver allows), the I/O gate is opened, and a replacement worker starts (at most 4 per session). If the stuck worker comes back later, it leaves if it was replaced, or simply goes on working; its image then replaces the placeholder.
- The testing delay `DecodeDelayMs` doesn't count as stuck.
- The scanner: when it hasn't come back for 20 s, the info line says "reading folders: the disk is not responding". Opening something else then starts a new scanner (at most 4).

### 5.7 Delivering results to the UI thread

- Worker finishes → `TThread.Queue(nil, @Job.Deliver)`.
- `Deliver` (UI thread): put the image into `TImageCache`. If it is the current image, pass it to the renderer and `Invalidate`.
- Never use `TThread.Synchronize` from workers. It makes the worker wait for the UI thread.
- *(v1.2d)* **Safety net:** a 50 ms UI timer calls `CheckSynchronize(0)` (`TMView.PumpDeliveries`). Without it, deliveries were occasionally left waiting after fast scrolling ("image name shown, picture never came").
- *(v1.3)* The scanner delivers in two steps: first the start folder's listing (`TScanStart`, `OnStartReady`), then the tree with every folder's listing (`OnTreeReady`). A tree can't overtake its start.

### 5.8 Shutdown order

1. Stop accepting commands. *(v1.3: arm the watchdog's exit deadline, and save the settings first, so they survive a forced end.)*
2. Cancel all jobs, signal the scanner to stop, lower the I/O gate.
3. `WaitFor` all threads. *(v1.3: except threads taken as stuck: they are not waited for, and what they may still use is not freed.)*
4. Remove pending queued deliveries (`TThread.RemoveQueuedEvents`).
5. Free cache, renderer (textures), then the remaining subsystems in reverse creation order.

Missing any of these steps usually shows up as a crash on exit, when a queued `Deliver` runs against a freed object.

*(v1.3)* **Watchdog** [Decision] (`uWatchdog`). Reported on 2026-09-27: on an image workstation a corrupt JPEG froze MView so badly that the process could not be ended. The watchdog is a small thread of its own that depends on neither the window nor the workers:
- **Emergency exit: Ctrl+Alt+Shift+Q**, a system-wide hotkey registered by the watchdog thread. It ends the process at once (`TerminateProcess`), even while the window is frozen. No settings are saved. The context menu shows the key next to Exit. If another program already uses the key, it isn't available (`TWatchdog.HotkeyRegistered = False`); the Exit menu item, Esc (via the settings screen) and the deadline still work.
- **Exit deadline:** every way of closing (Esc, gesture, menu, window button, settings editor) arms a **4 s** deadline. A shutdown that takes longer, e.g. waiting for a worker stuck in a decode, ends with the process being terminated, instead of a process without a window left running.
- What it can't do: when a thread is stuck inside Windows (a driver, a read that never returns), Windows itself can't end the process until the read returns. The window is gone at once; the process ends when the read returns.

---

## 6. Browse and Skim modes [Decision]

| | Browse | Skim |
|---|---|---|
| Goal | Best quality, smooth browsing | Lowest latency while flicking through |
| Preloading | Aggressive | Suspended *(v1.3: except previews ahead)* |
| Current image | Preview → full | Preview / screen quality only |
| Recursive scan | Runs | Paused *(v1.3: not paused, not needed so far)* |

**Entering Skim:** fast navigation has lasted for `SkimEnterMs` (default **1500 ms**, range 1–2 s). "Fast" means each new navigation command arrives before the current image is displayed, or more than `SkimRate` image changes per second (default 4).

**Leaving Skim:** no navigation for `SkimExitMs` (default **250 ms**), much shorter than entering, so full quality returns almost as soon as scrolling stops. The next reconcile runs in Browse mode, so refinement and preloading restart automatically.

Only the scheduler knows the mode. The renderer and loader never see it.

**[Decision]** Both times are ini settings (§14). Defaults to be tuned on real data.

*(v1.3)* **As built (Phase E):**
- **Rate over a sliding window** [Decision]: Skim while the steps of the last `SkimEnterMs` average `SkimRate` per second or more (a ring of the last 64 step times). With the defaults: 6 steps within 1.5 s. The first build (Day 18) needed an uninterrupted run of fast steps; the short pauses of spinning a wheel, and wheel events arriving in bursts while large quick views are put on screen, kept resetting the run, so Skim came too rarely.
- In Skim only previews are wanted (current and ahead): no Screen or Full decodes, no Screen preloads. Files without a thumbnail still get a Screen decode, which the next step cancels.
- `SkimExitMs` without a step switches back to Browse: the image the user stopped at gets its quick view at once, full size after `RefineDelayMs`. The next fast step takes Skim up again at once.
- The info line says "skimming", the D line "SKIM" (otherwise "browse").
- No animation plays while skimming; it starts when Skim ends (§8.7).
- `SkimEnterMs=0` turns Skim off.

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

**As built (v1.2d, updated v1.3)** [Decision]:

| Level | JPEG | TIFF *(v1.3)* | PNG, BMP *(v1.3)* | GIF *(v1.3)* |
|---|---|---|---|---|
| Preview | *(v1.3)* EXIF thumbnail (`uJpegHeader` reads only the start of the file): decoded, turned upright, black bars cut off when its shape differs from the photo. | — | — | — |
| Screen ("quick view") | WIC scaled decode 1/2 … 1/8 inside the codec *(v1.3, `UseWICQuickView=1`)*, or the own decoder with DCT scaling; then shrunk on the worker to **exactly the fitted window size**. Drawn 1:1, no resampling at paint time. | Uncompressed strips: own row-skipping reader. LZW strips: own decoder. Others: WIC in bands, averaged down while the bands arrive. | WIC in bands, averaged down while the bands arrive: only a screen-size bitmap is allocated. | The first frame only (§7.6). |
| Full | **WIC** (`uWicDecoder`), own decoder as fallback (except on out-of-memory). Plus a screen copy made the same way. | LZW: own decoder, straight into the bitmap. Others: WIC. Plus a screen copy. | WIC, after the memory guard. Plus a screen copy. | Every frame (§7.6). |

- Formats and JPEGs not larger than the window are decoded in full at once; the result then says Full.
- *(v1.3)* Files without a thumbnail answer "No preview in this file"; MView remembers them and doesn't ask again. A broken file whose thumbnail was readable shows its error, not the thumbnail. The 108 MP and 12 MP phone photos of the test set have no EXIF thumbnail; older phone photos do (190 × 107, 256 × 144).
- *(v1.3)* The final resize step is an own bilinear resize (`uImageScaling.BilinearResize`, 8-bit fractions), not BGRABitmap's resampler. It matches Pillow's bilinear within 0.4 levels on average.
- *(v1.3)* If WIC can't read a file, BGRABitmap / FPReadTiff take over, now with the memory guard first (§7.5).
- The target size follows the window. After the size has been stable for 400 ms, cached quick views are remade.
- The full decode of the current image starts after `RefineDelayMs` on the image (default 250 ms), or at once on zoom in / 100 % *(v1.3: or when edit mode is switched on)*.
- A Full result replaces the Screen version without resetting zoom, pan or rotation: all geometry is in original pixels (`FullWidth` / `FullHeight`).
- **EXIF orientation** is applied on the worker, at every level (`uExifOrientation`, `[View] AutoRotate=1`).
- Measured (GTX 960M laptop): WIC full decode 120–160 ms for 12 MP, about 1 s for 108 MP (pasjpeg: 6.1 s). More in §12.

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

*(v1.3)* An animated image carries a `TAnimation` (the frames, read only after the worker made them); its bitmap is the first frame. The frames stay palette indices until the UI thread builds the picture to show (§7.6, §8.7). This is the one exception to "conversion on the worker": building a GIF frame is a copy of a changed rectangle, done per frame.

### 7.3 TIFF specifics [Open]

- 16-bit and 32-bit float microscopy TIFFs need a mapping to 8-bit for display. Proposal for v1: linear min/max stretch computed on the worker. Later: adjustable window (brightness/contrast) as a shader.
- Multi-page TIFF (z-stacks, time series): v1 shows page 1. Later: page navigation as a separate command pair.
- Decoder: FPC's `FPReadTiff` first. If compressions used in your real data are unsupported, a libtiff DLL behind the same `TMediaLoader` interface.
- **Action:** collect 10–20 real TIFFs from the microscopes (bit depth, compression, size, page count) into `test\images\tiff\`. This decides the questions above. *(v1.3: still to come. The user says they are not super-sized.)*

*(v1.3)* **As built.** Test set so far: the 108 MP photos saved as TIFF by IrfanView (12000 × 9000, 24-bit RGB, 9 strips of 1024 rows, no embedded preview): `compressed` = LZW with horizontal predictor (53–60 MB), `uncompressed` = 324 MB each.

Loader order for TIFF [Decision]: **uncompressed quick view (row skipping) → own LZW reader → WIC → FPReadTiff.**

- **Uncompressed quick view** (`uTiffQuick`, own minimal IFD reader, layout checked against the file size). In an uncompressed strip TIFF every row's place in the file is known. A quick view reduced by S reads 2 rows of every S (a quarter and three quarters into each group, so fine patterns don't alias) and averages all columns: 81 MB instead of 324 MB at S = 8. Full size of these files goes through WIC, which reads them quickly.
- **LZW** (`uTiffQuick.LzwDecodeStrip`, `LoadLzwTiff`), quick view and full size. WIC needed 4.4–4.7 s for the quick view of a 108 MP LZW TIFF.
  - LZW decoding by position: each table entry is (position, length) of a string already in the output, so decoding is short copies inside the output buffer. One strip at a time; strips over 256 MB are left to WIC.
  - Predictor 2 is undone per row, only for the rows used (the quick view uses 2 of every S).
  - Full size goes straight into the bitmap.
  - `{$OPTIMIZATION ON}` (-O2) in the unit, whatever the project's level.
  - **Display jobs decode the strips in parallel:** up to 3 helper threads (`TLzwStripThread`, cores − 1), each taking every n-th strip with its own file handle and buffers. Each writes only its own rows. Preloads stay single-threaded and keep giving way at the I/O gate. Cancel: the worker checks between its strips and sets an abort flag the helpers watch.
  - A damaged strip leaves the rest black. Unreadable strip data or other layouts go to WIC.
  - Verified: a Python copy of the algorithm decodes all 9 strips of a test file bit-identical to Pillow (predictor included); the Pascal port was checked against it by an independent review.
- Supported by the own readers: strips (not tiles), 8 bits per sample, chunky, RGB (3 samples, or 4 with the extra one ignored) or grey (BlackIsZero / WhiteIsZero); uncompressed (quick view only) or LZW with predictor 1 or 2. **16-bit, float, tiled, planar and multi-page files are not handled by them**; they go to WIC / FPReadTiff until the real microscopy TIFFs decide (§18 #2, #3).
- Note: the current TIFF is decoded twice (quick view, then full after `RefineDelayMs` or on zoom), like JPEG.

### 7.4 Errors

- Unreadable, corrupt or vanished file → cache stores an error entry, the renderer draws a placeholder (dark screen, file name, short reason), and navigation continues normally.
- Never a modal dialog. Errors go to the log if logging is enabled.
- *(v1.3)* Specific cases, recognised before any large allocation:

| Case | Text on the placeholder |
|---|---|
| **Empty file** (size 0 from the listing), every quality level, so it isn't asked for again | "Empty file (0 bytes)" |
| **Implausible JPEG size:** the header claims more than 1000 pixels per byte of file (even a black JPEG needs about a byte per 160 pixels) | "Damaged file: the header claims W x H pixels, but the file has only N KB" |
| Too large for this computer (§7.5) | "image too large for this computer: W x H would need N MB (limit M MB)" |
| Read not coming back (§5.6) | "Disk not responding (no answer for 20 s)" |

- *(v1.3)* A damaged or cut-off GIF shows / plays what it contains (§7.6). A damaged LZW strip leaves the rest of the TIFF black.
- *(v1.3)* Test files in `test\images\broken` (see README.txt there): empty.jpg / .tif / .png, garbage.jpg (random bytes), header_only.jpg, truncated.jpg, jpeg_named.png (a JPEG with a .png name), huge_claim.jpg (frame header patched to 65535 × 65535, EXIF thumbnail intact). Browsing through that folder must show placeholders (for huge_claim.jpg: the thumbnail, then the error) and never stall.

### 7.5 Memory guard *(v1.3)* [Decision]

A corrupt header can claim any size: a JPEG up to 65535 × 65535, 17 GB as BGRA. Trying to allocate that makes Windows page the whole machine to disk until nothing responds, not even Task Manager. This is the most likely cause of the freeze reported on Day 19.

`uMemoryGuard`: before a bitmap is allocated, the loader checks that it fits: **at most half of the physical memory for one image, and never more than 2 gigapixels**. Otherwise the image gets the "too large" placeholder (§7.4). Applied to:
- JPEG, from the header, for the size actually decoded (1/2 … 1/8 for the quick view; full size plus screen copy);
- EXIF thumbnails (more than 4 MP is not a thumbnail);
- TIFF, PNG and BMP through WIC (after WIC reports the size), the own TIFF readers;
- GIF (§7.6);
- the BGRABitmap fallback: the size is taken from the PNG / BMP / GIF header before loading.

The JPEG plausibility check (§7.4) closes a gap the guard leaves: a claimed 65535 × 65535 fails the guard at full size, but its 1/8 quick view (268 MB) would still have been decoded, as grey.

### 7.6 GIF *(v1.3)* [Decision]

**Own decoder** (`uGifDecoder`) instead of BGRABitmap's reader, because MView needs the first frame alone and quickly, cancellation and the memory guard, damaged files that still show what they contain, and small frames.

- **Quality levels:** Screen = the first frame only, read from the start of the file (8 MB; the whole file only if the first frame needs more). It says Screen if more frames follow, Full for a still GIF. Full = every frame, asked for after the usual `RefineDelayMs` pause. So browsing and preloads never decode whole animations.
- **Frames as palette indices:** 8-bit indices plus a palette per frame, a quarter of BGRA (Test.gif: 126 frames of 800 × 704 = 70 MB instead of 284 MB). LZW by position, as for LZW TIFF; `{$OPTIMIZATION ON}`.
- **The picture is the logical screen size;** frames are clipped to it (as the GIF test suite expects). Only a logical screen of 0 × 0 takes the first frame's size.
- Disposal 1 / 2 / 3 and transparency. The picture starts transparent; transparent pixels show black. A delay of 0 or 1 plays at 100 ms (as browsers do).
- **Loop counts are honoured** (NETSCAPE2.0 / ANIMEXTS1.0): 0 = forever, n = n repeats after the first play; without the extension the animation plays once and stays on its last frame.
- Damage: a frame whose data is damaged or cut off is drawn as far as it was decoded; unknown blocks end the file (what came before is kept). A frame claiming more than the memory guard allows, or more than 4 times the picture (at least 16 MP), ends the file there (the first frame: error).
- Memory limit for all frames of one animation: a quarter of RAM, at most 2 GB. Frames beyond it are left out; the D line says so.
- Files named .gif that aren't GIFs go to BGRABitmap.
- Verified: a Python copy of the algorithm (`test\images\gif\gifproto.py`) is identical to Pillow frame by frame on Test.gif, three other real GIFs and synthetic ones; the Pascal port was compared against it by an independent review (cut at every length and 400 random corruptions: no out-of-bounds access). Playback: §8.7.

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

*(v1.2d)* As built:
- Zoom with the wheel keeps the point under the mouse fixed (`cmdZoomAt`): `Pan' = q − C − r·(q − C − Pan)` (q = mouse, C = window centre, r = zoom ratio). *(v1.3: the step per wheel notch is `ZoomStepPercent`; the + / − keys are gone, §9.3.)* Range 1/64 … 256×.
- Free rotation angle on the GPU (the CPU renderer rounds to quarter turns). Fit uses the bounding box of the turned image, so the size changes smoothly while turning.
- **[Decision]** Rotation is around the window centre. Rotation around the mouse (`Pan' = R(Pan + C − q) + q − C`) is postponed: it is only useful when preparing a crop (§3.2), so it comes with that feature.

### 8.2 Textures, tiles and mipmaps

- Query `GL_MAX_TEXTURE_SIZE` at startup. Images larger than that are split into **tiles** (proposal: 2048 × 2048) drawn as adjacent quads. *(v1.2d: every full image is tiled at **1024 × 1024**, for fine upload steps; smaller if the GPU's maximum is smaller.)*
- Generate **mipmaps** per texture so zoomed-out views are smooth and not aliased (`UseMipMaps=1` in the ini). *(v1.2d: with `glGenerateMipmap` (OpenGL 3.0, loaded at run time) after each tile. The old automatic `GL_GENERATE_MIPMAP` is only the fallback: with it, uploads ran at about 35 MB/s, 0.6 s per 2048 tile.)*
- Magnification filter: linear by default. **Nearest** as an option when zoomed beyond 1:1, so individual pixels can be inspected. *(v1.2d: nearest from 400 % on, automatically.)*
- Tiles overlap by a 1-pixel border and use clamp-to-edge. Otherwise linear filtering shows visible seams at high zoom. Hamana used 64×64 tiles by default and its manual warns about exactly these seams.
- At exactly 1:1, place the image on whole pixels and use nearest filtering, so original size is really pixel-exact. Hamana's manual admits its 1:1 view "may be slightly blurred depending on the video card".

### 8.3 Uploading without blocking

- An OpenGL context belongs to one thread, the UI thread here. Uploads happen there.
- Uploading a large image in one go can take long enough to cause a visible hitch. So uploads are **time-sliced**: each frame uploads tiles for at most a fixed budget (proposal: 4 ms). Current-image tiles go first; preloaded images' tiles are uploaded in `Application.OnIdle`.
- While tiles are missing, the renderer draws what is there, for example the preview texture scaled up underneath.
- Later: pixel buffer objects (PBOs) for asynchronous upload, if measurement shows the need.

*(v1.2d)* As built: budget **12 ms per frame**. A new image shows its screen copy first (one small texture). The full image's tiles are uploaded **nearest to the middle of the view first** and each tile is drawn over the screen copy as soon as it is there, so the view sharpens where the user looks. Preloaded images get no textures yet. The D line shows "sharpening n / N" and the time per tile (pixels + mipmaps).

*(v1.3)* An animation frame goes to the renderer as a new version of the same image, so zoom, pan and rotation stay. While the GPU is still uploading the previous frame (`TRenderer.IsUploading`), no new frame is built: the frame clock skips instead of queueing (§8.7).

### 8.4 GPU memory

`TTextureCache` keeps textures for the current image and the nearest preloaded images within a VRAM budget (proposal: 512 MB, configurable). *(v1.2d: not built; only the current image has textures. Needed only if the upload of preloaded full images shows up in measurements.)* A texture with mipmaps needs about 1.33 × width × height × 4 bytes.

### 8.5 Technology choice [Decision]

| Option | For | Against |
|---|---|---|
| **A. `TOpenGLControl` (LazOpenGLContext) + own texture class** | Full control over tiles, mipmaps, upload. Most educational. | More code to write. |
| B. BGRABitmap `BGRAOpenGL` (`TBGLVirtualScreen`) | Already using BGRABitmap, quick start. | Less control over tiling and upload timing. |
| C. Direct3D 9/11 via headers | Closest to Hamana. | Windows-only, most work, fewest Lazarus examples. |

Decision: **A (`TOpenGLControl`)**, unless another option clearly outperforms it in the spike. The spike must pass the Day 9 key test: *a large image at high magnification pans with no delay.*

*(v1.2d)* Built with A (`uGLRenderer`, `uGLMediaView`). OpenGL 2.0 is the minimum. If the context can't be made, OpenGL is too old, or only the Windows software OpenGL is there, MView uses the CPU renderer and the D line says why (`[Renderer] UseGPU=0` forces it). When the window is recreated (fullscreen switch), the textures are uploaded again. Panning and zooming 108 MP photos is smooth on a GTX 960M; the TIFF test is still to do. *(v1.3: a renderer made when switching to fullscreen also takes over edit mode and the selection.)*

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

*(v1.2d)* As built, an abstract class instead of an interface: `TRenderer` holds the shared view model (fit / original mode, zoom, pan, angle, `ZoomAt`, `PanBy`, `RotateBy`, `ToggleFit`) and the text bars; `TGLRenderer` and `TCpuRenderer` implement painting. `RequestScreenshot` saves a picture of the window for the debugging menu.

*(v1.3)* Texts and marks drawn over the image, by both renderers:

| Item | What it shows |
|---|---|
| Info line | File name, size, zoom; "skimming"; "animated, N frames"; "Cropped from <name>", "Clipboard image … not saved". |
| Diagnostics line (D) | Now **two lines** (one ran past the right edge on a full-HD screen): decode, screen copy, cache, latency, paint times, queue, mode (SKIM / browse), "sharpening n / N", animation "frame i / N, k skipped" or "done", and a note if the memory limit left frames out. |
| Mode label | "ZOOM" / "ROTATE" / "EDIT …" with a short hint (§9.5). |
| Zone label | The zone's name in its corner, for 1.5 s when the mouse enters the zone and with each command from it. **Only while the diagnostics line is on** (otherwise distracting, user, Day 19). |
| Gesture preview | While a gesture is made, what it will do, in the middle of the window (back to the start = nothing). |
| Selection frame | In edit mode: the selected area as a dark / light frame, in original image pixels, turned with the image (§9.5). |

Readability options (`[View]`, §14):
- `OverlaySolid=1`: the info and diagnostics lines on a solid black bar across the window instead of straight over the image (default 0).
- `OverlayColor=White | Yellow | Red`: colour of the texts over the image (default White). On the GPU the white text texture is tinted, so it costs nothing extra.

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

*(v1.3)* **Movie playback stays on the back burner** [Decision]: the user edits microscope movies in VirtualDub, so MView doesn't need to replicate that. The design above stays as the plan if movies are ever scheduled.

*(v1.3)* **GIF playback, as built** (`uAnimation`, `TMView`), following the design above:
- Three parts: `TAnimation` (the frames, made by a worker, read only afterwards), `TAnimationCursor` (builds whole pictures frame by frame on the UI thread; a GIF frame usually changes only a rectangle), and `TFrameClock` (which frame is due when).
- **`TFrameClock` knows nothing about GIF:** it asks for each frame's display time through a function, so a movie without sound can drive it the same way (rule M6). Fixed times from the start, so a late frame doesn't slow the animation; skipped frames are counted; after a stall of more than 1 s it goes on from now. It takes a play count and reports Finished (loop counts, §7.6).
- A UI-thread timer, set to the time until the next frame is due.
- Playback starts when the Full version (all frames) arrives, after about `RefineDelayMs`. Not while skimming (starts when Skim ends). Stops when another file is shown (and releases its frames). Showing the file again plays it again. A minimised window uploads nothing, so playback waits.
- Zoom, pan and rotation work while it plays. Crop takes the frame on screen (§9.5).

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

*(v1.2d)* Done. Commands can carry values (`TCommandArgs`: X, Y, Value): `ZoomAt(x, y, notches)`, `PanBy(dx, dy)`, `RotateBy(degrees)`, `ToggleFit(x, y)`, plus `InputMode` (shown on screen) and `SaveImage` (debugging). The mouse engine of Phase F produces the same commands.

*(v1.3)* Added: `SortByDate`, `SortByName`, `ParentDirectory` (browse from the parent of the opened folder), `OriginalSizeAt(x, y)`, `ToggleInfo`, `ToggleDiagnostics`, `ToggleFullscreen`, `ShowMenu(x, y)`, `Back` (leave a mode, else exit), `Paste`, `SaveImage` (the image as PNG), `SaveDebug` (image and window, the old save), `EditMode`, `EditModeOn`, `EditModeOff`, `CropSelection`, `DragStart(x, y)`, `DragPoint(x, y)`, `ShowZone(zone)`, `GesturePreview`. `Magnifier` is still reserved.

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

*(v1.3)* **The mouse language, as built (Phase F)** [Decision]. `uMouseProfile` (the profile file), `uMouseEngine` (raw input → commands). Both use no LCL, so `test\TestMouse.lpr` tests them with plain fpc. The user's aim: avoid keyboard interaction altogether.

**Profile file.** `Default.mouse` next to MView.ini (`[Mouse] Profile` names it). It is written with the built-in profile at the first start, so it can be edited. Lines it doesn't understand are reported with their line number (in the viewer's info line) and skipped; the rest of the file still counts.

```ini
[Anywhere]
RightClick   = Menu
GestureDown  = Exit

[Zone BottomLeft]
Name      = Browse by date
Order     = Date
WheelDown = NextImage
WheelUp   = PreviousImage

[Keys]
Space = NextImage
```

- **Zones:** the four quarters of the view (`TopLeft`, `TopRight`, `BottomLeft`, `BottomRight`). Each has a **name** (shown on screen, §8.6), an optional browsing **order** (`Date`, `Name` or `None`) and its own event table.
- **`[Anywhere]`:** what a zone doesn't set itself. In a zone, `None` switches an Anywhere entry off there.
- **`[Keys]`:** the three programmable keys (§9.3). Esc is fixed; an old `Esc = …` line is ignored.
- **Up to three commands per event,** run from left to right: `WheelDown = SortByName, NextImage`.
- Command names instead of Hamana's numbers. Names are not case sensitive; `;` and `#` start a comment (not inside a zone name). A UTF-8 byte order mark is accepted.
- **Zones switch:** `[Mouse] ZonesEnabled=0` in MView.ini: every button does its Anywhere command everywhere; no zone orders, no zone names.

**Events** (names as in the file):

| Kind | Events |
|---|---|
| Buttons | `LeftClick`, `LeftDouble`, `RightClick`, `RightDouble` |
| Wheel | `WheelUp` (away), `WheelDown` (towards you), `WheelClick` |
| Tilt | `TiltLeft`, `TiltRight` |
| Side buttons | `X1` (rear), `X2` (front) |
| Gestures | `GestureLeft`, `GestureRight`, `GestureUp`, `GestureDown` |
| Keys | `Space`, `Enter`, `D` |

**Commands** (names as in the file):

| Group | Commands |
|---|---|
| Navigation | `NextImage`, `PreviousImage`, `NextFolder`, `PreviousFolder`, `ParentFolder`, `Rescan` |
| View | `ZoomIn`, `ZoomOut` (at the mouse), `Fit`, `OriginalSize`, `FitOr100` (at the mouse), `RotateLeft`, `RotateRight` (90°), `TurnLeft`, `TurnRight` (5° per wheel notch) |
| Order | `SortByDate`, `SortByName`, `ToggleSort` |
| Modes | `ZoomMode`, `RotateMode` (switches), `EditMode`, `EditModeOn`, `EditModeOff` |
| Window | `Fullscreen`, `Info`, `Diagnostics`, `Menu` |
| Image | `Paste`, `SaveImage`, `CropSelection` |
| Leave | `Back` (leave a mode, else exit), `Exit` |
| — | `None` |

**Default profile** (built in, `DefaultProfileText`):

| Where | Settings |
|---|---|
| Anywhere | Wheel down / up = next / previous image; left double-click = fit ↔ 100 %; right click = menu; wheel click = fullscreen; tilt left / right and gesture left / right = previous / next folder; gesture up = parent folder; gesture down = exit; X1 = zoom mode; X2 = rotate mode. |
| Top left "Edit" | Left click = edit mode on; left double-click = edit mode off; wheel up / down = turn right / left 5°. |
| Top right "Browse by name" | Order Name. |
| Bottom left "Browse by date" | Order Date. |
| Bottom right "Inspect" | Wheel down = zoom in, wheel up = zoom out (towards you = in); left double-click = fit ↔ 100 %. |
| Keys | Space = next image; Enter = fullscreen; D = diagnostics. (Esc is fixed, §9.3.) |

An existing `Default.mouse` keeps its entries. The "Mouse & keys" page has a button "Use the built-in profile" (then Save) to get the current defaults.

**Other profiles** *(v1.3)*: `[Mouse] Profile=` in MView.ini names the profile file (next to MView.ini; default `Default.mouse`; a missing file is created with the built-in profile). MView ships `mouse\Hamana.mouse`, the homage profile (§1.1): the wheel steps through the images at the top right by name and at the bottom left by date and zooms everywhere else, Hamana's four gestures, right click = original size (at once), X1 = zoom mode, X2 = menu, top-left click / double-click = edit mode on / off, wheel click / Enter = fullscreen. TestMouse loads the shipped file and checks it.

**Fixed inputs** (not in the profile):

| Input | Action |
|---|---|
| Left button + drag | pan; in edit mode: select an area (§9.5) |
| Right button + drag | gesture (a gesture is not a right click) |
| Arrow keys | ↑ / ↓ = previous / next image, ← / → = previous / next folder (§9.3) |
| Ctrl+V | paste an image from the clipboard (§9.6) |
| Ctrl+Alt+Shift+Q | emergency exit (§5.8), system-wide |

**Rules** [Decision]:
- **Zones** have a dead band of 3 % along the middle lines, where the zone doesn't change (it doesn't flicker there). The zone is fixed while a button is held (drag, gesture).
- **Click or double-click:** a single click runs at once, unless the zone also has a double-click for that button: then it waits for the Windows double-click time and runs only if no second click came. A second press within that time, within 6 px of the first and in the same zone, is the double-click (on the press, as Windows does).
- **Drag:** movement of 4 px or more with the left button is a drag, not a click. The engine reports where a drag starts and is (`DragStart`, `DragPoint`) as well as `PanBy`.
- **Gestures** need 40 px of movement, and the main direction must be 1.5 times the other, so a diagonal stroke does nothing. The right-click and gesture thresholds agree, so every right-button stroke is either a menu or a gesture.
- **Wheel:** one event per notch. High-resolution wheels send parts of a notch, which are collected. Zoom and turn commands follow the parts smoothly instead.
- **Tilt:** one event per tilt. Holding the tilt wheel repeats the message; it fires again only after a 300 ms pause, or at once in the other direction.
- **X1 / X2 act on the press only.** LCL 4.6 never reports their release (`TControl.WMXButtonUp` looks for the button in the "buttons down" flags, where Windows no longer lists it). Hold-to-zoom got stuck; the side buttons are therefore switches, independent of mouse movement.
- Some mice send the side buttons as Browser Back / Forward keys; these count as X1 / X2, except within 700 ms of a real side-button press (echo).
- **Zoom mode / rotate mode** are switches: while one is on, the wheel zooms (at the mouse, towards you = in) or turns (5° per notch) everywhere. Back (Esc) or the same switch ends it.
- **Navigation from a zone with an order** first switches to that order (only if different; the current image stays).
- **Back (Esc):** leaves the zoom / rotate mode first, then edit mode; with no mode on it returns to the settings screen (§9.3). The engine sends Back to `TMView`, which knows about edit mode.
- **Cursor hiding:** after `[Mouse] MouseCursorHideTime` ms without input (default 3000; 0 = never). Not while the menu is open.
- The **menu** is a command (right click by default), no longer the LCL's automatic context menu.

### 9.3 Keyboard

Minimal: arrows, PgUp/PgDn, Home/End, Esc = exit. Keys also produce commands.

*(v1.3, replaces the v1.2d key list)* [Decision] **The keyboard is kept minimal**, because at a laser table the keyboard is out of reach; everything must work with the mouse. Only these keys are read by the viewer:

| Key | Action |
|---|---|
| Esc | fixed *(v1.3, Day 19)*: zoom / rotate mode off; else edit mode off; else back to the settings screen (as after a start without an image). On the settings screen, Esc exits MView (unsaved changes: a second press). |
| Space, Enter, D | programmable in the profile's `[Keys]` (default: next image, fullscreen, diagnostics) |
| ↑ / ↓ | previous / next image (like the wheel) |
| ← / → | previous / next folder (like tilt and the gestures) |
| Ctrl+V | paste image |
| Ctrl+Alt+Shift+Q | emergency exit (watchdog, §5.8) |

The other keys of v1.2d (→ / PgDn / Backspace / PgUp for images, + / −, Home, End, L, R, S, F5, I, Z) are gone. Their actions are commands in the profile (§9.2).

### 9.4 Wheel press *(v1.3)*

Pressing the wheel (middle button) switches fullscreen on / off, like Enter. In the profile this is `WheelClick = Fullscreen`.

### 9.5 Edit mode: select and crop *(v1.3)* [Open: first step]

The first part of the crop feature of §3.2, as the user asked for it: "single left click in the edit field enables edit mode, double left click disables it; edit mode enables a selection box and in the right-click menu 'crop selection'; the cropped selection is zoomed to screen and can be saved with Save image."

- **On / off:** a left click in the Edit zone (top left) switches it on (after the double-click time); a double-click there, or Esc, switches it off. Switching it on starts the full-size decode.
- The mode label says "EDIT … left drag = select an area, right click: Crop selection, double-click in the Edit zone / Esc = end".
- **Selection:** left drag draws it instead of panning. It is kept in original image pixels, so it stays on the image while zooming and turns with the image. A new image clears it; the Full version of the same image keeps it.
- **Crop selection** (menu, shown only in edit mode, enabled with a selection): the area is cut from the best version in memory (the full image; the quick view if the full one isn't there yet, and the info line says so; the frame on screen of a playing animation). It is shown fitted to the screen with the same rotation, as "Cropped from <name>". A crop can be cropped again. The next step goes back to the files.
- **Save image** writes a crop as `<name>_crop_<time>.png` into the save folder (§9.6).

Later (§3.2): rotation around the mouse for preparing a crop, brightness / contrast / dynamic range, Fiji-derived filters and measurement tools.

### 9.6 Context menu, paste and save *(v1.3)*

Menu entries (right click by default):

| Entry | Does |
|---|---|
| Paste image (Ctrl+V) | Shows the clipboard's image ("Clipboard image … not saved") until the next step. |
| Crop selection | Edit mode only (§9.5). |
| Save image | Writes only the image, as PNG, to the save folder. |
| Save image and view (debugging) | The old save: the decoded image and a picture of the window (§15). |
| Exit | Shows the emergency exit key next to it. |

**Save folder** [Decision]: `[Debug] SaveImageDirectory`. If empty, the user's **Documents** folder (`SHGetFolderPath`, also when it was moved, e.g. to OneDrive), which is then written into MView.ini at the first save. In a read-only folder it is used for that session only. (An MView.ini written by earlier versions may still hold the old default `…\test\saved_images\`; delete the value to use Documents.)

---

## 10. Navigation

- `TNavigator` lives on the UI thread and holds **snapshots** (`TDirectoryTree`, `TDirectoryImages`) produced by the scanner. A rescan produces a new snapshot that is swapped in. Snapshots are never modified in place.
- Navigation is index manipulation only. It never touches the disk.
- *(v1.3)* **The window thread never reads folders or files** [Decision]; a shortcut taken in Phase B is gone:
  - `TDirectoryTree.Build(..., ACollectImages)` lists every folder's images while it reads the folder anyway.
  - `TDirectoryScanner` does the whole opening: it resolves the path (file or folder, root, start file), lists the start folder and delivers that first, then the tree with all lists (§5.7).
  - `TNavigator.ReadsDisk := False` in the viewer: it uses only the scanner's lists (`OpenListed`, the tree); a folder not known yet is simply not entered. The tests keep the old mode (`ReadsDisk = True`).
  - `TMView.OpenMedia` only asks the scanner. "Opening …" until it answers, "Not found" from the scanner. No `FileExists` / `DirectoryExists` on the window thread (drag and drop, start, last session).
  - No file access per step: the cache is asked by file name (`GetByName`), not by a key read from the disk (the old `MakeImageKey` did a `FindFirst` on every step). `TNavigator.ListedKey` gives size and date from the lists where a key is needed. Opening and Rescan clear the cache, since new lists may name other versions of the files.
- **Wrap-around:** last image → first image, also when there is only one directory. Last directory → first directory.
- *(v1.2d)* `WrapScope=Dir`: the last image of a folder is followed by the first image of the **same** folder; only the folder commands (*v1.3: ← / →, tilt, gestures*) change folders. `WrapScope=Tree`: navigation continues into the next folder with images. (`Folder` and `Directory` are read as `Dir`.)
- Directories without images are skipped.
- **Peek:** `Navigator.FileAtOffset(k)` returns the file *k* steps away in either direction, crossing directory boundaries, or "unknown" if that directory has not been listed yet. The scheduler uses it for preloading. "Unknown" makes the scanner list that neighbor directory at S1.
- **Sorting:** date (newest → oldest default, oldest → newest optional) or **natural filename** (digit runs compare numerically, case-insensitive: `Image2 < Image10`). Changing sort mode re-sorts only the current directory's list and triggers a reconcile. Directories are always alphabetical (natural). *(v1.3: a zone with an order switches to it before navigating, §9.2.)*
- *(v1.3)* **Parent folder** (gesture up): browsing restarts from the parent of the opened folder, keeping the current file ("browsing from …"; at a drive root: "already at the top").
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

*(v1.3)* As built, the scanner resolves the path first (file or folder, §10), so the window thread never checks the disk. The start folder's listing comes first, then the tree with all lists.

**Changed in v1.2d [Decision]:** if nothing was given, MView **always** shows its settings editor (`TIniEditor`) in the main window:
- `MView.ini` as text (SynEdit, ini highlighting). Before it opens, the file is completed with all keys MView knows; values, comments and unknown keys stay.
- A help line explains the key under the cursor (`uConfig.ConfigKeyHelp`). *(v1.3: also as balloon help; SortMode and WrapScope list their values one per line, with meaning and default.)*
- **View images** (F5) saves and starts the viewer with the last session (`LastDirectory` / `LastFile`). `TMView` is created only then, so it reads the saved settings. Save (Ctrl+S), Undo changes, Exit (with unsaved changes only on the second press: no dialogs). *(v1.3: these cover both pages.)*
- It is a page control: a graphical page for the mouse quadrants and profile (Phase F) is added next to the text. *(v1.3: built, see below.)*
- `[Startup] OpenLastSession` is no longer used.

Rationale: MView is normally started from Total Commander with a file. A start without a file is a start to change settings.

*(v1.3)* **"Mouse & keys" page** (`uMousePage`):
- Left: a **picture of the screen** with its four zones, and below them "Anywhere" and "Keys". A click selects one of them. The zone cells show caption, name and order on separate lines, cut at the cell's edges.
- A green / red **zones button** at the top left ("Zones ON" / "Zones OFF: only Anywhere counts"). It writes `[Mouse] ZonesEnabled` into the MView.ini text of the editor (saved with Save, like any other change); the zone picture then says "(zones off)".
- Right: for the selection, its name and browsing order (zones only), and **one row per event** with up to three commands from lists, under the headings **Command / then / and then**. One press runs a row's commands from left to right. In a zone, the lists offer "(as in Anywhere: …)" and "(nothing here)".
- **"Use the built-in profile"** button (then Save).
- Bottom: **"Try it here"**, a small area with the same zones and a real `TMouseEngine` with the profile being edited. Every button, wheel, tilt, side button and key pressed over it shows what arrived and what it would run. This also shows at once whether a mouse really sends X1, X2 and tilt. It follows the zones switch.
- Saving writes the profile afresh (comments of a hand-edited file are not kept), and only when something was changed on the page. The viewer reads the file when it starts.

*(v1.3)* **Drag and drop:** a file or folder dropped on the MView window opens it, like a command-line argument; its folder becomes the browsing root. Dropped on the settings editor, it starts the viewer with it. Of several files only the first counts.

*(v1.3)* **Window place remembered:** `[Window] Left / Top / Width / Height`. The main window reopens where it was, for the settings editor and the viewer's normal (not fullscreen) window, if that place is still on a monitor. Fullscreen keeps it as the place to return to. Saved (only these four keys, `TConfig.SaveWindowBounds`): by the viewer one second after the last move / resize and on close; by the settings editor on close and when "View images" starts the viewer (not on every resize, because the editor holds MView.ini as text and its next Save would write the old values back). Not while maximised or minimised.

*(v1.3)* **Start-up log:** with `TimingLog=1`, one line per start in `startup.csv` next to MView.exe: exe size, ms from process start to the window, OpenGL set-up, view ready, first image painted, the renderer and the first file.

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

*(v1.2d)* Measured on the development laptop (GTX 960M, 108 MP JPEGs 12000 × 9000 and 12 MP photos):

| Measure | Result |
|---|---|
| Next image, preloaded | 0–8 ms |
| Quick view paint | 4 ms (was 340 ms before the worker-side shrink) |
| Quick view decode, 108 MP (1/8) | about 600 ms on a worker, ahead of time |
| Full decode, WIC | 120–160 ms (12 MP), about 1 s (108 MP) |
| Full image sharp after zoom, 108 MP | tile by tile from the middle of the view (day 16); before: about 18 s at once |

*(v1.3)* Measured on Days 18–19 (same laptop, `timing.csv`):

**Uncompressed 108 MP TIFF (324 MB):**

| Measure | Before Day 18 | After |
|---|---|---|
| Quick view decode | 2696 ms (WIC in bands); 1712 ms full decode with the old reader | 168–368 ms (row-skipping reader); 320–360 ms on Day 19 |
| Screen copy / final resize | 344–680 ms | 24–120 ms (own bilinear) |
| Full decode (WIC) | 1712 ms (old reader) | 1432–1480 ms |
| Next image from cache | — | 8–48 ms |
| GPU upload per 1024 tile | 6.3 ms pixels + 13.1 ms mipmaps | — |
| Cache per TIFF quick view | about 430 MB (old reader, always full) | 17 MB |

**LZW 108 MP TIFF (55 MB):**

| Reader | Quick view decode |
|---|---|
| WIC | 4.4–4.7 s; 9.2 s with two at once; from cache 24–48 ms |
| Own LZW decoder, first build (single thread) | 3.76–3.87 s for the displayed image (7.8 s rows are preloads, including their wait at the gate) |
| The same algorithm in C, for comparison | 1.5 s unoptimised, 0.75 s at -O2 |
| Own decoder at -O2, strips in parallel | expected about 1 s on 4 cores; **not yet measured** |

Hamana needs a little under 3 s for these TIFFs. The user's comparison of the first own-decoder build: "compared to hamana the loading is really fast, factor 2-3 at least".

**NASA Blue Marble, 21600 × 21600 (467 MP), `test\images\super images`:**

| File | Result |
|---|---|
| JPG (84 MB) | quick view 3.3 s (own decoder at 1/8) |
| PNG (457 MB), BGRABitmap (before) | error after about 21 s: always the full 1.9 GB, no progress reports, most likely taken as a hung disk by the stuck-read check |
| PNG, WIC in bands (after), quick view | 12.3 s for the 108 MB PNG, 30.6 s for the 457 MB PNG (`timing.csv` 2026-09-27 13:58); from cache 16–40 ms |
| PNG, Full (C1.png, 457 MB) | 16.4 s decode, 220 ms screen copy; cache 1845 of 2048 MB; the GTX 960M took all 484 tiles (visible ones first, about 20 ms per tile incl. mipmaps) — from the user's screenshot of the diagnostics line, 2026-09-27 |

Hamana skips these PNGs. With them the Phase D pan test at high zoom on a very large image can now be done; the TIFF variant still waits for a large TIFF.

A **diagnostics overlay** (`ShowFPS=1`) shows: frame time, decode time and upload time of the current image, queue depth per priority, cache MB, texture MB, mode (Browse/Skim). This is the main tool for verifying the targets. *(v1.3: two lines, §8.6.)*

---

## 13. Memory

- `TImageCache` budget in MB (`CacheSizeMB`). Eviction by **distance from the current image** (sliding window), not LRU. The current image is never evicted.
- The effective preload count = min(`PreloadCount`, what fits in the budget). Example: 24 MP images are about 96 MB each at BGRA 8-bit, so 512 MB holds only 5.
- **[Decision, v1.2d]** default budget (`CacheSizeMB=0`): 25 % of physical RAM, 256 … 4096 MB.
- *(v1.2d)* Up to one entry per file and quality. Eviction: files outside the preload window first, big Full versions before small Screen versions. Only as many neighbours are preloaded as fit next to the current image.
- *(v1.3)* Room is kept for the quick view still to come when a preview is cached. Previews (thumbnails) are tiny.
- *(v1.3)* **Screen quality never allocates the full image** for TIFF, PNG and BMP through WIC or the own TIFF readers: bands are averaged down while they arrive (17 MB instead of about 430 MB for a 108 MP TIFF; a screen-size bitmap instead of 1.9 GB for a 467 MP PNG).
- *(v1.3)* **Memory guard** (§7.5): at most half of the physical memory for one bitmap, never more than 2 gigapixels.
- *(v1.3)* **Animation frames are kept as palette indices** (8 bits per pixel plus a palette per frame), a quarter of BGRA. All frames of one animation together: at most a quarter of RAM and 2 GB; frames beyond that are left out (§7.6). The picture being shown is built from them on the UI thread.
- *(v1.3)* An LZW strip is decoded one at a time (37 MB for the test files); strips over 256 MB are left to WIC.
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

*(v1.2d, updated v1.3)* Keys in use now (the others above are still planned). New or changed in v1.3 are marked `*`:

```ini
[Startup]
LastDirectory= / LastFile=   ; written on exit
StartFullscreen=0
[Window]                     ; *
Left= / Top= / Width= / Height=  ; * written by MView: window place when not fullscreen (§11)
[View]
ShowInfo=1
AutoRotate=1            ; EXIF orientation
OverlaySolid=0          ; * 1 = info and diagnostics lines on a solid black bar
OverlayColor=White      ; * White | Yellow | Red: colour of the texts over the image
[Navigation]
SortMode=DateDescending ; DateAscending | FileNameAscending | FileNameDescending
Recursive=1
WrapAround=1
WrapScope=Tree          ; Dir | Tree
PlaceholderForBadImages=1
[Performance]
PreloadCount=5          ; 0..20
PreloadBehind=2         ; 0..10
DecodeThreads=0
UseWIC=1                ; * WIC for full-size JPEGs, and for TIFF, PNG, BMP (in bands)
UseWICQuickView=1       ; * JPEG quick views scaled inside the WIC codec; 0 = own decoder
RefineDelayMs=250       ; full decode after this long on an image; 0 = at once
CacheSizeMB=0
PreviewAhead=10         ; * EXIF thumbnails read ahead; 0 = none (0..50)
SkimEnterMs=1500        ; * Skim while the last this-many ms averaged SkimRate steps/s; 0 = never
SkimRate=4              ; * 1..50
SkimExitMs=250          ; * ms without a step that end Skim (50..10000)
[Mouse]
Profile=Default.mouse   ; * now used: the mouse profile file, next to MView.ini (§9.2)
MouseCursorHideTime=3000 ; * now used: ms without input until the cursor hides; 0 = never
ZonesEnabled=1          ; * 0 = zones off: every button does its Anywhere command
[Renderer]
UseGPU=1                ; replaces the planned Renderer=GPU|CPU
UseMipMaps=1
ZoomStepPercent=20      ; * zoom step per wheel notch (1..200)
[Debug]
ShowFPS=0               ; diagnostics line (key D)
TimingLog=0             ; timing.csv and * startup.csv next to MView.exe
DecodeDelayMs=0         ; testing: every decode waits this long
SaveImageDirectory=     ; * for "Save image"; empty = the user's Documents folder, written here at the first save
```

Not used yet: `OpenLastSession` (see §11), `BackgroundScan`. *(v1.3: `[Mouse] Profile` and `MouseCursorHideTime` are now used.)*

*(v1.3)* The editor's help texts for `ZoomStepPercent`, `ShowInfo`, `SortMode` and `WrapScope` were updated for the removed keys (§9.3).

---

## 15. Testing and benchmarks

- **Navigation tests** (`test\TestNavigation.lpr`, exists): extend with wrap-around in a single directory, natural sort, directory skipping, `FileAtOffset` across directories.
- **Scheduler tests:** a fake loader that sleeps for a configurable time makes the scheduler deterministic to test. Checks: P0 always starts within one job slot, obsolete jobs are cancelled, running jobs are promoted not restarted, the wanted set is respected.
- **Benchmarks** (`benchmarks\`): decode time per format and size, directory scan time on a large tree (local and network), upload time per texture size, frame time while panning at 1600 %.
- **Test data:** the existing ~100 images plus the real TIFF set from §7.3.
- *(v1.2d)* `test\build_test.bat` builds and runs `TestNavigation` (75 checks: wrap, natural sort, skipping empty folders, tree not yet known, `FilesAhead` across folders) and `TestExif` (20 checks, including the eight pictures in `test\images\exif`). Scheduler tests with a fake loader are still to do.
- *(v1.2d)* **Debugging aid:** the context menu's *Save current image* writes the decoded image and a picture of the window as PNG to `[Debug] SaveImageDirectory`. Claude reads that folder for direct feedback on what MView shows. *(v1.3: now "Save image and view (debugging)", §9.6.)*

*(v1.3)* `test\build_test.bat` now builds four test programs. Three with plain fpc (from Lazarus, the `FPC` line at the top), and `TestGif` with **lazbuild** from `TestGif.lpi`, because it needs BGRABitmap (the `LAZBUILD` line; without lazbuild TestGif is skipped).

| Test | Checks | Covers |
|---|---|---|
| `TestNavigation.lpr` | **87** | As before, plus (Day 19) the no-disk mode: a tree with every folder's images, a navigator without disk access starting from the scanner's start list, crossing folders from the tree's lists, `ListedKey`, previous directory. |
| `TestExif.lpr` | **40** | As before, plus (Day 18) `uJpegHeader`: size, orientation and thumbnail of the four pictures in `test\images\thumb` (one with big-endian EXIF), no thumbnail, missing file; `AspectCrop`. |
| `TestMouse.lpr` *(new)* | 58 in the user's run of 16:11, before the edit mode and zones switch checks were added | Profile parsing, errors with line numbers, save / load round trip, zones and dead band; the engine with a fake clock: zone order, wheel parts, zoom / turn smoothness, click vs double-click timing, drag (start / point reported), menu, gestures and preview, tilt repeat, X1 mode and Browser Back echo, Esc = Back, keys, each arrow key, focus lost, Edit zone click / double-click, zones off. |
| `TestGif.lpr` *(new)* | 156 (user's run 02:14), 198 (16:11) | Every file in `test\images\gif` and Test.gif against `expected.txt` (size, frames, delays, a checksum of every frame); the **GIF test suite** (`animated_*.gif`, `static_*.gif`): every frame against its reference picture in `gif\frames` (transparent pixels by transparency only) and the loop counts; the first frame alone and from the start of a file only; a PNG named .gif; cut at every length; 300 random corruptions; frames claiming 65535 × 65535; cancel; memory limit; the frame clock (skipping, stalls, 1 and 2 plays). |

User's run 2026-09-27 16:11: 87 + 40 + 58 + 198 passed, 0 failed. `expected.txt` comes from `gifproto.py`, the Python copy of the decoder, checked against Pillow. See `test\images\gif\README.txt`.

*(v1.3)* Manual test folders: `test\images\thumb` (previews; `thumb_letterbox.jpg` must fill the frame without black bars), `test\images\broken` (§7.4), `test\images\gif`, `test\images\super images` (NASA, §12), `test\images\tiff\compressed` and `\uncompressed`.

---

## 16. Current code vs. this spec

Found in the mview3 source (2026-09-24). These are the first things to address.

*(v1.2d)* Items 1–12 and 14 were done in Phases A and B (day010, day011). Still open: #13 (`mview.lpk` / `mview.pas`), the two build modes (§19.4, item 4), and removing the `backup` folders.

| # | Where | Now | Spec |
|---|---|---|---|
| 1 | `TRenderer.Render` | `FBitmap.LoadFromFile` decodes on the UI thread inside the renderer. | Decoding in `TMediaLoader` on a worker. Renderer receives `IDecodedImage`. |
| 2 | `TMediaLoader.Load` | Returns a `TMedia` holding only the file name. | Returns decoded pixels (§7.2). |
| 3 | `TNavigator.OpenPath` / `TDirectoryTree.Build` | Directory listing and recursive scan run synchronously on the UI thread. | Scanner thread + snapshots (§10, §11). *(v1.3: the last shortcut, folder reads on the window thread, is gone too, §10.)* |
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

*(v1.3)* New small items: `source\mouse\uInputHandler.pas` is no longer used (replaced by `uMouseEngine`) and can be removed; the help texts noted at the end of §14.

---

## 17. Implementation roadmap

Each phase ends with a compiling, usable viewer and a session log entry.

| Phase | Content | Done when |
|---|---|---|
| **A. Clean foundation** ✓ | Project setup from §19.4, items 1–2 and 4–14 from §16 (still synchronous), `IDecodedImage`, command dispatch through `TMView`. | Command-line start works, no dialogs, no crash on empty folder, natural sort, wrap works. |
| **B. Threading core** ✓ | `TJobQueue`, 1 decode worker, `TThread.Queue` delivery, cancellation, `TImageCache`, scanner thread for the current directory (item 3), clean shutdown. | Opening a huge TIFF never freezes the window. Esc during a decode exits immediately. |
| **C. Preloading** ✓ | Wanted set + reconcile, directional window, `FileAtOffset` across directories, N workers with the reserved-worker rule, I/O gate. | Next image is instant when preloaded. The current image is never delayed by preloads (verified with the overlay). |
| **D. GPU renderer** ✓ | Spike (§8.5), then textures, tiles, mipmaps, transform, time-sliced upload, CPU fallback. *(v1.2d: plus interim mouse profile, gestures, settings editor.)* | Pan at 1600 % on the largest test TIFF stays at 60 fps. *(Open: the test on the largest TIFF; now possible with the NASA images, §12.)* |
| **E. Skim & quality levels** ✓ *(v1.3)* | Preview decode, Skim detection, refinement. *(v1.3: plus WIC quick views, own uncompressed and LZW TIFF readers, PNG / BMP through WIC, the failsafe against lockups, §5.6, §5.8, §7.5.)* | Holding the wheel never builds up lag. |
| **F. Mouse engine** *(v1.3: built, in testing)* | Quadrants, gestures (up = parent folder), mouse profile file, cursor hide, graphical profile page in the settings editor, a way from the viewer back to the settings. *(v1.3: built as zones with names and orders, `Default.mouse`, "Mouse & keys" page with "Try it here", zones switch, minimal keyboard, paste and save. A way from the viewer back to the settings is not built.)* | Daily browsing without keyboard. |
| **G. Later** | Edge move/copy menu, ~~GIF animation~~ *(v1.3: done, pulled forward)*, 16-bit windowing, multi-page TIFF, thumbnail cache, scripting, crop with rotation around the mouse *(v1.3: edit mode with select and crop started, §9.5)*, optimisation of the TIFF loaders, *(v1.3)* Fiji-derived filters and measurement tools. Movies: on the back burner (§8.7). | — |

The GPU spike in phase D is independent of B and C, because the renderer only ever receives `IDecodedImage`. It can be done earlier if you want to settle the technology question first.

---

## 18. Decisions and open questions

| # | Question | Status |
|---|---|---|
| 1 | GPU technology | **Decided:** `TOpenGLControl`, unless another option clearly outperforms it (§8.5). |
| 2 | TIFF decoder, bit depths, compressions | Decided after the TIFF analysis (§7.3). *(v1.3: for 8-bit strip TIFFs decided: own uncompressed quick view → own LZW → WIC → FPReadTiff. 16-bit, multi-page and tiled still wait for the real microscopy TIFFs.)* |
| 3 | 16-bit display mapping for v1 | Decided after the TIFF analysis (§7.3). |
| 4 | 32/64-bit | **Decided:** 64-bit is the target, 32-bit would be a fork (§13). Default cache budget: 25 % of RAM, 256 … 4096 MB (v1.2d). |
| 5 | Skim thresholds | **Decided:** enter after 1–2 s of fast scrolling, leave quickly (~250 ms), both in the ini (§6, §14). *(v1.3: fast = the average rate over the last `SkimEnterMs`, not an unbroken run.)* |
| 6 | Start without arguments | **Decided (changed in v1.2d):** always the settings editor; "View images" opens the last session (§11). |
| 7 | Default decode thread count | **Decided:** cores − 1, 1 … 4 (`DecodeThreads=0`, §5.1). |
| 8 | Thumbnail cache storage | Open: safest option, can be turned on and off (§3.2). |
| 9 | Movie playback | **Decided:** bundled FFmpeg decoder, detection by content, frames rendered as ordinary textures, no system video renderer (§8.7). Audio output library still open. *(v1.3: on the back burner: the user edits microscope movies in VirtualDub, no need to replicate that.)* |
| 10 | JPEG decoding | **Decided (v1.2d):** own pasjpeg decoder for quick views (cancellable, DCT scaling), WIC for full size (§7.1). *(v1.3: quick views scaled inside WIC by default, `UseWICQuickView`; the own decoder is the fallback.)* |
| 11 | Side buttons X1 / X2 | **Decided (v1.2d):** switches on press (LCL never reports the release), §9.2. |
| 12 | Rotation centre | **Decided (v1.2d):** window centre; around the mouse only with the crop feature (§8.1). |
| 13 | Preview level *(v1.3)* | **Decided:** EXIF thumbnail, read from the start of the file; shown first, then the quick view. Skim wants only previews (§6, §7.1). |
| 14 | PNG and BMP *(v1.3)* | **Decided:** WIC in bands (cancellable, screen quality averaged down while reading); BGRABitmap only as fallback, with the memory guard first (§7.1). |
| 15 | GIF *(v1.3)* | **Decided:** own decoder; Screen = first frame, Full = all frames; frames as palette indices; picture = logical screen, frames clipped; loop counts honoured; transparent = black (§7.6, §8.7). |
| 16 | Frame timing *(v1.3)* | **Decided:** `TFrameClock` with fixed times from the start, skipping instead of queueing, independent of GIF, so movies without sound can reuse it (§8.7, rule M6). |
| 17 | Robustness against lockups *(v1.3)* | **Decided:** memory guard (half of RAM, 2 gigapixels); JPEG plausibility check; emergency exit Ctrl+Alt+Shift+Q; 4 s exit deadline; the window thread never reads the disk; a read not alive for 20 s is abandoned and its worker replaced (at most 4) (§5.6, §5.8, §7.5, §10). |
| 18 | Preloads and the disk *(v1.3)* | **Decided:** preloads wait at the I/O gate while a display job reads (§5.5). |
| 19 | Mouse language *(v1.3)* | **Decided:** four zones with name, order and own table, plus Anywhere and Keys; command names; up to three commands per event; profile in `Default.mouse`; zones can be switched off (§9.2). |
| 20 | Keyboard *(v1.3)* | **Decided:** minimal, because at a laser table the keyboard is out of reach: Space, Enter, D (programmable), Esc (fixed: modes off, else settings screen; there it exits), arrows (↑ / ↓ images, ← / → folders), Ctrl+V (§9.3). |
| 21 | Zone names on screen *(v1.3)* | **Decided:** only while the diagnostics line is on (§8.6). |
| 22 | Edit mode *(v1.3)* | **Decided (first step):** click in the Edit zone = on, double-click / Esc = off; left drag selects; crop from the menu; Save image writes the crop (§9.5). |
| 23 | Save folder *(v1.3)* | **Decided:** `SaveImageDirectory`, default the user's Documents folder, written into the ini at the first save (§9.6). |
| 24 | Menu *(v1.3)* | **Decided:** a command (right click by default), not the LCL's automatic context menu (§9.6). |

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
| **BGRABitmapPack** | `TBGRABitmap`, `TBGRAPixel`, resampling for the CPU renderer | **Online Package Manager** (*Package → Online Package Manager → BGRABitmap*) | Not required. Adding it as a project requirement is enough, since MView creates no BGRA components at design time. | Now (replaces the source path, §16 #12). *(v1.3: also needed by `TestGif`, built with lazbuild.)* |
| **LazOpenGLContext** | `TOpenGLControl` (unit `OpenGLContext`), the GPU surface for `TMediaView` | Ships with Lazarus (`components\opengl`) | Not required. MView creates the control in code. | Phase D |
| **SynEdit** | `TSynEdit`, `TSynIniSyn` for the settings editor (§11) | Ships with Lazarus | No | v1.2d |
| **FPCUnitConsoleRunner** (or FPCUnitTestRunner for a GUI runner) | FPCUnit tests for navigation and scheduler (§15) | Ships with Lazarus | No | Phase B (test projects only) |

How to add a requirement: *Project → Project Inspector → Add → New Requirement*, then choose the package. It is stored in `MView.lpi` under `RequiredPackages`, so every PC that opens the project knows what it needs.

### 19.3 Units and libraries without a package

| Unit / library | Use | Note |
|---|---|---|
| `GL`, `GLext` (FPC `packages\opengl`) | OpenGL calls: textures, `GL_MAX_TEXTURE_SIZE`, mipmaps | Functions newer than OpenGL 1.1 must be loaded at runtime with the `Load_GL_version_x_y` functions in `GLext`, after the context exists. |
| `Math` → `SetExceptionMask` | Mask floating-point exceptions before creating the OpenGL context | Many OpenGL drivers trigger floating-point exceptions that FPC programs treat as errors by default. Mask them at startup of the GPU renderer. |
| `cthreads` | Thread support on Unix | Already in `MView.lpr` behind `{$IFDEF UNIX}`. Windows needs nothing. |
| libtiff DLL (optional) | Fallback TIFF decoder | Only if the TIFF analysis shows `FPReadTiff` is not enough (§7.3). Shipped next to `MView.exe`. *(v1.3: not needed so far; own readers and WIC cover the 8-bit test TIFFs.)* |
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

*(v1.3)* `uTiffQuick` and `uGifDecoder` set `{$OPTIMIZATION ON}` themselves, whatever the build mode, because their decode loops must be fast.

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
- GPU with OpenGL **2.1** as the minimum (textures of any size) and **3.0** recommended (mipmap generation on the GPU). *(v1.2d: MView accepts 2.0; without 3.0's `glGenerateMipmap` uploads are much slower, the D line then says "old mipmaps".)* Nearly every GPU of the last 10 years qualifies.
- **The GPU vendor's driver must be installed.** Without it, Windows offers only an OpenGL 1.1 software fallback. MView detects this at startup, logs it, and switches to the CPU renderer (v1.2d: the reason is shown in the D line).
- RAM: 8 GB minimum, 16 GB or more recommended for large microscopy TIFFs (§13). *(v1.3: the Full version of a 467 MP image needs 1.9 GB; the memory guard allows at most half of the physical memory for one image, §7.5.)*
