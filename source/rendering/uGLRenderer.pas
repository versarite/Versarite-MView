unit uGLRenderer;

{
  Unit: uGLRenderer

  Purpose
  -------
  The GPU renderer (spec §8.5, the key feature). The image is uploaded
  to the graphics card once, as textures; zoom, pan and rotation then
  only change a transformation, so they stay smooth at any image size.

  Owns
  ----
  - The OpenGL textures of the image shown (FShown) and of the one
    being uploaded (FPending), each a TGLImageTextures.
  - Small textures for the text bars (info, diagnostics, mode label,
    placeholder, zone label, gesture text) and the two panels.
  - The display filters' fragment shader (FShader), made at the first
    paint with filters set or the magnifier on; it also cuts the lens
    round and sharpens it.
  - FDeleteQueue: textures waiting to be deleted in the next paint.

  Knows
  -----
  - The TOpenGLControl it draws into (for the context); owned by the
    view (uGLMediaView).
  - The current IDecodedImage (shared, read only; each
    TGLImageTextures holds a reference that keeps its bitmap alive).

  Responsibilities
  ----------------
  - Check at creation what the GPU can do; raise EGLUnsuitable if it
    is not good enough.
  - Plan tiles, upload them in steps, draw them with the view
    transformation, draw the edit-mode selection frame and the text
    bars, swap the buffers.
  - Start again from scratch when the context is lost (ContextLost).
  - Save a picture of the window (the frame just drawn) on request.

  Does NOT
  --------
  - Decode, cache, navigate or handle input.
  - Make GL calls outside Paint (and the constructor), nor in the
    destructor: the context may already be gone.

  Threads
  -------
  UI thread only: Paint is called by the view's paint handler with the
  context current. Further upload steps are asked for by marking the
  window for repainting (InvalidateRect; the control's own Invalidate
  is ignored during its paint), not with a thread; TMView's 50 ms
  timer repaints too while IsUploading.

  Uses (MView units)
  ------------------
  interface:      uDecodedImage, uFilters, uRenderer, uImageSaver, uStopwatch
  Libraries:      Classes, Types, SysUtils, Math, GL, OpenGLContext, LCLIntf,
                  BGRABitmap, BGRABitmapTypes

  Used by
  -------
  uGLMediaView, uMainForm

  How
  ---
  Tiles: a 12000 x 9000 image is larger than a GPU accepts as one
  texture, so it is cut into tiles of up to 1024 x 1024. Each tile
  carries a 1-pixel border from its neighbours, so linear filtering
  shows no seams between tiles.
  Mipmaps (glGenerateMipmap; GL_GENERATE_MIPMAP as the fallback): zoomed-out views stay sharp and free
  of aliasing. Above 400 % pixels are shown as sharp squares (nearest),
  so single pixels can be inspected.
  Pixels go straight from the BGRABitmap memory to the GPU
  (GL_UNPACK_ROW_LENGTH, GL_UNPACK_SKIP_PIXELS, GL_UNPACK_SKIP_ROWS),
  no copy; BGRABitmap's bottom-up row order on Windows is handled in
  the texture coordinates.
  Upload in steps: a large image is uploaded a few tiles per frame
  (about 12 ms each), so the window never stalls. Meanwhile the small
  version is shown: the screen copy of a new image, or the quick view
  when the full image arrives (spec §7.1). The full image's tiles are
  drawn over it as soon as each is on the GPU, the ones in the middle
  of the view first, so the part being looked at sharpens first.
  Mipmaps are made by the GPU (glGenerateMipmap) after each tile; the
  D line shows the time per tile for pixels and mipmaps.
  Text bars (info, diagnostics, mode label, placeholder) are drawn with
  BGRABitmap into small bitmaps and shown as textures; they are only
  redrawn when their text changes. Info, diagnostics and mode label
  are text with a thin dark outline straight over the image (no box),
  in the overlay colour ([View] OverlayColor: White, Yellow or Red);
  with [View] OverlaySolid=1 info and diagnostics sit on a solid
  black bar. The placeholder message stays on black.

  Notes
  -----
  All GL calls happen in Paint, with the context current. Textures
  that are no longer needed are queued and deleted in the next paint.
  Display filters (Phase H): a GLSL 1.10 fragment shader draws the
  image tiles with the filters (uFilters, same maths as the CPU); the
  textures stay unchanged, so moving a filter costs one frame. Without
  shader functions FiltersAvailable is False.
  Needs OpenGL 2.0 or later (for mipmaps of any texture size); the
  constructor raises EGLUnsuitable otherwise, and the form falls back
  to the CPU renderer.
}

{$mode ObjFPC}{$H+}

interface

uses
  Classes,
  Types,
  SysUtils,
  Math,
  GL,
  OpenGLContext,
  LCLIntf,
  BGRABitmap,
  BGRABitmapTypes,
  uDecodedImage,
  uFilters,
  uRenderer,
  uImageSaver,
  uStopwatch;

