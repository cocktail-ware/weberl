%% The multiplexed WebSocket (/_weberl/ws): several pages on one socket, page
%% tagged frames, subscribe/unsubscribe, requests, and what happens when a page
%% or the whole socket ends. Over real HTTP with a hand-rolled WS client.
-module(weberl_live_ws_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util,
        [with_router/2, new_page/2, await_state/2, jsonp/1,
         ws_connect/2, ws_send/3, ws_recv/2, ws_close/1]).

ws_test_() ->
    {setup,
     fun weberl_live_test_util:start_apps/0,
     fun(_) -> ok end,
     [{"pushed events arrive tagged with their page", fun push/0},
      {"request round trip with ref", fun request/0},
      {"request answers (ok, bad, unsupported, crash)", fun request_answers/0},
      {"requests need a subscribed page", fun request_needs_subscription/0},
      {"subscribe is refused for bad tokens, other channels and unknown pages", fun refused/0},
      {"upgrade is refused for another origin and other methods", fun upgrade_refused/0},
      {"several pages share one socket", fun many_pages/0},
      {"stats count the connections and sessions", fun stats/0},
      {"unsubscribe stops the page's events and detaches it", fun unsubscribe/0},
      {"a ended page closes only itself", fun page_closed/0},
      {"another socket taking a page replaces it on the first", fun replaced/0},
      {"client close and dropped sockets detach every page", fun detaches/0},
      {"binary frames are refused", fun binary_frames/0},
      {"a socket that never subscribes is closed", fun subscribe_deadline/0},
      {"stopping the router closes the pages", fun router_stop/0}]}.

%% ---------------------------------------------------------------------

%% Next JSON text frame from the socket.
json_frame(Sock, Buf) ->
    {{text, Payload}, Rest} = ws_recv(Sock, Buf),
    {json:decode(Payload), Rest}.

send(Sock, Map) -> ok = ws_send(Sock, text, jsonp(Map)).

%% Subscribe `Page' = {Id, Token}; returns the socket buffer after the answer.
subscribe(Sock, Buf, {Id, Token}) ->
    send(Sock, #{op => subscribe, page => Id, token => Token}),
    {Answer, Rest} = json_frame(Sock, Buf),
    ?assertEqual(#{~"page" => Id, ~"subscribed" => true}, Answer),
    Rest.

%% A socket with `Paths' (page paths) subscribed: {Sock, Buf, [{Id, Token}]}.
open(Name, Paths) ->
    {ok, Sock, Buf} = ws_connect(Name, []),
    Pages = [new_page(Name, P) || P <- Paths],
    Buf1 = lists:foldl(fun(Page, B) -> subscribe(Sock, B, Page) end, Buf, Pages),
    [await_state(Id, attached) || {Id, _} <- Pages],
    {Sock, Buf1, Pages}.

with_ws(Paths, Fun) ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        {Sock, Buf, Pages} = open(Name, Paths),
        try Fun(Sock, Buf, Pages) after gen_tcp:close(Sock) end
    end).

%% ---------------------------------------------------------------------

