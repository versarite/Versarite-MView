# Versarite MView 1.0.1

A small update to 1.0, from the first requests after the release.

## New

- **A welcome picture for new users.** `MView_welcome.png` is a map of the screen: the filter
  panel, the sort panel, the icon preview, the four screen zones, the info line, and what the
  mouse does everywhere (wheel, double-click, gestures, tilt wheel, side buttons, right-click
  menu, Esc, the emergency exit). On the very first start (no `MView.ini` yet, no file given) MView
  shows it in the viewer. Keep it next to `MView.exe` (it is in `docs\`).
- **How MView starts: `[Startup] Mode`** replaces `StartFullscreen` (an old `StartFullscreen=1`
  becomes `Mode=1`):
  - `0` — without a file the settings screen, with a file the viewer in a window;
  - `1` (default) — the viewer fullscreen, in the last session's folder (none yet: MView's own
    folder);
  - `2` — the same, then side by side with Total Commander (MView left, Total Commander right, in
    that folder). A user's tip: the best way to start when you sort with Total Commander.

## Changed

- **Defaults:** `[Startup] Mode=1` and `[Sort] FollowTotalCommander=0` (off; switch it on with the
  TC label or the right-click menu). Existing `MView.ini` files keep their values.
- MView's own folder, as a start folder, is opened without its subfolders, so the folders around
  it are never scanned.

## Installing

As 1.0: unzip anywhere and start `MView.exe`, with `MView_welcome.png` next to it.
