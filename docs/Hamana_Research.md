# Hamana Research Notes

**Date:** 2026-09-24 (§8 and §9 updated 2026-09-25 from the command table in Hamana.exe, see Hamana_Commands.md)
**Purpose:** Learn from Hamana's design for MView. Ideas only. No code, formats or scripting language are copied (see Session 001).

Sources: the author's site and Japanese manual (translated), plus Japanese software review sites. The links are at the end.

---

## 1. Facts

| | |
|---|---|
| Author | Makito Miyano (宮野 牧人) |
| Last version | 1.48, 2006-06-19. Development and the support BBS have stopped. |
| Platform | Windows 2000/XP, DirectX 9.0c ("Direct Graphics"). Users report crashes on Windows 10/11. |
| Formats | JPEG built in. PNG, GIF, BMP, TIFF, ICO, WMF, EMF via GDI+ wrapped as a Susie plugin. Archives (zip, 7z, rar, cab, arj, lzh) via Susie plugins. PDF via Ghostscript. |
| Licence | Freeware, closed source. Only the ax7z.spi archive plugin is LGPL. |
| Built with | Visual C++ .NET (from the note on the resource DLL project). |

---

## 2. Rendering: what the author says

**Tiled textures.** "Hamana splits the image into textures of a fixed size." The default tile is **64 × 64**, configurable since v0.96. The manual warns that tile borders can become visible when zooming in, and that larger tiles hide the borders but use video memory less efficiently.
→ Confirms the MView tile design. Lesson: seams come from linear filtering across tile edges, and are fixed properly with a 1-pixel overlap, not by making tiles bigger (spec §8.2).

**Mipmaps.** Optional since v1.10, **off by default**. They "greatly improve quality when shrinking" but cost texture memory and add a little time before the image appears.
→ MView: mipmaps on, but generated after the first display (show the image first, refine after), in line with the load-priority rule.

**1:1 display is not pixel-exact.** "Original size … may be slightly blurred depending on the video card." This is the typical Direct3D 9 half-pixel offset.
→ MView: pixel-aligned placement and nearest filtering at exactly 1:1 (spec §8.2).

**Pixel-shader filters.** Edge enhancement and smoothing (need Pixel Shader 2.0). Tone curve editable by dragging, with presets (high contrast, inversion, posterization, solarization), in two variants: per RGB channel, or on luminance only via YUV (inverts brightness but keeps colors). Filters can't be combined.
→ Very relevant for microscopy. MView can do brightness/contrast/gamma windowing, and later a tone curve, as one combined shader. 16-bit data makes this more valuable (spec §7.3).

**Other.** 3D rotation (Shift+Ctrl+drag), perspective/orthographic toggle, 11 slideshow transition effects (reviewers say random effects cause dizziness), two-page mode, basic video playback.

**Preloading.** "File pre-reading for a comfortable slideshow." The manual doesn't document any details.

---

## 3. Input and the command system

**Command lists with conditions.** Every key or mouse action is mapped to a *list* of commands, edited in the settings dialog and stored in `Hamana.key`. Special commands give conditional branching:

```
if (file list visible) {
  move cursor
} else {
  next image
}
```

`if (...) {`, `} else {` and `}` are themselves commands in the list. The left click cannot be customized.
→ This is the "event → condition → command" idea from MView Session 001. An improvement for MView: a readable text file with the conditions MView needs (quadrant, screen edge, zoom state, modifiers), not a list built in a dialog.

