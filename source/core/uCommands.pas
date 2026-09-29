unit uCommands;

{
  Unit: uCommands

  Purpose
  -------
  Everything the user can make MView do is a TCommand (spec §2.3,
  §9.1). Keyboard, mouse, gestures and later the scripting language
  only produce commands; TMView carries them out.

  Some commands carry values (TCommandArgs): where the mouse is, how
  far it moved, how many wheel notches. The mouse language (Phase F)
  will produce the same commands with the same values.

  Owns
  ----
  - Nothing: type declarations, the NoArgs constant and CommandArgs.

  Knows
  -----
  - Nothing else.

  Responsibilities
  ----------------
  - Declare TCommand, the full list of commands (navigation, view,
    window, images, mouse language feedback, debugging, planned).
  - Declare TCommandArgs, and CommandArgs / NoArgs to build one.
  - Declare TInputMode (what the wheel does while a mode is on) and
    TCommandEvent, the event through which input hands on commands.

  Does NOT
  --------
  - Carry out commands. See TMView.Execute.
  - Turn keys or mouse input into commands (uMouseEngine).

  Threads
  -------
  No state and no running code apart from CommandArgs, which is safe
  on any thread.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.

  Used by
  -------
  uGLMediaView, uInputHandler, uMView, uMainForm, uMediaView,
  uMouseEngine, uMousePage, uRenderer
}

{$mode ObjFPC}{$H+}

interface

type
  TCommand = (
    cmdNone,

    { Navigation }
    cmdNextImage,
    cmdPreviousImage,
    cmdNextDirectory,
    cmdPreviousDirectory,
    cmdToggleSortMode,
    cmdSortByDate,
    cmdSortByName,
    cmdParentDirectory,  { browse from the parent of the opened folder }
    cmdRescan,

    { View }
    cmdZoomIn,
    cmdZoomOut,
    cmdFitToScreen,
    cmdOriginalSize,
    cmdRotateLeft,
    cmdRotateRight,

    { View, with values (TCommandArgs) }
    cmdZoomAt,           { X, Y: fixed point on screen; Value: wheel notches (+ = in) }
    cmdPanBy,            { X, Y: movement in screen pixels }
    cmdRotateBy,         { Value: degrees, + = clockwise }
    cmdToggleFit,        { X, Y: point to keep; fit <-> 100 % }
    cmdOriginalSizeAt,   { X, Y: point to keep }
    cmdInputMode,        { Value: Ord(TInputMode); only shown on screen }

    { Window }
    cmdToggleInfo,
    cmdToggleDiagnostics,
    cmdToggleFullscreen,
    cmdShowMenu,         { X, Y: where (surface pixels); the form shows it }
    cmdBack,             { leave edit mode, else exit }
    cmdExit,

    { Images }
    cmdPaste,            { the clipboard's image is shown, can be saved }
    cmdSaveImage,        { the image as PNG into the save folder }
    cmdEditMode,         { edit mode on / off: left drag selects an area }
    cmdEditModeOn,
    cmdEditModeOff,
    cmdCropSelection,    { the selected area becomes the image shown (can be saved) }
    cmdDragStart,        { X, Y: where a left-button drag started (surface pixels) }
    cmdDragPoint,        { X, Y: where the drag is now (with every cmdPanBy) }

    { Mouse language feedback (Phase F) }
    cmdShowZone,         { Value: Ord(TMouseZone): show the zone's name }
    cmdGesturePreview,   { X: Ord(TMouseZone); Value: Ord(TMouseEvent) + 1, 0 = none }

    { Sorting into folders (Phase G) }
    cmdSortPanel,        { open the sort panel (else the edge opens it) }
    cmdDeleteImage,      { move the image into the deleted-files folder }
    cmdUndo,             { take back the last copy / move / delete }
    cmdSideBySide,       { MView left, Total Commander right (the form does it) }

    { Debugging }
    cmdSaveDebug,        { the decoded image and a picture of the window }

    { Planned (spec §9.1), not carried out yet }
    cmdMagnifier
  );

  TCommandArgs = record
    X: Double;
    Y: Double;
    Value: Double;
  end;

  { What the mouse wheel does while a mode is switched on (ZoomMode /
    RotateMode in the mouse profile); imBrowse = the profile decides. }
  TInputMode = (imBrowse, imZoom, imRotate);

  TCommandEvent = procedure(Sender: TObject; ACommand: TCommand;
    const AArgs: TCommandArgs) of object;

  { Mouse input offered to something drawn over the image (the sort
    panel, Phase G) before the mouse engine sees it. The handler returns
    True if it took the event (for a press: the release goes to it too,
    and the engine sees neither). Moves are offered too (hover, the
    edge timer); omLeave: the mouse left the view. ADouble: the second
    press of a double-click. }
  TOverlayMouseKind = (omDown, omMove, omUp, omWheel, omLeave);
  TOverlayButton = (obLeft, obRight, obMiddle, obOther);
  TOverlayMouseEvent = function(AKind: TOverlayMouseKind; AButton: TOverlayButton;
    AX, AY, AWheel: Integer; AButtonDown, ADouble: Boolean): Boolean of object;

function CommandArgs(AX: Double = 0; AY: Double = 0; AValue: Double = 0): TCommandArgs;

const
  NoArgs: TCommandArgs = (X: 0; Y: 0; Value: 0);

implementation

function CommandArgs(AX: Double; AY: Double; AValue: Double): TCommandArgs;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Value := AValue;
end;

end.
