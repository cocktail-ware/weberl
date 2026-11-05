%% Live pages over real HTTP: beacon injection, client.js, SSE stream, and the
%% credentials every live endpoint requires.
-module(weberl_live_http_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util,
        [page_handler/0, with_router/2, get/2, request/5, new_page/1, has/2,
         await_state/2, open_stream/3, read_until/3, await_end/1]).

http_test_() ->
    {setup,
     fun weberl_live_test_util:start_apps/0,
     fun(_) -> ok end,
     [{"page carries the beacon; client.js is served", fun page_and_script/0},
      {"events stream to the browser over SSE", fun sse_stream/0},
      {"events pushed before the stream connects arrive on connect", fun sse_buffered/0},
      {"unknown page, wrong method", fun sse_errors/0},
      {"token is required and bound to the page", fun token_required/0},
      {"cross-origin browser requests are refused", fun origin_checked/0},
      {"client disconnect detaches the session", fun sse_disconnect/0},
      {"stopping the router ends the stream", fun stop_ends_stream/0},
      {"a second stream replaces the first", fun second_stream_replaces/0}]}.

%% ---------------------------------------------------------------------

live_routes() ->
    [{"/live", page_handler(), #{live => one_way}}].

page_and_script() ->
    H = page_handler(),
    with_router([{"/live", H, #{live => one_way}}, {"/plain", H}], fun(Name) ->
        {200, _, Page} = get(Name, "/live"),
        ?assert(has(Page, <<"<script src=\"/_weberl/engine.js\" defer></script>"
                            "<script src=\"/_weberl/client.js\"">>)),
        ?assert(has(Page, <<"data-weberl-token=\"">>)),
        ?assert(has(Page, <<"data-weberl-fallback=\"poll\"">>)),
        ?assert(has(Page, <<"</script></body></html>">>)),
        {200, _, Plain} = get(Name, "/plain"),
        ?assertNot(has(Plain, <<"<script">>)),
        {200, Headers, Js} = get(Name, "/_weberl/client.js"),
        ?assertMatch("text/javascript" ++ _, proplists:get_value("content-type", Headers)),
        ?assert(has(Js, <<"window.Weberl">>)),
        {200, EngineHeaders, Engine} = get(Name, "/_weberl/engine.js"),
        ?assertMatch("text/javascript" ++ _, proplists:get_value("content-type", EngineHeaders)),
        ?assert(has(Engine, <<"WeberlEngine">>))
    end).

sse_stream() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        {Sock, Head, Rest} = open_stream(Name, Id, Token),
        ?assert(has(Head, <<"HTTP/1.1 200">>)),
        ?assert(has(Head, <<"text/event-stream">>)),
        await_state(Id, attached),
        ok = weberl_live:push(Id, <<"tick">>, <<"one">>),
        ok = weberl_live:push(Id, <<"tock">>, <<"two\nlines">>),
        {ok, Data} = read_until(Sock, Rest, <<"lines">>),
        ?assert(has(Data, <<"retry: 2000">>)),
        %% unnamed messages carrying the JSON event (newlines are escaped)
        ?assert(has(Data, <<"data: {\"data\":\"one\",\"event\":\"tick\"}\n\n">>)),
        ?assert(has(Data, <<"data: {\"data\":\"two\\nlines\",\"event\":\"tock\"}\n\n">>)),
        gen_tcp:close(Sock)
    end).

sse_buffered() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        ok = weberl_live:push(Id, <<"early">>, <<"x">>),
        {Sock, _, Rest} = open_stream(Name, Id, Token),
        {ok, Data} = read_until(Sock, Rest, <<"\"early\"">>),
        ?assert(has(Data, <<"\"data\":\"x\"">>)),
        gen_tcp:close(Sock)
    end).

sse_errors() ->
    with_router(live_routes(), fun(Name) ->
        %% a valid token for an id that is not a session: 404
        Ghost = <<"ghost-page-id">>,
        GhostPath = "/_weberl/sse/" ++ binary_to_list(Ghost) ++ "?t=" ++
            binary_to_list(weberl_live_guard:issue(Ghost, [sse])),
        ?assertMatch({404, _, _}, get(Name, GhostPath)),
        {Id, Token} = new_page(Name),
        Path = "/_weberl/sse/" ++ binary_to_list(Id) ++ "?t=" ++ binary_to_list(Token),
        {405, Headers, _} = request(Name, post, Path, [], {"text/plain", <<>>}),
        ?assertEqual("GET", proplists:get_value("allow", Headers))
    end).

token_required() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        {_Other, OtherToken} = new_page(Name),
        Base = "/_weberl/sse/" ++ binary_to_list(Id),
        %% missing, garbage, another page's token, a tampered token
        ?assertMatch({403, _, _}, get(Name, Base)),
        ?assertMatch({403, _, _}, get(Name, Base ++ "?t=garbage!")),
        ?assertMatch({403, _, _}, get(Name, Base ++ "?t=" ++ binary_to_list(OtherToken))),
        Tampered = flip(Token),
        ?assertMatch({403, _, _}, get(Name, Base ++ "?t=" ++ binary_to_list(Tampered))),
        %% an unknown page id is indistinguishable from a forged token
        ?assertMatch({403, _, _}, get(Name, "/_weberl/sse/unknown")),
        ?assertMatch({403, _, _}, get(Name, "/_weberl/sse/unknown?t=" ++ binary_to_list(Token))),
        %% the header works as well as the query parameter
        {Sock, Head, _} = raw_get(Name, Base, ["X-Weberl-Token: ", Token, "\r\n"], "localhost"),
        ?assert(has(Head, <<"200">>)),
        gen_tcp:close(Sock)
    end).

%% A different token of the same shape: change the first character (the last
%% one carries padding bits that the decoder ignores).
flip(<<First, Rest/binary>>) ->
    New = case First of $A -> $B; _ -> $A end,
    <<New, Rest/binary>>.

origin_checked() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        Path = "/_weberl/sse/" ++ binary_to_list(Id) ++ "?t=" ++ binary_to_list(Token),
        ?assertMatch({403, _, _}, request(Name, get, Path,
                                          [{"origin", "http://evil.example"}], undefined)),
        ?assertMatch({403, _, _}, request(Name, get, Path, [{"origin", "null"}], undefined)),
        %% same-origin browser request: Origin equals Host (httpc sends the port)
        Host = "127.0.0.1:" ++ integer_to_list(weberl:port(Name)),
        {Sock, Head, _} = raw_get(Name, Path, ["Origin: http://", Host, "\r\n"], Host),
        ?assert(has(Head, <<"200">>)),
        gen_tcp:close(Sock)
    end).

