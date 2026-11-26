unit guiwin;
{ Win32 embedded channelstrip: per-era background, named knob sprite-strips at
  fixed positions, VU sprite on top. Data-driven: edit the KnobLayout table and
  the assets/<era>/ folder to change positions/art. Non-Windows: stubs. }
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
interface

type
  TGuiWin = record
    hwnd: pointer;
    gain: ^Double;
    console: ^Double;
    params: ^Single;      // pointer to the plugin param array (15 floats)
    vu: ^Double;           // pointer to the DSP VU value (0..1)
    host: pointer;        // clap_host_t*
    request_cb: procedure(host: pointer); cdecl;
    loadedConsole: Integer;
    bgBmp: pointer;
    knobBmps: array[0..13] of pointer; // per-function knob sprite strips
    knobCurve: array[0..13] of Integer; // 0=linear 1=log 2=reverse
    vuBmp: pointer;        // VU sprite strip
    vuMinDb: Double; vuMaxDb: Double; vuFrames: Integer;
    dragging: Boolean;
    dragParam: Integer;
    startY: Integer;
    startVal: Double;
{$IFDEF LINUX}
    disp: pointer;
    gc: pointer;
    stripBuf: pointer;
    bgImg: pointer;
    knobImg: array[0..13] of pointer;
    vuImg: pointer;
    rmask: UInt32; gmask: UInt32; bmask: UInt32;
    depth: LongInt;
{$ENDIF}
  end;
  PGuiWin = ^TGuiWin;

function GuiCreate(var gw: TGuiWin; width, height: LongWord): Boolean;
procedure GuiDestroy(var gw: TGuiWin);
procedure GuiSetParent(var gw: TGuiWin; parent: pointer);
procedure GuiShow(var gw: TGuiWin; showIt: Boolean);
procedure GuiPump(var gw: TGuiWin);

implementation

{$IFDEF MSWINDOWS}
uses Windows, SysUtils, hostcb, pngload, IniFiles;

const
  GWLP_USERDATA = -21;
  STRIP_W = 90;
  STRIP_H = 600;
  LABEL_Y = 80;
  LABEL_H = 24;
  NUM_KNOBS = 14;

type
  TSampleF = array[0..1048575] of Single;
  PSampleF = ^TSampleF;
  TKnobSpec = record
    name: PAnsiChar;
    param: Integer;
    x, y: Integer;   // top-left of a 64x64 knob
  end;

{ Knob layout (positions are placeholders - edit freely). param = index into the
  plugin param array (see clapplugin P_*). }
const
  KnobLayout: array[0..NUM_KNOBS-1] of TKnobSpec = (
    (name:'trim';     param:1;  x:20; y:110),
    (name:'drive';    param:2;  x:20; y:162),
    (name:'hpf';      param:3;  x:20; y:214),
    (name:'lpf';      param:4;  x:20; y:266),
    (name:'eq_lo_f';  param:5;  x:20; y:318),
    (name:'eq_lo_g';  param:6;  x:20; y:370),
    (name:'eq_mid_f'; param:7;  x:20; y:422),
    (name:'eq_mid_g'; param:8;  x:20; y:474),
    (name:'eq_hi_f';  param:9;  x:20; y:526),
    (name:'eq_hi_g';  param:10; x:20; y:578),
    (name:'lux';      param:11; x:20; y:630),
    (name:'gloss';    param:12; x:20; y:682),
    (name:'tape';     param:13; x:20; y:734),
    (name:'volume';   param:14; x:20; y:786)
  );

var
  g_classRegistered: Boolean = False;
  g_className: PAnsiChar = 'ChameleonStripGui';

function Clamp01(v: Double): Double;
begin if v<0 then Exit(0); if v>1 then Exit(1); Result:=v; end;

function EraName(i: Integer): ShortString;
begin
  case i of
    0: Result:='neve'; 1: Result:='api'; 2: Result:='ssl'; 3: Result:='isa';
    4: Result:='mackie'; 5: Result:='redd'; 6: Result:='ua'; 7: Result:='telefunken';
    8: Result:='helios'; 9: Result:='hybrid'; 10: Result:='rca'; 11: Result:='detroit';
    12: Result:='studer'; 13: Result:='polar'; 14: Result:='harrison'; 15: Result:='trident';
    16: Result:='mci';
  else Result:='neve'; end;
end;

{ Draw a horizontal sprite-strip frame (square frames) into (x,y). }
procedure DrawSprite(dc: HDC; bmp: HBITMAP; frame, frames, x, y: Integer);
var
  mem: HDC; old: HGDIOBJ; bm: BITMAP; fw: Integer;
