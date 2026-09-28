# Hamana command table (recovered from Hamana.exe)

**Date:** 2026-09-25
**Source:** `hamana\Hamana.exe` v1.45 (2005-10-10, from Vector). Read only, nothing was modified or run.
**Purpose:** Complete the decoding of `Hamana.key` started in `Hamana_Research.md` §8. Ideas only, as before: nothing here is copied into MView.

## How it was obtained

- The English string table (resource language 1033) holds every name shown in the key-settings dialog: commands, parameter names and help texts, conditions, and mouse event names.
- One function in `Hamana.exe` (at 0x4969DC) builds the dialog's command list. For each command it stores the command ID, loads the parameter strings and then the command name, and inserts the entry into a map. Walking that function pairs every ID with its name and parameters. Only three commands (Exec application, Change base texture, Change shader) take string parameters; their IDs are built differently and weren't resolved. None of the three appears in your key file.
- A second function (at 0x4640BA) builds the list of mouse events and pairs each event name with its code. That settles the custom codes 136–159.
- A helper confirms the ID ranges: the number of numeric parameters is `(ID > 10000) + (ID > 20000)`.

## Commands without parameters (1–999)

| ID | Command |
|---|---|
| 1 | Next image |
| 2 | Previous image |
| 3 | Next 1 image |
| 4 | Previous 1 image |
| 5 | Goto next folder |
| 6 | Goto previous folder |
| 7 | Goto parent folder |
| 9 | Add all files to library |
| 10 | Perspective/Ortho |
| 11 | PageUp file list |
| 12 | PageDown file list |
| 13 | Add file(@display) to library |
| 14 | Delete file(@display) from library |
| 15 | Text size up |
| 16 | Text size down |
| 17 | Swap L R |
| 20 | Exit |
| 21 | Open file |
| 23 | Fit (preserve direction) |
| 24 | Fit |
| 25 | Save library |
| 26 | Open library to edit |
| 27 | Open library to peruse |
| 35 | Setting dialog |
| 36 | Default tone |
| 37 | Nega |
| 38 | Solarlization |
| 44 | Original size |
| 45 | Hide mouse cursor |
| 46 | Mark file(@display) |
| 47 | Add file(@cursor) to library |
| 48 | Delete file(@cursor) from library |
| 49 | Mark file(@cursor) |
| 50 | Fit to window width |
| 51 | Fit to window height |
| 52 | Incremantal search |
| 53 | Open folder |
| 54 | Edit library detail |
| 55 | Minimize window |
| 56 | Reload file list |
| 57 | Movie pause on/off |
| 58 | Movie mute on/off |
| 59 | Show context menu |

## Commands with one parameter (10001–10999)

Toggles take `mode`: 0 = off, 1 = on, 2 = toggle.

| ID | Command | Parameters |
|---|---|---|
| 10001 | Pan(X) | Value |
| 10002 | Pan(Y) | Value |
| 10003 | Move file list cursor | Value |
| 10004 | Posterization | Gradations |
| 10005 | Brighten | Rate |
| 10006 | High contrast | Rate |
| 10007 | Low contrast | Rate |
| 10008 | Open file/folder(@cursor) | Mode |
| 10009 | Move marked files to recycle box. | Confirm |
| 10010 | Change left drag mode | mode |
| 10011 | Fit (rotate for most large scale) | Rotation direction |
| 10012 | Auto hide menu | mode |
| 10013 | Movie volume | Volume |
| 10014 | Twin image On/Off | mode |
| 10015 | Auto slideshow | mode |
| 10016 | Fullscreen On/Off | mode |
| 10017 | Show file list | mode |
| 10018 | Show image infomation | mode |
| 10019 | Show thumbnail On/Off | mode |
| 10020 | Effect On/Off | mode |
| 10021 | Grayscale On/Off | mode |
| 10022 | Nega On/Off | mode |
| 10023 | Sepia On/Off | mode |
| 10024 | Tone curve On/Off (RGB) | mode |
| 10025 | Tone curve On/Off (YIQ) | mode |
| 10026 | Loupe On/Off | mode |
| 10027 | Edge emphasis On/Off | mode |
| 10028 | Unsharpness On/Off | mode |

