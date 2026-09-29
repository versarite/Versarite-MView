# Versarite MView v0.20.0-alpha

The second pre-release. Its main part is **sorting**: after looking at an image, one double-click
copies or moves it into a folder. Days 20 and 21 of development.

## New: the sort panel

- **A slim panel at the right edge** slides out when the mouse rests there for half a second
  (`[Sort] EdgeDelayMs`, `EdgeWidth` in MView.ini), or from the right-click menu ("Sort panel (side
  menu)"). Transparent, drawn by MView on the GPU; as tall as the window, with as many folder buttons
  as fit (the wheel scrolls the rest). A **pin** keeps it open; unpinned it closes after each action.
- **Double-click left = copy, double-click right = move** the image into that button's folder. A
  single click only says so, so nothing is sorted by accident.
- **Moving is instant:** the next image shows at once; the file is copied or moved on a thread of its
  own (a 300 MB TIFF to another drive never freezes the window). A moved image comes back if the
  move fails.
- **You see that it worked:** the button flashes in its folder's colour with a check mark when the
  file is really there, red with a cross if not. With the panel closed, a strip at the edge flashes.
- **Never overwrites** (`_1`, `_2` … instead), **never really deletes**, and writes every action to
  `sorting.log` next to MView.exe.
- **Undo** (the panel's bottom line, the menu, or a mouse command) takes back the last copy, move or
  delete, up to 50 in a row.
- **Delete current image** (right-click menu) moves the file into one deleted-files folder
  (`[Sort] DeletedFolder`, default `Documents\MView deleted files`). Emptying it is up to you.
- **Choosing folders:** drag folders from Total Commander or Explorer onto the panel; or the "…"
  corner of a button: folder dialog, recent folders, this image's folder or its parent, colour, move
  up / down, remove. Everything is kept in MView.ini, `[Sort]`.
- **Into a folder:** swipe right over a button, or click it with the wheel, to browse that folder.
- **Icons on the buttons:** `.ico` / `.png` files from an icon folder (`icons\` next to MView.exe).
  A file named like the folder (`Good.ico` for `…\Good`) is used automatically; or drop an icon on a
  button, or pick one from its "…" menu. Scaled to the button; missing folders are shown grey.
- **Make icon from this image** (right-click menu): the selection or the middle of the screen as a
  multi-size icon (16 … 256 px), named after the image's folder, into the icon folder.
- **Side by side with Total Commander** (right-click menu): MView on the left half of the screen,
  Total Commander on the right half in the image's folder, the sort panel right next to it. Again:
  back to fullscreen.
- **Pasted or cropped images** can be sorted too: they are saved as PNG into the folder.

## Also new

- **Info line** in a new order: file name, image size, folder, then the rest.
- **Save image as …** (right-click menu) with a Windows save dialog, next to **Save image**, which
  now falls back to the Documents folder if the configured save folder can't be used.
- **Settings screen:** Ctrl+V with an image in the clipboard opens the viewer with it; files dropped
  anywhere on the settings screen open as well.
- **Mouse profile commands** for all of it: `SortPanel`, `DeleteImage`, `Undo`, `SideBySide`.

## Not yet

- Magnifier (Hamana's round lens, with pixel values, a scale and optional sharpening) — next.
- Display filters: gamma, brightness, contrast, dynamic range, saturation, hue, inversion — after
  the magnifier. The plans are in `docs\Strategy_Phase_G.md`.
- Microscope metadata on screen, scale bar, measurements; 16-bit, multi-channel and multi-page
  images (waiting for files from the new microscope).
- A settings page for the sort folders (they are set on the panel itself for now).
- Linux (planned as a separate branch).

## Installing

Unzip anywhere and start `MView.exe` (no installer, no registry). It creates `MView.ini` and
`Default.mouse` next to itself at the first start. Windows 10 / 11, 64-bit, with OpenGL.
Side by side needs Total Commander; MView finds it itself, or set `[Sort] TotalCommander=`.

## Thanks

To Makito Miyano, whose Hamana showed how browsing images should feel.
