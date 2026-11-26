unit clapplugin;
{ ChameleonConsole - CLAP channelstrip wired to ChannelStripDSP. }
{$IFDEF FPC}{$MODE Delphi}{$H+}{$ENDIF}
interface
uses clap, clapentry;

implementation
uses SysUtils, guiwin, hostcb, ChannelStripDSP;

const
  NUM_PARAMS = 15;
  P_CONSOLE=0; P_TRIM=1; P_DRIVE=2; P_HPF=3; P_LPF=4;
  P_EQ_LO_F=5; P_EQ_LO_G=6; P_EQ_MID_F=7; P_EQ_MID_G=8;
  P_EQ_HI_F=9; P_EQ_HI_G=10; P_LUX=11; P_GLOSS=12; P_TAPE=13; P_VOLUME=14;

type
  PPluginData = ^TPluginData;
  TPluginData = record
    host: PClapHost;
    sample_rate: c_double;
    max_frames: c_uint32;
    dsp: PDSPInstance;
    params: array[0..NUM_PARAMS-1] of c_float;
    gw: TGuiWin;
  end;

  TChan32 = array[0..1023] of PSingle;
  PChan32 = ^TChan32;
  TAudioBufArray = array[0..1023] of clap_audio_buffer_t;
  PAudioBufArray = ^TAudioBufArray;

var
  g_descriptor: clap_plugin_descriptor_t;
  g_features: array[0..1] of PAnsiChar;
  g_factory: clap_plugin_factory_t;
  g_params: clap_plugin_params_t;
  g_gui: clap_plugin_gui_t;
  g_state: clap_plugin_state_t;

procedure setStr(dst: PAnsiChar; src: PAnsiChar); cdecl;
begin if (dst<>nil) and (src<>nil) then StrCopy(dst, src); end;

function ParamName(i:Integer):PAnsiChar; cdecl; forward;
function ParamMin(i:Integer):c_double; cdecl; forward;
function ParamMax(i:Integer):c_double; cdecl; forward;
function ParamDef(i:Integer):c_double; cdecl; forward;

{ forward }
function plugin_init(plugin: pointer): clap_bool; cdecl; forward;
procedure plugin_destroy(plugin: pointer); cdecl; forward;
function plugin_activate(plugin: pointer; sample_rate: c_double; mn: c_uint32; mx: c_uint32): clap_bool; cdecl; forward;
procedure plugin_deactivate(plugin: pointer); cdecl; forward;
function plugin_start_processing(plugin: pointer): clap_bool; cdecl; forward;
procedure plugin_stop_processing(plugin: pointer); cdecl; forward;
procedure plugin_reset(plugin: pointer); cdecl; forward;
function plugin_process(plugin: pointer; proc: PClapProcess): c_int32; cdecl; forward;
function plugin_get_extension(plugin: pointer; id: PAnsiChar): pointer; cdecl; forward;
procedure plugin_on_main_thread(plugin: pointer); cdecl; forward;

{ ---- entry ---- }
function entry_init(p: PAnsiChar): clap_bool; cdecl; begin Result:=True; end;
procedure entry_deinit; cdecl; begin end;
function entry_get_factory(id: PAnsiChar): pointer; cdecl;
begin if (id<>nil) and (StrComp(id,CLAP_PLUGIN_FACTORY_ID)=0) then Exit(@g_factory); Result:=nil; end;

{ ---- factory ---- }
function factory_get_count(f: pointer): c_uint32; cdecl; begin Result:=1; end;
function factory_get_descriptor(f: pointer; i: c_uint32): PClapPluginDescriptor; cdecl;
begin if i=0 then Exit(@g_descriptor); Result:=nil; end;
function factory_create_plugin(f: pointer; host: PClapHost; id: PAnsiChar): PClapPlugin; cdecl;
var p: PClapPlugin; pd: PPluginData; i: Integer;
begin
  if (id=nil) or (StrComp(id,g_descriptor.id)<>0) then Exit(nil);
  New(pd);
  pd^.host:=host; pd^.sample_rate:=0; pd^.max_frames:=0;
  pd^.dsp := PDSPInstance(instantiate_dsp(nil, 44100.0, nil, nil));
  for i:=0 to NUM_PARAMS-1 do pd^.params[i] := 0;
  pd^.gw.hwnd:=nil; pd^.gw.gain:=nil; pd^.gw.console:=nil; pd^.gw.params:=nil; pd^.gw.vu:=nil;
  pd^.gw.loadedConsole:=-1; pd^.gw.bgBmp:=nil; pd^.gw.vuBmp:=nil; for i:=0 to 13 do pd^.gw.knobBmps[i]:=nil;
  pd^.gw.dragging:=False; pd^.gw.dragParam:=0; pd^.gw.startY:=0; pd^.gw.startVal:=0; pd^.gw.host:=nil;
  New(p); FillChar(p^,SizeOf(clap_plugin_t),0);
  p^.desc:=@g_descriptor; p^.plugin_data:=pd;
  p^.init:=@plugin_init; p^.destroy:=@plugin_destroy; p^.activate:=@plugin_activate;
  p^.deactivate:=@plugin_deactivate; p^.start_processing:=@plugin_start_processing;
  p^.stop_processing:=@plugin_stop_processing; p^.reset:=@plugin_reset;
  p^.process:=@plugin_process; p^.get_extension:=@plugin_get_extension;
  p^.on_main_thread:=@plugin_on_main_thread;
  Result:=p;
