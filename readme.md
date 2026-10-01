# Versarite MView Pre-release
## Written with support from Claude/Opus5.5 and ChatGPT

A native Windows image viewer for scientific microscopy, driven by the mouse.
By [Versarite](https://github.com/versarite). Free software under the GNU GPL v3.
Pascal/Lazarus is underappreciated. It is powerful and beautiful at the same time, but 
not documented well enough. Claude and ChatGPT helped me greatly to unlock the capabilities.

**Status: pre-release (v0.21.0-alpha).** It is used daily, but things may still change.

> **Dedicated to Hamana** - written by Makito Miyano (last version 1.48, 2006), 
> the viewer that showed how browsing images should feel: 
> **fast first, mouse first, never in the way.**
> Hamana drew its images on the graphics card when few viewers did, read the next image
> before you asked for it, and let you drive *everything* with the mouse. Its development stopped in
> 2006 and its source was never published, so its bugs could never be fixed. Versarite MView carries its
> ideas forward in code anyone can read, fix and extend.
> See [From Hamana to MView](docs/From_Hamana_to_MView.md).

## Goals

- Hamana-like fullscreen browsing through whole experiment folders
- Extremely fast loading and preloading, drawn on the GPU
- A mouse-driven interface: screen zones, gestures, tilt wheel, no keyboard needed
  (made for the microscope bench)
- Sorting after inspection: a slide-out panel copies or moves the image into preset folders
  with a double-click (with undo, a log, icons, and Total Commander side by side)
- A viewer for Total Commander: MView follows its folder, or even the file under its cursor
- Looking closer: display filters with Auto contrast, and a magnifier lens
- Microscopy-aware: instrument metadata, scale bar, channels and measurements (next)
- An educational Lazarus / Free Pascal project: every unit explains itself

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
  copy" makes a new image with them.
- Magnifier: right-click menu, "Magnifier (lens)". Left drag sideways = magnification, up / down =
  size, wheel = sharpening, wheel click = lock the lens.
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
  - While MView follows, folders are opened without their subfolders (Total Commander decides
    where you are); otherwise `[Navigation] Recursive` applies.
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
- `docs\dayNNN.log` — the development log, one file per day
- `docs\Strategy_Phase_G.md` — the plan for sorting, metadata, magnifier and filters (and what comes
  next: microscopy)
- `docs\release_notes_*.md` — what each pre-release brings
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

