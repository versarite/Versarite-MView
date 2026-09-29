---
title: "MView — Strategy for Phase G"
subtitle: "Sorting, microscope metadata, scale bar, adjustments, measuring, magnifier (v7, 2026-09-29: G1 built; G4 and G6 decided)"
---

# The question behind all of it

MView's first principle is **fast first, mouse first, never in the way**, and its purpose is to
**minimise the time between "interesting image" and "next image"** (spec §1, §2.0). Every idea in
this document is measured against that. Each annotation feature is easy on its own; together they
turn a viewer into a clumsy drawing program. This document says **what to build, in which order,
and where to stop**.

| Step | What | Status |
|---|---|---|
| G1 | **Sorting panel**: copy / move the image to preset folders | **Decided: first.** |
| G2 | **Microscope metadata**: read it, show it | Decided: a panel at the top left. |
| G3 | **Scale bar**, burned into a copy on request | Decided. Text labels: **not now** (see G3). |
| G4 | **Display filters**: gamma, brightness, contrast, dynamic range, saturation, hue, inversion | **Planned (user, Day 21): next after G6.** |
| G5 | **Measuring line** with its length in µm | Decided: only this. No arrows, frames, markers. |
| G6 | **Magnifier** (Hamana's loupe), with pixel readout, a scale, optional sharpening | **Planned (user, Day 21): next.** |

**Order now (Day 21):** G1 is built except **side by side with Total Commander** (user: carried
over, from the right-click menu), which finishes it. Then **G6 magnifier**, then **G4 filters**
(they share the GPU shader work, see "Why this order"), then G5, and G2 / G3 when the files of the
new microscope arrive (an inverted research microscope; camera and software not known yet).

# G1 — Sorting panel

## Decided (user, 2026-09-29)

- **Sorting comes first.**
- The panel **opens when the mouse rests at the right edge** of the screen (0.5 s since Day 21,
  `[Sort] EdgeDelayMs`; the edge zone is `EdgeWidth`, 12 px).
- **Built on Day 21** (docs\day021.log, spec §9.7), with the flash confirmation, icons, "Make
  icon", swipe into a folder, and sorting of pasted / cropped images.
- It has a **pin**. Unpinned (the default) it **closes after each action**; pinned it stays open
  for sorting a whole folder.
- **Left click = copy, right click = move** — changed on Day 21 to **double-click left = copy,
  double-click right = move** (user: single clicks sorted too easily).
- **No relative folders**: Total Commander does the directory work. The effort goes into making
  folder selection convenient.
- **Drag and drop from Total Commander** assigns folders, onto the (pinned) side panel.
- **The panel is elastic**: it takes the height of the window, and shows as many folder buttons as
  fit; slim, without compromising usability.
- **Delete** (user): "Delete current image" in the right-click menu moves the file to one
  **deleted-files folder** set in MView.ini. Nothing is ever really deleted by MView; no "empty
  trash" button (Total Commander does the housekeeping).

## Why it can't be the normal right-click menu

The right-click menu is a Windows menu (`TPopupMenu`). Its items only know "chosen", not which
button chose them, so left = copy and right = move is not possible there. The sort panel is
**MView's own panel**, drawn by the renderer like the info line (GPU and CPU renderers alike).

## Layout: a column at the right edge

```
                                          +-----------------+
                                          |  Sort     [pin] |
                                          | [1] Good        |  left click  = copy
                                          | [2] Interesting |  right click = move
                                          | [3] Reject      |  (...) = choose folder
                                          | [4] Figures     |
                                          | [+]             |
                                          | Undo: moved ... |
                                          +-----------------+
```

- A **column** fits where the mouse already is (the right edge) and leaves the top left free for
  the metadata panel (G2).
- **Elastic** (user): the column is as tall as the window and resizes with it. It shows **as many
  slots as fit**: each slot button is between a comfortable height (about 36 px) and a minimum that
  stays easy to hit and read (about 20 px, one line of text), scaled for the screen's DPI. More
  slots than fit at the minimum: the column scrolls with the wheel.
- **Slim**: about 150 px wide (DPI-scaled); long names are cut with "…"; the full folder shows as
  a hint when the mouse rests on a slot.
- Each slot: a folder icon in the slot's colour (drawn by MView, 8 colours) with the slot number,
  the name, and a small "…" corner. Empty slots are hidden except one "+". The number of slots is
  not fixed (`Slot1` … `SlotN` in MView.ini).
- The bottom line shows the last action, clickable to **undo** it.
- **Opening:** the mouse rests 1 s within a few pixels of the right edge (a setting in
  MView.ini: `EdgeDelayMs=1000`; 0 = off). Also a command `SortPanel` for the mouse profile and a
  menu entry "Sort into folders ...", for windowed mode and for anyone who prefers a button.
- **Closing:** after a copy / move (unless pinned), when the mouse leaves the panel for about half
  a second, or with Esc.
- The right edge is inside the TopRight / BottomRight zones; resting there is not a zone event, so
  nothing clashes. Right-drag gestures that end at the edge don't open it (the button is down).

## Choosing folders conveniently

This is where the effort goes. Ways to assign a folder to a slot, fastest first:

1. **Drag a folder from Total Commander or Explorer onto the side panel** (user: "a great idea").
   Pin the panel, then drop folders on it: onto a slot replaces that slot's folder, onto "+" (or
   the empty space below the slots) adds a slot. Dropped anywhere else, a folder is opened for
   browsing, as today. Several folders dropped at once fill several slots. This fits the Total
   Commander workflow best: the folders are already on screen there.
