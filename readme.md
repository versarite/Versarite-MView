# Versarite MView Pre-release
## Written with support from Claude/Opus5.5 and ChatGPT

A native Windows image viewer for scientific microscopy, driven by the mouse.
By [Versarite](https://github.com/versarite). Free software under the GNU GPL v3.
Pascal/Lazarus is underappreciated. It is powerful and beautiful at the same time, but 
not documented well enough. Claude and ChatGPT helped me greatly to unlock the capabilities.

**Status: pre-release (v0.20.0-alpha).** It is used daily, but things may still change.

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
- Microscopy-aware: instrument metadata, scale bar, channels and measurements (in progress)
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
- Esc leaves a mode, then goes to the settings screen; Esc there exits.
- If MView ever hangs: Ctrl+Alt+Shift+Q.

## Building

- Lazarus 4.x with Free Pascal 3.2.2, Windows 64-bit.
- Lazarus packages: **BGRABitmapPack** (install through the Online Package Manager),
  **LazOpenGLContext** and **SynEdit** (both come with Lazarus).
- Open `MView.lpi`, build. The program goes to `build\`.
- Tests: `test\build_test.bat` builds and runs TestNavigation, TestExif, TestMouse, TestSort and
  TestGif.

## Documentation

- `specs\` — the developer specification
- `docs\architecture\` — how the units depend on each other and work together at run time
- `docs\dayNNN.log` — the development log, one file per day
- `docs\Strategy_Phase_G.md` — the plan for sorting, metadata, magnifier and filters
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