## Commands with two parameters (20001–20999)

The second parameter of zoom and rotate is **Effect**: 0 = follow the global effect flag, 1 = on, 2 = off. It controls the animated transition, not an anchor.

`Sort file list` method: 0/1 = name, 2/3 = size, 4/5 = time, 6 = shuffle, 7 = random rotation. Durability: 0 = this time only, 1 = set as default.

| ID | Command | Parameters |
|---|---|---|
| 20001 | Rotate(X) | Degrees, Effect On/Off |
| 20002 | Rotate(Y) | Degrees, Effect On/Off |
| 20003 | Rotate(Z) | Degrees, Effect On/Off |
| 20004 | Zoom in | Rate, Effect On/Off |
| 20005 | Zoom out | Rate, Effect On/Off |
| 20006 | Sort file list | Method, Durability |
| 20007 | Slideshow fit mode | mode, Direction |
| 20008 | Auto levels | Black clipping, White clipping |
| 20009 | Movie seek (by second) | Mode, Second |
| 20010 | Movie seek (%) | Mode, % |
| 20011 | Movie play speed | Mode, Speed |
| 20012 | Change aspect ratio | X, Y |

## Conditions (15001–15016) and block markers

Every condition takes one parameter, **Reverse condition** (0 = normal, 1 = reverse). So `15012 %0` means "if (mouse is in window right-top)", and `15012 %1` would mean "if not". The `%0` is **not** the opening brace. The `if` opens the block itself, and `9001` / `9002` close it (`}` / `} else {`).

| ID | Command | Parameters |
|---|---|---|
| 15001 | isFileListShowed | Reverse condition |
| 15002 | isThumbnailShowed | Reverse condition |
| 15003 | isMarkExist | Reverse condition |
| 15004 | isAutoSlideShowEnabled | Reverse condition |
| 15005 | isFullScreen | Reverse condition |
| 15006 | isTwinImageMode | Reverse condition |
| 15007 | isSlideEffectEnabled | Reverse condition |
| 15008 | mouse is in file list window | Reverse condition |
| 15009 | mouse is in thumbnail window | Reverse condition |
| 15010 | mouse is in window left-top | Reverse condition |
| 15011 | mouse is in window left-bottom | Reverse condition |
| 15012 | mouse is in window right-top | Reverse condition |
| 15013 | mouse is in window right-bottom | Reverse condition |
| 15014 | cursor is on folder | Reverse condition |
| 15015 | Movie is loaded | Reverse condition |
| 15016 | arc file is opened | Reverse condition |
| 9001 | `}` (end of block) | |
| 9002 | `} else {` | |

## Mouse event codes

Slot = code × 4 + Ctrl + 2 × Shift, the same as for keys.

| Code | Event | Code | Event |
|---|---|---|---|
| 2 | Right click | 151 | Gesture ← |
| 4 | Wheel click | 152 | Gesture → |
| 5 | X button 1 | 153 | Gesture ↑ |
| 6 | X button 2 | 154 | Gesture ↓ |
| 155 | Wheel up | 157 | **Screen-saver startup** (not a mouse event) |
| 156 | Wheel down | 158 / 159 / 136 | R button + wheel click / up / down |
| 137 / 138 / 139 | X1 + wheel click / up / down | 140 / 141 / 142 | X2 + wheel click / up / down |

## Your Hamana.key, fully decoded

**`@8` — Right click**

```
Original size   ; 44
```

**`@16` — Wheel click**

```
Fullscreen On/Off(mode=2)   ; 10016
```

**`@20` — X button 1**

```
Pan(Y)(Value=2000)   ; 10002
```