begin
  if bmp = 0 then Exit;
  GetObject(bmp, SizeOf(BITMAP), @bm);
  if frames < 1 then frames := 1;
  fw := bm.bmWidth div frames;
  if fw <= 0 then Exit;
  if frame < 0 then frame := 0; if frame >= frames then frame := frames-1;
  mem := CreateCompatibleDC(dc);
  old := SelectObject(mem, bmp);
  BitBlt(dc, x, y, fw, bm.bmHeight, mem, frame*fw, 0, SRCCOPY);
  SelectObject(mem, old);
  DeleteDC(mem);
end;

var
  g_dllDir: ShortString = '';

function DllDir: ShortString;
var
  mbi: MEMORY_BASIC_INFORMATION;
  h: HMODULE;
  buf: array[0..MAX_PATH] of Char;
begin
  if g_dllDir <> '' then Exit(g_dllDir);
  VirtualQuery(@EraName, @mbi, SizeOf(mbi));
  h := HMODULE(mbi.AllocationBase);
  FillChar(buf, SizeOf(buf), 0);
  GetModuleFileNameA(h, buf, MAX_PATH);
  g_dllDir := ExtractFilePath(StrPas(buf));
  Result := g_dllDir;
end;

function AssetPath(name: ShortString): ShortString;
begin
  Result := DllDir + 'assets\' + name;
end;


function EraDisplay(i: Integer): ShortString;
begin
  case i of
    0: Result:='Neve 1073'; 1: Result:='API 500'; 2: Result:='SSL 4000G';
    3: Result:='Neve ISA'; 4: Result:='Mackie VLZ'; 5: Result:='EMI REDD';
    6: Result:='UA Classic'; 7: Result:='Telefunken V72'; 8: Result:='Helios 69';
    9: Result:='Hybrid'; 10: Result:='RCA SR-780'; 11: Result:='Detroit';
    12: Result:='Studer 169'; 13: Result:='Polar Nordic'; 14: Result:='Harrison 32C';
    15: Result:='Trident A-Range'; 16: Result:='MCI JH Series';
  else Result:='Neve 1073'; end;
end;

procedure ReadVuConfig(path: ShortString; var minDb, maxDb: Double; var frames: Integer);
var ini: TIniFile;
begin
  minDb := -40; maxDb := 3; frames := 101;
  if (path <> '') and FileExists(path) then
  begin
    ini := TIniFile.Create(path);
    try
      minDb := ini.ReadFloat('vu', 'min_db', -40);
      maxDb := ini.ReadFloat('vu', 'max_db', 3);
      frames := ini.ReadInteger('vu', 'frames', 101);
    finally ini.Free; end;
  end;
end;

function CurveLog(x: Double): Double;
const k = 9.0;
begin
  if x <= 0 then Exit(0);
  Result := Ln(1.0 + k * x) / Ln(1.0 + k);
end;

function ApplyCurve(x: Double; curve: Integer): Double;
begin
  case curve of
    1: Result := CurveLog(x);
    2: Result := 1.0 - x;
  else Result := x; end;
end;

procedure ReadKnobsConfig(path: ShortString; var curves: array of Integer);
var ini: TIniFile; i: Integer;
begin
  for i := 0 to 13 do curves[i] := 0;
  if (path <> '') and FileExists(path) then
  begin
    ini := TIniFile.Create(path);
    try
      for i := 0 to 13 do
      begin
        if SameText(ini.ReadString('knob'+IntToStr(i),'curve','linear'),'log') then curves[i]:=1
        else if SameText(ini.ReadString('knob'+IntToStr(i),'curve','linear'),'reverse') then curves[i]:=2;
      end;
    finally ini.Free; end;
  end;
end;

procedure PaintClient(hwnd: HWND; gw: PGuiWin);
var
  ps: PAINTSTRUCT;
  dc, mem: HDC;
  old: HGDIOBJ;
  bm: BITMAP;
  era, i, frames, knobFrame, vuFrame: Integer;
  path: ShortString;
  s: ShortString;
  cx, cy: Integer;
