# Versarite MView v0.19.0-alpha

The first public pre-release of Versarite MView: a native Windows image viewer for microscopy,
driven by the mouse, and a homage to Hamana. Nineteen development days so far; used daily, but
things may still change.

## What it does

- **Fullscreen browsing through whole experiment folders.** A background thread scans the folder
  tree; next / previous image and folder are instant, sorted by date or by name (natural order),
  with wrap-around and no dialogs.
- **Drawn on the GPU** (OpenGL): tiled textures, mipmaps, pixel-exact 1:1, zoom at the mouse,
  free rotation. A CPU renderer takes over if OpenGL is not usable.
- **Never waits.** Several decode threads preload the neighbours; the image on screen always
  reads the disk first. Quick views (EXIF thumbnails, reduced JPEG decoding) come before the full
  image.
- **The mouse language.** The screen has four zones, each with its own name, browsing order and
  commands; right-drag gestures, tilt wheel, side buttons; everything in a readable profile file
  (`Default.mouse`) with a settings page and a "Try it here" area. The keyboard is optional.
- **A Hamana profile** (`mouse\Hamana.mouse`): Hamana's mouse, as it was set up by the author for
  years.
- **Formats:** JPEG, TIFF (own fast reader for uncompressed and LZW TIFFs, parallel), PNG, BMP
  (huge files decoded in bands through Windows WIC, e.g. 21600 × 21600 NASA images), GIF with
  animation (own decoder).
- **Edit mode:** select an area and crop it; save the image, a crop or a picture pasted from the
  clipboard as PNG.
- **Safe:** emergency exit (Ctrl+Alt+Shift+Q), a shutdown deadline, a memory guard for images that
  would not fit, and decode threads stuck on a failing disk are replaced.
- **Documented:** every unit explains itself (Purpose, Owns, Responsibilities, Does NOT, Threads);
  architecture pictures in `docs\architecture`; a developer specification; a daily log.

## Not yet

- 16-bit images, multi-page and multi-channel files, z-stacks (next, with the newer microscopes).
- Microscope metadata on screen, scale bar, channel merge, measurements.
- Move / copy images into destination folders from a slide-in menu.
- Linux (planned as a separate branch).

## Installing

Unzip anywhere and start `MView.exe` (no installer, no registry). It creates `MView.ini` and
`Default.mouse` next to itself at the first start. Windows 10 / 11, 64-bit, with OpenGL.

## Thanks

To Makito Miyano, whose Hamana showed how browsing images should feel.