raw_get(Name, Path, Extra, Host) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, weberl:port(Name), [binary, {active, false}]),
    ok = gen_tcp:send(Sock, ["GET ", Path, " HTTP/1.1\r\nHost: ", Host, "\r\n", Extra, "\r\n"]),
    {ok, Head, Rest} = weberl_live_test_util:read_head(Sock, <<>>),
    {Sock, Head, Rest}.

sse_disconnect() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        {Sock, _, _} = open_stream(Name, Id, Token),
        await_state(Id, attached),
        gen_tcp:close(Sock),
        await_state(Id, detached)
    end).

stop_ends_stream() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        {Sock, _, _} = open_stream(Name, Id, Token),
        await_state(Id, attached),
        ok = weberl:stop(Name),
        ?assertEqual(ok, await_end(Sock)),
        ?assertEqual({error, not_found}, weberl_live:whereis(Id))
    end).

second_stream_replaces() ->
    with_router(live_routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        {First, _, _} = open_stream(Name, Id, Token),
        await_state(Id, attached),
        {Second, _, Rest} = open_stream(Name, Id, Token),
        ?assertEqual(ok, await_end(First)),
        ok = weberl_live:push(Id, <<"n">>, <<"for second">>),
        {ok, _} = read_until(Second, Rest, <<"for second">>),
        gen_tcp:close(Second)
    end).
