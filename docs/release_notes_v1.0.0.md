# Versarite MView 1.0

The first release. After 24 development days, three pre-releases (v0.19, v0.20, v0.21) and weeks of
daily use, the viewer is complete: browsing, sorting, display filters, the magnifier and the
connection to Total Commander. From here on 1.x gets fixes and polish; new features go into the
microscopy edition (below).

## In one paragraph

Versarite MView is a fullscreen image viewer for Windows that never makes you wait and never needs
the keyboard. It reads the next images before you ask for them, draws on the graphics card, handles
images of hundreds of megapixels, and lets you drive everything with the mouse: screen zones,
gestures, tilt wheel. After looking, one double-click sorts the image into a folder; display filters
and a magnifier help you look closer; Total Commander and MView work as a pair. It is a homage to
Hamana (Makito Miyano, 2006), whose ideas it carries forward in code anyone can read.

## New since v0.21.0-alpha (Day 24)

- **Icon preview:** resting the mouse on a sort button with an icon shows the icon large (up to its
  own size, 256 px) at the top of the screen, left of the panel. The buttons' icons no longer carry
  a number.
- **Swipe left or right** over a sort button opens its folder (before: only to the right). Left is
  the natural direction at the right edge.
- **The info line in the ini** (`[InfoLine]`): its parts are listed one per line, 1 = shown,
  0 = left out, and appear in the order of the lines (move a line to move the part). `Font` and
  `FontSize` set its font. Parts: FileName, Dimensions, Folder, Position, Videos, Sorting, Zoom,
  State, Animation, Filters, Messages.
- **Videos are counted:** MView 1.0 shows images only, but the info line says "3 videos" when a
  folder has them, and a folder with only videos says so instead of "No images found".
- **Following Total Commander:** Total Commander decides the folder. A folder step in MView now
  shows a short flashing notice, "TC connection: directory change disabled!", in the TC label's
  colour. Image steps wrap around inside the folder.
- **Apply filters and rotation to a copy:** a turned view is turned in the copy's pixels too
  (quarter turns exactly, other angles smoothly with black corners); the copy is named `_rot90`
  and so on. A turn alone is enough for a copy.
- **Drive roots** (`C:\`, `\\server\share`) open without their subfolders
  (`[Navigation] RecurseFromDriveRoot=0`, the default), so a whole drive is never scanned by
  accident; also when going up with the parent-folder command.
- **About box:** "Versarite MView 1.0".

### Fixed

- **A sort folder `C:\` opened MView's own folder.** MView keeps folders without their trailing
  backslash, and Windows reads a bare `C:` as "the current folder on drive C". A bare drive is now
  always its root, wherever a path comes in.

## Everything in 1.0

### Fast browsing

- Fullscreen browsing through whole folder trees, scanned on a background thread; date or natural
  name order; wrap-around; `ClimbUp` continues into the neighbouring folders at the end of the tree.
- Preloading on several decode threads; the image on screen reads the disk first (I/O gate); quick
  views and EXIF thumbnails first; Skim mode while the wheel is held.
- GPU rendering (OpenGL) with tiles and mipmaps; CPU fallback; free rotation; Fit ↔ 100 % centred.
- Formats: JPEG (WIC, own fallback), TIFF (own fast readers for uncompressed and LZW, WIC for the
  rest), PNG and BMP in bands through WIC, GIF with animation (own decoder).
- Safety: memory guard, emergency exit Ctrl+Alt+Shift+Q, shutdown deadline, stuck readers replaced.

### Mouse language

- Four screen zones with names, orders and commands; gestures, tilt wheel, side buttons; up to three
  commands per event; `Default.mouse` edited on the "Mouse & keys" page; the Hamana profile.

### Sorting (v0.20)

- The sort panel at the right edge: double-click left = copy, right = move; a thread of its own;
  a flash in the folder's colour when done; undo; `sorting.log`; never overwrites, never deletes.
- Icons on the buttons (from files, or made from the image), now with a large preview.
- Folders dropped from Total Commander or Explorer; side by side with Total Commander.

### Looking closer (v0.21)

- Display filters on the GPU (shader) or CPU: black / white point, brightness, contrast, gamma,
  saturation, hue, invert, mirror; histogram; Auto (once or for every image, from a selection);
  Lock filters; Apply filters (and rotation) to a copy.
- The magnifier lens: 1.25 to 32 ×, sharpening off / low / high, lockable.
- Resize to the size shown.

### Total Commander (v0.21)

- Follows its folder, or its folder and the file under its cursor; the TC label; only one MView;
  side by side.

### Everyday

- Edit mode with select and crop; paste (Ctrl+V); Save image / Save image as (PNG).
- The settings screen: MView.ini with help for every key, the "Mouse & keys" page.
- The info line's parts, order and font in the ini.

## What comes next: the microscopy edition

Decided on Day 24: the microscopy features don't go into MView itself. They become a **second
program, the microscopy edition**, built from the same source tree, so fixes to the shared core
reach both. MView stays the lean, fast viewer; the microscopy edition adds:

- instrument metadata (Leica .lif / .lei and LAS X exports, Nikon, TIFF / OME / ImageJ);
- calibration per objective, a measuring line (click – follow – click), a scale bar for figures;
- a provenance note in saved images;
- movies and camera recordings as frame stacks with time stamps;
- editing with the keyboard allowed: Photoshop .8bf filters, Fiji / ImageJ through Fiji itself.

## Not in 1.0

- Video playback (videos are counted only), 16-bit and multi-channel display, multi-page TIFF:
  in the microscopy edition.
- Linux (planned as a separate branch).

## Installing

Unzip anywhere and start `MView.exe`. There is no installer, and nothing goes into the registry. At
the first start MView creates `MView.ini` and `Default.mouse` next to itself; keys added in this
version are added to an existing `MView.ini` automatically.

You need Windows 10 or 11, 64-bit, with OpenGL 2.0 or later (for the filters on the graphics card,
a driver with shaders; without, `UseGPU=0` shows them on the CPU). The Total Commander features need
Total Commander.

## Thanks

To Makito Miyano, whose Hamana showed how browsing images should feel, and to Christian Ghisler,
whose Total Commander makes MView's job so much simpler.
