---
title: "From Hamana to MView"
subtitle: "A homage: what MView kept, what it changed, and why"
---

# Why this page exists

For twenty years the best image viewer on this desk was Hamana. It was fast, it stayed out of the
way, and it could be driven almost entirely with the mouse. It also had bugs, and they could never
be fixed: its development stopped in 2006 and its source was never published. On today's Windows it
crashes.

MView was written to keep what made Hamana great, in code that can be read, fixed and extended.
It is meant as a homage, not a copy: it takes Hamana's ideas, gives credit for them, and goes its
own way where the microscope bench asks for something different.

# Hamana in brief

| | |
|---|---|
| Author | Makito Miyano (宮野 牧人) |
| Last version | 1.48, 19 June 2006. Development and the support forum have stopped. |
| Platform | Windows 2000 / XP, DirectX 9.0c. Users report crashes on Windows 10 / 11. |
| Licence | Freeware, closed source. |
| Its own words (readme of v1.45, 10 Oct 2005) | fast zooming and effects through DirectX Graphics; a comfortable slideshow with no waiting, thanks to reading files ahead; no registry, so uninstalling means deleting the folder. It was written for a GeForce 3 or better: "with a strong card, far faster display than processing on the CPU." |

In 2005 that was unusual. Most viewers drew with the CPU; Hamana put the image on the graphics card
as textures and let the card scale and turn it. It was a GPU viewer before that was a category.

# What MView kept

| Hamana's idea | In MView |
|---|---|
| **The image lives on the graphics card.** Tiled textures, optional mipmaps. | The GPU renderer (uGLRenderer): tiles, mipmaps made after the first frame is shown, pixel-exact 1:1, a CPU renderer only as a fallback. |
| **Read ahead, never wait.** "File pre-reading for a comfortable slideshow." | A scheduler with several decode threads (uJobScheduler) preloads the neighbours, and the image on screen always reads the disk first (uIOGate). |
| **The mouse does the work.** Right-drag gestures: ← previous folder, → next folder, ↑ parent folder, ↓ exit. | The same four gestures, in MView's own profile and in the Hamana profile. |
| **The screen has places.** In the Hamana.key used here for years, the wheel stepped through the images by name at the top right, by date at the bottom left, and zoomed everywhere else. | Screen zones are a first-class idea in MView's mouse language (uMouseProfile): each quarter has a name, a browsing order and its own events. The default profile keeps the same layout: top right by name, bottom left by date, bottom right to inspect. |
| **One list of commands per event**, with conditions (if the mouse is at the top right…). | A readable text profile, `Default.mouse`: up to three commands per event, per zone. |
| Wheel click = fullscreen. Space = next image. Enter = fullscreen. | The same. |
| **No registry.** Everything lives next to the program. | MView.ini, Default.mouse and the logs live next to MView.exe. |
| Drop a file or folder on the window to open it. | The same. |

# What MView changed, and why

| Hamana | MView | Why |
|---|---|---|
| Closed source; bugs could not be fixed. | Open code; every unit explains itself (Purpose, Owns, Responsibilities, Does NOT, Threads). | The reason MView exists. |
| "Next folder" searched the disk when pressed; the manual warns it "may take some time". | A background thread scans the folder tree once; moving between folders is instant. | Browsing an experiment archive means many folders. |
| At the end of a list, a dialog asked what to do. | No dialogs: configurable wrap-around. | Never in the way. |
| Commands were numbers in a binary-looking key file, edited in a dialog. | Commands have names, in a text file, with a settings page and a "Try it here" area. | Readable, and changeable without a manual. |
| The wheel at the top right both stepped and zoomed (an `if` without `else` in its command list). | Each zone does one thing. | One gesture, one result. |
| Many functions lived on keys. Esc exited. | The mouse can do everything; the keyboard is optional (Space, Enter, D, Esc, arrows). Esc leaves a mode, then goes to the settings screen. | At a laser table the keyboard is out of reach. |
| Crashes, especially on today's Windows, with no way to fix them. | A watchdog with an emergency exit, a shutdown deadline, a memory guard, and replacement of decode threads stuck on a failing disk. | A hang should never cost the user a restart. |
| JPEG built in; everything else through GDI+ plug-ins. | Own decoders where speed matters: a parallel LZW TIFF reader, GIF, band-by-band decoding of huge PNG / TIFF through Windows' WIC. | Microscopy TIFFs first. |
| General photos, manga, archives, PDF, slideshow effects, screensaver. | Microscopy: edit mode with selection and crop, and next the instrument metadata, a scale bar, channel merge and measurements. | The bench, not the photo album. |
| Favourites as lists of paths (Libraries). | Planned: move or copy the file itself into destination folders, from a slide-in menu. | Paths break when files move. |

# The Hamana profile

`mouse\Hamana.mouse` gives MView Hamana's mouse, as it was set up in the Hamana.key used here:

- the wheel steps through the images at the **top right by name** and at the **bottom left by
  date**, and **zooms everywhere else** (towards you = in);
- right-drag **gestures**: ← previous folder, → next folder, ↑ parent folder, ↓ exit;
- **right click** = original size, at once; **wheel click** and **Enter** = fullscreen;
  **Space** = next image.

Where it differs on purpose:

- each zone does one thing (Hamana's top-right wheel also zoomed);
- Hamana's side buttons panned, but MView pans with the left button, so **X1** = zoom mode (as in
  MView) and **X2** = the menu (Hamana's menu was on a key);
- **edit mode** as in MView: left click in the top-left zone = on, double-click there = off;
- the **tilt wheel**, which Hamana never knew, steps through the folders;
- no rotation by mouse (Hamana turned the image with keys).

To use it, copy the file next to `MView.ini` **first** (if MView doesn't find the file, it writes
its own default profile under that name), then set, under `[Mouse]`:

```
Profile=Hamana.mouse
```

`Profile=Default.mouse` goes back to MView's own profile. TestMouse checks that the shipped
Hamana profile loads without errors and does what this page says.

# The principle

> **Fast first, mouse first, never in the way.**

This is what made Hamana worth twenty years, and it is the test for every MView feature, the
microscopy ones included: does it make the next image come sooner, can it be done with the mouse,
and does it stay out of the way when it is not needed?

# Respect

MView contains no Hamana code, file formats, artwork or text. Hamana's files and manual were read
only to understand its ideas (`docs\Hamana_Research.md`) and the mouse layout used with it here
(`docs\Hamana_Commands.md`). The name Hamana belongs to its author. MView has its own name, its own
icon and its own look; the homage is in the ideas, the credit, and the Hamana profile.

Thank you, Miyano-san.

# Sources

- Hamana's readme (Hamana.txt, v1.45, 2005-10-10) and manual (manual.html), in the hamana folder of
  this project
- [Hamana – the author's page](http://miyano.s53.xrea.com/)
- [Hamana operating manual (Japanese)](http://miyano.s53.xrea.com/manual.html)
- [Vector software library entry](https://www.vector.co.jp/soft/winnt/art/se298407.html)
- MView's own research notes: `docs\Hamana_Research.md`, `docs\Hamana_Commands.md`