push() ->
    with_ws(["/two"], fun(Sock, Buf, [{Id, _}]) ->
        ok = weberl_live:push(Id, <<"tick">>, <<"one">>),
        ok = weberl_live:push(Id, <<"tock">>, <<"two">>),
        {M1, Buf1} = json_frame(Sock, Buf),
        {M2, _} = json_frame(Sock, Buf1),
        ?assertEqual(#{~"page" => Id, ~"event" => ~"tick", ~"data" => ~"one"}, M1),
        ?assertEqual(#{~"page" => Id, ~"event" => ~"tock", ~"data" => ~"two"}, M2)
    end).

request() ->
    with_ws(["/two"], fun(Sock, Buf, [{Id, _}]) ->
        send(Sock, #{op => request, page => Id, request => echo, data => #{a => [1, 2]},
                     ref => ~"r1"}),
        {Answer, Buf1} = json_frame(Sock, Buf),
        ?assertEqual(#{~"page" => Id, ~"reply" => #{~"echoed" => #{~"a" => [1, 2]}},
                       ~"ref" => ~"r1"}, Answer),
        %% integer refs are echoed too; data defaults to null
        send(Sock, #{op => request, page => Id, request => echo, ref => 7}),
        {Answer2, _} = json_frame(Sock, Buf1),
        ?assertEqual(#{~"page" => Id, ~"reply" => #{~"echoed" => null}, ~"ref" => 7}, Answer2)
    end).

request_answers() ->
    weberl_live_test_util:quiet(fun request_answers_/0).

request_answers_() ->
    with_ws(["/two", "/bare"], fun(Sock, Buf, [{Id, _}, {Bare, _}]) ->
        send(Sock, #{op => request, page => Id, request => ignore, ref => ~"a"}),
        {A1, B1} = json_frame(Sock, Buf),
        ?assertEqual(#{~"page" => Id, ~"ok" => true, ~"ref" => ~"a"}, A1),
        ok = ws_send(Sock, text, <<"not json">>),
        {A2, B2} = json_frame(Sock, B1),
        ?assertEqual(#{~"error" => ~"bad_request"}, A2),
        %% frames without an op, without a page, or with a bad request
        [send(Sock, M) || M <- [#{request => echo}, #{op => request, request => echo},
                                #{op => request, page => Id}, #{op => nope, page => Id},
                                #{op => subscribe, page => Id}]],
        B3 = lists:foldl(fun(_, B) ->
                                 {A, Rest} = json_frame(Sock, B),
                                 ?assertEqual(#{~"error" => ~"bad_request"}, A),
                                 Rest
                         end, B2, lists:seq(1, 5)),
        send(Sock, #{op => request, page => Id, request => boom, ref => ~"b"}),
        {A4, B4} = json_frame(Sock, B3),
        ?assertEqual(#{~"page" => Id, ~"error" => ~"failed", ~"ref" => ~"b"}, A4),
        %% the session survives a crashing handler
        send(Sock, #{op => request, page => Id, request => echo, data => 1}),
        {A5, B5} = json_frame(Sock, B4),
        ?assertMatch(#{~"reply" := _}, A5),
        %% a page whose handler has no handle_request/3
        send(Sock, #{op => request, page => Bare, request => echo, ref => ~"u"}),
        {A6, _} = json_frame(Sock, B5),
        ?assertEqual(#{~"page" => Bare, ~"error" => ~"unsupported", ~"ref" => ~"u"}, A6)
    end).

request_needs_subscription() ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        {Id, _Token} = new_page(Name, "/two"),
        {ok, Sock, Buf} = ws_connect(Name, []),
        %% a page that exists but is not subscribed on this socket
        send(Sock, #{op => request, page => Id, request => echo, ref => ~"x"}),
        {A, _} = json_frame(Sock, Buf),
        ?assertEqual(#{~"page" => Id, ~"error" => ~"forbidden", ~"ref" => ~"x"}, A),
        gen_tcp:close(Sock)
    end).

refused() ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        {OneId, _OneToken} = new_page(Name, "/one"),
        {Id, _Token} = new_page(Name, "/two"),
        {_Other, OtherToken} = new_page(Name, "/two"),
        {ok, Sock, Buf} = ws_connect(Name, []),
        Ghost = <<"ghost-page-id">>,
        Cases = [{OneId, weberl_live_guard:issue(OneId, [sse, request]), ~"forbidden"},
                                                           % a token without the ws channel
                 {Id, <<"bad">>, ~"forbidden"},
                 {Id, OtherToken, ~"forbidden"},           % another page's token
                 {Id, weberl_live_guard:issue(Id, [sse, request]), ~"forbidden"},
                 {Ghost, weberl_live_guard:issue(Ghost, [ws]), ~"not_found"}],
        lists:foldl(fun({PageId, Tok, Reason}, B) ->
                            send(Sock, #{op => subscribe, page => PageId, token => Tok}),
                            {A, Rest} = json_frame(Sock, B),
                            ?assertEqual(#{~"page" => PageId, ~"error" => Reason}, A),
                            Rest
                    end, Buf, Cases),
        %% nothing was attached by the refused attempts
        ?assertMatch({ok, #{state := waiting}}, weberl_live:info(Id)),
        ?assertMatch({ok, #{state := waiting}}, weberl_live:info(OneId)),
        gen_tcp:close(Sock)
    end).

upgrade_refused() ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        ?assertMatch({error, <<"HTTP/1.1 403", _/binary>>},
                     ws_connect(Name, ["Origin: http://evil.example\r\n"])),
        {405, _, _} = weberl_live_test_util:request(Name, post, "/_weberl/ws", [],
                                                    {"text/plain", <<>>})
    end).

%% Three pages on one socket: one websocket, three sessions (counted by
%% weberl_live:stats/0, which the browser tests read).
stats() ->
    Before = weberl_live:stats(),
    with_ws(["/two", "/two", "/bare"], fun(_Sock, _Buf, _Pages) ->
        #{websockets := Ws, sessions := Sessions} = weberl_live:stats(),
        ?assertEqual(maps:get(websockets, Before) + 1, Ws),
        ?assertEqual(maps:get(sessions, Before) + 3, Sessions)
    end),
    %% the connection and the sessions end with the socket / on their own
    await_stat(websockets, maps:get(websockets, Before)).

await_stat(Key, Expected) -> await_stat(Key, Expected, 40).
await_stat(Key, Expected, 0) -> ?assertEqual(Expected, maps:get(Key, weberl_live:stats()));
await_stat(Key, Expected, N) ->
    case maps:get(Key, weberl_live:stats()) of
        Expected -> ok;
        _ -> timer:sleep(25), await_stat(Key, Expected, N - 1)
    end.

many_pages() ->
    with_ws(["/two", "/two", "/bare"], fun(Sock, Buf, [{A, _}, {B, _}, {C, _}]) ->
        ok = weberl_live:push(B, <<"b">>, <<"for b">>),
        ok = weberl_live:push(A, <<"a">>, <<"for a">>),
        ok = weberl_live:push(C, <<"c">>, <<"for c">>),
        {M1, B1} = json_frame(Sock, Buf),
        {M2, B2} = json_frame(Sock, B1),
        {M3, _} = json_frame(Sock, B2),
        %% (events of different pages come from different processes: no order)
        ?assertEqual(lists:sort([#{~"page" => B, ~"event" => ~"b", ~"data" => ~"for b"},
                                 #{~"page" => A, ~"event" => ~"a", ~"data" => ~"for a"},
                                 #{~"page" => C, ~"event" => ~"c", ~"data" => ~"for c"}]),
                     lists:sort([M1, M2, M3])),
        %% every page is attached to this one process
        {ok, #{transport := T1}} = weberl_live:info(A),
        ?assertMatch({ok, #{transport := T1}}, weberl_live:info(B)),
        ?assertMatch({ok, #{transport := T1}}, weberl_live:info(C))
    end).

unsubscribe() ->
    with_ws(["/two", "/two"], fun(Sock, Buf, [{A, _}, {B, _}]) ->
        send(Sock, #{op => unsubscribe, page => A}),
        await_state(A, detached),
        ok = weberl_live:push(A, <<"gone">>, <<"x">>),   % buffered for a later attach
        ok = weberl_live:push(B, <<"kept">>, <<"y">>),
        {M, _} = json_frame(Sock, Buf),
        ?assertEqual(#{~"page" => B, ~"event" => ~"kept", ~"data" => ~"y"}, M),
        ?assertMatch({ok, #{state := detached, buffered := 1}}, weberl_live:info(A)),
        %% unsubscribing an unknown page is harmless
        send(Sock, #{op => unsubscribe, page => <<"nope">>})
    end).

page_closed() ->
    with_ws(["/two", "/two"], fun(Sock, Buf, [{A, _}, {B, _}]) ->
        weberl_live:close(A),
        {M, Buf1} = json_frame(Sock, Buf),
        ?assertEqual(#{~"page" => A, ~"closed" => ~"closed"}, M),
        %% the socket and the other page carry on
        ok = weberl_live:push(B, <<"still">>, <<"here">>),
        {M2, _} = json_frame(Sock, Buf1),
        ?assertEqual(#{~"page" => B, ~"event" => ~"still", ~"data" => ~"here"}, M2)
    end).

replaced() ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        {Sock1, B1, [{A, TokenA}, {B, _}]} = open(Name, ["/two", "/two"]),
        {ok, Sock2, B2} = ws_connect(Name, []),
        B2a = subscribe(Sock2, B2, {A, TokenA}),
        %% the first socket loses page A only
        {M, B1a} = json_frame(Sock1, B1),
        ?assertEqual(#{~"page" => A, ~"closed" => ~"replaced"}, M),
        ok = weberl_live:push(A, <<"n">>, <<"for second">>),
        ok = weberl_live:push(B, <<"m">>, <<"for first">>),
        {M2, _} = json_frame(Sock2, B2a),
        ?assertEqual(~"for second", maps:get(~"data", M2)),
        {M3, _} = json_frame(Sock1, B1a),
        ?assertEqual(#{~"page" => B, ~"event" => ~"m", ~"data" => ~"for first"}, M3),
        gen_tcp:close(Sock1),
        gen_tcp:close(Sock2)
    end).

detaches() ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        {Sock, _, [{A, _}, {B, _}]} = open(Name, ["/two", "/two"]),
        ws_close(Sock),
        await_state(A, detached),
        await_state(B, detached),
        {Sock2, _, [{C, _}]} = open(Name, ["/two"]),
        gen_tcp:close(Sock2),
        await_state(C, detached)
    end).

binary_frames() ->
    with_ws(["/two"], fun(Sock, Buf, _) ->
        ok = ws_send(Sock, binary, <<1, 2, 3>>),
        ?assertMatch({{close, <<1003:16, _/binary>>}, _}, ws_recv(Sock, Buf))
    end).

subscribe_deadline() ->
    application:set_env(weberl, live_subscribe_timeout, 150),
    try
        with_router(weberl_live_test_util:request_routes(), fun(Name) ->
            {ok, Sock, Buf} = ws_connect(Name, []),
            ?assertMatch({{close, <<1008:16, _/binary>>}, _}, ws_recv(Sock, Buf)),
            gen_tcp:close(Sock),
            %% a socket that subscribed in time is left alone
            {Sock2, Buf2, [{Id, _}]} = open(Name, ["/two"]),
            timer:sleep(300),
            ok = weberl_live:push(Id, <<"late">>, <<"ok">>),
            {M, _} = json_frame(Sock2, Buf2),
            ?assertEqual(~"late", maps:get(~"event", M)),
            gen_tcp:close(Sock2)
        end)
    after
        application:unset_env(weberl, live_subscribe_timeout)
    end.

router_stop() ->
    with_router(weberl_live_test_util:request_routes(), fun(Name) ->
        {Sock, Buf, [{A, _}, {B, _}]} = open(Name, ["/two", "/two"]),
        ok = weberl:stop(Name),
        {M1, B1} = json_frame(Sock, Buf),
        {M2, _} = json_frame(Sock, B1),
        ?assertEqual(lists:sort([#{~"page" => A, ~"closed" => ~"closed"},
                                 #{~"page" => B, ~"closed" => ~"closed"}]),
                     lists:sort([M1, M2])),
        ?assertEqual({error, not_found}, weberl_live:whereis(A)),
        gen_tcp:close(Sock)
    end).