begin
  { lazy-load artwork: knob + vu once, background per console era }
  if gw^.console <> nil then
  begin
    era := Round(gw^.console^);
    if era < 0 then era := 0;
    if era > 16 then era := 16;
    if era <> gw^.loadedConsole then
    begin
      gw^.loadedConsole := era;
      if gw^.bgBmp <> nil then DeleteObject(HBITMAP(gw^.bgBmp));
      if gw^.vuBmp <> nil then DeleteObject(HBITMAP(gw^.vuBmp));
      for i := 0 to NUM_KNOBS-1 do
        if gw^.knobBmps[i] <> nil then DeleteObject(HBITMAP(gw^.knobBmps[i]));
      path := AssetPath(EraName(era) + '\background.png');
      gw^.bgBmp := pointer(LoadPngToHBitmap(PAnsiChar(@path[1])));
      path := AssetPath(EraName(era) + '\vu.png');
      gw^.vuBmp := pointer(LoadPngToHBitmap(PAnsiChar(@path[1])));
      for i := 0 to NUM_KNOBS-1 do
      begin
        path := AssetPath(EraName(era) + '\knobs\' + KnobLayout[i].name + '.png');
        gw^.knobBmps[i] := pointer(LoadPngToHBitmap(PAnsiChar(@path[1])));
      end;
    end;
  end;

  dc := BeginPaint(hwnd, @ps);
  try
    if gw^.bgBmp <> nil then
    begin
      mem := CreateCompatibleDC(dc); old := SelectObject(mem, HBITMAP(gw^.bgBmp));
      BitBlt(dc, 0, 0, STRIP_W, STRIP_H, mem, 0, 0, SRCCOPY);
      SelectObject(mem, old); DeleteDC(mem);
    end
    else
    begin
      { no background loaded yet - nothing to paint }
    end;

    { knobs }
    for i := 0 to NUM_KNOBS-1 do
    begin
      if gw^.knobBmps[i] = nil then Continue;
      GetObject(HBITMAP(gw^.knobBmps[i]), SizeOf(BITMAP), @bm);
      frames := bm.bmWidth div bm.bmHeight; if frames < 1 then frames := 1;
      if gw^.params <> nil then
        knobFrame := Round(ApplyCurve(Clamp01(PSampleF(gw^.params)[KnobLayout[i].param]), gw^.knobCurve[i]) * (frames-1))
      else knobFrame := 0;
      DrawSprite(dc, HBITMAP(gw^.knobBmps[i]), knobFrame, frames,
        KnobLayout[i].x, KnobLayout[i].y);
    end;

    { VU on top }
    if gw^.vuBmp <> nil then
    begin
      GetObject(HBITMAP(gw^.vuBmp), SizeOf(BITMAP), @bm);
      frames := bm.bmWidth div bm.bmHeight; if frames < 1 then frames := 1;
      if gw^.vu <> nil then vuFrame := Round(Clamp01(gw^.vu^) * (frames-1)) else vuFrame := 0;
      DrawSprite(dc, HBITMAP(gw^.vuBmp), vuFrame, frames, 0, 8);
    end;

    if gw^.console <> nil then
    begin
      s := EraDisplay(Round(gw^.console^));
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, RGB(230, 230, 230));
      TextOut(dc, 8, LABEL_Y, PAnsiChar(@s[1]), Length(s));
    end;
  finally
    EndPaint(hwnd, @ps);
  end;
end;

