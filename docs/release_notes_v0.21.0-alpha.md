# Versarite MView v0.21.0-alpha

The third pre-release, from days 22 and 23 of development. It has three parts:
- **Looking closer:** display filters with Auto contrast, and a magnifier lens.
- **Total Commander:** MView now works as a viewer for it.
- **Fixes and smaller additions** from daily use.

## New: working with Total Commander

Total Commander is the tree manager, and MView is its viewer. Neither tries to do the other's job.

- **Follow Total Commander.** Turn it on in the right-click menu ("Follow Total Commander"), or click the **TC** label in the bottom right corner to cycle through the settings:
  - **Its folder:** when Total Commander's active panel changes folder, MView opens that folder.
  - **Its folder and the image under its cursor:** as you arrow through a folder in Total Commander, MView shows each image when the cursor reaches it. Holding an arrow key skips the in-between images; the last one shows when the folder is ready.
- **The TC label shows what is happening:**
  - see-through: not following (it is off, or Total Commander isn't running);
  - light blue: following the folder;
  - amber: following the folder and the cursor.
- **Subfolders:** while MView follows Total Commander, it opens folders without their subfolders, because Total Commander decides where you are. Otherwise `[Navigation] Recursive` applies as before.
- **Limits:**
  - Archives, FTP and plugin folders in Total Commander are ignored.
  - MView only reacts to changes in Total Commander. It never pulls you back from browsing in MView.
- **Only one MView:** `[Startup] OnlyOneInstance=1` is the default. An image opened from Total Commander while MView runs goes to the running MView, which comes to the front. Before, every Enter in Total Commander started another MView.
- **Settings screen:** a new button, "Total Commander side by side", puts MView on the left half of the screen and Total Commander on the right. Total Commander opens in the last session's folder, or Documents if there is none.
- **How it works:** Total Commander announces nothing, so MView asks it five times a second. It uses Total Commander's documented window messages (`WM_USER+50`) and its `WM_COPYDATA` questions:
  - "SP" for the active panel's path;
  - "SN" for the name under the cursor.

  Total Commander needs no plugin or setting. `[Sort] FollowTotalCommander` (0 off, 1 folder, 2 folder and cursor) keeps your choice. Tested with Total Commander 11.03, 64-bit.

## New: display filters

- **The filter panel at the left edge.** It opens when the mouse rests at the left edge, or from the right-click menu ("Filters"). Its pin (`[Filters] Pinned`) and lock are at the panel's left.
- **The filters:** black / white point (dynamic range), brightness, contrast, gamma, saturation, hue, invert, and **mirror left / right**. Mirror is for the mirrored images of an inverted microscope.
- **How to use them:**
  - wheel over a row: one step;
  - drag along a row: adjust;
  - double-click a row: back to neutral;
  - Reset all clears everything.
- **Speed:** on the graphics card a GLSL shader applies the filters, so a change costs one frame even on 100 MP images. Without the graphics card, the CPU filters only the part shown on screen.
- **Display only:** the image file is never changed. `[filtered]` (or `[filtered, mirrored, auto, locked]`) in the info line says so.
- **Lock filters** (right-click menu, or the lock in the panel) keeps the filters for the next images. Unlocked, each new image starts unfiltered.
- **Histogram** at the top of the panel, of the whole image or of the edit-mode selection. The black and white points are marked on it.
- **Auto** sets the black and white point the way Fiji's Auto contrast does: 0.35 % of the pixels may clip. If there is a selection, Auto uses only the selection.
  - Click Auto: once, for this image.
  - Double-click Auto: on for every image, shown as `[auto]` in the info line.
  - `[Filters] AutoFilter=1` (the default) switches it on from the start.
- **Apply filters to a copy** (right-click menu) makes a new image with the filters in its pixels, named after them (for example `name_bp12_wp240_g0.80_inv`). Save it, or sort it with the sort panel.

## New: the magnifier

- **Switching it on and off:** right-click menu "Magnifier (lens)" (ticked while on), or the `Magnifier` mouse command. Esc switches it off.
- **The lens:** a round lens that follows the mouse. It shows what is under it 1.25 to 32 times larger than on screen, from the full image. The top line shows the magnification against the original, for example `= 450 %`.
- **Left drag:** sideways changes the magnification, up / down changes the size.
- **Wheel:** sharpening off / low / high. While the lens is on, the wheel doesn't change images. The tilt wheel still steps between folders.
- **Wheel click:** locks the lens where it is. The rim turns amber and the mouse is free again, so you can select in edit mode.
- **Filters and mirror** apply inside the lens too.
- **Remembered:** `[Magnifier]` keeps the magnification, size and sharpening.

## Also new and changed

- **Info line:** shows the size on screen in pixels, for example `52 % = 1997 x 1331`. It ends before the TC label.
- **Resize to the size shown** (right-click menu) makes a copy of the image at its size on screen, like a crop. Save, Save as and the sort panel then write that size. Before, they always wrote the original size.
- **Leaving the folder tree upwards:** `[Navigation] ClimbUp=1`. At the end of the tree, the next or previous step continues one level higher, into the neighbouring folders. This also works for folders opened from the sort panel.
- **Zoom centre:** with the four zones on, the zoom zooms at the middle of the window.
- **Fit ↔ 100 % and OriginalSize** show 100 % centred in the window. Only the zoom mode (X1) zooms at the mouse.
- **Edit mode under zoom / rotate:** the top line says `EDIT ON | ZOOM …`, so edit mode is never hidden.
- **New mouse profile commands:**
  - `FilterPanel`, `LockFilters`, `ResetFilters`;
  - `AutoLevels`, `AutoLevelsMode`;
  - `ApplyFilters`, `ResizeToShown`;
  - `Magnifier`.

## Fixed

- **Partly blocky photo:** a photo could stay partly blocky ("sharpening 3 / 12" in the diagnostics line). The graphics card stopped asking for the next part of a large image halfway.
- **Leak report dialogs:** a second MView started from Total Commander could show such dialogs in debug builds.

## Not yet

- **Microscope metadata, scale bar and measuring**, waiting for files from the new instruments:
  - a modern Leica SP8 confocal as the reference;
  - a Nikon camera.

  A camera body records nothing about the microscope, so its scale will come from a calibration with a stage micrometer, one per objective.
- **A note in the images MView saves**, listing what was done to them (planned).
- **16-bit, multi-channel and multi-page images.**
- **Linux** (planned as a separate branch).

Drawing, text and other editing tools are deliberately left out. They are not viewing, and they need the keyboard.

## Installing

Unzip anywhere and start `MView.exe`. There is no installer, and nothing goes into the registry. At the first start MView creates `MView.ini` and `Default.mouse` next to itself. Keys added in this version are added to an existing `MView.ini` automatically.

You need Windows 10 or 11, 64-bit, with OpenGL 2.0 or later. For the filters on the graphics card, the driver must support shaders. Without them, `UseGPU=0` shows the filters on the CPU. The Total Commander features need Total Commander; MView finds it itself, or you can name it with `[Sort] TotalCommander=`.

## Thanks

To Makito Miyano, whose Hamana showed how browsing images should feel, and to Christian Ghisler, whose Total Commander makes MView's job so much simpler.