**`@24` — X button 2**

```
Pan(Y)(Value=-2000)   ; 10002
```

**`@32` — Backspace**

```
Previous image   ; 2
```

**`@33` — Ctrl+Backspace**

```
Goto previous folder   ; 6
```

**`@34` — Shift+Backspace**

```
Previous 1 image   ; 4
```

**`@52` — Enter**

```
Fullscreen On/Off(mode=2)   ; 10016
```

**`@108` — Esc**

```
Exit   ; 20
```

**`@128` — Space**

```
Next image   ; 1
```

**`@129` — Ctrl+Space**

```
Goto next folder   ; 5
```

**`@130` — Shift+Space**

```
Next 1 image   ; 3
```

**`@132` — PgUp**

```
Goto previous folder   ; 6
```

**`@136` — PgDn**

```
Goto next folder   ; 5
```

**`@148` — ←**

```
Previous image   ; 2
```

**`@150` — Shift+←**

```
Pan(X)(Value=-500)   ; 10001
```

**`@152` — ↑**

```
Move file list cursor(Value=-1)   ; 10003
```

**`@154` — Shift+↑**

```
Pan(Y)(Value=500)   ; 10002
```

**`@156` — →**

```
Next image   ; 1
```

**`@158` — Shift+→**

```
Pan(X)(Value=500)   ; 10001
```

**`@160` — ↓**

```
Move file list cursor(Value=1)   ; 10003
```

**`@162` — Shift+↓**

```
Pan(Y)(Value=-500)   ; 10002
```

**`@180` — Insert**

```
Text size down   ; 16
```

**`@184` — Delete**

```
Text size up   ; 15
```

**`@200` — 2**

```
Twin image On/Off(mode=2)   ; 10014
```

**`@260` — A**

```
Add file(@display) to library   ; 13
```

**`@262` — Shift+A**

```
Add all files to library   ; 9
```

**`@272` — D**

```
Delete file(@display) from library   ; 14
```

**`@276` — E**

```
Effect On/Off(mode=2)   ; 10020
```

**`@280` — F**

```
Show file list(mode=2)   ; 10017
```

**`@281` — Ctrl+F**

```
Incremantal search   ; 52
```

**`@288` — H**

```
Rotate(Y)(Degrees=18000, Effect On/Off=0)   ; 20002
```

**`@289` — Ctrl+H**

```
Fit   ; 24
```

**`@290` — Shift+H**

```
Rotate(Y)(Degrees=300, Effect On/Off=2)   ; 20002
```

**`@291` — Ctrl+Shift+H**

```
Fit (preserve direction)   ; 23
```

**`@292` — I**

```
Show image infomation(mode=2)   ; 10018
```

**`@304` — L**

```
Rotate(Z)(Degrees=-9000, Effect On/Off=0)   ; 20003
```

**`@306` — Shift+L**

```
Rotate(Z)(Degrees=-300, Effect On/Off=2)   ; 20003
```

**`@316` — O**

```
Open library to peruse   ; 27
```

**`@317` — Ctrl+O**

```
Open file   ; 21
```

**`@320` — P**

```
Perspective/Ortho   ; 10
```

**`@328` — R**

```
Rotate(Z)(Degrees=9000, Effect On/Off=0)   ; 20003
```

**`@330` — Shift+R**

```
Rotate(Z)(Degrees=300, Effect On/Off=2)   ; 20003
```

**`@332` — S**

```
Swap L R   ; 17
```

**`@333` — Ctrl+S**

```
Save library   ; 25
```

**`@334` — Shift+S**

```
Auto slideshow(mode=2)   ; 10015
Hide mouse cursor   ; 45
```

**`@336` — T**

```
Show thumbnail On/Off(mode=2)   ; 10019
```

**`@344` — V**

```
Rotate(X)(Degrees=18000, Effect On/Off=0)   ; 20001
```

**`@346` — Shift+V**