function MainWndProc(hwnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  gw: PGuiWin; lp, x, y, i, era: Integer; ng: Double;
begin
  gw := PGuiWin(GetWindowLongPtrA(hwnd, GWLP_USERDATA));
  case msg of
    WM_PAINT: begin if gw<>nil then PaintClient(hwnd, gw); Result:=0; end;
    WM_LBUTTONDOWN:
      begin
        if gw<>nil then
        begin
          lp:=Integer(lParam); x:=SmallInt(lp and $FFFF); y:=SmallInt((lp shr 16) and $FFFF);
          gw^.dragging:=False;
          for i:=0 to NUM_KNOBS-1 do
            if (x>=KnobLayout[i].x) and (x<=KnobLayout[i].x+64) and (y>=KnobLayout[i].y) and (y<=KnobLayout[i].y+64) then
            begin
              gw^.dragging:=True; gw^.dragParam:=KnobLayout[i].param; gw^.startY:=y;
              if gw^.params<>nil then gw^.startVal:=PSampleF(gw^.params)[gw^.dragParam];
              Break;
            end;
          if (not gw^.dragging) and (gw^.console<>nil) and (y>=LABEL_Y) and (y<=LABEL_Y+LABEL_H) then
          begin
            era := (Round(gw^.console^) + 1) mod 17;
            gw^.console^ := era;
            gw^.loadedConsole := -1;
            RequestCallbackHost(gw^.host);
            InvalidateRect(hwnd, nil, True);
          end;
        end;
        Result:=0;
      end;
    WM_MOUSEMOVE:
      begin
        if (gw<>nil) and gw^.dragging and (gw^.params<>nil) then
        begin
          lp:=Integer(lParam); y:=SmallInt((lp shr 16) and $FFFF);
          ng:=Clamp01(gw^.startVal + (gw^.startY - y)/200.0);
          PSampleF(gw^.params)[gw^.dragParam] := ng;
          if gw^.gain<>nil then gw^.gain^ := ng; { keep gain mirror in sync for the host }
          InvalidateRect(hwnd, nil, True);
        end;
        Result:=0;
      end;
    WM_LBUTTONUP: begin if gw<>nil then gw^.dragging:=False; Result:=0; end;
  else Result := DefWindowProcA(hwnd, msg, wParam, lParam); end;
end;

function GuiCreate(var gw: TGuiWin; width, height: LongWord): Boolean;
var wc: WNDCLASSEX; inst: HINST; title: ShortString;
begin
  Result:=False; inst:=GetModuleHandle(nil);
  if not g_classRegistered then
  begin
    FillChar(wc,SizeOf(wc),0); wc.cbSize:=SizeOf(wc); wc.style:=CS_HREDRAW or CS_VREDRAW;
    wc.lpfnWndProc:=@MainWndProc; wc.hInstance:=inst; wc.hCursor:=LoadCursorA(0,IDC_ARROW);
    wc.lpszClassName:=g_className;
    if RegisterClassExA(wc)=0 then if GetLastError<>ERROR_CLASS_ALREADY_EXISTS then Exit;
    g_classRegistered:=True;
  end;
  title:='Chameleon Strip';
  gw.hwnd := pointer(CreateWindowExA(0, g_className, PAnsiChar(@title[1]),
    WS_CHILD or WS_CLIPSIBLINGS, 0,0,Integer(width),Integer(height), 0,0, inst, nil));
  if gw.hwnd=nil then Exit;
  SetWindowLongPtrA(HWND(gw.hwnd), GWLP_USERDATA, LONG_PTR(@gw));
  Result:=True;
end;

procedure GuiDestroy(var gw: TGuiWin);
var i: Integer;
begin
  if gw.hwnd<>nil then begin DestroyWindow(HWND(gw.hwnd)); gw.hwnd:=nil; end;
  if gw.bgBmp<>nil then begin DeleteObject(HBITMAP(gw.bgBmp)); gw.bgBmp:=nil; end;
  for i:=0 to NUM_KNOBS-1 do if gw.knobBmps[i]<>nil then begin DeleteObject(HBITMAP(gw.knobBmps[i])); gw.knobBmps[i]:=nil; end;
  if gw.vuBmp<>nil then begin DeleteObject(HBITMAP(gw.vuBmp)); gw.vuBmp:=nil; end;
end;

procedure GuiSetParent(var gw: TGuiWin; parent: pointer);
begin if (gw.hwnd<>nil) and (parent<>nil) then SetParent(HWND(gw.hwnd), HWND(parent)); end;

procedure GuiShow(var gw: TGuiWin; showIt: Boolean);
begin if gw.hwnd<>nil then begin if showIt then ShowWindow(HWND(gw.hwnd),SW_SHOW) else ShowWindow(HWND(gw.hwnd),SW_HIDE); end; end;

procedure GuiPump(var gw: TGuiWin);
begin if gw.hwnd<>nil then InvalidateRect(HWND(gw.hwnd), nil, True); end;

{$ELSE}
{$IFDEF LINUX}
{ X11 embedded channelstrip (Linux). PNG sprite strips (background, 14 knobs,
  VU) with software alpha blending, era label click, ini-tunable curves.
  GuiPump must be called from on_main_thread to process X events. }
uses xlib, x, sysutils, hostcb, fpimage, fpreadpng, classes, IniFiles;

const
  STRIP_W = 90;
  STRIP_H = 852;
  LABEL_Y = 80;
  LABEL_H = 24;
  NUM_KNOBS = 14;

type
  TSampleF = array[0..1048575] of Single;
  PSampleF = ^TSampleF;
  TUInt32Arr = array[0..16777215] of UInt32;
  PUInt32 = ^TUInt32Arr;
  TDecoded = record
    w, h: Integer;
    data: PUInt32;   { UInt32 array, 0xAARRGGBB }
  end;
  PDecoded = ^TDecoded;
  TStripBuf = array[0..STRIP_W*STRIP_H-1] of UInt32;
  PStripBuf = ^TStripBuf;
  TKnobSpec = record
    name: PAnsiChar;
    param: Integer;
    x, y: Integer;
  end;

const
  KnobLayout: array[0..NUM_KNOBS-1] of TKnobSpec = (
    (name:'trim';     param:1;  x:20; y:110),
    (name:'drive';    param:2;  x:20; y:162),
    (name:'hpf';      param:3;  x:20; y:214),
    (name:'lpf';      param:4;  x:20; y:266),
    (name:'eq_lo_f';  param:5;  x:20; y:318),
    (name:'eq_lo_g';  param:6;  x:20; y:370),
    (name:'eq_mid_f'; param:7;  x:20; y:422),
    (name:'eq_mid_g'; param:8;  x:20; y:474),
    (name:'eq_hi_f';  param:9;  x:20; y:526),
    (name:'eq_hi_g';  param:10; x:20; y:578),
    (name:'lux';      param:11; x:20; y:630),
    (name:'gloss';    param:12; x:20; y:682),
    (name:'tape';     param:13; x:20; y:734),
    (name:'volume';   param:14; x:20; y:786)
  );

var
  g_dllDir: ShortString = '';

function Clamp01(v: Double): Double;
begin if v<0 then Exit(0); if v>1 then Exit(1); Result:=v; end;

function EraName(i: Integer): ShortString;
begin
  case i of
    0: Result:='neve'; 1: Result:='api'; 2: Result:='ssl'; 3: Result:='isa';
    4: Result:='mackie'; 5: Result:='redd'; 6: Result:='ua'; 7: Result:='telefunken';
    8: Result:='helios'; 9: Result:='hybrid'; 10: Result:='rca'; 11: Result:='detroit';
    12: Result:='studer'; 13: Result:='polar'; 14: Result:='harrison'; 15: Result:='trident';
    16: Result:='mci';
  else Result:='neve'; end;
end;

function EraDisplay(i: Integer): ShortString;
begin
  case i of
    0: Result:='Neve 1073'; 1: Result:='API 500'; 2: Result:='SSL 4000G';
    3: Result:='Neve ISA'; 4: Result:='Mackie VLZ'; 5: Result:='EMI REDD';
    6: Result:='UA Classic'; 7: Result:='Telefunken V72'; 8: Result:='Helios 69';
    9: Result:='Hybrid'; 10: Result:='RCA SR-780'; 11: Result:='Detroit';
    12: Result:='Studer 169'; 13: Result:='Polar Nordic'; 14: Result:='Harrison 32C';
    15: Result:='Trident A-Range'; 16: Result:='MCI JH Series';
  else Result:='Neve 1073'; end;
end;

{ Locate the directory of the loaded plugin by scanning /proc/self/maps. }
function DllDir: ShortString;
var f: TextFile; line: ShortString; p: Integer;
begin
  if g_dllDir<>'' then Exit(g_dllDir);
  g_dllDir:='';
  AssignFile(f, '/proc/self/maps');
  Reset(f);
  try
    while not Eof(f) do
    begin
      ReadLn(f, line);
      if Pos('clap_skeleton', line)>0 then
      begin
        p := Pos('/', line);
        if p>0 then
        begin
          g_dllDir := ExtractFilePath(Copy(line, p, Length(line)));
          Break;
        end;
      end;
    end;
  finally CloseFile(f); end;
  Result := g_dllDir;
end;

function AssetPath(name: ShortString): ShortString;
begin
  Result := DllDir + 'Assets/' + name;
  if not FileExists(Result) then
    Result := DllDir + 'assets/' + name;
end;

procedure ReadVuConfig(path: ShortString; var minDb, maxDb: Double; var frames: Integer);
var ini: TIniFile;
begin
  minDb := -40; maxDb := 3; frames := 101;
  if (path <> '') and FileExists(path) then
  begin
    ini := TIniFile.Create(path);
    try
      minDb := ini.ReadFloat('vu', 'min_db', -40);
      maxDb := ini.ReadFloat('vu', 'max_db', 3);
      frames := ini.ReadInteger('vu', 'frames', 101);
    finally ini.Free; end;
  end;
end;

function CurveLog(x: Double): Double;
const k = 9.0;
begin
  if x <= 0 then Exit(0);
  Result := Ln(1.0 + k * x) / Ln(1.0 + k);
end;

function ApplyCurve(x: Double; curve: Integer): Double;
begin
  case curve of
    1: Result := CurveLog(x);
    2: Result := 1.0 - x;
  else Result := x; end;
end;

procedure ReadKnobsConfig(path: ShortString; var curves: array of Integer);
var ini: TIniFile; i: Integer;
begin
  for i := 0 to 13 do curves[i] := 0;
  if (path <> '') and FileExists(path) then
  begin
    ini := TIniFile.Create(path);
    try
      for i := 0 to 13 do
      begin
        if SameText(ini.ReadString('knob'+IntToStr(i),'curve','linear'),'log') then curves[i]:=1
        else if SameText(ini.ReadString('knob'+IntToStr(i),'curve','linear'),'reverse') then curves[i]:=2;
      end;
    finally ini.Free; end;
  end;
end;

function DecodePng(const path: ShortString): TDecoded;
var fs: TFileStream; rdr: TFPReaderPNG; img: TFPMemoryImage;
    x, y, w, h: Integer; c: TFPColor;
begin
  Result.w:=0; Result.h:=0; Result.data:=nil;
  if (path='') or (not FileExists(path)) then Exit;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    rdr := TFPReaderPNG.Create;
    try
      img := TFPMemoryImage.Create(0,0);
      try
        rdr.ImageRead(fs, img);
        w:=img.Width; h:=img.Height;
        if (w<=0) or (h<=0) then Exit;
        GetMem(Result.data, w*h*4);
        for y:=0 to h-1 do
          for x:=0 to w-1 do
          begin
            c := img.Colors[x,y];
            Result.data[y*w+x] := (UInt32(c.alpha shr 8) shl 24) or (UInt32(c.red shr 8) shl 16)
                  or (UInt32(c.green shr 8) shl 8) or UInt32(c.blue shr 8);
          end;
        Result.w:=w; Result.h:=h;
      finally img.Free; end;
    finally rdr.Free; end;
  finally fs.Free; end;
end;

procedure FreeDecoded(var d: TDecoded);
begin
  if d.data<>nil then begin FreeMem(d.data); d.data:=nil; end;
  d.w:=0; d.h:=0;
end;

procedure ComputeMask(m: UInt32; out shift, bits: Integer);
begin
  shift:=0; bits:=0;
  if m=0 then Exit;
  while (m and 1)=0 do begin m:=m shr 1; Inc(shift); end;
  while (m and 1)=1 do begin Inc(bits); m:=m shr 1; end;
end;

function PackPixel(gw: PGuiWin; r, g, b: Byte): UInt32;
var rs, gs, bs, rb, gb, bb: Integer;
begin
  ComputeMask(gw^.rmask, rs, rb);
  ComputeMask(gw^.gmask, gs, gb);
  ComputeMask(gw^.bmask, bs, bb);
  Result := 0;
  if rb>0 then Result := Result or UInt32(((UInt32(r)*((1 shl rb)-1)+127) div 255) shl rs);
  if gb>0 then Result := Result or UInt32(((UInt32(g)*((1 shl gb)-1)+127) div 255) shl gs);
  if bb>0 then Result := Result or UInt32(((UInt32(b)*((1 shl bb)-1)+127) div 255) shl bs);
end;

procedure UnpackPixel(gw: PGuiWin; p: UInt32; out r, g, b: Byte);
var rs, gs, bs, rb, gb, bb: Integer;
begin
  ComputeMask(gw^.rmask, rs, rb);
  ComputeMask(gw^.gmask, gs, gb);
  ComputeMask(gw^.bmask, bs, bb);
  if rb=0 then r:=0 else r:=Byte((((p and gw^.rmask) shr rs)*255 + ((1 shl rb)-1) div 2) div ((1 shl rb)-1));
  if gb=0 then g:=0 else g:=Byte((((p and gw^.gmask) shr gs)*255 + ((1 shl gb)-1) div 2) div ((1 shl gb)-1));
  if bb=0 then b:=0 else b:=Byte((((p and gw^.bmask) shr bs)*255 + ((1 shl bb)-1) div 2) div ((1 shl bb)-1));
end;

procedure BlendPixel(gw: PGuiWin; x, y: Integer; src: UInt32);
var idx: Integer; dst: UInt32; sr, sg, sb, sa, dr, dg, db: Byte;
begin
  if (x<0) or (y<0) or (x>=STRIP_W) or (y>=STRIP_H) then Exit;
  sa := Byte(src shr 24);
  if sa=0 then Exit;
  idx := y*STRIP_W + x;
  if sa=255 then
  begin
    PStripBuf(gw^.stripBuf)^[idx] := PackPixel(gw, Byte(src shr 16), Byte(src shr 8), Byte(src));
    Exit;
  end;
  sr:=Byte(src shr 16); sg:=Byte(src shr 8); sb:=Byte(src);
  dst := PStripBuf(gw^.stripBuf)^[idx];
  UnpackPixel(gw, dst, dr, dg, db);
  PStripBuf(gw^.stripBuf)^[idx] := PackPixel(gw,
    Byte((sr*sa + dr*(255-sa)) div 255),
    Byte((sg*sa + dg*(255-sa)) div 255),
    Byte((sb*sa + db*(255-sa)) div 255));
end;

procedure LoadEra(gw: PGuiWin; era: Integer);
var i: Integer; d: PDecoded;
begin
  gw^.loadedConsole := era;
  if gw^.bgImg<>nil then begin FreeDecoded(PDecoded(gw^.bgImg)^); Dispose(PDecoded(gw^.bgImg)); gw^.bgImg:=nil; end;
  if gw^.vuImg<>nil then begin FreeDecoded(PDecoded(gw^.vuImg)^); Dispose(PDecoded(gw^.vuImg)); gw^.vuImg:=nil; end;
  for i:=0 to NUM_KNOBS-1 do
    if gw^.knobImg[i]<>nil then
    begin FreeDecoded(PDecoded(gw^.knobImg[i])^); Dispose(PDecoded(gw^.knobImg[i])); gw^.knobImg[i]:=nil; end;
  New(d); d^ := DecodePng(AssetPath(EraName(era)+'/background.png')); gw^.bgImg:=d;
  New(d); d^ := DecodePng(AssetPath(EraName(era)+'/vu.png')); gw^.vuImg:=d;
  for i:=0 to NUM_KNOBS-1 do
  begin
    New(d); d^ := DecodePng(AssetPath(EraName(era)+'/knobs/'+KnobLayout[i].name+'.png'));
    gw^.knobImg[i]:=d;
  end;
  ReadVuConfig(AssetPath(EraName(era)+'/vu.ini'), gw^.vuMinDb, gw^.vuMaxDb, gw^.vuFrames);
  ReadKnobsConfig(AssetPath(EraName(era)+'/knobs.ini'), gw^.knobCurve);
end;

procedure Redraw(gw: PGuiWin);
var dpy: PDisplay; w: TWindow; g: TGC; img: PXImage;
    era, i, frames, knobFrame, vuFrame, fw, fh, sx, x, y: Integer;
    bgd, kd, vd: TDecoded;
    s: ShortString; font: PXFontStruct;
begin
  if (gw=nil) or (gw^.disp=nil) then Exit;
  dpy:=PDisplay(gw^.disp); w:=TWindow(UInt64(gw^.hwnd)); g:=TGC(gw^.gc);
  if gw^.console<>nil then
  begin
    era:=Round(gw^.console^);
    if era<0 then era:=0; if era>16 then era:=16;
    if era<>gw^.loadedConsole then LoadEra(gw, era);
  end;

  FillChar(PStripBuf(gw^.stripBuf)^, STRIP_W*STRIP_H*4, 0);

  { background }
  if gw^.bgImg<>nil then
  begin
    bgd := PDecoded(gw^.bgImg)^;
    if (bgd.w>0) and (bgd.h>0) then
      for y:=0 to bgd.h-1 do
        for x:=0 to bgd.w-1 do
          if (x<STRIP_W) and (y<STRIP_H) then
          begin
            PStripBuf(gw^.stripBuf)^[y*STRIP_W+x] :=
              PackPixel(gw, Byte(bgd.data[y*bgd.w+x] shr 16),
                            Byte(bgd.data[y*bgd.w+x] shr 8),
                            Byte(bgd.data[y*bgd.w+x]));
          end;
  end;

  { knobs }
  for i:=0 to NUM_KNOBS-1 do
  begin
    if gw^.knobImg[i]=nil then Continue;
    kd := PDecoded(gw^.knobImg[i])^;
    if kd.h<=0 then Continue;
    frames := kd.w div kd.h; if frames<1 then frames:=1;
    if gw^.params<>nil then
      knobFrame := Round(ApplyCurve(Clamp01(PSampleF(gw^.params)[KnobLayout[i].param]), gw^.knobCurve[i])*(frames-1))
    else knobFrame:=0;
    if knobFrame<0 then knobFrame:=0; if knobFrame>=frames then knobFrame:=frames-1;
    fw := kd.w div frames; fh := kd.h; sx := knobFrame*fw;
    for y:=0 to fh-1 do
      for x:=0 to fw-1 do
        BlendPixel(gw, KnobLayout[i].x + x, KnobLayout[i].y + y,
          kd.data[y*kd.w + sx + x]);
  end;

  { VU on top }
  if gw^.vuImg<>nil then
  begin
    vd := PDecoded(gw^.vuImg)^;
    if vd.h>0 then
    begin
      frames := vd.w div vd.h; if frames<1 then frames:=1;
      if gw^.vu<>nil then vuFrame := Round(Clamp01(gw^.vu^)*(frames-1)) else vuFrame:=0;
      if vuFrame<0 then vuFrame:=0; if vuFrame>=frames then vuFrame:=frames-1;
      fw:=vd.w div frames; fh:=vd.h; sx:=vuFrame*fw;
      for y:=0 to fh-1 do
        for x:=0 to fw-1 do
          BlendPixel(gw, x, 8+y, vd.data[y*vd.w + sx + x]);
    end;
  end;

  { blit strip to the window }
  img := XCreateImage(dpy, XDefaultVisual(dpy,0), gw^.depth, ZPixmap, 0,
                      gw^.stripBuf, STRIP_W, STRIP_H, 32, STRIP_W*4);
  if img<>nil then
  begin
    XPutImage(dpy, w, g, img, 0, 0, 0, 0, STRIP_W, STRIP_H);
    XFree(img);
  end;

  { era label }
  if gw^.console<>nil then
  begin
    s := EraDisplay(Round(gw^.console^));
    XSetForeground(dpy, g, PackPixel(gw, 230, 230, 230));
    font := XLoadQueryFont(dpy, PAnsiChar('fixed'));
    if font<>nil then XSetFont(dpy, g, font^.fid);
    XDrawString(dpy, w, g, 8, LABEL_Y+16, PAnsiChar(@s[1]), Length(s));
  end;
  XFlush(dpy);
end;

function GuiCreate(var gw: TGuiWin; width, height: LongWord): Boolean;
var dpy: PDisplay; vis: PVisual; i: Integer;
begin
  Result:=False;
  dpy:=XOpenDisplay(nil);
  if dpy=nil then Exit;
  gw.disp:=dpy;
  vis := XDefaultVisual(dpy, 0);
  gw.rmask := vis^.red_mask; gw.gmask := vis^.green_mask; gw.bmask := vis^.blue_mask;
  gw.depth := XDefaultDepth(dpy, 0);
  gw.hwnd := pointer(UInt64(XCreateSimpleWindow(dpy, XDefaultRootWindow(dpy), 0, 0, width, height, 0, 0, 0)));
  gw.gc := pointer(UInt64(XCreateGC(dpy, TWindow(UInt64(gw.hwnd)), 0, nil)));
  XSelectInput(dpy, TWindow(UInt64(gw.hwnd)),
    ExposureMask or ButtonPressMask or ButtonReleaseMask or PointerMotionMask);
  GetMem(gw.stripBuf, STRIP_W*STRIP_H*4);
  FillChar(PStripBuf(gw.stripBuf)^, STRIP_W*STRIP_H*4, 0);
  gw.loadedConsole := -1;
  gw.bgImg:=nil; gw.vuImg:=nil;
  for i:=0 to NUM_KNOBS-1 do gw.knobImg[i]:=nil;
  Result:=True;
end;

procedure GuiDestroy(var gw: TGuiWin);
var i: Integer;
begin
  if gw.disp<>nil then
  begin
    if gw.hwnd<>nil then XDestroyWindow(PDisplay(gw.disp), TWindow(UInt64(gw.hwnd)));
    if gw.gc<>nil then XFreeGC(PDisplay(gw.disp), TGC(UInt64(gw.gc)));
    XCloseDisplay(PDisplay(gw.disp));
    gw.disp:=nil; gw.hwnd:=nil; gw.gc:=nil;
  end;
  if gw.stripBuf<>nil then begin FreeMem(gw.stripBuf); gw.stripBuf:=nil; end;
  if gw.bgImg<>nil then begin FreeDecoded(PDecoded(gw.bgImg)^); Dispose(PDecoded(gw.bgImg)); gw.bgImg:=nil; end;
  if gw.vuImg<>nil then begin FreeDecoded(PDecoded(gw.vuImg)^); Dispose(PDecoded(gw.vuImg)); gw.vuImg:=nil; end;
  for i:=0 to NUM_KNOBS-1 do
    if gw.knobImg[i]<>nil then
    begin FreeDecoded(PDecoded(gw.knobImg[i])^); Dispose(PDecoded(gw.knobImg[i])); gw.knobImg[i]:=nil; end;
end;

procedure GuiSetParent(var gw: TGuiWin; parent: pointer);
begin
  if (gw.disp<>nil) and (parent<>nil) then
    XReparentWindow(PDisplay(gw.disp), TWindow(UInt64(gw.hwnd)), TWindow(UInt64(parent)), 0, 0);
end;

procedure GuiShow(var gw: TGuiWin; showIt: Boolean);
begin
  if gw.disp<>nil then
  begin
    if showIt then XMapWindow(PDisplay(gw.disp), TWindow(UInt64(gw.hwnd)))
    else XUnmapWindow(PDisplay(gw.disp), TWindow(UInt64(gw.hwnd)));
    XFlush(PDisplay(gw.disp));
  end;
end;

procedure GuiPump(var gw: TGuiWin);
var ev: TXEvent; dpy: PDisplay; x, y, i, era: Integer; ng: Double;
begin
  if gw.disp=nil then Exit;
  dpy:=PDisplay(gw.disp);
  while XPending(dpy)>0 do
  begin
    XNextEvent(dpy, @ev);
    case ev._type of
      Expose: Redraw(@gw);
      ButtonPress:
        begin
          x:=ev.xbutton.x; y:=ev.xbutton.y;
          gw.dragging:=False;
          for i:=0 to NUM_KNOBS-1 do
            if (x>=KnobLayout[i].x) and (x<=KnobLayout[i].x+50) and
               (y>=KnobLayout[i].y) and (y<=KnobLayout[i].y+50) then
            begin
              gw.dragging:=True; gw.dragParam:=KnobLayout[i].param; gw.startY:=y;
              if gw.params<>nil then gw.startVal:=PSampleF(gw.params)[gw.dragParam];
              Break;
            end;
          if (not gw.dragging) and (gw.console<>nil) and (y>=LABEL_Y) and (y<=LABEL_Y+LABEL_H) then
          begin
            era := (Round(gw.console^)+1) mod 17;
            gw.console^ := era;
            gw.loadedConsole := -1;
            RequestCallbackHost(gw.host);
            Redraw(@gw);
          end;
        end;
      ButtonRelease: gw.dragging:=False;
      MotionNotify:
        if gw.dragging and (gw.params<>nil) then
        begin
          y:=ev.xmotion.y;
          ng:=Clamp01(gw.startVal + (gw.startY - y)/200.0);
          PSampleF(gw.params)[gw.dragParam] := ng;
          if gw.gain<>nil then gw.gain^ := ng;
          Redraw(@gw);
        end;
    end;
  end;
end;
{$ELSE}
function GuiCreate(var gw: TGuiWin; width, height: LongWord): Boolean; begin gw.hwnd:=nil; Result:=False; end;
procedure GuiDestroy(var gw: TGuiWin); begin gw.hwnd:=nil; end;
procedure GuiSetParent(var gw: TGuiWin; parent: pointer); begin end;
procedure GuiShow(var gw: TGuiWin; showIt: Boolean); begin end;
procedure GuiPump(var gw: TGuiWin); begin end;
{$ENDIF}
{$ENDIF}

end.