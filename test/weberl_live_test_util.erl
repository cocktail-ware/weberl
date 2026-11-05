%% Helpers for tests of live pages over real HTTP (no tests of its own).
%%
%% Streams and WebSockets use raw TCP clients: httpc's streaming mode does not
%% reliably surface a chunk that arrives together with the response head, and
%% OTP has no WebSocket client, so the handshake and frames are hand-rolled.
-module(weberl_live_test_util).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-export([start_apps/0, quiet/1, handler/1, page_handler/0, request_routes/0, jsonp/1,
         with_router/2, url/2,
         get/2, request/5, new_page/1, new_page/2, has/2, await_state/2,
         connect/1, open_stream/3, read_head/2, read_until/3, await_end/1,
         ws_connect/2, ws_connect/3, ws_send/3, ws_recv/2, ws_close/1]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

start_apps() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(weberl),
    {ok, _} = application:ensure_all_started(roadrunner),
    ok.

%% Run Fun with logging off (for tests that provoke logged errors on purpose).
quiet(Fun) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, Level) end.

%% A handler module: its body is appended after `-export([handle/1])'.
handler(Body) ->
    Mod = weberl_test_handlers:unique("lhh"),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

page_handler() ->
    handler("handle(_) -> weberl_response:html(200, "
            "<<\"<html><body><h1>Live</h1></body></html>\">>).").

%% Routes of pages whose handler implements handle_request/3 (echo, push, boom,
%% anything else is ok): "/two" (two_way), "/one" (one_way) and "/bare" (a
%% two_way page whose handler has no handle_request/3).
request_routes() ->
    H = handler("-export([handle_request/3]). "
                "handle(_) -> weberl_response:html(200, <<\"<html><body>x</body></html>\">>). "
                "handle_request(<<\"echo\">>, Data, _Id) -> {reply, #{echoed => Data}}; "
                "handle_request(<<\"push\">>, Data, #{page := Id}) -> "
                "  ok = weberl_live:push(Id, <<\"pushed\">>, Data), ok; "
                "handle_request(<<\"boom\">>, _, _) -> error(boom); "
                "handle_request(_, _, _) -> ok."),
    [{"/two", H, #{live => two_way}},
     {"/one", H, #{live => one_way}},
     {"/bare", page_handler(), #{live => two_way}}].

jsonp(Map) -> iolist_to_binary(json:encode(Map)).

with_router(Routes, Fun) ->
    Name = weberl_test_handlers:unique("lv"),
    RouterMod = weberl_test_handlers:unique("lvr"),
    weberl_test_util:load_router(RouterMod, Routes),
    {ok, Pid} = weberl:start_link(Name, #router{modules = [RouterMod]},
                                  #listener{port = 0, ip = {127, 0, 0, 1}}),
    try Fun(Name) after
        unlink(Pid),
        stop_if_running(Name)
    end.

stop_if_running(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _ -> weberl:stop(Name)
    end.

url(Name, Path) -> "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path.

get(Name, Path) ->
    request(Name, get, Path, [], undefined).

%% Plain (non-streaming) request through httpc. `Body' is `undefined' or
%% `{ContentType, Binary}'. Returns {Status, Headers, Body}.
request(Name, Method, Path, Headers, Body) ->
    Req = case Body of
              undefined -> {url(Name, Path), Headers};
              {Type, Bin} -> {url(Name, Path), Headers, Type, Bin}
          end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Req, [], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

%% Fetch a live page ("/live" by default) and return {PageId, Token}.
new_page(Name) -> new_page(Name, "/live").

new_page(Name, Path) ->
    {200, _, Body} = get(Name, Path),
    {attr(Body, "data-weberl-page"), attr(Body, "data-weberl-token")}.

attr(Body, Name) ->
    {match, [Value]} = re:run(Body, Name ++ "=\"([^\"]+)\"", [{capture, all_but_first, binary}]),
    Value.

has(Bin, Needle) -> binary:match(Bin, Needle) =/= nomatch.

await_state(Id, State) -> await_state(Id, State, 40).
await_state(Id, State, 0) -> ?assertMatch({ok, #{state := State}}, weberl_live:info(Id));
await_state(Id, State, N) ->
    case weberl_live:info(Id) of
        {ok, #{state := State}} -> ok;
        _ -> timer:sleep(25), await_state(Id, State, N - 1)
    end.

%% ---------------------------------------------------------------------
%% Raw TCP

connect(Name) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, weberl:port(Name), [binary, {active, false}]),
    Sock.

%% Open an SSE stream: {Socket, Head, Rest}.
open_stream(Name, Id, Token) ->
    Sock = connect(Name),
    ok = gen_tcp:send(Sock, ["GET /_weberl/sse/", Id, "?t=", Token,
                             "&v=", integer_to_list(weberl_live:client_version()), " HTTP/1.1\r\n"
                             "Host: localhost\r\nAccept: text/event-stream\r\n\r\n"]),
    {ok, Head, Rest} = read_head(Sock, <<>>),
    {Sock, Head, Rest}.

read_head(Sock, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] -> {ok, Head, Rest};
        [_] ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {ok, Bin} -> read_head(Sock, <<Acc/binary, Bin/binary>>);
                {error, Reason} -> {error, Reason, Acc}
            end
    end.

%% Read until `Needle' has arrived; `Acc' holds what was already received.
read_until(Sock, Acc, Needle) ->
    case binary:match(Acc, Needle) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {ok, Bin} -> read_until(Sock, <<Acc/binary, Bin/binary>>, Needle);
                {error, Reason} -> {error, Reason, Acc}
            end;
        _ ->
            {ok, Acc}
    end.