end;

{ ---- plugin ---- }
function plugin_init(plugin: pointer): clap_bool; cdecl; begin Result:=True; end;
procedure plugin_destroy(plugin: pointer); cdecl;
var p:PClapPlugin; pd:PPluginData;
begin
  p:=PClapPlugin(plugin); if p=nil then Exit;
  pd:=PPluginData(p^.plugin_data);
  if pd^.dsp<>nil then cleanup_dsp(pd^.dsp);
  if pd<>nil then Dispose(pd);
  Dispose(p);
end;
function plugin_activate(plugin: pointer; sample_rate: c_double; mn: c_uint32; mx: c_uint32): clap_bool; cdecl;
var pd:PPluginData;
begin
  pd:=PPluginData(PClapPlugin(plugin)^.plugin_data);
  pd^.sample_rate:=sample_rate; pd^.max_frames:=mx;
  if pd^.dsp<>nil then cleanup_dsp(pd^.dsp);
  pd^.dsp := PDSPInstance(instantiate_dsp(nil, sample_rate, nil, nil));
  Result:=True;
end;
procedure plugin_deactivate(plugin: pointer); cdecl; begin end;
function plugin_start_processing(plugin: pointer): clap_bool; cdecl; begin Result:=True; end;
procedure plugin_stop_processing(plugin: pointer); cdecl; begin end;
procedure plugin_reset(plugin: pointer); cdecl; begin end;

function plugin_process(plugin: pointer; proc: PClapProcess): c_int32; cdecl;
var
  pd: PPluginData;
  inb, outb: PClapAudioBuffer;
begin
  if proc=nil then Exit(CLAP_PROCESS_ERROR);
  pd:=PPluginData(PClapPlugin(plugin)^.plugin_data);
  if pd^.dsp=nil then Exit(CLAP_PROCESS_ERROR);

  pd^.dsp^.Ports[PORT_CONSOLE] := @pd^.params[P_CONSOLE];
  pd^.dsp^.Ports[PORT_TRIM]    := @pd^.params[P_TRIM];
  pd^.dsp^.Ports[PORT_DRIVE]   := @pd^.params[P_DRIVE];
  pd^.dsp^.Ports[PORT_HPF]     := @pd^.params[P_HPF];
  pd^.dsp^.Ports[PORT_LPF]     := @pd^.params[P_LPF];
  pd^.dsp^.Ports[PORT_EQ_LO_F] := @pd^.params[P_EQ_LO_F];
  pd^.dsp^.Ports[PORT_EQ_LO_G] := @pd^.params[P_EQ_LO_G];
  pd^.dsp^.Ports[PORT_EQ_MID_F]:= @pd^.params[P_EQ_MID_F];
  pd^.dsp^.Ports[PORT_EQ_MID_G]:= @pd^.params[P_EQ_MID_G];
  pd^.dsp^.Ports[PORT_EQ_HI_F] := @pd^.params[P_EQ_HI_F];
  pd^.dsp^.Ports[PORT_EQ_HI_G] := @pd^.params[P_EQ_HI_G];
  pd^.dsp^.Ports[PORT_LUX]     := @pd^.params[P_LUX];
  pd^.dsp^.Ports[PORT_GLOSS]   := @pd^.params[P_GLOSS];
  pd^.dsp^.Ports[PORT_TAPE]    := @pd^.params[P_TAPE];
  pd^.dsp^.Ports[PORT_VOLUME]  := @pd^.params[P_VOLUME];

  if (proc^.audio_inputs_count>0) and (PAudioBufArray(proc^.audio_inputs)^[0].data32<>nil) then
    pd^.dsp^.Ports[PORT_IN] := PChan32(PAudioBufArray(proc^.audio_inputs)^[0].data32)^[0]
  else pd^.dsp^.Ports[PORT_IN] := nil;
  if (proc^.audio_outputs_count>0) and (PAudioBufArray(proc^.audio_outputs)^[0].data32<>nil) then
    pd^.dsp^.Ports[PORT_OUT] := PChan32(PAudioBufArray(proc^.audio_outputs)^[0].data32)^[0]
  else pd^.dsp^.Ports[PORT_OUT] := nil;

  run_dsp(pd^.dsp, proc^.frames_count);
  Result := CLAP_PROCESS_CONTINUE;
