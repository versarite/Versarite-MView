unit uWatchdog;

{
  Unit: uWatchdog

  Purpose
  -------
  A way out when MView hangs. Reported on 2026-09-27: on another
  computer a corrupt JPEG froze MView so badly that it couldn't be
  ended. The watchdog is a small thread of its own that doesn't depend
  on the window or the decode workers:

  - Emergency exit: Ctrl+Alt+Shift+Q, a system-wide hotkey registered
    by this thread (WM_HOTKEY arrives in its own message queue), ends
    the process at once (TerminateProcess), even while the window is
    frozen.
  - Exit deadline: when MView is closed normally, the main form arms a
    deadline (ArmExitDeadline). If the process still runs after it,
    for example because a worker thread is stuck in a decode and the
    shutdown waits for it, the watchdog ends the process. Going back
    to the settings screen (Esc) arms it too, around the viewer's
    shutdown, and disarms it afterwards.

  Owns
  ----
  - TWatchdog, the one watchdog thread (TheWatchdog), made by
    StartWatchdog. It runs until the process ends; it is never freed.
  - The hotkey registration (unregistered only if the thread ends).

  Knows
  -----
  Nothing else. The main form (uMainForm) starts it and arms / disarms
  the deadline.

  Responsibilities
  ----------------
  - Register the hotkey (with MOD_NOREPEAT, Windows 7+; without it on
    older systems) and report whether that worked (HotkeyRegistered is
    False if another program already uses the key).
  - Every 100 ms: check for the hotkey and the deadline; end the
    process with exit code 3 (hotkey) or 4 (deadline).
  - EmergencyExit: end the process at once, without any cleanup.

  Does NOT
  --------
  - Free anything or save settings when it ends the process: that is
    the point of an emergency exit. (The normal exit saves them first,
    before the deadline can fire.)
  - Help when a thread is stuck inside Windows (a driver, a disk or
    network read that never returns): then Windows itself can't end
    the process until the read returns, whoever asks.

  Threads
  -------
  Execute runs on the watchdog thread. ArmExitDeadline and
  DisarmExitDeadline are called from the UI thread; they write one
  64-bit field (FExitDeadline), which is atomic on x64; the watchdog
  only reads it. No lock.

  Uses (MView units)
  ------------------
  None: depends only on the libraries below.
  Libraries:      Classes, SysUtils, Windows

  Used by
  -------
  uMainForm

  Notes
  -----
  With two MView windows open, only the first gets the hotkey. Outside
  Windows there is no hotkey, only the deadline.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils
  {$IFDEF WINDOWS}, Windows{$ENDIF};

type

  TWatchdog = class(TThread)
  private
    FExitDeadline: QWord;        { GetTickCount64; 0 = none }
    FHotkeyRegistered: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create;
    { UI thread: end the process if it is still running AMs from now. }
    procedure ArmExitDeadline(AMs: Cardinal);
    { UI thread: the deadline is no longer needed (the viewer ended in
      time and MView goes on, e.g. back to the settings screen). }
    procedure DisarmExitDeadline;
    { False if another program already uses the hotkey. }
    property HotkeyRegistered: Boolean read FHotkeyRegistered;
  end;

const
  EmergencyExitKeyText = 'Ctrl+Alt+Shift+Q';

{ Starts the watchdog (once). }
procedure StartWatchdog;

{ The running watchdog, or nil before StartWatchdog. }
function Watchdog: TWatchdog;

{ Ends the process at once, without any cleanup. }
procedure EmergencyExit(AExitCode: Integer);

implementation

const
  HotkeyId = $4D56;              { 'MV' }
  MOD_ALT_KEY = $0001;
  MOD_CONTROL_KEY = $0002;
  MOD_SHIFT_KEY = $0004;
  MOD_NOREPEAT_KEY = $4000;
  PollMs = 100;

  ExitCodeHotkey = 3;
  ExitCodeDeadline = 4;

var
  TheWatchdog: TWatchdog = nil;

procedure EmergencyExit(AExitCode: Integer);
begin
  {$IFDEF WINDOWS}
  TerminateProcess(GetCurrentProcess, UINT(AExitCode));
  {$ENDIF}
  Halt(AExitCode);   { not reached on Windows }
end;

constructor TWatchdog.Create;
begin
  FExitDeadline := 0;
  FHotkeyRegistered := False;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TWatchdog.ArmExitDeadline(AMs: Cardinal);
begin
  { A 64-bit aligned write is atomic on x64; the watchdog only reads. }
  FExitDeadline := GetTickCount64 + AMs;
end;

procedure TWatchdog.DisarmExitDeadline;
begin
  FExitDeadline := 0;
end;

procedure TWatchdog.Execute;
{$IFDEF WINDOWS}
var
  Msg: TMsg;
  Deadline: QWord;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  { Give this thread a message queue first; the hotkey messages (hWnd
    0) go to the queue of the thread that registered them. }
  PeekMessage(Msg, 0, 0, 0, PM_NOREMOVE);
  FHotkeyRegistered := RegisterHotKey(0, HotkeyId,
    MOD_CONTROL_KEY or MOD_ALT_KEY or MOD_SHIFT_KEY or MOD_NOREPEAT_KEY, Ord('Q'));
  { MOD_NOREPEAT is Windows 7+; without it on older systems. (With two
    MView windows open, only the first gets the key.) }
  if not FHotkeyRegistered then
    FHotkeyRegistered := RegisterHotKey(0, HotkeyId,
      MOD_CONTROL_KEY or MOD_ALT_KEY or MOD_SHIFT_KEY, Ord('Q'));
  try
    while not Terminated do
    begin
      Sleep(PollMs);
      while PeekMessage(Msg, 0, 0, 0, PM_REMOVE) do
        if (Msg.message = WM_HOTKEY) and (Msg.wParam = HotkeyId) then
          EmergencyExit(ExitCodeHotkey);

      Deadline := FExitDeadline;
      if (Deadline <> 0) and (GetTickCount64 >= Deadline) then
        EmergencyExit(ExitCodeDeadline);
    end;
  finally
    if FHotkeyRegistered then
      UnregisterHotKey(0, HotkeyId);
  end;
  {$ELSE}
  while not Terminated do
  begin
    Sleep(PollMs);
    if (FExitDeadline <> 0) and (GetTickCount64 >= FExitDeadline) then
      EmergencyExit(ExitCodeDeadline);
  end;
  {$ENDIF}
end;

procedure StartWatchdog;
begin
  if TheWatchdog = nil then
    TheWatchdog := TWatchdog.Create;
end;

function Watchdog: TWatchdog;
begin
  Result := TheWatchdog;
end;

end.