type
  EGLUnsuitable = class(Exception);

  TGLTile = record
    Texture: GLuint;
    { Content rectangle in bitmap pixels (rows counted from the top). }
    CX0, CY0, CX1, CY1: Integer;
    { Texture coordinates of the content's corners. }
    U0, U1, VTop, VBottom: Single;
    { The texture's size (with its border): one texel, for sharpening. }
    TexW, TexH: Integer;
  end;

  { The textures of one bitmap. }
  TGLImageTextures = class(TObject)
  public
    Image: IDecodedImage;        { keeps the bitmap alive }
    Bitmap: TBGRACustomBitmap;   { what is uploaded: Bitmap or Preview }
    Tiles: array of TGLTile;
    Uploaded: Integer;           { tiles done }
    Failed: Boolean;             { e.g. out of video memory }
    UploadMs: Double;
    function Complete: Boolean;
  end;

  { glGenerateMipmap (OpenGL 3.0 / GL_EXT_framebuffer_object), loaded
    at run time. }
  TGLGenerateMipmapProc = procedure(target: GLenum); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}

  { The OpenGL 2.0 shader functions the display filters need (Phase H),
    loaded at run time like glGenerateMipmap. }
  TGLCreateShaderProc = function(AType: GLenum): GLuint; {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLShaderSourceProc = procedure(AShader: GLuint; ACount: GLsizei; AStrings: PPAnsiChar;
    ALengths: PGLint); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLObjectProc = procedure(AObject: GLuint); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLGetivProc = procedure(AObject: GLuint; AName: GLenum; AParams: PGLint); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLCreateProgramProc = function: GLuint; {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLAttachShaderProc = procedure(AProgram, AShader: GLuint); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLGetUniformLocationProc = function(AProgram: GLuint; AName: PAnsiChar): GLint; {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLUniform1fProc = procedure(ALocation: GLint; AValue: GLfloat); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}
  TGLUniform1iProc = procedure(ALocation: GLint; AValue: GLint); {$IFDEF WINDOWS}stdcall;{$ELSE}cdecl;{$ENDIF}

  TGLShaderApi = record
    CreateShader: TGLCreateShaderProc;
    ShaderSource: TGLShaderSourceProc;
    CompileShader: TGLObjectProc;
    GetShaderiv: TGLGetivProc;
    DeleteShader: TGLObjectProc;
    CreateProgram: TGLCreateProgramProc;
    AttachShader: TGLAttachShaderProc;
    LinkProgram: TGLObjectProc;
    GetProgramiv: TGLGetivProc;
    UseProgram: TGLObjectProc;
    DeleteProgram: TGLObjectProc;
    GetUniformLocation: TGLGetUniformLocationProc;
    Uniform1f: TGLUniform1fProc;
    Uniform1i: TGLUniform1iProc;
    Loaded: Boolean;             { all of them found }
  end;

  { The filter shader's uniforms. }
  TGLFilterUniforms = record
    Tex, Black, Span, Factor, Offset, Gamma, Colour, Sat, HueCos, HueSin, Invert: GLint;
    { The magnifier: cut round at (LensX, LensY) (window pixels, from
      the bottom), radius LensR; sharpened by Sharpen with one texel
      (TexelX, TexelY). }
    LensOn, LensX, LensY, LensR, Sharpen, TexelX, TexelY: GLint;
  end;

  TGLTextBar = record
    Text: string;
    Texture: GLuint;
    Width, Height: Integer;
  end;

  { TGLRenderer }

  TGLRenderer = class(TRenderer)
  private
    FControl: TOpenGLControl;
    FShown: TGLImageTextures;    { drawn now }
    FPending: TGLImageTextures;  { being uploaded; replaces FShown when done }
    FDeleteQueue: array of GLuint;
    FTileSize: Integer;
    FUseMipMaps: Boolean;
    FGLName: string;
    FGLVersion: string;
    FLastUploadMs: Double;
    FGpuNote: string;            { e.g. "full image too large for the GPU" }
    FGenerateMipmap: TGLGenerateMipmapProc;   { nil: GL_GENERATE_MIPMAP }

    { Upload measurements (D line): per tile, pixels and mipmaps. }
    FTilesDone: Integer;
    FTexMs: Double;
    FMipMs: Double;

    { Pending tiles near this bitmap point go up first (the middle of
      the view), so the part being looked at gets sharp first. }
    FFocusX, FFocusY: Double;

    FInfoBar: TGLTextBar;
    FDiagBar: TGLTextBar;
    FModeBar: TGLTextBar;
    FCenterBar: TGLTextBar;
    FZoneBar: TGLTextBar;        { mouse language: the zone's name }
    FGestureBar: TGLTextBar;     { mouse language: what the gesture does }
    FPanelBar: TGLTextBar;       { the sort panel (Phase G) }
    FPanelUploaded: Cardinal;    { PanelVersion of the texture in FPanelBar }
    FFilterPanelBar: TGLTextBar; { the filter panel (Phase H) }
    FFilterPanelUploaded: Cardinal;
    FBadgeBar: TGLTextBar;       { the mode badge ("TC") }
    FBadgeUploaded: Cardinal;
    FNoticeBar: TGLTextBar;      { a notice in the middle (Day 24) }
    FNoticeUploaded: Cardinal;

    { The display filters: one small fragment shader, made at the first
      paint that needs it. }
    FGL2: TGLShaderApi;
    FShader: GLuint;             { 0 = not made (or failed) }
    FShaderTried: Boolean;
    FShaderNote: string;         { why the filters can't be shown }
    FUniforms: TGLFilterUniforms;

    function MakeTextures(const AImage: IDecodedImage; ABitmap: TBGRACustomBitmap): TGLImageTextures;
    procedure DropTextures(var ATextures: TGLImageTextures);
    procedure DeleteQueued;
    function UploadTile(ATextures: TGLImageTextures; AIndex: Integer): Boolean;
    procedure UploadSome(ATextures: TGLImageTextures; ABudgetMs: Double);
    function NextTile(ATextures: TGLImageTextures): Integer;
    procedure UpdateFocus(ATextures: TGLImageTextures; AWidth, AHeight: Integer);
    { ALens: the magnifier's pass (Mag times around the lens' centre, cut
      round, sharpened). }
    procedure DrawTextures(ATextures: TGLImageTextures; AWidth, AHeight: Integer;
      ALens: Boolean = False);
    procedure DrawLens(AWidth, AHeight: Integer);
    { AFontName / AFontPt: a font of its own ('' / 0 = the standard; the
      info line, Day 24). }
    procedure UpdateBar(var ABar: TGLTextBar; const AText: string; ACentered: Boolean;
      const AFontName: string = ''; AFontPt: Integer = 0);
    procedure UpdatePanel(ABitmap: TBGRABitmap; AVersion: Cardinal; var ABar: TGLTextBar;
      var AUploaded: Cardinal);
    function EnsureShader: Boolean;
    procedure UseFilterShader(ALens: Boolean; AHeight: Integer);
    { ASolidWidth > 0: a solid black bar that wide behind the text
      (OverlaySolid) instead of the outline. }
    procedure DrawBar(const ABar: TGLTextBar; AX, AY: Integer; AOverlay: Boolean = False;
      ASolidWidth: Integer = 0);
    procedure SetupScreenProjection(AWidth, AHeight: Integer);
    procedure PlanForCurrentImage;
    procedure CaptureFrame(AWidth, AHeight: Integer);
  protected
    procedure ImageChanged(AKeepView: Boolean); override;
  public
    { AControl must have its handle; the context is made current here
      to check what the GPU can do. }
    constructor Create(AControl: TOpenGLControl; AUseMipMaps: Boolean); reintroduce;
    destructor Destroy; override;

    { Draws a frame. Called by the view's paint handler with the
      context current; swaps the buffers itself. }
    procedure Paint(AWidth, AHeight: Integer);

    { The view's window (and with it the OpenGL context and all its
      textures) is about to be destroyed, e.g. when switching to
      fullscreen. Forgets every texture; the next paint uploads again. }
    procedure ContextLost;

    function Description: string; override;
    function IsUploading: Boolean; override;
    function FiltersAvailable: Boolean; override;
    property GLName: string read FGLName;
  end;

implementation

uses
  Forms;   { Screen.PixelsPerInch: the info line's font size in points }

const
  { Not in FPC's GL 1.1 unit. }
  MV_GL_BGRA = $80E1;
  MV_GL_CLAMP_TO_EDGE = $812F;
  MV_GL_GENERATE_MIPMAP = $8191;
  MV_GL_FRAGMENT_SHADER = $8B30;
  MV_GL_COMPILE_STATUS = $8B81;
  MV_GL_LINK_STATUS = $8B82;

  { The display filters (uFilters, same maths and order): range,
    brightness / contrast, gamma, saturation / hue (YIQ), inversion.
    GLSL 1.10, fragment stage only (the fixed pipeline does the rest). }
  FilterShaderSource: AnsiString =
    'uniform sampler2D tex;' + LineEnding +
    'uniform float black, span, factor, offset, gamma, colour, sat, hueCos, hueSin, invert;' + LineEnding +
    'uniform float lensOn, lensX, lensY, lensR, sharpen, texelX, texelY;' + LineEnding +
    'void main() {' + LineEnding +
    '  if (lensOn > 0.5) {' + LineEnding +
    '    vec2 d = gl_FragCoord.xy - vec2(lensX, lensY);' + LineEnding +
    '    if (dot(d, d) > lensR * lensR) discard;' + LineEnding +
    '  }' + LineEnding +
    '  vec2 uv = gl_TexCoord[0].st;' + LineEnding +
    '  vec4 c = texture2D(tex, uv);' + LineEnding +
    '  if (sharpen > 0.0) {' + LineEnding +
    '    vec3 n = (texture2D(tex, uv + vec2(texelX, 0.0)).rgb + texture2D(tex, uv - vec2(texelX, 0.0)).rgb' + LineEnding +
    '      + texture2D(tex, uv + vec2(0.0, texelY)).rgb + texture2D(tex, uv - vec2(0.0, texelY)).rgb) * 0.25;' + LineEnding +
    '    c.rgb = clamp(c.rgb + sharpen * (c.rgb - n), 0.0, 1.0);' + LineEnding +
    '  }' + LineEnding +
    '  vec3 v = clamp((c.rgb - vec3(black)) / span, 0.0, 1.0);' + LineEnding +
    '  v = clamp((v - 0.5) * factor + 0.5 + offset, 0.0, 1.0);' + LineEnding +
    '  v = pow(v, vec3(gamma));' + LineEnding +
    '  if (colour > 0.5) {' + LineEnding +
    '    float y = dot(v, vec3(0.299, 0.587, 0.114));' + LineEnding +
    '    float i = dot(v, vec3(0.596, -0.274, -0.322));' + LineEnding +
    '    float q = dot(v, vec3(0.211, -0.523, 0.312));' + LineEnding +
    '    float i2 = (i * hueCos - q * hueSin) * sat;' + LineEnding +
    '    float q2 = (i * hueSin + q * hueCos) * sat;' + LineEnding +
    '    v = clamp(vec3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2,' + LineEnding +
    '      y - 1.106 * i2 + 1.703 * q2), 0.0, 1.0);' + LineEnding +
    '  }' + LineEnding +
    '  if (invert > 0.5) v = vec3(1.0) - v;' + LineEnding +
    '  gl_FragColor = vec4(v, c.a);' + LineEnding +
    '}' + LineEnding;

  { Per frame, while a large image is being uploaded. }
  UploadBudgetMs = 12.0;

  { Tile size. 1024 (4 MB) rather than 2048: finer steps, so the view
    stays responsive and the visible part sharpens sooner. }
  PreferredTileSize = 1024;

  { From this scale on, pixels are shown as squares (no smoothing). }
  NearestFromScale = 4.0;

var
  PixelOrderIsBGRA: Boolean;

{$IFDEF WINDOWS}
function MViewWglGetProcAddress(AName: PAnsiChar): Pointer; stdcall;
  external 'opengl32.dll' name 'wglGetProcAddress';
{$ENDIF}

{ An OpenGL function by name; nil if the driver hasn't got it. }
function LoadGLProc(const AName: AnsiString): Pointer;
begin
  Result := nil;
  {$IFDEF WINDOWS}
  Result := MViewWglGetProcAddress(PAnsiChar(AName));
  { Some drivers return 1, 2 or 3 instead of nil for "not there". }
  if PtrUInt(Result) <= 3 then
    Result := nil;
  {$ENDIF}
end;

{ Errors left over from earlier calls must not be taken for an upload
  failure. }
procedure ClearGLErrors;
var
  I: Integer;
begin
  for I := 1 to 16 do
    if glGetError() = GL_NO_ERROR then
      Exit;
end;

function SplitLines(const AText: string): TStringArray;
var
  P, Start, N: Integer;
begin
  Result := nil;
  Start := 1;
  for P := 1 to Length(AText) + 1 do
    if (P > Length(AText)) or (AText[P] = #10) then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := Copy(AText, Start, P - Start);
      Start := P + 1;
    end;
end;

function JoinLines(const ALines: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ALines) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + ALines[I];
  end;
end;

{ TGLImageTextures }

function TGLImageTextures.Complete: Boolean;
begin
  Result := Failed or (Uploaded >= Length(Tiles));
end;

{ TGLRenderer }

constructor TGLRenderer.Create(AControl: TOpenGLControl; AUseMipMaps: Boolean);
var
  MaxSize: GLint;
  P: PChar;
  Major: Integer;
begin
  inherited Create;
  FControl := AControl;
  FUseMipMaps := AUseMipMaps;

  if not FControl.MakeCurrent then
    raise EGLUnsuitable.Create('no OpenGL context');

  P := glGetString(GL_VERSION);
  if P <> nil then
    FGLVersion := string(P);
  P := glGetString(GL_RENDERER);
  if P <> nil then
    FGLName := string(P);

  { "4.6.0 NVIDIA 551.23" -> 4 }
  Major := StrToIntDef(Copy(FGLVersion, 1, Pos('.', FGLVersion + '.') - 1), 0);
  if Major < 2 then
    raise EGLUnsuitable.CreateFmt('OpenGL %s is too old (2.0 needed)', [FGLVersion]);
  if Pos('GDI Generic', FGLName) > 0 then
    raise EGLUnsuitable.Create('only the Windows software OpenGL is available');

  MaxSize := 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, @MaxSize);
  FTileSize := PreferredTileSize;
  if (MaxSize > 0) and (MaxSize < FTileSize) then
    FTileSize := MaxSize;
  if FTileSize < 256 then
    raise EGLUnsuitable.CreateFmt('maximum texture size %d is too small', [MaxSize]);

  { Mipmaps made by the GPU in one call after the upload. The old
    automatic GL_GENERATE_MIPMAP is only the fallback: with it, uploads
    measured about 35 MB/s on a GTX 960M (600 ms per 2048 x 2048 tile). }
  FGenerateMipmap := nil;
  {$IFDEF WINDOWS}
  Pointer(FGenerateMipmap) := MViewWglGetProcAddress('glGenerateMipmap');
  if PtrUInt(Pointer(FGenerateMipmap)) <= 3 then
    Pointer(FGenerateMipmap) := MViewWglGetProcAddress('glGenerateMipmapEXT');
  { Some drivers return 1, 2 or 3 instead of nil for "not there". }
  if PtrUInt(Pointer(FGenerateMipmap)) <= 3 then
    FGenerateMipmap := nil;
  {$ENDIF}

  { The shader functions for the display filters (OpenGL 2.0). }
  with FGL2 do
  begin
    Pointer(CreateShader) := LoadGLProc('glCreateShader');
    Pointer(ShaderSource) := LoadGLProc('glShaderSource');
    Pointer(CompileShader) := LoadGLProc('glCompileShader');
    Pointer(GetShaderiv) := LoadGLProc('glGetShaderiv');
    Pointer(DeleteShader) := LoadGLProc('glDeleteShader');
    Pointer(CreateProgram) := LoadGLProc('glCreateProgram');
    Pointer(AttachShader) := LoadGLProc('glAttachShader');
    Pointer(LinkProgram) := LoadGLProc('glLinkProgram');
    Pointer(GetProgramiv) := LoadGLProc('glGetProgramiv');
    Pointer(UseProgram) := LoadGLProc('glUseProgram');
    Pointer(DeleteProgram) := LoadGLProc('glDeleteProgram');
    Pointer(GetUniformLocation) := LoadGLProc('glGetUniformLocation');
    Pointer(Uniform1f) := LoadGLProc('glUniform1f');
    Pointer(Uniform1i) := LoadGLProc('glUniform1i');
    Loaded := Assigned(CreateShader) and Assigned(ShaderSource) and Assigned(CompileShader)
      and Assigned(GetShaderiv) and Assigned(DeleteShader) and Assigned(CreateProgram)
      and Assigned(AttachShader) and Assigned(LinkProgram) and Assigned(GetProgramiv)
      and Assigned(UseProgram) and Assigned(DeleteProgram) and Assigned(GetUniformLocation) and Assigned(Uniform1f)
      and Assigned(Uniform1i);
  end;
  if not FGL2.Loaded then
    FShaderNote := 'no shaders: filters not available';
end;

function TGLRenderer.FiltersAvailable: Boolean;
begin
  Result := FGL2.Loaded and not (FShaderTried and (FShader = 0));
end;

{ Makes the filter shader once (context current). False if it can't be
  had; the reason goes to the D line. }
function TGLRenderer.EnsureShader: Boolean;
var
  Shader, Prog: GLuint;
  Status: GLint;
  Source: PAnsiChar;
begin
  Result := FShader <> 0;
  if Result or FShaderTried or not FGL2.Loaded then
    Exit;
  FShaderTried := True;
  ClearGLErrors;
  Shader := FGL2.CreateShader(MV_GL_FRAGMENT_SHADER);
  if Shader = 0 then
  begin
    FShaderNote := 'filter shader not made';
    Exit;
  end;
  Source := PAnsiChar(FilterShaderSource);
  FGL2.ShaderSource(Shader, 1, @Source, nil);
  FGL2.CompileShader(Shader);
  Status := 0;
  FGL2.GetShaderiv(Shader, MV_GL_COMPILE_STATUS, @Status);
  if Status = 0 then
  begin
    FGL2.DeleteShader(Shader);
    FShaderNote := 'filter shader did not compile';
    Exit;
  end;
  Prog := FGL2.CreateProgram();
  if Prog = 0 then
  begin
    FGL2.DeleteShader(Shader);
    FShaderNote := 'filter shader not made';
    Exit;
  end;
  FGL2.AttachShader(Prog, Shader);
  FGL2.LinkProgram(Prog);
  { Flagged for deletion; lives on while attached to the program. }
  FGL2.DeleteShader(Shader);
  Status := 0;
  FGL2.GetProgramiv(Prog, MV_GL_LINK_STATUS, @Status);
  if Status = 0 then
  begin
    FGL2.DeleteProgram(Prog);
    FShaderNote := 'filter shader did not link';
    Exit;
  end;
  FShader := Prog;
  with FUniforms do
  begin
    Tex := FGL2.GetUniformLocation(Prog, 'tex');
    Black := FGL2.GetUniformLocation(Prog, 'black');
    Span := FGL2.GetUniformLocation(Prog, 'span');
    Factor := FGL2.GetUniformLocation(Prog, 'factor');
    Offset := FGL2.GetUniformLocation(Prog, 'offset');
    Gamma := FGL2.GetUniformLocation(Prog, 'gamma');
    Colour := FGL2.GetUniformLocation(Prog, 'colour');
    Sat := FGL2.GetUniformLocation(Prog, 'sat');
    HueCos := FGL2.GetUniformLocation(Prog, 'hueCos');
    HueSin := FGL2.GetUniformLocation(Prog, 'hueSin');
    Invert := FGL2.GetUniformLocation(Prog, 'invert');
    LensOn := FGL2.GetUniformLocation(Prog, 'lensOn');
    LensX := FGL2.GetUniformLocation(Prog, 'lensX');
    LensY := FGL2.GetUniformLocation(Prog, 'lensY');
    LensR := FGL2.GetUniformLocation(Prog, 'lensR');
    Sharpen := FGL2.GetUniformLocation(Prog, 'sharpen');
    TexelX := FGL2.GetUniformLocation(Prog, 'texelX');
    TexelY := FGL2.GetUniformLocation(Prog, 'texelY');
  end;
  FShaderNote := '';
  Result := True;
end;

{ Switches the filter shader on with the current settings. }
procedure TGLRenderer.UseFilterShader(ALens: Boolean; AHeight: Integer);
var
  F: TFilterSettings;
  ColourOn, InvertOn: Single;
begin
  F := Filters;
  FGL2.UseProgram(FShader);
  if F.Invert then
    InvertOn := 1
  else
    InvertOn := 0;
  if NeedsColourStep(F) and ((Abs(F.Saturation - 1) > 1e-6) or (Abs(F.Hue) > 1e-6)) then
    ColourOn := 1
  else
    ColourOn := 0;
  with FUniforms do
  begin
    FGL2.Uniform1i(Tex, 0);
    FGL2.Uniform1f(Black, F.Black);
    FGL2.Uniform1f(Span, Max(F.White - F.Black, 1e-5));
    FGL2.Uniform1f(Factor, ContrastFactor(F.Contrast));
    FGL2.Uniform1f(Offset, BrightnessOffset(F.Brightness));
    FGL2.Uniform1f(Gamma, F.Gamma);
    FGL2.Uniform1f(Colour, ColourOn);
    FGL2.Uniform1f(Sat, F.Saturation);
    FGL2.Uniform1f(HueCos, Cos(DegToRad(F.Hue)));
    FGL2.Uniform1f(HueSin, Sin(DegToRad(F.Hue)));
    FGL2.Uniform1f(Invert, InvertOn);
    if ALens then
    begin
      FGL2.Uniform1f(LensOn, 1);
      { gl_FragCoord: window pixels from the bottom left, centres at .5. }
      FGL2.Uniform1f(LensX, Lens.X);
      FGL2.Uniform1f(LensY, AHeight - Lens.Y);
      FGL2.Uniform1f(LensR, Lens.Radius);
      FGL2.Uniform1f(Sharpen, LensSharpenAmount(Lens.Sharpen));
    end
    else
    begin
      FGL2.Uniform1f(LensOn, 0);
      FGL2.Uniform1f(Sharpen, 0);
    end;
    FGL2.Uniform1f(TexelX, 0);
    FGL2.Uniform1f(TexelY, 0);
  end;
end;

destructor TGLRenderer.Destroy;
begin
  { No GL calls here: the context may already be gone. Its textures go
    with it. }
  FreeAndNil(FShown);
  FreeAndNil(FPending);
  inherited Destroy;
end;

function TGLRenderer.IsUploading: Boolean;
begin
  Result := (FPending <> nil) or ((FShown <> nil) and not FShown.Complete);
end;

function TGLRenderer.Description: string;
begin
  Result := 'GPU ' + FGLName;
  if FLastUploadMs > 0 then
    Result := Result + Format('   upload %d ms', [Round(FLastUploadMs)]);
  if (FShown <> nil) and (Length(FShown.Tiles) > 1) then
    Result := Result + Format('   %d tiles', [Length(FShown.Tiles)]);
  if FPending <> nil then
    Result := Result + Format('   sharpening %d / %d', [FPending.Uploaded, Length(FPending.Tiles)]);
  if FTilesDone > 0 then
    Result := Result + Format('   per tile: pixels %.1f + mipmaps %.1f ms',
      [FTexMs / FTilesDone, FMipMs / FTilesDone]);
  if not Assigned(FGenerateMipmap) then
    Result := Result + '   (old mipmaps)';
  if FGpuNote <> '' then
    Result := Result + '   (' + FGpuNote + ')';
  if (FShaderNote <> '') and not ColourNeutral(Filters) then
    Result := Result + '   (' + FShaderNote + ')';
end;

{ Plans the tiles; nothing is uploaded yet. }
function TGLRenderer.MakeTextures(const AImage: IDecodedImage;
  ABitmap: TBGRACustomBitmap): TGLImageTextures;
var
  Step, W, H, NX, NY, I, J, K: Integer;
begin
  Result := TGLImageTextures.Create;
  Result.Image := AImage;
  Result.Bitmap := ABitmap;
  W := ABitmap.Width;
  H := ABitmap.Height;

  { Content per tile; the texture adds up to 1 pixel on each side. }
  Step := FTileSize - 2;
  NX := (W + Step - 1) div Step;
  NY := (H + Step - 1) div Step;
  SetLength(Result.Tiles, NX * NY);
  K := 0;
  for J := 0 to NY - 1 do
    for I := 0 to NX - 1 do
    begin
      Result.Tiles[K].Texture := 0;
      Result.Tiles[K].CX0 := I * Step;
      Result.Tiles[K].CY0 := J * Step;
      Result.Tiles[K].CX1 := Min(W, (I + 1) * Step);
      Result.Tiles[K].CY1 := Min(H, (J + 1) * Step);
      Inc(K);
    end;
  Result.Uploaded := 0;
end;

{ Queues the textures for deletion (next paint) and frees the object. }
procedure TGLRenderer.DropTextures(var ATextures: TGLImageTextures);
var
  I, N: Integer;
begin
  if ATextures = nil then
    Exit;
  for I := 0 to High(ATextures.Tiles) do
    if ATextures.Tiles[I].Texture <> 0 then
    begin
      N := Length(FDeleteQueue);
      SetLength(FDeleteQueue, N + 1);
      FDeleteQueue[N] := ATextures.Tiles[I].Texture;
    end;
  FreeAndNil(ATextures);
end;

procedure TGLRenderer.DeleteQueued;
begin
  if Length(FDeleteQueue) > 0 then
  begin
    glDeleteTextures(Length(FDeleteQueue), @FDeleteQueue[0]);
    FDeleteQueue := nil;
  end;
end;

procedure TGLRenderer.ImageChanged(AKeepView: Boolean);
begin
  DropTextures(FPending);

  if (FImage = nil) or FImage.IsError then
  begin
    DropTextures(FShown);
    Exit;
  end;

  if AKeepView and (FShown <> nil) then
  begin
    { A better version of the image shown: keep drawing the old one
      until the new one is fully on the GPU. }
    FGpuNote := '';
    FPending := MakeTextures(FImage, FImage.Bitmap);
    Exit;
  end;

  FGpuNote := '';
  DropTextures(FShown);
  PlanForCurrentImage;
end;

{ A new image: show its screen copy at once (small, one tile), and
  upload the full bitmap in the background if there is more. }
procedure TGLRenderer.PlanForCurrentImage;
var
  Small: TBGRACustomBitmap;
begin
  if (FImage = nil) or FImage.IsError then
    Exit;
  Small := FImage.Preview;
  if Small <> nil then
  begin
    FShown := MakeTextures(FImage, Small);
    FPending := MakeTextures(FImage, FImage.Bitmap);
  end
  else
    FShown := MakeTextures(FImage, FImage.Bitmap);
end;

procedure TGLRenderer.ContextLost;

  procedure ForgetBar(var ABar: TGLTextBar);
  begin
    ABar.Text := '';
    ABar.Texture := 0;
    ABar.Width := 0;
    ABar.Height := 0;
  end;

begin
  { No GL calls: the textures die with the context. }
  FDeleteQueue := nil;
  FreeAndNil(FPending);
  FreeAndNil(FShown);
  ForgetBar(FPanelBar);
  FPanelUploaded := 0;
  ForgetBar(FFilterPanelBar);
  ForgetBar(FBadgeBar);
  FBadgeUploaded := 0;
  ForgetBar(FNoticeBar);
  FNoticeUploaded := 0;
  FFilterPanelUploaded := 0;
  { The shader went with the context: made again when needed. }
  FShader := 0;
  FShaderTried := False;
  ForgetBar(FInfoBar);
  ForgetBar(FDiagBar);
  ForgetBar(FModeBar);
  ForgetBar(FCenterBar);
  ForgetBar(FZoneBar);
  ForgetBar(FGestureBar);
  { Start again as for a new image: small version first. }
  PlanForCurrentImage;
end;

{ Uploads one tile. False if the GPU refused (e.g. out of memory). }
function TGLRenderer.UploadTile(ATextures: TGLImageTextures; AIndex: Integer): Boolean;
var
  Bmp: TBGRACustomBitmap;
  W, H, TX0, TY0, TX1, TY1, TW, TH, SkipRows: Integer;
  BottomUp: Boolean;
  Base: PBGRAPixel;
  Tex: GLuint;
  Format: GLenum;
  Err: GLenum;
  T0, T1: Double;
begin
  Result := False;
  Bmp := ATextures.Bitmap;
  W := Bmp.Width;
  H := Bmp.Height;

  with ATextures.Tiles[AIndex] do
  begin
    { The content plus a 1-pixel border where there is a neighbour. }
    TX0 := Max(0, CX0 - 1);
    TY0 := Max(0, CY0 - 1);
    TX1 := Min(W, CX1 + 1);
    TY1 := Min(H, CY1 + 1);
    TW := TX1 - TX0;
    TH := TY1 - TY0;

    { Rows in memory: bottom-up (BGRABitmap on Windows) or top-down.
      Base is the row at the lowest address. }
    if H > 1 then
      BottomUp := PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1])
    else
      BottomUp := False;
    if BottomUp then
    begin
      Base := Bmp.ScanLine[H - 1];
      SkipRows := H - TY1;       { memory row of the tile's bottom row }
    end
    else
    begin
      Base := Bmp.ScanLine[0];
      SkipRows := TY0;
    end;

    glGenTextures(1, @Tex);
    glBindTexture(GL_TEXTURE_2D, Tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    if FUseMipMaps then
    begin
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
      if not Assigned(FGenerateMipmap) then
        glTexParameteri(GL_TEXTURE_2D, MV_GL_GENERATE_MIPMAP, GL_TRUE);
    end
    else
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);

    ClearGLErrors;
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, W);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, TX0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, SkipRows);
    if PixelOrderIsBGRA then
      Format := MV_GL_BGRA
    else
      Format := GL_RGBA;
    T0 := NowMs;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TW, TH, 0, Format, GL_UNSIGNED_BYTE, Base);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    { glFinish: the GPU really is done, so the time per frame budget and
      the measurements are honest. }
    glFinish;
    T1 := NowMs;
    if FUseMipMaps and Assigned(FGenerateMipmap) then
    begin
      FGenerateMipmap(GL_TEXTURE_2D);
      glFinish;
    end;
    FTexMs := FTexMs + (T1 - T0);
    FMipMs := FMipMs + (NowMs - T1);
    Inc(FTilesDone);

    Err := glGetError();
    if Err <> GL_NO_ERROR then
    begin
      glDeleteTextures(1, @Tex);
      Exit;
    end;
    Texture := Tex;
    TexW := TW;
    TexH := TH;

    { Texture coordinates of the content edges. The first row uploaded
      is t = 0: the tile's bottom row if bottom-up, else its top row. }
    U0 := (CX0 - TX0) / TW;
    U1 := (CX1 - TX0) / TW;
    if BottomUp then
    begin
      VTop := (TY1 - CY0) / TH;
      VBottom := (TY1 - CY1) / TH;
    end
    else
    begin
      VTop := (CY0 - TY0) / TH;
      VBottom := (CY1 - TY0) / TH;
    end;
  end;
  Result := True;
end;

procedure TGLRenderer.UploadSome(ATextures: TGLImageTextures; ABudgetMs: Double);
var
  StartMs: Double;
begin
  StartMs := NowMs;
  while not ATextures.Complete do
  begin
    if not UploadTile(ATextures, NextTile(ATextures)) then
    begin
      ATextures.Failed := True;
      Break;
    end;
    Inc(ATextures.Uploaded);
    if (ABudgetMs > 0) and (NowMs - StartMs >= ABudgetMs) then
      Break;
  end;
  ATextures.UploadMs := ATextures.UploadMs + (NowMs - StartMs);
end;

{ The tile not yet uploaded that is closest to the focus point. }
function TGLRenderer.NextTile(ATextures: TGLImageTextures): Integer;
var
  I: Integer;
  D, BestD, MX, MY: Double;
begin
  Result := -1;
  BestD := 0;
  for I := 0 to High(ATextures.Tiles) do
    with ATextures.Tiles[I] do
      if Texture = 0 then
      begin
        MX := (CX0 + CX1) / 2 - FFocusX;
        MY := (CY0 + CY1) / 2 - FFocusY;
        D := MX * MX + MY * MY;
        if (Result < 0) or (D < BestD) then
        begin
          Result := I;
          BestD := D;
        end;
      end;
end;

{ The bitmap point shown in the middle of the window: the inverse of
  the transformation in DrawTextures. }
procedure TGLRenderer.UpdateFocus(ATextures: TGLImageTextures; AWidth, AHeight: Integer);
var
  LogW, LogH, BmpW, BmpH: Integer;
  Scale, SX, SY, VX, VY, Rad, C, S: Double;
begin
  BmpW := ATextures.Bitmap.Width;
  BmpH := ATextures.Bitmap.Height;
  FFocusX := BmpW / 2;
  FFocusY := BmpH / 2;
  LogicalSize(LogW, LogH);
  Scale := ScaleFor(AWidth, AHeight);
  if (Scale <= 0) or (LogW <= 0) or (LogH <= 0) then
    Exit;
  SX := Scale * LogW / BmpW;
  SY := Scale * LogH / BmpH;
  { Window centre (the magnifier's, while it is on) relative to the
    image centre on screen, turned back. }
  if Lens.Active then
  begin
    VX := Lens.X - (AWidth / 2 + FView.PanX);
    VY := Lens.Y - (AHeight / 2 + FView.PanY);
  end
  else
  begin
    VX := -FView.PanX;
    VY := -FView.PanY;
  end;
  Rad := DegToRad(-FView.Angle);
  C := Cos(Rad);
  S := Sin(Rad);
  if Filters.Mirror then
    FFocusX := BmpW / 2 - (VX * C - VY * S) / SX
  else
    FFocusX := BmpW / 2 + (VX * C - VY * S) / SX;
  FFocusY := BmpH / 2 + (VX * S + VY * C) / SY;
end;

procedure TGLRenderer.SetupScreenProjection(AWidth, AHeight: Integer);
begin
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  { Screen pixels, y pointing down. }
  glOrtho(0, AWidth, AHeight, 0, -1, 1);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
end;

procedure TGLRenderer.DrawTextures(ATextures: TGLImageTextures; AWidth, AHeight: Integer;
  ALens: Boolean);
var
  LogW, LogH, BmpW, BmpH, I: Integer;
  Scale, SX, SY, CX, CY, Mag: Double;
  MagFilter: GLint;
  Filtered: Boolean;
begin
  BmpW := ATextures.Bitmap.Width;
  BmpH := ATextures.Bitmap.Height;
  LogicalSize(LogW, LogH);
  Scale := ScaleFor(AWidth, AHeight);
  if (Scale <= 0) or (LogW <= 0) or (BmpW <= 0) then
    Exit;
  FLastScale := Scale;

  { Bitmap pixels -> screen pixels. }
  SX := Scale * LogW / BmpW;
  SY := Scale * LogH / BmpH;
  CX := AWidth / 2 + FView.PanX;
  CY := AHeight / 2 + FView.PanY;

  { A bitmap made to fit exactly (quick view, screen copy): 1:1 on
    whole pixels, so it is as sharp as on the CPU. }
  if (FView.Angle = 0) and (Abs(BmpW * SX - BmpW) < 1.0) and (Abs(BmpH * SY - BmpH) < 1.0) then
  begin
    SX := 1.0;
    SY := 1.0;
    CX := Round(CX - BmpW / 2) + BmpW / 2;
    CY := Round(CY - BmpH / 2) + BmpH / 2;
  end;

  Mag := 1;
  if ALens then
    Mag := Lens.Mag;
  if SX * Mag >= NearestFromScale then
    MagFilter := GL_NEAREST
  else
    MagFilter := GL_LINEAR;

  SetupScreenProjection(AWidth, AHeight);
  { The magnifier: everything Mag times larger around its centre. }
  if ALens then
  begin
    glTranslatef(Lens.X, Lens.Y, 0);
    glScalef(Mag, Mag, 1);
    glTranslatef(-Lens.X, -Lens.Y, 0);
  end;
  glTranslatef(CX, CY, 0);
  glRotatef(FView.Angle, 0, 0, 1);
  { Mirrored (filters, Mirror): x runs the other way, before the turn. }
  if Filters.Mirror then
    glScalef(-SX, SY, 1)
  else
    glScalef(SX, SY, 1);
  glTranslatef(-BmpW / 2, -BmpH / 2, 0);

  glEnable(GL_TEXTURE_2D);
  glColor4f(1, 1, 1, 1);
  { The display filters, in the shader (the image textures stay as
    they are: changing a filter costs nothing but this frame). }
  { The lens always (cut round, sharpened) if the shader is there. }
  Filtered := (ALens or not ColourNeutral(Filters)) and EnsureShader;
  if Filtered then
    UseFilterShader(ALens, AHeight);
  for I := 0 to High(ATextures.Tiles) do
    with ATextures.Tiles[I] do
    begin
      if Texture = 0 then
        Continue;
      if Filtered and ALens and (TexW > 0) and (TexH > 0) then
      begin
        FGL2.Uniform1f(FUniforms.TexelX, 1 / TexW);
        FGL2.Uniform1f(FUniforms.TexelY, 1 / TexH);
      end;
      glBindTexture(GL_TEXTURE_2D, Texture);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, MagFilter);
      glBegin(GL_QUADS);
      glTexCoord2f(U0, VTop);    glVertex2f(CX0, CY0);
      glTexCoord2f(U1, VTop);    glVertex2f(CX1, CY0);
      glTexCoord2f(U1, VBottom); glVertex2f(CX1, CY1);
      glTexCoord2f(U0, VBottom); glVertex2f(CX0, CY1);
      glEnd;
    end;
  if Filtered then
    FGL2.UseProgram(0);
  glDisable(GL_TEXTURE_2D);
end;

{ The magnifier: a black disc, the image again Mag times larger cut
  round (the shader; without it a square, with the scissor), and a
  rim, dark under light (amber when locked). }
procedure TGLRenderer.DrawLens(AWidth, AHeight: Integer);
const
  Segments = 96;
var
  I, Pass: Integer;
  A, R: Double;
  Round_: Boolean;
begin
  R := Lens.Radius;
  if R < 4 then
    Exit;
  Round_ := EnsureShader;
  SetupScreenProjection(AWidth, AHeight);
  glDisable(GL_TEXTURE_2D);
  glColor4f(0, 0, 0, 1);
  if Round_ then
  begin
    glBegin(GL_TRIANGLE_FAN);
    glVertex2f(Lens.X, Lens.Y);
    for I := 0 to Segments do
    begin
      A := 2 * Pi * I / Segments;
      glVertex2f(Lens.X + R * Cos(A), Lens.Y + R * Sin(A));
    end;
    glEnd;
  end
  else
  begin
    glBegin(GL_QUADS);
    glVertex2f(Lens.X - R, Lens.Y - R);
    glVertex2f(Lens.X + R, Lens.Y - R);
    glVertex2f(Lens.X + R, Lens.Y + R);
    glVertex2f(Lens.X - R, Lens.Y + R);
    glEnd;
    glEnable(GL_SCISSOR_TEST);
    glScissor(Round(Lens.X - R), Round(AHeight - Lens.Y - R), Round(2 * R), Round(2 * R));
  end;
  glColor4f(1, 1, 1, 1);

  DrawTextures(FShown, AWidth, AHeight, True);
  if FPending <> nil then
    DrawTextures(FPending, AWidth, AHeight, True);
  if not Round_ then
    glDisable(GL_SCISSOR_TEST);

  { The rim. }
  SetupScreenProjection(AWidth, AHeight);
  glDisable(GL_TEXTURE_2D);
  for Pass := 0 to 1 do
  begin
    if Pass = 0 then
    begin
      glLineWidth(3);
      glColor4f(0, 0, 0, 1);
    end
    else
    begin
      glLineWidth(1);
      if Lens.Locked then
        glColor4f(1, 0.75, 0.25, 1)
      else
        glColor4f(1, 1, 1, 1);
    end;
    if Round_ then
    begin
      glBegin(GL_LINE_LOOP);
      for I := 0 to Segments - 1 do
      begin
        A := 2 * Pi * I / Segments;
        glVertex2f(Lens.X + R * Cos(A), Lens.Y + R * Sin(A));
      end;
      glEnd;
    end
    else
    begin
      glBegin(GL_LINE_LOOP);
      glVertex2f(Lens.X - R, Lens.Y - R);
      glVertex2f(Lens.X + R, Lens.Y - R);
      glVertex2f(Lens.X + R, Lens.Y + R);
      glVertex2f(Lens.X - R, Lens.Y + R);
      glEnd;
    end;
  end;
  glLineWidth(1);
  glColor4f(1, 1, 1, 1);
end;

{ Redraws a bar's bitmap and texture if its text changed. }
procedure TGLRenderer.UpdateBar(var ABar: TGLTextBar; const AText: string; ACentered: Boolean;
  const AFontName: string; AFontPt: Integer);
var
  Bmp: TBGRABitmap;
  Lines: TStringArray;
  I, LineH, W, H, Y, TW: Integer;
  Base: PBGRAPixel;
  Format: GLenum;
  Key: string;
begin
  { The text, and the font if it has its own (a new font: a new picture). }
  Key := AText;
  if (AText <> '') and ((AFontName <> '') or (AFontPt > 0)) then
    Key := AText + #0 + AFontName + #0 + IntToStr(AFontPt);
  if (Key = ABar.Text) and ((ABar.Texture <> 0) or (AText = '')) then
    Exit;

  if ABar.Texture <> 0 then
  begin
    glDeleteTextures(1, @ABar.Texture);
    ABar.Texture := 0;
  end;
  ABar.Text := Key;
  ABar.Width := 0;
  ABar.Height := 0;
  if AText = '' then
    Exit;

  Lines := SplitLines(AText);
  Bmp := TBGRABitmap.Create(1, 1);
  try
    if ACentered then
    begin
      Bmp.FontHeight := 21;
      Bmp.FontQuality := fqSystemClearType;
    end
    else
    begin
      Bmp.FontHeight := 17;
      { Overlay text goes on a transparent background: ClearType needs
        an opaque one (coloured fringes otherwise). }
      Bmp.FontQuality := fqSystem;
    end;
    if AFontName <> '' then
      Bmp.FontName := AFontName;
    { Points at the screen's resolution, as the CPU renderer's Font.Size
      gives them. FontHeight is the full line height, about 4/3 of the
      em (the standard sizes: 17 here, 13 on the CPU). }
    if AFontPt > 0 then
      Bmp.FontHeight := Max(8, Round(AFontPt * Screen.PixelsPerInch / 72 * 4 / 3));

    W := 0;
    LineH := 0;
    for I := 0 to High(Lines) do
    begin
      W := Max(W, Bmp.TextSize(Lines[I]).cx);
      LineH := Max(LineH, Bmp.TextSize(Lines[I] + 'Xg').cy);
    end;
    W := W + 16;
    H := LineH * Length(Lines) + 8;

    Bmp.SetSize(W, H);
    if ACentered then
      Bmp.Fill(BGRA(0, 0, 0, 255))
    else
      Bmp.Fill(BGRAPixelTransparent);   { white text only; DrawBar outlines it }
    Y := 4;
    for I := 0 to High(Lines) do
    begin
      if ACentered then
      begin
        TW := Bmp.TextSize(Lines[I]).cx;
        Bmp.TextOut((W - TW) div 2, Y, Lines[I], BGRA(192, 192, 192, 255));
      end
      else
        Bmp.TextOut(8, Y, Lines[I], BGRAWhite);
      Inc(Y, LineH);
    end;

    { One texture, no mipmaps; drawn 1:1. }
    if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
      Base := Bmp.ScanLine[H - 1]
    else
      Base := Bmp.ScanLine[0];
    if PixelOrderIsBGRA then
      Format := MV_GL_BGRA
    else
      Format := GL_RGBA;

    glGenTextures(1, @ABar.Texture);
    glBindTexture(GL_TEXTURE_2D, ABar.Texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, MV_GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    ClearGLErrors;
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, Format, GL_UNSIGNED_BYTE, Base);
    if glGetError() <> GL_NO_ERROR then
    begin
      glDeleteTextures(1, @ABar.Texture);
      ABar.Texture := 0;
      Exit;
    end;

    { Remember which way up the rows went in. }
    if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
      ABar.Height := -H          { bottom-up: flip when drawing }
    else
      ABar.Height := H;
    ABar.Width := W;
  finally
    Bmp.Free;
  end;
end;

{ A panel's picture (sort panel, filter panel) as a texture, uploaded
  again only when it changed (AVersion). Drawn 1:1, no mipmaps. }
procedure TGLRenderer.UpdatePanel(ABitmap: TBGRABitmap; AVersion: Cardinal;
  var ABar: TGLTextBar; var AUploaded: Cardinal);
var
  Bmp: TBGRABitmap;
  W, H: Integer;
  Base: PBGRAPixel;
  Format: GLenum;
begin
  Bmp := ABitmap;
  if (Bmp = nil) or (Bmp.Width <= 0) or (Bmp.Height <= 0) then
    Exit;
  if (ABar.Texture <> 0) and (AUploaded = AVersion) then
    Exit;
  if ABar.Texture <> 0 then
  begin
    glDeleteTextures(1, @ABar.Texture);
    ABar.Texture := 0;
  end;
  W := Bmp.Width;
  H := Bmp.Height;
  if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
    Base := Bmp.ScanLine[H - 1]
  else
    Base := Bmp.ScanLine[0];
  if PixelOrderIsBGRA then
    Format := MV_GL_BGRA
  else
    Format := GL_RGBA;
  glGenTextures(1, @ABar.Texture);
  glBindTexture(GL_TEXTURE_2D, ABar.Texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, MV_GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, MV_GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  ClearGLErrors;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, Format, GL_UNSIGNED_BYTE, Base);
  if glGetError() <> GL_NO_ERROR then
  begin
    glDeleteTextures(1, @ABar.Texture);
    ABar.Texture := 0;
    Exit;
  end;
  if PtrUInt(Bmp.ScanLine[0]) > PtrUInt(Bmp.ScanLine[H - 1]) then
    ABar.Height := -H
  else
    ABar.Height := H;
  ABar.Width := W;
  AUploaded := AVersion;
end;

{ AX, AY: top-left corner on screen. The screen projection is set.
  AOverlay: the texture is white text on transparent; it is drawn over
  the image with a thin dark outline (the same texture tinted black,
  shifted by one pixel in 8 directions, plus a soft shadow), so it
  reads on dark and bright images alike without a box behind it. The
  text is rasterised once; the extra quads cost nothing. }
procedure TGLRenderer.DrawBar(const ABar: TGLTextBar; AX, AY: Integer; AOverlay: Boolean;
  ASolidWidth: Integer);
var
  H, DX, DY: Integer;
  VTop, VBottom: Single;

  procedure Quad(X, Y: Integer);
  begin
    glBegin(GL_QUADS);
    glTexCoord2f(0, VTop);    glVertex2f(X, Y);
    glTexCoord2f(1, VTop);    glVertex2f(X + ABar.Width, Y);
    glTexCoord2f(1, VBottom); glVertex2f(X + ABar.Width, Y + H);
    glTexCoord2f(0, VBottom); glVertex2f(X, Y + H);
    glEnd;
  end;

begin
  if ABar.Texture = 0 then
    Exit;
  H := Abs(ABar.Height);
  if ABar.Height < 0 then
  begin
    VTop := 1;
    VBottom := 0;
  end
  else
  begin
    VTop := 0;
    VBottom := 1;
  end;

  { Solid: a black bar behind the text, no outline needed. }
  if AOverlay and (ASolidWidth > 0) then
  begin
    glDisable(GL_TEXTURE_2D);
    glColor4f(0, 0, 0, 1);
    glBegin(GL_QUADS);
    glVertex2f(AX, AY);
    glVertex2f(AX + ASolidWidth, AY);
    glVertex2f(AX + ASolidWidth, AY + H);
    glVertex2f(AX, AY + H);
    glEnd;
  end;

  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, ABar.Texture);
  if AOverlay and (ASolidWidth > 0) then
  begin
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  end
  else if AOverlay then
  begin
    { Texture colour x glColor (GL_MODULATE): black with the text's
      alpha. BGRABitmap alpha is not premultiplied. }
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glColor4f(0, 0, 0, 0.45);
    Quad(AX + 2, AY + 2);
    glColor4f(0, 0, 0, 0.9);
    for DY := -1 to 1 do
      for DX := -1 to 1 do
        if (DX <> 0) or (DY <> 0) then
          Quad(AX + DX, AY + DY);
  end;
  { The text: white in the texture, tinted to the overlay colour
    (GL_MODULATE). }
  if AOverlay then
    glColor4f(OverlayRed / 255, OverlayGreen / 255, OverlayBlue / 255, 1)
  else
    glColor4f(1, 1, 1, 1);
  Quad(AX, AY);
  glColor4f(1, 1, 1, 1);
  if AOverlay then
    glDisable(GL_BLEND);
  glDisable(GL_TEXTURE_2D);
end;

procedure TGLRenderer.Paint(AWidth, AHeight: Integer);
var
  StartMs: Double;
  NewImagePainted, MoreToUpload: Boolean;
  Lines: TStringArray;
  Bottom: Integer;
  Corners: array[0..3] of TPoint;
  Pass, I, SolidWidth: Integer;
begin
  StartMs := BeginPaint(AWidth, AHeight);
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;

  glViewport(0, 0, AWidth, AHeight);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glDisable(GL_BLEND);

  DeleteQueued;

  { The small version must be complete before it is drawn (one tile,
    a few ms). The large one goes up in steps. }
  if (FShown <> nil) and not FShown.Complete then
  begin
    UploadSome(FShown, 0);
    FLastUploadMs := FShown.UploadMs;
  end;

  MoreToUpload := False;
  if FPending <> nil then
  begin
    UpdateFocus(FPending, AWidth, AHeight);
    UploadSome(FPending, UploadBudgetMs);
    if FPending.Complete then
    begin
      if FPending.Failed then
      begin
        { Keep showing the small version. }
        FGpuNote := 'full image too large for the GPU memory';
        DropTextures(FPending);
      end
      else
      begin
        FLastUploadMs := FPending.UploadMs;
        DropTextures(FShown);
        FShown := FPending;
        FPending := nil;
      end;
      DeleteQueued;
    end
    else
      MoreToUpload := True;
  end;

  if (FImage = nil) or FImage.IsError then
  begin
    PlaceholderLines(Lines);
    SetupScreenProjection(AWidth, AHeight);
    UpdateBar(FCenterBar, JoinLines(Lines), True);
    DrawBar(FCenterBar, (AWidth - FCenterBar.Width) div 2,
      (AHeight - Abs(FCenterBar.Height)) div 2);
  end
  else if FShown <> nil then
  begin
    DrawTextures(FShown, AWidth, AHeight);
    { The full image's tiles that are already on the GPU, over the
      small version: the view sharpens tile by tile. }
    if FPending <> nil then
      DrawTextures(FPending, AWidth, AHeight);
  end;
  { The magnifier, over the image (the frame below stays on top). }
  if Lens.Active and (FShown <> nil) and (FImage <> nil) and not FImage.IsError then
    DrawLens(AWidth, AHeight);

  { Edit mode: the selection as a frame, dark under light so it shows
    on any image. }
  if SelectionCorners(Corners) then
  begin
    SetupScreenProjection(AWidth, AHeight);
    glDisable(GL_TEXTURE_2D);
    for Pass := 0 to 1 do
    begin
      if Pass = 0 then
      begin
        glLineWidth(3);
        glColor4f(0, 0, 0, 1);
      end
      else
      begin
        glLineWidth(1);
        glColor4f(1, 1, 1, 1);
      end;
      glBegin(GL_LINE_LOOP);
      for I := 0 to 3 do
        glVertex2f(Corners[I].X + 0.5, Corners[I].Y + 0.5);
      glEnd;
    end;
    glLineWidth(1);
    glColor4f(1, 1, 1, 1);
  end;

  NewImagePainted := EndImagePart(StartMs);

  { Overlays, in screen pixels. Info and diagnostics on a solid bar
    across the window, if wanted. }
  if OverlaySolid then
    SolidWidth := AWidth
  else
    SolidWidth := 0;
  SetupScreenProjection(AWidth, AHeight);
  Bottom := AHeight;
  UpdateBar(FInfoBar, InfoLine, False, InfoFontName, InfoFontSize);
  if FInfoBar.Texture <> 0 then
  begin
    Dec(Bottom, Abs(FInfoBar.Height));
    { It ends before the mode badge (bottom right): cut there. }
    if BadgeRoom > 0 then
    begin
      glEnable(GL_SCISSOR_TEST);
      glScissor(0, 0, Max(0, AWidth - BadgeRoom), AHeight);
    end;
    DrawBar(FInfoBar, 0, Bottom, True, SolidWidth);
    if BadgeRoom > 0 then
      glDisable(GL_SCISSOR_TEST);
  end;
  UpdateBar(FDiagBar, DiagnosticsLine, False);
  if FDiagBar.Texture <> 0 then
  begin
    Dec(Bottom, Abs(FDiagBar.Height));
    DrawBar(FDiagBar, 0, Bottom, True, SolidWidth);
  end;
  UpdateBar(FModeBar, ModeLine, False);
  DrawBar(FModeBar, 0, 0, True);

  { Mouse language: the zone's name in its corner (top left: below the
    mode label; bottom: above the info and diagnostics lines). }
  UpdateBar(FZoneBar, ZoneLabel, False);
  if FZoneBar.Texture <> 0 then
    case ZoneCorner of
      0: DrawBar(FZoneBar, 0, Abs(FModeBar.Height), True);
      1: DrawBar(FZoneBar, AWidth - FZoneBar.Width, 0, True);
      2: DrawBar(FZoneBar, 0, Bottom - Abs(FZoneBar.Height), True);
    else
      DrawBar(FZoneBar, AWidth - FZoneBar.Width, Bottom - Abs(FZoneBar.Height), True);
    end;
  { A gesture being made: what it will do, in the middle. }
  UpdateBar(FGestureBar, GestureText, False);
  if FGestureBar.Texture <> 0 then
    DrawBar(FGestureBar, (AWidth - FGestureBar.Width) div 2,
      (AHeight - Abs(FGestureBar.Height)) div 2, True);

  { The mode badge, bottom right (blinking: drawn while BadgeOn). }
  if BadgeOn and (BadgeBitmap <> nil) then
  begin
    UpdatePanel(BadgeBitmap, BadgeVersion, FBadgeBar, FBadgeUploaded);
    if FBadgeBar.Texture <> 0 then
    begin
      glEnable(GL_BLEND);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      DrawBar(FBadgeBar, AWidth - FBadgeBar.Width - 8, AHeight - Abs(FBadgeBar.Height) - 6);
      glDisable(GL_BLEND);
    end;
  end;
  { A notice, in the middle (flashing: drawn while NoticeOn). }
  if NoticeOn and (NoticeBitmap <> nil) then
  begin
    UpdatePanel(NoticeBitmap, NoticeVersion, FNoticeBar, FNoticeUploaded);
    if FNoticeBar.Texture <> 0 then
    begin
      glEnable(GL_BLEND);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      DrawBar(FNoticeBar, (AWidth - FNoticeBar.Width) div 2,
        (AHeight - Abs(FNoticeBar.Height)) div 2);
      glDisable(GL_BLEND);
    end;
  end;
  { The sort panel, on top, with its transparency. }
  if Assigned(Panel) then
  begin
    UpdatePanel(Panel, PanelVersion, FPanelBar, FPanelUploaded);
    if FPanelBar.Texture <> 0 then
    begin
      glEnable(GL_BLEND);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      DrawBar(FPanelBar, PanelX, PanelY);
      glDisable(GL_BLEND);
    end;
  end;
  { The filter panel, at the left edge, the same way. }
  if Assigned(FilterPanel) then
  begin
    UpdatePanel(FilterPanel, FilterPanelVersion, FFilterPanelBar, FFilterPanelUploaded);
    if FFilterPanelBar.Texture <> 0 then
    begin
      glEnable(GL_BLEND);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      DrawBar(FFilterPanelBar, FilterPanelX, FilterPanelY);
      glDisable(GL_BLEND);
    end;
  end;

  { Debugging: a picture of this frame, before it is shown. }
  if FScreenshotFile <> '' then
    CaptureFrame(AWidth, AHeight);

  FControl.SwapBuffers;

  if NewImagePainted then
    ReportPainted;

  { Continue the upload in the next frame. Not FControl.Invalidate:
    TOpenGLControl ignores that while it paints (csCustomPaint), so the
    upload stopped halfway until something else asked for a paint
    (Day 22: a photo stayed half blocky, "sharpening 3 / 12"). The
    window itself is marked instead; TMView.PumpDeliveries is the
    safety net. }
  if MoreToUpload and FControl.HandleAllocated then
    InvalidateRect(FControl.Handle, nil, False);
end;

{ Reads the frame just drawn (back buffer) and saves it as PNG. GL rows
  come bottom row first. }
procedure TGLRenderer.CaptureFrame(AWidth, AHeight: Integer);
var
  Bmp: TBGRABitmap;
  Buffer: PByte;
  Y: Integer;
  Format: GLenum;
  FileName: string;
begin
  FileName := FScreenshotFile;
  FScreenshotFile := '';
  Buffer := nil;
  Bmp := TBGRABitmap.Create(AWidth, AHeight);
  try
    try
      GetMem(Buffer, PtrUInt(AWidth) * PtrUInt(AHeight) * 4);
      if PixelOrderIsBGRA then
        Format := MV_GL_BGRA
      else
        Format := GL_RGBA;
      glPixelStorei(GL_PACK_ALIGNMENT, 4);
      glReadPixels(0, 0, AWidth, AHeight, Format, GL_UNSIGNED_BYTE, Buffer);
      for Y := 0 to AHeight - 1 do
        Move((Buffer + PtrUInt(Y) * PtrUInt(AWidth) * 4)^,
          Bmp.ScanLine[AHeight - 1 - Y]^, AWidth * 4);
      Bmp.InvalidateBitmap;
      SaveBitmapAsPng(Bmp, FileName);
      FScreenshotResult := 'view saved: ' + FileName;
    except
      on E: Exception do
        FScreenshotResult := 'view not saved: ' + E.Message;
    end;
  finally
    if Buffer <> nil then
      FreeMem(Buffer);
    Bmp.Free;
  end;
end;

procedure DetectPixelOrder;
var
  P: TBGRAPixel;
  B: PByte;
begin
  P := BGRA(1, 2, 3, 4);   { red 1, green 2, blue 3, alpha 4 }
  B := PByte(@P);
  PixelOrderIsBGRA := (B[0] = 3) and (B[1] = 2) and (B[2] = 1) and (B[3] = 4);
end;

initialization
  DetectPixelOrder;

end.