```
Rotate(X)(Degrees=300, Effect On/Off=2)   ; 20001
```

**`@348` — W**

```
Open library to edit   ; 26
```

**`@360` — Z**

```
Setting dialog   ; 35
```

**`@428` — Num +**

```
Zoom in(Rate=10, Effect On/Off=2)   ; 20004
```

**`@436` — Num −**

```
Zoom out(Rate=10, Effect On/Off=2)   ; 20005
```

**`@604` — Gesture ←**

```
Goto previous folder   ; 6
```

**`@608` — Gesture →**

```
Goto next folder   ; 5
```

**`@612` — Gesture ↑**

```
Goto parent folder   ; 7
```

**`@616` — Gesture ↓**

```
Exit   ; 20
```

**`@620` — Wheel up**

```
if (mouse is in window right-top) {   ; 15012 %0
  Sort file list(Method=0, Durability=0)   ; 20006
  Previous image   ; 2
}
if (mouse is in window left-bottom) {   ; 15011 %0
  Sort file list(Method=4, Durability=0)   ; 20006
  Previous image   ; 2
} else {
  Zoom out(Rate=10, Effect On/Off=0)   ; 20005
}
```

**`@624` — Wheel down**

```
if (mouse is in window right-top) {   ; 15012 %0
  Sort file list(Method=0, Durability=0)   ; 20006
  Next image   ; 1
}
if (mouse is in window left-bottom) {   ; 15011 %0
  Sort file list(Method=4, Durability=0)   ; 20006
  Next image   ; 1
} else {
  Zoom in(Rate=10, Effect On/Off=0)   ; 20004
}
```

**`@628` — Screen-saver startup**

```
Sort file list(Method=6, Durability=0)   ; 20006
Fullscreen On/Off(mode=2)   ; 10016
Hide mouse cursor   ; 45
```

**`@904` — <> key**

```
Show context menu   ; 59
```

## Corrections to Hamana_Research.md §8

| §8 says | Recovered |
|---|---|
| `%0` after an `if` stands for the opening `{` | It is the condition's parameter, *Reverse condition* = 0 (normal). |
| 15013 = right bottom (presumed) | Confirmed. 15001–15009 and 15014–15016 are further conditions (file list shown, fullscreen, mouse in file list, cursor on folder, …). |
| 7 = ? (gesture ↑) | Goto parent folder |
| 44 = ? (right click) | **Original size**, so your right click switches to 1:1 |
| 45 = ? | Hide mouse cursor |
| 59 = ? (`<>` key) | Show context menu |
| @628 = VK 157 ? | Screen-saver startup: shuffle, fullscreen, hide cursor |
| 25 / 26 / 27 = save / select / view library | Save library / open library to edit / open library to peruse. Original size, fit width and fit height are 44, 50 and 51. |
| 10014–10020 toggles | 10014 twin image, 10015 slideshow, 10016 fullscreen, 10017 file list, 10018 info, 10019 thumbnails, 10020 effect. 10021–10028 are the filter toggles. |
| Second parameter of rotate/zoom: probably "animate" or "relative to the mouse" | Effect (animation): 0 = follow global flag, 1 = on, 2 = off. Your Shift+rotate and Num± use 2, so no animation. |
| 20006(mode, ?) | Method, Durability. Wheel: 0 = by name, 4 = by time, this time only. Screen saver: 6 = shuffle. |

The if/else quirk in §8 still holds. At the top right, one wheel step browses by name **and** zooms, because the `else` belongs to the second `if` only.

## What this means for MView

- Hamana's condition set is small: window state (file list shown, fullscreen, …) plus mouse region. MView needs the four quadrants, screen edges and zoom state (spec §9.2).
- "Reverse condition" as a parameter is Hamana's way of writing `not`. MView's profile language can simply have `not`.
- A dedicated startup event (VK 157) that runs a command list is a neat idea. MView could have `OnStart` in its mouse profile for the same purpose.