2. **The "…" corner** opens a small menu:
   - **Choose folder ...** (the Windows folder dialog, see "where it starts" below);
   - **Recent folders**: the last 8 folders used by any slot, one click to reuse;
   - **This image's folder** and **its parent folder**;
   - **Clear slot**.
3. **The settings screen** gets a page "Sort folders" next to "Mouse & keys": all slots in a table
   (number, name, folder, colour), with the same "…" and drag-and-drop.

**Where the folder dialog starts** (the first that exists):

1. the slot's own folder (to change it to a neighbour);
2. the parent of the folder last assigned to any slot (sort folders are often siblings:
   `...\sorted\good`, `...\sorted\reject`);
3. the parent of the current image's folder (the experiment);
4. the Documents folder.

**Names:** the folder's own name by default (`D:\Sorted\Good` → "Good"); renaming needs the
keyboard, so it is only offered in the settings page.

## Where the folders are stored

In **MView.ini**, like every other setting, readable and editable in the settings screen:

```
[Sort]
EdgeDelayMs=1000        ; mouse at the right edge this long opens the panel; 0 = off
Pinned=0                ; the panel's pin, remembered
Slot1Folder=D:\Sorted\Good
Slot1Name=Good
Slot1Color=Green
Slot2Folder=D:\Sorted\Reject
Slot2Name=Reject
Slot2Color=Red
Recent1=D:\Sorted\Figures
...
```

One key per value (not packed into one line), so folder names with any character are safe and the
settings editor can explain each key. **Sets of slots** (one set per project, switched like mouse
profiles) are a possible later step if one set isn't enough; the ini layout above allows it
(`[Sort Project A]`).

## What makes it safe

- **Never overwrite.** A name that exists gets `_1`, `_2` … added.
- **Undo instead of "are you sure?".** The last actions go on an undo list; the panel's bottom
  line and a command `Undo` take back the last one (a copy is deleted again, a move goes back).
- **A log**: `sorting.log` next to MView.exe, one line per action (time, copy / move, from, to).
- **On a worker thread**: copying a 300 MB TIFF or moving it to another drive must not freeze the
  window (spec §2). The status line shows progress and the result.
- **Checking folders in the background**: whether a slot's folder exists is checked by the worker
  when the panel opens (a dead network drive must not freeze the window); a missing folder shows
  its slot greyed, with the reason.
- **After a move** the image leaves the current folder: the list, the cache and the preloads forget
  it, and the next image is shown.

## Icons for the slots (user: custom .ico files from an icon folder)

