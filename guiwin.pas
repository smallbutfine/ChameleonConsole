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
    knobBmp: pointer;      // shared knob sprite strip (placeholder)
    vuBmp: pointer;        // VU sprite strip
    dragging: Boolean;
    dragParam: Integer;
    startY: Integer;
    startVal: Double;
  end;
  PGuiWin = ^TGuiWin;

function GuiCreate(var gw: TGuiWin; width, height: LongWord): Boolean;
procedure GuiDestroy(var gw: TGuiWin);
procedure GuiSetParent(var gw: TGuiWin; parent: pointer);
procedure GuiShow(var gw: TGuiWin; showIt: Boolean);
procedure GuiPump(var gw: TGuiWin);

implementation

{$IFDEF MSWINDOWS}
uses Windows, SysUtils, hostcb, pngload;

const
  GWLP_USERDATA = -21;
  STRIP_W = 90;
  STRIP_H = 600;
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
    (name:'trim';     param:1;  x:13; y:70),
    (name:'drive';    param:2;  x:13; y:140),
    (name:'hpf';      param:3;  x:13; y:210),
    (name:'lpf';      param:4;  x:13; y:280),
    (name:'eq_lo_f';  param:5;  x:13; y:350),
    (name:'eq_lo_g';  param:6;  x:13; y:420),
    (name:'eq_mid_f'; param:7;  x:13; y:490),
    (name:'eq_mid_g'; param:8;  x:13; y:560),
    (name:'eq_hi_f';  param:9;  x:13; y:630),
    (name:'eq_hi_g';  param:10; x:13; y:700),
    (name:'lux';      param:11; x:13; y:770),
    (name:'gloss';    param:12; x:13; y:840),
    (name:'tape';     param:13; x:13; y:910),
    (name:'volume';   param:14; x:13; y:980)
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

procedure PaintClient(hwnd: HWND; gw: PGuiWin);
var
  ps: PAINTSTRUCT;
  dc, mem: HDC;
  old: HGDIOBJ;
  bm: BITMAP;
  era, i, frames, knobFrame, vuFrame: Integer;
  path: ShortString;
  cx, cy: Integer;
begin
  { lazy-load artwork: knob + vu once, background per console era }
  if gw^.knobBmp = nil then
    gw^.knobBmp := pointer(LoadPngToHBitmap(PAnsiChar('assets/knob.png')));
  if gw^.vuBmp = nil then
    gw^.vuBmp := pointer(LoadPngToHBitmap(PAnsiChar('assets/vu.png')));
  if gw^.console <> nil then
  begin
    era := Round(gw^.console^);
    if era < 0 then era := 0;
    if era > 16 then era := 16;
    if era <> gw^.loadedConsole then
    begin
      gw^.loadedConsole := era;
      if gw^.bgBmp <> nil then DeleteObject(HBITMAP(gw^.bgBmp));
      path := 'assets/bg_' + EraName(era) + '.png';
      gw^.bgBmp := pointer(LoadPngToHBitmap(PAnsiChar(@path[1])));
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
    if gw^.knobBmp <> nil then
    begin
      GetObject(HBITMAP(gw^.knobBmp), SizeOf(BITMAP), @bm);
      frames := bm.bmWidth div (bm.bmHeight) ; if frames < 1 then frames := 1;
      for i := 0 to NUM_KNOBS-1 do
      begin
        if gw^.params <> nil then
          knobFrame := Round(Clamp01(PSampleF(gw^.params)[KnobLayout[i].param]) * (frames-1))
        else knobFrame := 0;
        DrawSprite(dc, HBITMAP(gw^.knobBmp), knobFrame, frames,
          KnobLayout[i].x, KnobLayout[i].y);
      end;
    end;

    { VU on top }
    if gw^.vuBmp <> nil then
    begin
      GetObject(HBITMAP(gw^.vuBmp), SizeOf(BITMAP), @bm);
      frames := bm.bmWidth div bm.bmHeight; if frames < 1 then frames := 1;
      if gw^.vu <> nil then vuFrame := Round(Clamp01(gw^.vu^) * (frames-1)) else vuFrame := 0;
      DrawSprite(dc, HBITMAP(gw^.vuBmp), vuFrame, frames, 13, 8);
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
          if (not gw^.dragging) and (gw^.console<>nil) then
          begin
            era := (Round(gw^.console^) + 1) mod 17;
            gw^.console^ := era;
            gw^.loadedConsole := -1;
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
begin
  if gw.hwnd<>nil then begin DestroyWindow(HWND(gw.hwnd)); gw.hwnd:=nil; end;
  if gw.bgBmp<>nil then begin DeleteObject(HBITMAP(gw.bgBmp)); gw.bgBmp:=nil; end;
  if gw.knobBmp<>nil then begin DeleteObject(HBITMAP(gw.knobBmp)); gw.knobBmp:=nil; end;
  if gw.vuBmp<>nil then begin DeleteObject(HBITMAP(gw.vuBmp)); gw.vuBmp:=nil; end;
end;

procedure GuiSetParent(var gw: TGuiWin; parent: pointer);
begin if (gw.hwnd<>nil) and (parent<>nil) then SetParent(HWND(gw.hwnd), HWND(parent)); end;

procedure GuiShow(var gw: TGuiWin; showIt: Boolean);
begin if gw.hwnd<>nil then begin if showIt then ShowWindow(HWND(gw.hwnd),SW_SHOW) else ShowWindow(HWND(gw.hwnd),SW_HIDE); end; end;

procedure GuiPump(var gw: TGuiWin);
begin if gw.hwnd<>nil then InvalidateRect(HWND(gw.hwnd), nil, True); end;

{$ELSE}
function GuiCreate(var gw: TGuiWin; width, height: LongWord): Boolean; begin gw.hwnd:=nil; Result:=False; end;
procedure GuiDestroy(var gw: TGuiWin); begin gw.hwnd:=nil; end;
procedure GuiSetParent(var gw: TGuiWin; parent: pointer); begin end;
procedure GuiShow(var gw: TGuiWin; showIt: Boolean); begin end;
procedure GuiPump(var gw: TGuiWin); begin end;
{$ENDIF}

end.