**Default mouse** (from the manual's appendix):

| Action | Default |
|---|---|
| Wheel up/down | Move the file-list cursor (not change image) |
| Right click | Next image |
| Left drag | Pan, zoom or rotate, depending on a mode chosen in the toolbar |
| Shift + left drag | Pan |
| Ctrl + left drag | Zoom |
| Shift + Ctrl + left drag | 3D rotation |
| Right drag → / ← | "Simple mouse gestures": open item / parent folder |

The manual does not document screen-quadrant conditions. The file list pops up when the cursor reaches the top-left, and reviewers mention an image seek bar at the bottom right. If quadrant-dependent wheel behaviour exists, it comes from the conditions in the key settings, which are only listed in the program itself.

**Keyboard defaults:** Space / Backspace = next / previous image, Ctrl+Space / Ctrl+Backspace = next / previous folder containing images, +/− = zoom 10 %, R/L = rotate 90° (with Shift: 3° steps), H/V = mirror, Ctrl+H = fit, Enter = fullscreen, Esc = exit.

**External programs.** A command runs any program, synchronously or asynchronously, with macros: `$F` file at the cursor, `$MF` marked files, `$DF` displayed files, `$P` current folder. The manual's own example of moving files is a workaround: `mv $MF "C:\Jpeg Files\"`, run synchronously, then "reload file list".
→ Moving files was clearly not built in. MView's slide-in move/copy menu is a real improvement here.

---

## 4. Navigation

- A pop-up **file list** (and thumbnails) at the top left, hidden automatically. Folders are green, archives light blue, images white, unsupported files red, the current image pink.
- **Folder order** for next/previous folder, applied recursively: images in the folder, then subfolders, then archives in the folder.
- "Next folder" **searches when you press it**, and the manual warns it "may take some time". There is no background tree.
  → MView's background directory scan removes this wait.
- At the **end of the list, a dialog asks** whether to go to the next folder or back to the start (the automatic slideshow always wraps).
  → MView: no dialog, configurable wrap-around. This is a clear improvement for fast browsing.
- Incremental search in the file list, with wildcard, regex and Migemo (romaji → kanji) modes.
- Sort order is selectable. Two-page mode (with automatic single page for landscape images) is aimed at manga.

---

## 5. Favorites: "Libraries"

- A library is a text file (`*.hfl`) with **paths** to images, not the images themselves.
- One library is chosen for editing (W). A adds the displayed image, Shift+A the whole list, D removes it. **Saving is manual** (Ctrl+S). Opening a library (O) loads it as a file list.
- Per file, the order, a page-turn sound and a transition effect can be set.

→ This is Hamana's closest feature to MView's goal, and the weaknesses show the improvement:

| Hamana library | MView (planned) |
|---|---|
| Stores paths only, which break when files move | Moves or copies the actual file into a favorite folder |
| One active library at a time, chosen by key | Several destinations always visible in the slide-in menu |
| Manual save | Immediate, with undo |
| Whole image only | Also a cropped/rotated region, saved into a repository with the original left untouched |

---

## 6. Thumbnail cache

- One file (`HamanaThumb.mcf`) next to the exe, about 2.5 KB per thumbnail. The author's target: usable with 500,000 files on an Athlon 2700+.
- **Key = file name without path + size + timestamp.** Thumbnails therefore follow files that are copied or moved, as long as name, size and timestamp stay the same. The drawback: two different files with the same name, size and time share a thumbnail, which is very rare.
- Caching can be switched off, because on some systems it gains little.

→ Good idea for MView's later thumbnail cache. A path-free key survives the move/copy workflow, which fits MView well. Adding a small hash of the first bytes of the file removes the collision risk.

---

## 7. What MView takes, and where it goes further

| Take (as an idea) | Improve |
|---|---|
| GPU textures, tiles, mipmaps, shader filters | Seam-free tiles, pixel-exact 1:1, mipmaps after first display |
| Command lists with if/else conditions | Readable text profile, quadrant/edge conditions, no dialog editor |
| Pan/zoom/rotate by drag with modifiers | Quadrant contexts, gestures |
| Path-free thumbnail key | Plus a content hash |
| Preloading | Priority scheduler, cancellation, skim mode, multithreading (spec §5–6) |
| — | Background recursive scan instead of search on keypress |
| — | No dialogs at end of list |
| — | Built-in move/copy to favorite folders (slide-in menu) |
| — | Crop/rotate a region into a repository |
| — | 16-bit microscopy TIFF support, contrast windowing |
| Not taken | Slideshow effects, 3D rotation, two-page mode, archives, PDF, screensaver |

---

## 8. The `Hamana.key` file (decoded)

Decoded from a real `Hamana.key` ("Hamana Key Settings v1.43"), first by comparing it with the manual's default keys. On 2026-09-25 the command table was read out of `Hamana.exe` v1.45 itself, which confirmed or corrected every entry. The full table, all mouse event codes and the complete decoded key file are in **`Hamana_Commands.md`**. This section keeps the parts that matter for MView.

### Format

A plain text file with one token per line:

```
@<slot>              start of the command list for one key/mouse event
<id>                 a command
%<value>             a parameter of the preceding command
```

- **Slot** = `Code × 4 + Ctrl × 1 + Shift × 2`. Examples: `@128` = Space (VK 32), `@129` = Ctrl+Space, `@130` = Shift+Space.
- Codes 2, 4, 5, 6 are the Windows mouse buttons (right, wheel click, X1, X2). **Codes 136–159 are Hamana's own**, for events Windows has no key code for: wheel up/down (155/156), gestures ← → ↑ ↓ (151–154), wheel combined with a held button (136–142, 158, 159), and **157 = screen-saver startup**, which is not a mouse event at all.
- **The ID range tells how many parameters follow:** `1–999` none, `10001–10999` one, `15001–15016` one (conditions), `20001–20999` two. Hamana's own code computes it as `(ID > 10000) + (ID > 20000)`. `9001` = `}` and `9002` = `} else {`.
- A command list is a flat sequence. `if` / `else` / `}` are ordinary entries in it. That is exactly the dialog-built list from the manual.
- **Conditions have one parameter, "Reverse condition"** (0 = normal, 1 = reverse). So `15012 %0` reads "if (mouse in right top)", and `15012 %1` reads "if not". The `if` opens the block itself; the `%0` is not a brace.

### Mouse and custom codes in this file

| Slot | Event | Commands |
|---|---|---|
| @8 | Right click | 44 original size (the manual's default is "next image"; this file changes it) |
| @16 | Wheel click | 10016(2) toggle fullscreen |
| @20 / @24 | X1 / X2 button | 10002(±2000) pan vertically by a large step |
| @604 | Gesture ← | 6 previous folder |
| @608 | Gesture → | 5 next folder |
| @612 | Gesture ↑ | 7 parent folder |
| @616 | Gesture ↓ | 20 exit |
| @620 | Wheel up | see below |
| @624 | Wheel down | see below |
| @628 | Screen-saver startup | 20006(6,0) shuffle the list once, 10016(2) toggle fullscreen, 45 hide mouse cursor |
| @904 | `<>` key (VK 226) | 59 show context menu |

These gestures (← previous folder, → next folder, ↓ exit) are exactly the ones in the MView design notes.

**Wheel down (@624), which is the screen-region logic:**

```
if (mouse in right top) {           ; 15012 %0   (0 = not reversed)
  sort file list (name, once)       ; 20006 %0 %0
  next image                        ; 1
}                                   ; 9001
if (mouse in left bottom) {         ; 15011 %0
  sort file list (time, once)       ; 20006 %4 %0
  next image                        ; 1
} else {                            ; 9002
  zoom in 10 %, follow effect flag  ; 20004 %10 %0
}                                   ; 9001
```

Wheel up (@620) is the same with "previous image" (2) and "zoom out" (20005).

Mouse-region conditions: **15010 = left top, 15011 = left bottom, 15012 = right top, 15013 = right bottom** (all four confirmed from the exe). Other conditions: file list / thumbnails shown, marks exist, slideshow running, fullscreen, twin image mode, slide effect enabled, mouse in file list / thumbnail window, cursor on a folder, movie loaded, archive open (15001–15009, 15014–15016).

This is the layout from MView Session 002: bottom left = main browsing by date, top right = secondary browsing by filename, other quadrants = zoom.

**Quirk:** the first `if` has no `else`. With the mouse at the top right, the second `if` (left bottom) is false, so its `else` also runs, and one wheel step does "next image" **and** "zoom in 10 %". MView's profile language should have `else if` or a `case` on the quadrant, so only one branch can run.

### Command IDs used in this file

| ID | Meaning | Key in this file |
|---|---|---|
| 1 / 2 | Next / previous image | Space, → / Backspace, ← |
| 3 / 4 | One image forward / back (two-page mode) | Shift+Space / Shift+Backspace |
| 5 / 6 | Next / previous folder | Ctrl+Space, PgDn, gesture → / Ctrl+Backspace, PgUp, gesture ← |
| 7 | Parent folder | gesture ↑ |
| 9 | Add all files to library | Shift+A |
| 10 | Perspective / ortho | P |
| 13 / 14 | Add / remove displayed file in library | A / D |
| 15 / 16 | Text size up / down | Delete / Insert |
| 17 | Swap left/right page | S |
| 20 | Exit | Esc, gesture ↓ |
| 21 | Open file | Ctrl+O |
| 23 / 24 | Fit keeping orientation / fit | Ctrl+Shift+H / Ctrl+H |
| 25 / 26 / 27 | Save library / open library to edit / open library to peruse | Ctrl+S / W / O |
| 35 | Settings dialog | Z |
| 44 | Original size (1:1) | right click |
| 45 | Hide mouse cursor | Shift+S, screen-saver startup |
| 52 | Incremental search | Ctrl+F |
| 59 | Show context menu | `<>` key |
| 10001 / 10002 (n) | Pan X / Y by n | Shift+arrows, X1/X2 |
| 10003 (n) | Move file-list cursor by n | ↑ / ↓ |
| 10014–10020 (mode) | Toggles: twin image, slideshow, fullscreen, file list, image info, thumbnails, effect. Mode 0 = off, 1 = on, 2 = toggle. | 2, Shift+S, Enter/wheel click, F, I, T, E |
| 15011 / 15012 (reverse) | if mouse in left bottom / right top | wheel |
| 20001 / 20002 / 20003 (angle, effect) | Rotate around X / Y / Z, in 1/100 degree | V = 18000 around X (vertical flip), H = 18000 around Y (horizontal flip), R/L = ±9000 around Z, Shift = ±300 (3°) |
| 20004 / 20005 (percent, effect) | Zoom in / out | Num + / Num − = 10 %, wheel |
| 20006 (method, durability) | Sort file list. Method 0/1 = name, 2/3 = size, 4/5 = time, 6 = shuffle, 7 = random rotation. Durability 0 = this time only, 1 = set as default. | wheel, screen-saver startup |
| 9001 / 9002 | `}` / `} else {` | wheel |

The second parameter of rotate and zoom is **Effect**, the animated transition: 0 = follow the global effect flag, 1 = on, 2 = off. The Shift variants (3° steps) and Num± use 2, so small steps happen without animation; the 90°/180° steps and the wheel follow the global setting.

**Design lessons for MView:**
- Flips are just 180° rotations around the X or Y axis. Hamana's whole view is one 3D transform, so mirror, rotate and 3D tilt are the same mechanism. MView's `TViewState` can use the same trick: mirror = negative scale on one axis.
- Animation is a per-command choice: small repeated steps without it, big jumps with it. Worth keeping for MView's zoom and rotate commands.
- "Reverse condition" as a numeric parameter is Hamana's way of writing `not`. MView's profile language can simply have `not`.
- A startup event (code 157) that runs a command list is a neat idea. MView's profile could have `OnStart` for the same purpose.
- The binary-looking ID scheme is hard to read and edit. MView's profile should use names (`WheelUp`, `NextImage`, `if Quadrant(TopRight)`) for the same power with readable text.

## 9. Not yet examined

- The IDs of the three commands with string parameters (Exec application, Change base texture, Change shader). They are built differently in the exe and don't appear in this key file.
- `Hamana.txt` (readme) with the full version history.
- Which of each sort-method pair (0/1, 2/3, 4/5) is ascending and which is descending.

---

## Sources

- [Hamana – author's page (Makito Miyano)](http://miyano.s53.xrea.com/)
- [Hamana operating manual (Japanese)](http://miyano.s53.xrea.com/manual.html)
- [Vector software library entry](https://www.vector.co.jp/soft/winnt/art/se298407.html)
- [freesoft-100 review](https://freesoft-100.com/review/hamana.php)
- [gigafree review](https://www.gigafree.net/tool/view/hamana.html)
- [kooss review](https://www.kooss.com/pc-soft/hamana.html)
- [zigsow user review](https://zigsow.jp/item/235296/review/180153)
- [husuma photo viewer comparison](https://imageviewer.husuma.com/hamana/)
