unit hostcb;
{$mode fpc}{$H+}
interface
uses clap;

type
  TRequestCb = procedure(host: pointer); cdecl;
  TTryPush = function(list: pointer; event: PClapEventHeader): clap_bool; cdecl;

procedure CallRequest(cb: TRequestCb; host: pointer);
procedure CallTryPush(tp: TTryPush; list: pointer; event: PClapEventHeader);
procedure RequestCallbackHost(host: pointer);

implementation

procedure CallRequest(cb: TRequestCb; host: pointer);
begin
  if cb <> nil then cb(host);
end;

procedure CallTryPush(tp: TTryPush; list: pointer; event: PClapEventHeader);
begin
  if tp <> nil then tp(list, event);
end;

procedure RequestCallbackHost(host: pointer);
var h: PClapHost;
begin
  if host = nil then Exit;
  h := PClapHost(host);
  if h^.request_callback <> nil then
    h^.request_callback(h);
end;

end.