end;

{ ---- params ---- }
function params_count(plugin: pointer): c_uint32; cdecl; begin Result:=NUM_PARAMS; end;
function params_get_info(plugin: pointer; idx: c_uint32; info: PClapParamInfo): clap_bool; cdecl;
begin
  if (info=nil) or (idx>=NUM_PARAMS) then Exit(False);
  info^.id:=idx; info^.flags:=CLAP_PARAM_IS_AUTOMATABLE; info^.cookie:=nil;
  setStr(PAnsiChar(@info^.name), ParamName(idx)); setStr(PAnsiChar(@info^.module),'');
  info^.min_value:=ParamMin(idx); info^.max_value:=ParamMax(idx); info^.default_value:=ParamDef(idx);
  Result:=True;
end;
function params_get_value(plugin: pointer; id: clap_id; outv: PDouble): clap_bool; cdecl;
begin if (outv=nil) or (id>=NUM_PARAMS) then Exit(False);
  outv^:=PPluginData(PClapPlugin(plugin)^.plugin_data)^.params[id]; Result:=True; end;
function params_value_to_text(plugin: pointer; id: clap_id; v: c_double; buf: PAnsiChar; cap: c_uint32): clap_bool; cdecl;
var s:ShortString;
begin if (buf=nil) or (id>=NUM_PARAMS) or (cap=0) then Exit(False);
  Str(v:0:2,s); StrLCopy(buf,PAnsiChar(@s[1]),cap-1); Result:=True; end;
function params_text_to_value(plugin: pointer; id: clap_id; t: PAnsiChar; outv: PDouble): clap_bool; cdecl;
begin if (outv=nil) or (id>=NUM_PARAMS) then Exit(False); outv^:=StrToFloatDef(t,0); Result:=True; end;
procedure params_flush(plugin: pointer; in_: PClapInputEvents; out_: PClapOutputEvents); cdecl;
var i:c_uint32; ev:PClapEventHeader; pv:PClapEventParamValue; pd:PPluginData;
begin
  pd:=PPluginData(PClapPlugin(plugin)^.plugin_data);
  if in_=nil then Exit;
  for i:=0 to in_^.size_fn(in_)-1 do
  begin
    ev:=in_^.get_fn(in_,i);
    if (ev<>nil) and (ev^.evt_type=CLAP_EVENT_PARAM_VALUE) then
    begin pv:=PClapEventParamValue(ev); if pv^.param_id<NUM_PARAMS then pd^.params[pv^.param_id]:=pv^.value; end;
  end;
end;