- **An icon folder**: `icons\` next to MView.exe by default (`[Sort] IconFolder=` to use another).
  Any `.ico` (or `.png`) put there can be used.
- **Assigning, fastest first:**
  1. **Drag an .ico file from Total Commander onto a slot** of the pinned panel: the same gesture
     as for folders. A dropped folder sets the slot's folder, a dropped icon file sets its icon.
  2. **By name, automatically**: an icon named like the slot's folder (`Good.ico` for
     `D:\Sorted\Good`) is used without any assigning. Name the icons once, and every slot finds
     its own.
  3. **The "…" menu → Icon**: the icons of the icon folder as a small picture list, one click;
     "Coloured folder" goes back to the drawn folder.
- **Making an icon from an image** (user): the right-click menu entry **"Make icon from this
  image"** takes the edit-mode selection if there is one, otherwise the middle of what is on
  screen, cut to a square; scales it to 16, 24, 32, 48, 64, 128 and 256 px and writes them all
  into one .ico (PNG entries, as Windows does for its own icons). The file goes into the icon
  folder, **named after the current image's folder** (browsing in `D:\Sorted\Good` gives
  `Good.ico`), so the slot for that folder picks it up by name. An existing icon of that name is
  kept as `<name>_previous.ico`.
- **Stored** as `Slot1Icon=good.ico` (a name in the icon folder, or a full path).
- **Scaled to the button** (user), whatever size the elastic panel gives it: an .ico holds several
  sizes (16, 32, 48, 256 px …); MView takes the smallest one that is at least as large as the
  button and shrinks it with a good filter, so it stays sharp. The scaled picture is made once per
  size and kept until the panel's size changes (resizing the window), so drawing costs nothing.
  An icon with only small sizes (16 px) is enlarged and looks soft: icons with 32 / 48 px or more
  are best. The slot number sits small in a corner. An icon that can't be read falls back to the
  coloured folder.
- Icons are read once (at start and when assigned) and kept in memory: small files next to
  MView.exe, like MView.ini, never image data.

## Side by side with Total Commander (user)

- **Built on Day 21** (user: carried over, from the right-click menu; spec §9.7).
- A menu entry "Side by side with Total Commander" (and a command for the mouse profile):
  - **MView to the left half**, **Total Commander to the right half** (user) of the screen MView
    is on (the work area, so the taskbar stays free; Windows 10 / 11's invisible window borders
    are corrected so the halves meet exactly). MView's sort panel, at its right edge, then sits in
    the middle of the screen, right next to Total Commander: the shortest way to drag a folder or
    an icon onto it.
  - **Total Commander changes to the current image's folder** (user: yes), in its active panel,
    through its documented command line `/O /S /L="<folder>"`.
  - Not running: MView starts it (the path from `[Sort] TotalCommander=`, else from Total
    Commander's own registry entry).
  - The same entry again: MView goes back to fullscreen / its previous place; Total Commander stays.
- Limits, accepted by the user: Windows only; if Total Commander runs as administrator and MView
  doesn't, Windows doesn't let MView move it (ignored for now).

## Delete = move to the deleted-files folder

- **"Delete current image"** in the right-click menu (and a command `Delete` for the mouse
  profile) **moves** the file into one deleted-files folder:
  ```
  [Sort]
  DeletedFolder=D:\MView_deleted_files   ; empty = <Documents>\MView deleted files
  ```
- It is a move like any other: never overwrites (`_1`), goes on the undo list, into
  `sorting.log`, on the worker thread, and the next image is shown.
- **MView never really deletes a file.** No "empty trash" button: emptying the folder is
  housekeeping for Total Commander.
- If the folder can't be used, nothing is moved and the status line says why (no silent
  fallback for deletes).

# G2 — Microscope metadata

## Reading

- On the **decode worker**, from the file header, into the decoded image (like the EXIF
  orientation today). The UI thread never parses files.
- **One small record** for what MView needs, whatever the instrument: pixel size (µm / px, x and
  y), objective (magnification, NA, immersion), channel / stain / wavelength, date and time, zoom,
  bit depth, instrument; plus the full original text for "show everything".
- **One reader per format**, each small and testable:
  - Leica TCS NT (the text block in ImageDescription: the archive at hand);
  - TIFF resolution tags (XResolution + unit) as the general fallback;
  - later, as the files arrive: ImageJ TIFF, OME-TIFF (OME-XML), Zeiss, Nikon, Olympus, newer Leica.
- Test files for each reader in `test\images\meta` (small, anonymised).

## Showing: decided

- **A panel drawn by MView at the top left** (like Hamana's file list), so it doesn't meet the
  right-click menu or the sort panel on the right.
- Shown and hidden by a command (`Metadata`) for the mouse profile; curated fields first (instrument,
  objective, pixel size, channels, date), "more" folds out the full original text.
- Semi-transparent; text colour and solid background follow the overlay settings of the info line.
- **The info line** gets a compact summary: `40x / 1.25 oil   0.163 µm/px   GFP`.
- Not burned in: the panel is for reading.

# G3 — Scale bar

- From the pixel size (G2). If it is missing, the metadata panel offers a few common values or
  "from the folder's other images"; no typing.
- **Length chosen automatically** as a round number (1, 2, 5, 10, 20, 50 … µm), about a fifth of
  the image width; a click on the bar steps through the neighbouring lengths.
- Corner of choice, white or black, with or without a background box; sized in proportion to the
  image, so it looks the same in the saved file at any zoom.
- Shown as an overlay until **burned in** from the right-click menu ("Burn in scale bar"): that
  makes a new image, like Crop, which Save / Save as write. **The original is never changed.**

**Text labels: not now** (user). Typing needs the keyboard; it is for later, or for a separate
annotation app that could be designed on its own.

# G4 — Display filters (planned, user Day 21)

The user's list: **gamma, brightness, contrast, dynamic range, saturation, hue, inversion** —
"great for looking at ROI features". What they do and how they feel with the mouse:

## The filters

| Filter | What it does | Range, reset |
|---|---|---|
| Dynamic range (black / white point) | Stretches the values between two points to the full range; below black is black, above white is white. **The** tool for faint structures and for 12 / 16-bit images. | 0 … max of the data; reset = full range |
| Brightness | Adds to every value. | −100 … +100 %; 0 |
| Contrast | Stretches around the middle grey. | −100 … +100 %; 0 |
| Gamma | Bends the curve: < 1 brightens the dark parts, > 1 darkens them. Non-linear: marked as such. | 0.2 … 5; 1.0 |
| Saturation | 0 = grey, 1 = as is, 2 = twice as colourful. | 0 … 3; 1 |
| Hue | Turns the colours around the colour wheel. | −180° … +180°; 0 |
| Inversion | Dark becomes light (dark-field look; faint dark structures on a light background become easier to see). | on / off |

Order in which they are applied (fixed, shown in the panel): dynamic range → brightness /
contrast → gamma → saturation / hue → inversion. **Auto** sets the black / white point like Fiji's
auto contrast (0.35 % of the pixels saturated), on the whole image or, with a selection, on the
**region of interest** (see below).

## Mouse first

- **A filter panel**, drawn by MView like the sort panel, **at the left edge**: it opens when the
  mouse rests at the left edge (user), like the sort panel at the right (same delay and edge width
  settings), with a **pin** remembered in MView.ini (user: `[Filters] Pinned`). Also the
  right-click menu ("Filters …") and a mouse profile command `Filters`. It lists the filters as slim rows with a bar each; a small
  histogram at the top shows the black / white points.
- **Wheel over a row** changes that value in small steps; **left drag** along the row changes it
  continuously; **double-click** a row resets it; a **reset all** and an **Auto** button.
- Changes show **instantly** while dragging, at full frame rate, also on 100 MP images.
- A mark in the info line whenever any filter is active (`[filtered]`), so a filtered view is
  never mistaken for the data.

## Regions of interest

- **The whole view** is filtered by default.
- **With an edit-mode selection**: Auto takes its black / white points from the selection only
  (the ROI's own range), and a switch "only inside the selection" filters just that rectangle, the
  rest stays as it was, for comparing.
- **In the magnifier** (G6): a switch "filters only in the magnifier" — the lens becomes a movable
  ROI filter: the image stays honest, the lens shows the enhanced detail.

## How it is built

- **GPU renderer: a fragment shader.** All seven filters are a few lines of arithmetic per pixel
  on the texture that is already there; changing a value only changes a few numbers (uniforms), no
  upload. That is why it is instant. It needs MView's first shader (today MView draws with the
  fixed-function OpenGL pipeline); the magnifier (G6) introduces it first.
- **CPU renderer**: the same maths on the screen-size copy it already makes (never on the full
  image): dynamic range, brightness, contrast, gamma and inversion as one lookup table per channel
  (256 entries, very fast), saturation / hue per pixel (slower, still fine at screen size).
- **16-bit images** (G2, the new microscope): the black / white points work on the real 16-bit
  values; that goes together with 16-bit display (spec §7.3).
- **Scientific honesty:** display only. "Apply filters to a copy" (menu) makes a new image, like
  Crop, whose name says what was applied (`_bp120_wp3400_g0.8_inv`); Save / Save as and the sort
  panel then write it. The original file is never changed.

## Decided (user, Day 21)

1. **"Lock filters"**, a toggle in the right-click menu: locked, the filters stay for every image
   shown next; unlocked (the default), the next image is shown unfiltered. The `[filtered]` mark
   is always visible while filters are on.
2. The filter panel opens by **resting at the left edge**, with a **pin** linked to MView.ini.

Still open: per-channel black / white points (red, green, blue separately) now, or with the
multichannel microscope files? (Proposal: with the microscope files.)

# G5 — Measuring line (decided: only this)

- A **line** drawn with the mouse in edit mode (a mode switch, like the selection frame), showing
  its **length in µm** (from the pixel size; in pixels if none is known).
- The number stays readable at any zoom; the line can be burned in with the scale bar.
- **Out of scope:** arrows, callouts, frames, region markers, styles, layers. Figures go to
  PowerPoint or Inkscape.

# G6 — Magnifier (planned, user Day 21)

Hamana had a magnifier: a lens that follows the mouse and shows the part under it enlarged. The
user wants it back, **combined with the metadata and measuring**, and with **adaptive sharpening**
or a similar enhancement.

## Using it (user)

- **On / off from the right-click menu** ("Magnifier"), and a mouse profile command `Magnifier`
  (for a button or a zone of one's own). Esc ends it, like the other modes.
- The lens **follows the mouse**; the image under it doesn't move.
- **Left click + drag horizontally: magnification** (to the right = more). **Left click + drag
  vertically: the size of the lens** (up = larger). The direction is decided by the first few
  pixels of the drag, as for gestures, so the two never mix.
- **The wheel cycles the sharpening: off → low → high → off** (user). Off by default.
- **A wheel click locks the lens** in place (for reading values or measuring at leisure);
  another one unlocks it and it follows the mouse again (user).
- The right click keeps opening the menu (magnifier settings are in it).
- Magnification and size are remembered in MView.ini (`[Magnifier] Zoom=4`, `Size=300`, …).

## What the lens shows

- **Real pixels**: it magnifies the **full image** (the full-size decode is asked for as soon as the
  magnifier is on), not the screen. Magnification relative to the view: 2 × … 32 ×; beyond one
  screen pixel per image pixel the pixels are shown as sharp squares (as MView's own zoom above
  400 %), with a faint **pixel grid** at high magnification (switchable).
- **Its own scale**: a small scale bar in the lens (e.g. "5 µm"), from the pixel size (G2); in
  pixels if none is known.
- **Readout** at the centre (a small cross): the pixel's **coordinates** (px, and µm with a pixel
  size), its **value** (RGB, or the 12 / 16-bit value of microscope images) and, with filters on,
  the displayed value too.
- **Measuring (G5) through the lens**: while the magnifier is on, the measuring line's ends can be
  placed with the lens's precision (sub-pixel by eye), and the lens shows the length while
  dragging.
- **Filters in the lens only** (G4): the lens as a movable ROI enhancer.
- **Round** (user: "because it is cute"), a thin frame, a soft shadow, drawn on top of everything
  except the panels.

## Enhancement: adaptive sharpening

- **Contrast-adaptive sharpening** (the kind used in games: AMD's CAS idea): sharpens edges more
  where the local contrast is low and less where it is already high, so it brings out faint
  structure **without the halos and noise** of a plain unsharp mask. Three steps, **off / low /
  high**, cycled with the wheel (user); the strengths of low and high are settings in MView.ini.
- Possible extra, later: **local contrast** (a light CLAHE-like stretch of the lens's own range),
  in the menu, off by default.
- **Marked**: the lens frame turns a different colour and shows "sharpened" / "local contrast"
  while an enhancement is on; never burned into anything unless asked ("Apply to a copy").
- Inside the lens only; the view outside stays as it is.

## How it is built

- **GPU renderer**: the lens is a second textured quad drawn from **the same texture** as the
  image (no new upload), with its own zoom around the mouse, clipped to a circle; sharpening and
  filters are a **fragment shader** on that quad (MView's first shader, reused by G4). Cost: a few
  hundred thousand pixels per frame, nothing for any GPU.
- **CPU renderer**: the lens cut from the full image, scaled (nearest neighbour above 1:1), then
  sharpened in software; lens-sized only, so it stays fast.
- In the **mouse engine** it is a mode like zoom and rotate mode (imMagnifier): the engine turns
  the drags into commands (`MagnifierZoomBy`, `MagnifierSizeBy`), TMView keeps the state, the
  renderers draw it.
- Pixel values come from the decoded image in memory (the full version); 16-bit values once the
  16-bit path exists (G2 / spec §7.3).

## Decided (user, Day 21)

1. **Round** lens.
2. Magnification **relative to the screen** (the view): 2 × = twice what you see (user: the
   other way might be confusing). The lens shows the original factor small ("= 1:3.2").
3. Sharpening **off by default**; the **wheel cycles off → low → high**.
4. **Hamana's natural lens**: the mouse moves it; left drags (swipes) change magnification
   (horizontal) and size (vertical); the wheel cycles the sharpening; a **wheel click locks /
   unlocks** the lens, so measurements can be made.

## Why this order (G6, then G4)

The magnifier needs the renderer to draw a second view of the same texture and MView's first
**shader** (for sharpening). The filters (G4) are then "more lines in the same shader" for the
lens and for the whole view. Building the lens first gives the filters a place to be tried on a
small area, and the magnifier is useful on its own at once.

# Principles for Phase G

1. **Never change an original.** Everything that changes pixels makes a new file.
2. **Display first, burn in on request.**
3. **Undo instead of confirmation** for file actions.
4. **File work on worker threads**, like decoding.
5. **Measure, don't illustrate.**
6. **Mouse only.** Nothing in Phase G needs the keyboard.
7. **Enhancement is marked.** A filtered or sharpened view always says so on screen.

# Decisions

| # | Question | Decision (2026-09-29) |
|---|---|---|
| 1 | Order | G1 sorting first, then G2, G3, G4, G5. |
| 2 | Sort panel opens | Mouse rests 1 s at the right edge (plus a command and a menu entry). |
| 3 | Sort panel after an action | Closes; a pin keeps it open. |
| 4 | Relative folders | No. Convenient folder choosing instead (drag and drop, recent folders, dialog start). |
| 5 | Metadata display | A panel drawn by MView at the top left. |
| 6 | Text labels | Not now; later, or a separate app. |
| 7 | Drawing tools | Only a measuring line in µm. |
| 8 | Folder assignment | Drag and drop from Total Commander onto the (pinned) panel; "…" menu; settings page. |
| 9 | Panel size | Elastic: window height, as many slots as fit, slim. |
| 10 | Delete | Menu "Delete current image" moves to a deleted-files folder (MView.ini); never a real delete; no "empty trash". |
| 11 | Undo | The panel's bottom line and a command `Undo`. |
| 12 | Side by side with Total Commander | Yes: MView left, Total Commander right (next to the sort panel), 50 / 50; Total Commander opens the image's folder. |
| 13 | Slot icons | Custom .ico / .png from an icon folder: drag and drop onto a slot, automatic by name, or the "…" menu; scaled to the button size. |
| 14 | Making icons | "Make icon from this image": square crop, multi-size .ico, named after the current image's folder, into the icon folder. |
| 15 | Copy / move clicks (Day 21) | Double-click left = copy, double-click right = move (single clicks sorted too easily). |
| 16 | Edge opening (Day 21) | 0.5 s (`EdgeDelayMs`), 12 px edge zone (`EdgeWidth`). |
| 17 | Next stages (Day 21) | G6 magnifier, then G4 filters; G2 / G3 when the new microscope's files arrive. |
| 18 | Magnifier controls (Day 21) | Right-click menu on / off; left drag horizontal = magnification, vertical = lens size; open points above. |
| 19 | Filters (Day 21) | Gamma, brightness, contrast, dynamic range, saturation, hue, inversion; display only. |
| 20 | Magnifier (Day 21) | Round; magnification relative to the screen; mouse moves it, left drag horizontal = magnification, vertical = size; wheel cycles sharpening off / low / high (off by default); wheel click locks / unlocks. |
| 21 | Filters, keeping them (Day 21) | "Lock filters" toggle in the right-click menu; unlocked, the next image is unfiltered. |
| 22 | Filter panel (Day 21) | Opens by resting at the left edge; pin remembered in MView.ini. |
| 23 | Total Commander side by side (Day 21) | Carried over: from the right-click menu; built next, before G6. |