%% The server ended the stream: the chunked terminator, then the socket closes.
await_end(Sock) ->
    case gen_tcp:recv(Sock, 0, 3000) of
        {ok, _} -> await_end(Sock);
        {error, closed} -> ok;
        {error, Other} -> Other
    end.

%% ---------------------------------------------------------------------
%% WebSocket client (RFC 6455, just enough)

%% Handshake with the multiplexed endpoint. `Extra' are extra request header
%% lines (iodata, each ending in CRLF). Returns {ok, Socket, Rest} on 101,
%% otherwise {error, Head}.
ws_connect(Name, Extra) ->
    ws_connect(Name, Extra, "?v=" ++ integer_to_list(weberl_live:client_version())).

%% As ws_connect/2, with the query string of the request (`""' declares no
%% version).
ws_connect(Name, Extra, Query) ->
    Sock = connect(Name),
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    ok = gen_tcp:send(Sock, ["GET /_weberl/ws", Query, " HTTP/1.1\r\n"
                             "Host: localhost\r\nUpgrade: websocket\r\n"
                             "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                             "Sec-WebSocket-Key: ", Key, "\r\n", Extra, "\r\n"]),
    {ok, Head, Rest} = read_head(Sock, <<>>),
    case has(Head, <<"HTTP/1.1 101">>) of
        true -> {ok, Sock, Rest};
        false -> gen_tcp:close(Sock), {error, Head}
    end.

%% Send one masked, unfragmented frame. Opcode: text | binary | close | ping.
ws_send(Sock, Opcode, Payload0) ->
    Payload = iolist_to_binary(Payload0),
    Mask = crypto:strong_rand_bytes(4),
    Len = byte_size(Payload),
    LenBits = if Len < 126 -> <<(16#80 bor Len)>>;
                 Len < 65536 -> <<(16#80 bor 126), Len:16>>;
                 true -> <<(16#80 bor 127), Len:64>>
              end,
    gen_tcp:send(Sock, [<<1:1, 0:3, (opcode(Opcode)):4>>, LenBits, Mask, mask(Payload, Mask)]).

%% Next frame from the server: {{Opcode, Payload}, Rest} | {error, Reason}.
%% `Buf' is what was already received.
ws_recv(Sock, Buf) ->
    case parse(Buf) of
        {ok, Frame, Rest} -> {Frame, Rest};
        more ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {ok, Bin} -> ws_recv(Sock, <<Buf/binary, Bin/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

ws_close(Sock) ->
    _ = ws_send(Sock, close, <<1000:16>>),
    gen_tcp:close(Sock).

parse(<<_Fin:1, _Rsv:3, Op:4, 0:1, Len:7, Rest/binary>>) when Len < 126 -> frame(Op, Len, Rest);
parse(<<_:1, _:3, Op:4, 0:1, 126:7, Len:16, Rest/binary>>) -> frame(Op, Len, Rest);
parse(<<_:1, _:3, Op:4, 0:1, 127:7, Len:64, Rest/binary>>) -> frame(Op, Len, Rest);
parse(_) -> more.

frame(Op, Len, Rest) ->
    case Rest of
        <<Payload:Len/binary, Tail/binary>> -> {ok, {opcode(Op), Payload}, Tail};
        _ -> more
    end.

opcode(text) -> 1;
opcode(binary) -> 2;
opcode(close) -> 8;
opcode(ping) -> 9;
opcode(1) -> text;
opcode(2) -> binary;
opcode(8) -> close;
opcode(9) -> ping;
opcode(10) -> pong.

mask(Payload, Mask) ->
    <<M0, M1, M2, M3>> = Mask,
    Keys = {M0, M1, M2, M3},
    list_to_binary([B bxor element((I rem 4) + 1, Keys)
                    || {I, B} <- lists:enumerate(0, binary_to_list(Payload))]).