{ ---- gui (stub) ---- }
function gui_is_api_supported(plugin:pointer; api:PAnsiChar; f:clap_bool):clap_bool; cdecl;
begin if (api<>nil) and ((StrComp(api,CLAP_WINDOW_API_WIN32)=0) or (StrComp(api,CLAP_WINDOW_API_COCOA)=0) or (StrComp(api,CLAP_WINDOW_API_X11)=0)) then Exit(True); Result:=False; end;
function gui_get_preferred_api(plugin:pointer; api:PPAnsiChar; f:PClapBool):clap_bool; cdecl;
begin if api<>nil then api^:=PAnsiChar(CLAP_WINDOW_API_WIN32); if f<>nil then f^:=False; Result:=True; end;
function gui_create(plugin:pointer; api:PAnsiChar; f:clap_bool):clap_bool; cdecl;
var pd:PPluginData; begin pd:=PPluginData(PClapPlugin(plugin)^.plugin_data); pd^.gw.gain:=@pd^.params[P_VOLUME]; pd^.gw.console:=@pd^.params[P_CONSOLE]; pd^.gw.params:=@pd^.params[0]; pd^.gw.host:=pd^.host; pd^.gw.loadedConsole:=-1; Result:=GuiCreate(pd^.gw,90,852); end;
procedure gui_destroy(plugin:pointer); cdecl; begin GuiDestroy(PPluginData(PClapPlugin(plugin)^.plugin_data)^.gw); end;
function gui_set_scale(plugin:pointer; s:c_double):clap_bool; cdecl; begin Result:=True; end;
function gui_get_size(plugin:pointer; w:PClapSize; h:PClapSize):clap_bool; cdecl; begin if w<>nil then w^:=90; if h<>nil then h^:=852; Result:=True; end;
function gui_can_resize(plugin:pointer):clap_bool; cdecl; begin Result:=False; end;
function gui_get_resize_hints(plugin:pointer; h:PClapGuiResizeHints):clap_bool; cdecl; begin Result:=False; end;
function gui_adjust_size(plugin:pointer; w:PClapSize; h:PClapSize):clap_bool; cdecl; begin Result:=True; end;
function gui_set_size(plugin:pointer; w:c_uint32; h:c_uint32):clap_bool; cdecl; begin Result:=True; end;
function gui_set_parent(plugin:pointer; win:PClapWindow):clap_bool; cdecl; begin if win<>nil then GuiSetParent(PPluginData(PClapPlugin(plugin)^.plugin_data)^.gw, win^.ptr); Result:=True; end;
function gui_set_transient(plugin:pointer; win:PClapWindow):clap_bool; cdecl; begin Result:=True; end;
procedure gui_suggest_title(plugin:pointer; t:PAnsiChar); cdecl; begin end;
function gui_show(plugin:pointer):clap_bool; cdecl; begin GuiShow(PPluginData(PClapPlugin(plugin)^.plugin_data)^.gw,True); Result:=True; end;
function gui_hide(plugin:pointer): clap_bool; cdecl; begin GuiShow(PPluginData(PClapPlugin(plugin)^.plugin_data)^.gw,False); Result:=True; end;

{ ---- state ---- }
function state_save(plugin:pointer; st:PClapOStream):clap_bool; cdecl;
var pd:PPluginData; buf:array[0..23] of c_byte; total:c_int64; w:c_int64;
begin if st=nil then Exit(False); pd:=PPluginData(PClapPlugin(plugin)^.plugin_data);
  buf[0]:=67;buf[1]:=72;buf[2]:=83;buf[3]:=49;buf[4]:=2; Move(pd^.params[P_VOLUME],buf[8],8);
  total:=0; while total<24 do begin w:=st^.write_fn(st,@buf[total],24-total); if w<=0 then Exit(False); total:=total+w; end; Result:=True; end;
function state_load(plugin:pointer; st:PClapIStream):clap_bool; cdecl;
var pd:PPluginData; buf:array[0..23] of c_byte; total:c_int64; r:c_int64; g:c_double;
begin if st=nil then Exit(False); pd:=PPluginData(PClapPlugin(plugin)^.plugin_data); total:=0;
  while total<24 do begin r:=st^.read_fn(st,@buf[total],24-total); if r<=0 then Exit(False); total:=total+r; end;
  if not ((buf[0]=67) and (buf[1]=72) and (buf[2]=83) and (buf[3]=49) and (buf[4]=2)) then Exit(False);
  Move(buf[8],g,8); pd^.params[P_VOLUME]:=g; Result:=True; end;

{ ---- extension dispatch ---- }
function plugin_get_extension(plugin:pointer; id:PAnsiChar):pointer; cdecl;
begin
  if (id<>nil) and (StrComp(id,CLAP_EXT_PARAMS)=0) then Exit(@g_params);
  if (id<>nil) and (StrComp(id,CLAP_EXT_GUI)=0) then Exit(@g_gui);
  if (id<>nil) and (StrComp(id,CLAP_EXT_STATE)=0) then Exit(@g_state);
  Result:=nil;
end;
procedure plugin_on_main_thread(plugin:pointer); cdecl; begin GuiPump(PPluginData(PClapPlugin(plugin)^.plugin_data)^.gw); end;

