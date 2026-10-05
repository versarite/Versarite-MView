# Versarite MView 1.0
## Written with support from Claude/Opus5.5 and ChatGPT

A fast native Windows image viewer, driven by the mouse. Made at the microscope bench, for
browsing whole experiment folders, and good at any other kind of image collection.
By [Versarite](https://github.com/versarite). Free software under the GNU GPL v3.
Pascal/Lazarus is underappreciated. It is powerful and beautiful at the same time, but
not documented well enough. Claude and ChatGPT helped me greatly to unlock the capabilities.

**Status: release 1.0 (2026-10-05).** After 24 development days and weeks of daily use, the viewer is
complete. Its feature set is frozen; 1.x brings fixes and polish. Microscopy-specific work continues
in a separate **microscopy edition** (see [What comes next](#what-comes-next-the-microscopy-edition)).

> **Dedicated to Hamana** - written by Makito Miyano (last version 1.48, 2006),
> the viewer that showed how browsing images should feel:
> **fast first, mouse first, never in the way.**
> Hamana drew its images on the graphics card when few viewers did, read the next image
> before you asked for it, and let you drive *everything* with the mouse. Its development stopped in
> 2006 and its source was never published, so its bugs could never be fixed. Versarite MView carries its
> ideas forward in code anyone can read, fix and extend.
> See [From Hamana to MView](docs/From_Hamana_to_MView.md).

## What 1.0 brings

### Fast, from the first image to the last

- **Fullscreen browsing through whole folder trees.** A background thread scans the folders; next /
  previous image and folder are instant, sorted by date or by name (natural order: Image2 before
  Image10), with wrap-around and no dialogs.
- **Never waits.** Several decode threads read the neighbours ahead; the image on screen always reads
  the disk first. Quick views (EXIF thumbnails, reduced decoding) come before the full image; holding
  the wheel switches to a skim mode that never builds up lag.
- **Drawn on the GPU** (OpenGL): tiled textures, mipmaps, pixel-exact 1:1, free rotation. A CPU
  renderer takes over when OpenGL can't be used.
- **Large images:** own fast TIFF readers (uncompressed and parallel LZW), PNG / BMP / TIFF in bands
  through Windows WIC (21600 × 21600 NASA images), JPEG through WIC with an own fallback decoder,
  GIF with animation (own decoder). Images that would not fit in memory are refused, not crashed on.
- **Fit ↔ 100 %, zoom, rotate:** 100 % shows centred in the window; the zoom mode zooms at the mouse.

### The mouse language

- **Four screen zones**, each with its own name, browsing order and commands; right-drag gestures,
  tilt wheel, side buttons. Everything lives in a readable profile (`Default.mouse`), edited on the
  "Mouse & keys" page with a "Try it here" area. The keyboard is optional.
- **A Hamana profile** (`mouse\Hamana.mouse`) gives MView Hamana's mouse.

### Sorting after inspection

- **The sort panel** slides out at the right edge: double-click left copies, double-click right moves
  the image into a button's folder. The copy or move runs on a thread of its own; the button flashes
  in its colour when the file is really there.
- **Nothing is ever lost:** never overwrites, never really deletes (a deleted-files folder), undo up to
  50 steps, every action in `sorting.log`.
- **Icons on the buttons** from `.ico` / `.png` files, or made from the image itself ("Make icon from
  this image"). Resting the mouse on a button shows its icon large at the top of the screen.
- **Into a folder:** swipe left or right over a button, or click it with the wheel.
- **Folders from Total Commander or Explorer:** drop them on the panel to make buttons.

### Looking closer

- **Display filters** at the left edge: black / white point, brightness, contrast, gamma, saturation,
  hue, invert, mirror left / right. Applied by a shader on the graphics card (one frame even on
  100-megapixel images); the image file is never changed.
- **Auto** sets the black and white point like Fiji's Auto contrast, from a live histogram (or from a
  selection); double-click makes it work on every image, `[Filters] AutoFilter=1` from the start.
- **Lock filters** keeps them for the next images; **Apply filters (and rotation) to a copy** makes
  a new image with them in its pixels, ready to save or sort.
- **The magnifier:** a round lens over the image, 1.25 to 32 × from the full image, with optional
  sharpening, lockable in place.
- **Resize to the size shown:** the info line shows the size on screen (`52 % = 1997 x 1331`); one
  menu entry makes a copy of exactly that size.

### A viewer for Total Commander

- **Follows Total Commander:** its folder, or even the file under its cursor. A **TC** label shows the
  state (see-through, light blue, amber) and switches it with a click.
- **Only one MView:** opening images from Total Commander one after another goes to the running
  MView, which comes to the front.
- **Side by side:** MView on the left half of the screen, Total Commander on the right.
- See [Working with Total Commander](#working-with-total-commander) below.

### Everyday details

- **Edit mode:** select an area, crop it; save an image, a crop or a picture pasted from the
  clipboard (Ctrl+V) as PNG.
- **The info line is yours:** `[InfoLine]` in MView.ini lists its parts (file name, size, folder,
  position, videos, sorting, zoom, state, animation, filters, messages); switch each on or off,
  move the lines to change the order, choose the font.
- **Videos are counted, not shown:** the info line says "3 videos" when a folder has them, and a
  folder with only videos says so instead of looking empty.
- **Drive roots** (C:\, a network share) open without their subfolders unless you want them
  (`[Navigation] RecurseFromDriveRoot`), so a whole drive is never scanned by accident.
- **Safe:** emergency exit (Ctrl+Alt+Shift+Q), a shutdown deadline, decode threads stuck on a failing
  disk are replaced, the window never waits for a slow drive.
- **Documented:** every unit explains itself (Purpose, Owns, Responsibilities, Does NOT, Threads),
  architecture pictures, a developer specification and a daily development log.

The full list for this release: [release notes 1.0](docs/release_notes_v1.0.0.md).

## What comes next: the microscopy edition

With 1.0 the general viewer is finished. Everything specific to microscopy, and to image editing,
goes into a **second program, the microscopy edition**, so MView stays the lean, fast viewer it is.
It is not a fork: both programs are built from the same source tree, so every fix to the renderer,
the decoders or the navigation reaches both with one rebuild. The microscopy edition has its own
project file, and its units live in their own folder (`source\microscopy\`).

Planned for it:

- **Instrument metadata:** Leica (.lif / .lei and LAS X exports with their MetaData), Nikon, and the
  usual TIFF / OME / ImageJ descriptions, shown in a panel.
- **Calibration** per objective (by numbers, or by measuring a stage micrometer or a known object),
  so camera images without metadata get a real scale too.
- **Measuring:** a straight line that follows the mouse after the first click and shows its length
  after the second; no dragging needed.
- **Scale bar** with round lengths, written into a saved copy for figures.
- **A provenance note** in saved PNGs listing what was done to the image.
- **Movies and camera recordings** (Prosilica, Thorlabs, Imaging Source, Point Grey: raw AVI, TIFF
  stacks, MP4 / MKV through FFmpeg's libraries) as frame stacks with time stamps.
- **Editing**, with the keyboard allowed: Photoshop .8bf filters (64-bit), and Fiji / ImageJ plugins
  and macros run by Fiji itself.

## Using it

- Start `MView.exe` with a file or folder, or drop one on the window.
  Started without one, it shows the settings screen.
- The mouse profile `Default.mouse` says what each button, wheel, gesture and zone does.
  `mouse\Hamana.mouse` gives MView Hamana's mouse: copy it next to `MView.ini` first,
  then set `Profile=Hamana.mouse` under `[Mouse]` (`Profile=Default.mouse` goes back).
- Sorting: rest the mouse at the right edge (or right-click menu, "Sort panel"). Double-click
  left copies, double-click right moves the image into a button's folder; drop folders from
  Total Commander or Explorer onto the panel to add buttons. Nothing is ever overwritten or
  really deleted ("Delete current image" moves the file to a deleted-files folder).
- Filters: rest the mouse at the left edge (or right-click menu, "Filters"). Black / white point,
  brightness, contrast, gamma, saturation, hue, invert, mirror; **Auto** sets the black and white
  point like Fiji (click: once, double-click: for every image). Display only; "Apply filters to a
  copy" makes a new image with them (and with the rotation, if the view is turned).
- Magnifier: right-click menu, "Magnifier (lens)". Left drag sideways = magnification, up / down =
  size, wheel = sharpening, wheel click = lock the lens.
- The info line: `[InfoLine]` in the settings screen (MView.ini). The help text on the right says
  what each line does.
- Esc leaves a mode, then goes to the settings screen; Esc there exits.
- If MView ever hangs: Ctrl+Alt+Shift+Q.

## Working with Total Commander

MView doesn't try to be a file manager: [Total Commander](https://www.ghisler.com) is the
tree manager, MView is its viewer. They work together in four ways:

- **Opening from Total Commander.** Make MView the program for image files (Enter or a double-click
  opens it). With `[Startup] OnlyOneInstance=1` (the default) there is only ever one MView: an image
  opened while MView runs goes to the running MView, which comes to the front.
- **Following Total Commander** (right-click menu "Follow Total Commander", or click the **TC**
  label in the bottom right corner to cycle):
  - *Its folder:* when Total Commander's active panel changes folder, MView shows that folder.
  - *Its folder and the image under its cursor:* arrow through a folder in Total Commander and
    MView shows each image as the cursor reaches it, MView becomes Total Commander's viewer.
  - The **TC** label shows the state: see-through = not following (off, or Total Commander isn't
    running), light blue = its folder, amber = folder and cursor.
  - While MView follows, Total Commander decides the folder: folders are opened without their
    subfolders, the image steps wrap around inside the folder, and a folder step in MView shows a
    short notice ("TC connection: directory change disabled!") instead.
  - Archives, FTP and plugin folders in Total Commander are ignored. MView only reacts to changes
    in Total Commander, never pulls you back from your own browsing in MView.
- **Side by side** (right-click menu, or the button on the settings screen): MView on the left half
  of the screen, Total Commander on the right half, in the image's folder (from the settings
  screen: the last session's folder, else Documents).
- **Sorting with folders from Total Commander:** drag folders from Total Commander onto the open
  sort panel to make them sort buttons.

How it works: Total Commander announces nothing, so MView asks it a few times a second through its
documented window messages (`WM_USER+50`, see the Total Commander wiki) and its `WM_COPYDATA`
questions ("SP" = the active panel's path, "SN" = the name under the cursor). It costs nothing
noticeable and needs no plugin or setting in Total Commander. `[Sort] FollowTotalCommander=0/1/2`
keeps the choice; `[Sort] TotalCommander=` can name the program if MView doesn't find it itself.
Tested with Total Commander 11.03 (64-bit).

## Building

- Lazarus 4.x with Free Pascal 3.2.2, Windows 64-bit.
- Lazarus packages: **BGRABitmapPack** (install through the Online Package Manager),
  **LazOpenGLContext** and **SynEdit** (both come with Lazarus).
- Open `MView.lpi`, build. The program goes to `build\`.
- Tests: `test\build_test.bat` builds and runs TestNavigation, TestExif, TestMouse, TestSort,
  TestFilters and TestGif.

## Documentation

- `specs\` — the developer specification
- `docs\architecture\` — how the units depend on each other and work together at run time
  (updated for 1.0)
- `docs\dayNNN.log` — the development log, one file per day
- `docs\Strategy_Phase_G.md` — the plan for sorting, metadata, magnifier and filters
- `docs\release_notes_*.md` — what each release brings; `release_notes_v1.0.0.md` for this one
- `docs\Hamana_Research.md`, `docs\Hamana_Commands.md` — what was learned from Hamana
- `docs\From_Hamana_to_MView.md` — the homage: what MView kept, what it changed, and why

## Principles

Fast first, mouse first, never in the way.
No frills, every feature must improve the workflow.
Every module should be easy to understand.
Every design decision should be documented.
The source code should teach as well as implement.

## License

Versarite MView is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License, version 3 (see `LICENSE`).

It is built with the Free Pascal runtime and the Lazarus LCL (modified LGPL), BGRABitmap
(modified LGPL) and pasjpeg (Independent JPEG Group licence).

## What is not in this repository

- Hamana itself: its program, plug-ins, manual and screenshots belong to its author.
  MView contains no Hamana code, formats, artwork or text.
- The author's own test images (microscopy data, photos, very large images). Only the test sets
  the tests need are included: `test\images\gif`, `test\images\exif` and `test\images\thumb`,
  all made for testing.
