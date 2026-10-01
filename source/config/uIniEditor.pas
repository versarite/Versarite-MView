unit uIniEditor;

{
  Unit: uIniEditor

  Purpose
  -------
  The settings page MView shows when it is started without a file or
  folder (spec §11, v1.2d): MView.ini in a text editor, with one line
  of help for the key under the cursor, and a button that starts the
  viewer with the last session.

  Built as a page control: the second page, "Mouse & keys"
  (uMousePage, Phase F), edits the mouse profile (Default.mouse).
  Save, Undo, Exit and View images cover both pages.

  Owns
  ----
  Its child controls (through the LCL component tree): the header
  label, the page control with the "MView.ini" page (a TSynEdit with
  an ini highlighter) and the "Mouse & keys" page (TMouseProfilePage),
  the button bar and the help line.

  Knows
  -----
  - The ini file name given to LoadFile, and the mouse profile file
    name given to LoadMouseProfile (the main form passes both).
  - ConfigKeyHelp (uConfig): the help text for a key.
  - OnViewImages, OnExitRequest and OnSideBySide: the main form's
    handlers.
  - Application.HintHidePause: set to 15 s at creation, for the
    longer balloon texts.

  Responsibilities
  ----------------
  - Load and save the ini as text (comments and unknown keys stay as
    they are).
  - Save the mouse profile too, if it was changed on its page.
  - Keep [Mouse] ZonesEnabled of the ini text and the zones switch of
    the mouse page in step (in the text being edited, not the file).
  - Help line: ConfigKeyHelp for the key on the cursor line.
  - Balloon help: the same text as a hint for the line under the
    mouse.
  - Undo: read both files again as they are on disk.
  - No dialogs (spec §3.1): leaving with unsaved changes needs a
    second press of Exit, the help line says so.

  Does NOT
  --------
  - Interpret the settings. TConfig reads the file when the viewer
    starts.
  - Start the viewer itself: OnViewImages, the main form does it.
  - Edit the mouse profile itself (uMousePage).

  Threads
  -------
  UI thread only (LCL events). No locking.

  Uses (MView units)
  ------------------
  interface:      uConfig, uMousePage
  Libraries:      Classes, SysUtils, Controls, Forms, Graphics,
                  StdCtrls, ExtCtrls, ComCtrls, LCLType, SynEdit,
                  SynEditTypes, SynHighlighterIni

  Used by
  -------
  uMainForm

  Keys: Ctrl+S = save, F5 = save and view images.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  SysUtils,
  Controls,
  Forms,
  Graphics,
  StdCtrls,
  ExtCtrls,
  ComCtrls,
  LCLType,
  SynEdit,
  SynEditTypes,
  SynHighlighterIni,
  uConfig,
  uMousePage;

type

  { TIniEditor }

  TIniEditor = class(TPanel)
  private
    FFileName: string;
    FHeader: TLabel;
    FPages: TPageControl;
    FIniPage: TTabSheet;
    FMouseTab: TTabSheet;
    FMouse: TMouseProfilePage;
    FEdit: TSynEdit;
    FHighlighter: TSynIniSyn;
    FBar: TPanel;
    FHelp: TLabel;
    FExitArmed: Boolean;
    FNextButtonLeft: Integer;
    FHintLine: Integer;          { line the hint was made for, -1 = none }
    FOnViewImages: TNotifyEvent;
    FOnExitRequest: TNotifyEvent;
    FOnSideBySide: TNotifyEvent;

    function MakeButton(const ACaption: string; AHandler: TNotifyEvent): TButton;
    procedure HandleViewClick(Sender: TObject);
    procedure HandleSaveClick(Sender: TObject);
    procedure HandleUndoClick(Sender: TObject);
    procedure HandleExitClick(Sender: TObject);
    procedure HandleSideBySideClick(Sender: TObject);
    procedure HandleEditStatus(Sender: TObject; Changes: TSynStatusChanges);
    procedure HandleEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleEditMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    function SectionOfLine(ALine: Integer): string;
    { Help text for a line (0-based), '' for blank lines and comments. }
    function HelpForLine(ALine: Integer): string;
    procedure UpdateHelp;
    procedure HandleMouseChange(Sender: TObject);
    procedure HandleZonesToggle(Sender: TObject);
    { A value in the ini text being edited (not the file). }
    function GetIniValue(const ASection, AKey, ADefault: string): string;
    procedure SetIniValue(const ASection, AKey, AValue: string);
    procedure HandlePageChange(Sender: TObject);
    function AnyModified: Boolean;
  public
    constructor Create(AOwner: TComponent); override;

    procedure LoadFile(const AFileName: string);
    { The mouse profile for the "Mouse & keys" page. }
    procedure LoadMouseProfile(const AFileName: string);
    { False (and a note in the help line) if a file couldn't be
      written. Saves the ini and, if changed, the mouse profile. }
    function SaveFile: Boolean;
    procedure FocusEditor;
    { Esc on the settings screen (the main form sees it first): like
      Exit, so with unsaved changes only the second press ends MView. }
    procedure RequestExit;
    { A note in the help line (also the main form's, e.g. side by side). }
    procedure ShowNote(const AText: string);

    { "View images" / F5, after saving. }
    property OnViewImages: TNotifyEvent read FOnViewImages write FOnViewImages;
    { "Exit" (unsaved changes: only on the second press). }
    property OnExitRequest: TNotifyEvent read FOnExitRequest write FOnExitRequest;
    { "Total Commander side by side" (user, Day 22): the main form places
      the windows (the last session's folder, else Documents). }
    property OnSideBySide: TNotifyEvent read FOnSideBySide write FOnSideBySide;
  end;

implementation

constructor TIniEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  ParentColor := False;
  Color := clBtnFace;
  Caption := '';

  FHeader := TLabel.Create(Self);
  FHeader.Parent := Self;
  FHeader.Align := alTop;
  FHeader.BorderSpacing.Around := 8;
  FHeader.Font.Style := [fsBold];
  FHeader.Caption := 'MView settings';

  FBar := TPanel.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alBottom;
  FBar.BevelOuter := bvNone;
  FBar.Height := 110;   { room for the value lists of some keys }
  FBar.Caption := '';

  FNextButtonLeft := 0;
  MakeButton('View images (F5)', @HandleViewClick);
  MakeButton('Save (Ctrl+S)', @HandleSaveClick);
  MakeButton('Undo changes', @HandleUndoClick);
  MakeButton('Total Commander side by side', @HandleSideBySideClick);
  MakeButton('Exit', @HandleExitClick);

  FHelp := TLabel.Create(Self);
  FHelp.Parent := FBar;
  FHelp.Align := alClient;
  FHelp.BorderSpacing.Left := 12;
  FHelp.BorderSpacing.Right := 8;
  FHelp.Layout := tlCenter;
  FHelp.WordWrap := True;
  FHelp.AutoSize := False;
  FHelp.Caption := '';

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;

  FIniPage := FPages.AddTabSheet;
  FIniPage.Caption := 'MView.ini';

  FMouseTab := FPages.AddTabSheet;
  FMouseTab.Caption := 'Mouse & keys';
  FMouse := TMouseProfilePage.Create(Self);
  FMouse.Parent := FMouseTab;
  FMouse.Align := alClient;
  FMouse.OnChange := @HandleMouseChange;
  FMouse.OnZonesToggle := @HandleZonesToggle;
  FPages.OnChange := @HandlePageChange;
  FPages.ActivePage := FIniPage;

  FHighlighter := TSynIniSyn.Create(Self);

  FEdit := TSynEdit.Create(Self);
  FEdit.Parent := FIniPage;
  FEdit.Align := alClient;
  FEdit.Highlighter := FHighlighter;
  FEdit.Font.Name := 'Consolas';
  FEdit.Font.Size := 11;
  FEdit.OnStatusChange := @HandleEditStatus;
  FEdit.OnKeyDown := @HandleEditKeyDown;
  FEdit.OnMouseMove := @HandleEditMouseMove;
  FEdit.ShowHint := True;
  FHintLine := -1;
  { Time to read the longer explanations (the viewer shows no hints). }
  Application.HintHidePause := 15000;
end;

{ Buttons from left to right in the order they are made. }
function TIniEditor.MakeButton(const ACaption: string; AHandler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := FBar;
  Result.Caption := ACaption;
  Result.AutoSize := True;
  Result.Left := FNextButtonLeft;
  Result.Align := alLeft;
  Result.BorderSpacing.Around := 10;
  Result.OnClick := AHandler;
  Inc(FNextButtonLeft, 1000);
end;

procedure TIniEditor.LoadFile(const AFileName: string);
begin
  FFileName := AFileName;
  FHeader.Caption := 'MView settings:   ' + AFileName
    + '      (start MView with an image or a folder to view it directly)';
  try
    if FileExists(AFileName) then
      FEdit.Lines.LoadFromFile(AFileName)
    else
      FEdit.Lines.Clear;
    FEdit.Modified := False;
    FEdit.MarkTextAsSaved;
    FExitArmed := False;
    { The zones switch of the mouse page lives in this file. }
    { As TIniFile.ReadBool reads it: only 1 is on. }
    FMouse.ZonesEnabled := GetIniValue('Mouse', 'ZonesEnabled', '1') = '1';
    UpdateHelp;
  except
    on E: Exception do
      ShowNote('Could not read the settings: ' + E.Message);
  end;
end;

procedure TIniEditor.LoadMouseProfile(const AFileName: string);
begin
  FMouse.LoadFile(AFileName);
end;

function TIniEditor.AnyModified: Boolean;
begin
  Result := FEdit.Modified or FMouse.Modified;
end;

function TIniEditor.SaveFile: Boolean;
begin
  Result := False;
  try
    FEdit.Lines.SaveToFile(FFileName);
    FEdit.Modified := False;
    FEdit.MarkTextAsSaved;
  except
    on E: Exception do
    begin
      ShowNote('Could not save: ' + E.Message);
      Exit;
    end;
  end;
  if FMouse.Modified and not FMouse.SaveFile then
  begin
    ShowNote('Settings saved, but not the mouse profile: see the "Mouse & keys" page.');
    Exit;
  end;
  FExitArmed := False;
  ShowNote('Saved.');
  Result := True;
end;

procedure TIniEditor.HandleMouseChange(Sender: TObject);
begin
  FExitArmed := False;
  ShowNote('Mouse & keys: changed, not saved (Save writes ' + ExtractFileName(FMouse.FileName) + ').');
end;

procedure TIniEditor.HandleZonesToggle(Sender: TObject);
begin
  if FMouse.ZonesEnabled then
    SetIniValue('Mouse', 'ZonesEnabled', '1')
  else
    SetIniValue('Mouse', 'ZonesEnabled', '0');
  FExitArmed := False;
  ShowNote('[Mouse] ZonesEnabled changed in MView.ini, not saved yet (Save).');
end;

function TIniEditor.GetIniValue(const ASection, AKey, ADefault: string): string;
var
  I, P: Integer;
  S, Section: string;
begin
  Result := ADefault;
  Section := '';
  for I := 0 to FEdit.Lines.Count - 1 do
  begin
    S := Trim(FEdit.Lines[I]);
    if (S = '') or (S[1] in [';', '#']) then
      Continue;
    if S[1] = '[' then
    begin
      Section := Trim(Copy(S, 2, Pos(']', S) - 2));
      Continue;
    end;
    P := Pos('=', S);
    if (P > 1) and SameText(Section, ASection) and SameText(Trim(Copy(S, 1, P - 1)), AKey) then
      Exit(Trim(Copy(S, P + 1, MaxInt)));
  end;
end;

{ Changes the key's line in the text, or adds it to its section (or
  the section at the end). The text is then modified, like an edit by
  hand. }
procedure TIniEditor.SetIniValue(const ASection, AKey, AValue: string);
var
  I, P, InsertAt: Integer;
  S, Section: string;
begin
  Section := '';
  InsertAt := -1;
  for I := 0 to FEdit.Lines.Count - 1 do
  begin
    S := Trim(FEdit.Lines[I]);
    if (S <> '') and (S[1] = '[') then
    begin
      Section := Trim(Copy(S, 2, Pos(']', S) - 2));
      if SameText(Section, ASection) then
        InsertAt := I + 1;
      Continue;
    end;
    if not SameText(Section, ASection) then
      Continue;
    if (S <> '') and not (S[1] in [';', '#']) then
      InsertAt := I + 1;
    P := Pos('=', S);
    if (P > 1) and SameText(Trim(Copy(S, 1, P - 1)), AKey) then
    begin
      FEdit.Lines[I] := AKey + '=' + AValue;
      FEdit.Modified := True;
      Exit;
    end;
  end;
  if InsertAt < 0 then
  begin
    FEdit.Lines.Add('');
    FEdit.Lines.Add('[' + ASection + ']');
    FEdit.Lines.Add(AKey + '=' + AValue);
  end
  else
    FEdit.Lines.Insert(InsertAt, AKey + '=' + AValue);
  FEdit.Modified := True;
end;

procedure TIniEditor.HandlePageChange(Sender: TObject);
begin
  if FPages.ActivePage = FMouseTab then
  begin
    { The switch follows the text (it may have been edited by hand). }
    FMouse.ZonesEnabled := GetIniValue('Mouse', 'ZonesEnabled', '1') = '1';
    ShowNote('Click a zone, Anywhere or Keys on the left, then choose what each button does. '
      + 'Try it in the dark area below before saving.');
  end
  else
    UpdateHelp;
end;

procedure TIniEditor.FocusEditor;
begin
  if (FPages.ActivePage = FIniPage) and FEdit.CanFocus then
    FEdit.SetFocus;
end;

procedure TIniEditor.RequestExit;
begin
  HandleExitClick(Self);
end;

procedure TIniEditor.HandleViewClick(Sender: TObject);
begin
  if AnyModified and not SaveFile then
    Exit;
  if Assigned(FOnViewImages) then
    FOnViewImages(Self);
end;

procedure TIniEditor.HandleSideBySideClick(Sender: TObject);
begin
  if Assigned(FOnSideBySide) then
    FOnSideBySide(Self);
  FocusEditor;
end;

procedure TIniEditor.HandleSaveClick(Sender: TObject);
begin
  SaveFile;
  FocusEditor;
end;

procedure TIniEditor.HandleUndoClick(Sender: TObject);
begin
  LoadFile(FFileName);
  FMouse.LoadFile(FMouse.FileName);
  ShowNote('Changes undone: the files as they are on disk.');
  FocusEditor;
end;

procedure TIniEditor.HandleExitClick(Sender: TObject);
begin
  if AnyModified and not FExitArmed then
  begin
    FExitArmed := True;
    ShowNote('There are unsaved changes. Press Exit (or Esc) again to leave without them, or Save first.');
    Exit;
  end;
  if Assigned(FOnExitRequest) then
    FOnExitRequest(Self);
end;

procedure TIniEditor.HandleEditStatus(Sender: TObject; Changes: TSynStatusChanges);
begin
  if [scCaretX, scCaretY, scModified] * Changes <> [] then
  begin
    FExitArmed := False;
    UpdateHelp;
  end;
end;

procedure TIniEditor.HandleEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_S) and (ssCtrl in Shift) then
  begin
    Key := 0;
    SaveFile;
  end
  else if (Key = VK_F5) and (Shift = []) then
  begin
    Key := 0;
    HandleViewClick(Self);
  end;
end;

{ The [Section] above ALine (0-based), without brackets. }
function TIniEditor.SectionOfLine(ALine: Integer): string;
var
  I: Integer;
  S: string;
begin
  Result := '';
  for I := ALine downto 0 do
  begin
    S := Trim(FEdit.Lines[I]);
    if (Length(S) >= 2) and (S[1] = '[') and (Pos(']', S) > 0) then
      Exit(Trim(Copy(S, 2, Pos(']', S) - 2)));
  end;
end;

function TIniEditor.HelpForLine(ALine: Integer): string;
var
  EqPos: Integer;
  S, Key, Section: string;
begin
  Result := '';
  if (ALine < 0) or (ALine >= FEdit.Lines.Count) then
    Exit;
  S := Trim(FEdit.Lines[ALine]);
  if (S = '') or (S[1] in [';', '#']) then
    Exit;
  if S[1] = '[' then
    Exit('Section ' + S);
  EqPos := Pos('=', S);
  if EqPos <= 1 then
    Exit('A setting is written as Key=Value.');
  Key := Trim(Copy(S, 1, EqPos - 1));
  Section := SectionOfLine(ALine);
  Result := ConfigKeyHelp(Section, Key);
  if Result = '' then
    Result := Key + ': not a key MView knows (in [' + Section + ']). It is kept, but not used.'
  else
    Result := Key + ':   ' + Result;
end;

procedure TIniEditor.UpdateHelp;
var
  HelpText: string;
begin
  HelpText := HelpForLine(FEdit.CaretY - 1);
  if HelpText = '' then
    HelpText := 'Lines starting with ; are comments. Point at a setting for its explanation.';
  if FEdit.Modified then
    HelpText := HelpText + '      (changed, not saved)';
  ShowNote(HelpText);
end;

{ Balloon help: the hint follows the line under the mouse. Lines are
  found from the top line and the line height (the ini editor neither
  wraps nor folds). }
procedure TIniEditor.HandleEditMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  Line: Integer;
begin
  if FEdit.LineHeight <= 0 then
    Exit;
  Line := FEdit.TopLine - 1 + Y div FEdit.LineHeight;
  if Line = FHintLine then
    Exit;
  FHintLine := Line;
  { Key on the first line of the balloon, explanation below. }
  FEdit.Hint := StringReplace(HelpForLine(Line), ':   ', ':' + LineEnding, []);
  { Hide the old balloon; the new one comes after the usual pause. }
  Application.CancelHint;
end;

procedure TIniEditor.ShowNote(const AText: string);
begin
  FHelp.Caption := AText;
end;

end.