{ ---- param metadata ---- }
function ParamName(i:Integer):PAnsiChar; cdecl;
begin
  case i of
    0: Result:=PAnsiChar('Console'); 1: Result:=PAnsiChar('Trim'); 2: Result:=PAnsiChar('Drive');
    3: Result:=PAnsiChar('HPF'); 4: Result:=PAnsiChar('LPF');
    5: Result:=PAnsiChar('EQ Lo Freq'); 6: Result:=PAnsiChar('EQ Lo Gain');
    7: Result:=PAnsiChar('EQ Mid Freq'); 8: Result:=PAnsiChar('EQ Mid Gain');
    9: Result:=PAnsiChar('EQ Hi Freq'); 10: Result:=PAnsiChar('EQ Hi Gain');
    11: Result:=PAnsiChar('Lux'); 12: Result:=PAnsiChar('Gloss'); 13: Result:=PAnsiChar('Tape');
    14: Result:=PAnsiChar('Volume');
  else Result:=PAnsiChar('?'); end;
end;
function ParamMin(i:Integer):c_double; cdecl;
begin case i of 1:Result:=-24;2:Result:=0;3:Result:=0;4:Result:=1000;5:Result:=20;6:Result:=-15;7:Result:=80;8:Result:=-15;9:Result:=500;10:Result:=-15;14:Result:=-24; else Result:=0; end; end;
function ParamMax(i:Integer):c_double; cdecl;
begin case i of 1:Result:=24;2:Result:=100;3:Result:=500;4:Result:=20000;5:Result:=500;6:Result:=15;7:Result:=8000;8:Result:=15;9:Result:=20000;10:Result:=15;11:Result:=1;12:Result:=1;13:Result:=1;14:Result:=12; else Result:=1; end; end;
function ParamDef(i:Integer):c_double; cdecl;
begin case i of 3:Result:=20;4:Result:=10000;5:Result:=80;7:Result:=1000;9:Result:=5000;14:Result:=8; else Result:=0; end; end;

{ ---- module setup ---- }
initialization
  clap_entry.version.major:=CLAP_VERSION_MAJOR; clap_entry.version.minor:=CLAP_VERSION_MINOR; clap_entry.version.revision:=CLAP_VERSION_REVISION;
  clap_entry.init:=@entry_init; clap_entry.deinit:=@entry_deinit; clap_entry.get_factory:=@entry_get_factory;
  g_features[0]:=PAnsiChar('audio-effect'); g_features[1]:=nil;
  g_descriptor.version.major:=CLAP_VERSION_MAJOR; g_descriptor.version.minor:=CLAP_VERSION_MINOR; g_descriptor.version.revision:=CLAP_VERSION_REVISION;
  g_descriptor.id:=PAnsiChar('com.smallbutfine.chameleonconsole'); g_descriptor.name:=PAnsiChar('Chameleon Console');
  g_descriptor.vendor:=PAnsiChar('smallbutfine'); g_descriptor.url:=PAnsiChar('https://github.com/smallbutfine/ChameleonConsole');
  g_descriptor.manual_url:=nil; g_descriptor.support_url:=nil; g_descriptor.version_str:=PAnsiChar('1.1.0');
  g_descriptor.description:=PAnsiChar('17-console channelstrip (DSP in Pascal).'); g_descriptor.features:=@g_features;
  g_factory.get_plugin_count:=@factory_get_count; g_factory.get_plugin_descriptor:=@factory_get_descriptor; g_factory.create_plugin:=@factory_create_plugin;
  g_params.count:=@params_count; g_params.get_info:=@params_get_info; g_params.get_value:=@params_get_value;
  g_params.value_to_text:=@params_value_to_text; g_params.text_to_value:=@params_text_to_value; g_params.flush:=@params_flush;
  g_gui.is_api_supported:=@gui_is_api_supported; g_gui.get_preferred_api:=@gui_get_preferred_api; g_gui.create:=@gui_create;
  g_gui.destroy:=@gui_destroy; g_gui.set_scale:=@gui_set_scale; g_gui.get_size:=@gui_get_size; g_gui.can_resize:=@gui_can_resize;
  g_gui.get_resize_hints:=@gui_get_resize_hints; g_gui.adjust_size:=@gui_adjust_size; g_gui.set_size:=@gui_set_size;
  g_gui.set_parent:=@gui_set_parent; g_gui.set_transient:=@gui_set_transient; g_gui.suggest_title:=@gui_suggest_title;
  g_gui.show:=@gui_show; g_gui.hide:=@gui_hide;
  g_state.save:=@state_save; g_state.load:=@state_load;
end.