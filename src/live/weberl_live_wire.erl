%% @doc JSON wire format of live pages, shared by every transport.
%%
%% == Requests (any transport) ==
%% `{"request": Name, "data": Json, "ref": Ref}' where `request' is a
%% non-empty string, `data' any JSON value (default `null') and `ref' an
%% optional string or integer the server echoes in the answer. Over HTTP it is
%% the body of `POST /_weberl/request/:id' (the page is the id in the path).
%%
%% == The SSE stream (`/_weberl/sse/:id') ==
%% One page per stream (the id is in the path). Every pushed event is an
%% unnamed SSE message whose data is `{"event": Name, "data": Data}', so the
%% browser needs no per-name listeners and all transports deliver the same
%% shape. Long-poll answers `{"events": [{"event", "data"}, ...], "closed":
%% Bool}'.
%%
%% == The multiplexed WebSocket (`/_weberl/ws') ==
%% One socket carries any number of pages (a hub shares one connection between
%% tabs), so every frame names its page. All frames are JSON text.
%%
%% Client to server:
%% <ul>
%%   <li>`{"op": "subscribe", "page": Id, "token": Token}' attach the page to
%%       this socket (the token must allow the `ws' channel);</li>
%%   <li>`{"op": "unsubscribe", "page": Id}';</li>
%%   <li>`{"op": "request", "page": Id, "request": Name, "data": Json,
%%       "ref": Ref}' a request of a subscribed page.</li>
%% </ul>
%%
%% Server to client (always with `"page": Id'):
%% <ul>
%%   <li>`{"page": Id, "subscribed": true}' or `{"page": Id, "error": Reason}'
%%       answering a subscribe;</li>
%%   <li>`{"page": Id, "event": Name, "data": Data}' a pushed event (`Data' is
%%       the string given to `weberl_live:push/3');</li>
%%   <li>`{"page": Id, "reply": Json, "ref": Ref}', `{"page": Id, "ok": true,
%%       "ref": Ref}' or `{"page": Id, "error": Reason, "ref": Ref}' answering a
%%       request;</li>
%%   <li>`{"page": Id, "closed": Why}' the page's session ended (`"closed"') or
%%       another connection took the page over (`"replaced"'). The socket stays
%%       open for the other pages.</li>
%% </ul>
%% `Reason' is one of `"bad_request"', `"forbidden"', `"not_found"',
%% `"unsupported"', `"failed"'. `ref' is omitted when the request had none.
%%
%% == Topics ==
%% A topic event (`weberl_live:publish/3') is one frame per connection, tagged
%% by topic and not by page: `{"topic": Topic, "event": Name, "data": Data}'.
%% It travels the same way on every transport (a WebSocket frame, the data of
%% an SSE message, an entry of the long-poll `events'), so the browser engine
%% hands it to every page of the connection that subscribed to the topic. A
%% snapshot (`handle_subscribe/2') is sent to one page only and so is an
%% ordinary page event: `{"page": Id, "event": Name, "data": Data}'.
-module(weberl_live_wire).

-export([decode_request/1, decode_frame/1, run_request/2, run_request/3, event/2, event/3,
         topic_event/3, topic_event_json/3, frame/2]).
-export_type([request/0, client_frame/0]).

-type request() :: #{name := binary(), data := term(), ref => binary() | integer()}.
-type client_frame() ::
        {subscribe, weberl_live:page_id(), binary()}
      | {unsubscribe, weberl_live:page_id()}
      | {request, weberl_live:page_id(), request()}.

%% @doc Parse the body of a POST request.
-spec decode_request(binary()) -> {ok, request()} | {error, bad_request}.
decode_request(Bin) when is_binary(Bin) ->
    case decode_json(Bin) of
        {ok, Msg} -> request_from_map(Msg);
        error -> {error, bad_request}
    end;
decode_request(_) ->
    {error, bad_request}.

%% @doc Parse a frame of the multiplexed WebSocket.
-spec decode_frame(binary()) -> {ok, client_frame()} | {error, bad_request}.
decode_frame(Bin) when is_binary(Bin) ->
    case decode_json(Bin) of
        {ok, #{~"op" := ~"subscribe", ~"page" := Page, ~"token" := Token}}
          when is_binary(Page), Page =/= <<>>, is_binary(Token) ->
            {ok, {subscribe, Page, Token}};
        {ok, #{~"op" := ~"unsubscribe", ~"page" := Page}}
          when is_binary(Page), Page =/= <<>> ->
            {ok, {unsubscribe, Page}};
        {ok, #{~"op" := ~"request", ~"page" := Page} = Msg}
          when is_binary(Page), Page =/= <<>> ->
            case request_from_map(Msg) of
                {ok, Request} -> {ok, {request, Page, Request}};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, bad_request}
    end;
decode_frame(_) ->
    {error, bad_request}.

%% @doc Run a decoded request against the session and build the answer:
%% `{Status, Json}' where `Status' is an HTTP-style status for transports that
%% need one, and `Json' the map to send (with `ref' echoed).
-spec run_request(weberl_live:page_id(), request()) -> {200..599, map()}.
run_request(PageId, #{name := Name, data := Data} = Req) ->
    answer(Req, weberl_live:request(PageId, Name, Data)).

answer(Req, Result) ->
    Ref = maps:with([ref], Req),
    case Result of
        {ok, noreply} -> {200, Ref#{ok => true}};
        {ok, {reply, Reply}} -> {200, Ref#{reply => Reply}};
        {error, not_found} -> {404, Ref#{error => ~"not_found"}};
        {error, unsupported} -> {501, Ref#{error => ~"unsupported"}};
        {error, failed} -> {500, Ref#{error => ~"failed"}}
    end.

%% @doc Like {@link run_request/2} for a page described by the claims of its
%% token: with a session the request goes to it; a session-less page has none,
%% so the handler's `handle_request/3' runs right here, in the calling process.
-spec run_request(weberl_live:page_id(), weberl_live_guard:claims(), request()) ->
    {200..599, map()}.
run_request(PageId, #{session := true}, Req) ->
    run_request(PageId, Req);
run_request(PageId, #{kind := Kind, handler := Handler, topics := Topics},
            #{name := Name, data := Data} = Req) ->
    Context = weberl_live_callbacks:context(PageId, Kind, Topics),
    answer(Req, weberl_live_callbacks:request(Handler, Name, Data, Context)).

%% @doc A topic event as one frame for a transport that carries many pages
%% (the multiplexed socket) and for the SSE stream and long-poll of a single
%% page: `{"topic": Topic, "event": Name, "data": Data}'. It names no page: a
%% connection receives it once however many of its pages subscribed to the
%% topic, and the browser hands it to each of them.
-spec topic_event(weberl_live:topic(), binary(), binary()) -> iodata().
topic_event(Topic, Name, Data) ->
    json:encode(#{topic => Topic, event => Name, data => Data}).

%% @doc Like {@link topic_event/3} with `Json' (already encoded JSON text) as the
%% value of `data', not as a string: the browser receives the decoded value.
-spec topic_event_json(weberl_live:topic(), binary(), binary()) -> iodata().
topic_event_json(Topic, Name, Json) ->
    [<<"{\"topic\":">>, json:encode(Topic), <<",\"event\":">>, json:encode(Name),
     <<",\"data\":">>, Json, $}].

%% @doc A pushed event for a transport that carries one page (the SSE stream):
%% `{"event": Name, "data": Data}'.
-spec event(binary(), binary()) -> iodata().
event(Name, Data) ->
    json:encode(#{event => Name, data => Data}).

%% @doc A pushed event on the multiplexed socket, tagged with its page.
-spec event(weberl_live:page_id(), binary(), binary()) -> iodata().
event(PageId, Name, Data) ->
    json:encode(#{page => PageId, event => Name, data => Data}).

%% @doc Any server frame for a page: `Fields' (a map) plus the page id.
-spec frame(weberl_live:page_id(), map()) -> iodata().
frame(PageId, Fields) ->
    json:encode(Fields#{page => PageId}).

%% ---------------------------------------------------------------------

decode_json(Bin) ->
    try {ok, json:decode(Bin)}
    catch error:_ -> error
    end.

request_from_map(#{~"request" := Name} = Msg) when is_binary(Name), Name =/= <<>> ->
    Req = #{name => Name, data => maps:get(~"data", Msg, null)},
    case maps:find(~"ref", Msg) of
        {ok, Ref} when is_binary(Ref); is_integer(Ref) -> {ok, Req#{ref => Ref}};
        {ok, _} -> {error, bad_request};
        error -> {ok, Req}
    end;
request_from_map(_) ->
    {error, bad_request}.
