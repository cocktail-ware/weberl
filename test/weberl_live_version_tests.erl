%% The browser scripts declare their version (`v') when a connection starts;
%% the server logs a connection with another or no version, and serves the
%% shared hub script.
-module(weberl_live_version_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util,
        [with_router/2, get/2, new_page/1, has/2, connect/1, read_head/2, ws_connect/3,
         ws_close/1, request/5]).

version_test_() ->
    {setup,
     fun weberl_live_test_util:start_apps/0,
     fun(_) -> ok end,
     [{"the shared hub script is served", fun hub_script/0},
      {"the server's version is the engine's", fun engine_version/0},
      {"a stream declaring another or no version is logged", fun sse_versions/0},
      {"a socket without the version is logged", fun ws_version/0},
      {"requests carry no version and are not logged", fun request_not_checked/0}]}.

routes() -> [{"/live", weberl_live_test_util:page_handler(), #{live => one_way}}].

hub_script() ->
    with_router(routes(), fun(Name) ->
        {200, Headers, Js} = get(Name, "/_weberl/hub.js"),
        ?assertMatch("text/javascript" ++ _, proplists:get_value("content-type", Headers)),
        ?assert(has(Js, <<"WeberlEngine.serve">>))
    end).

engine_version() ->
    {ok, Engine} = file:read_file(filename:join(code:priv_dir(weberl), "engine.js")),
    ?assertMatch({match, _},
                 re:run(Engine, "var VERSION = " ++ integer_to_list(weberl_live:client_version()) ++ ";")).

%% The log reports (maps) the fun caused, as {What, Report}.
logged(Fun) ->
    Id = list_to_atom("ver_h_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(Id, weberl_test_log_handler, #{config => #{sink => Id}, level => warning}),
    register(Id, self()),
    Old = logger:get_primary_config(),
    ok = logger:set_primary_config(level, warning),
    try
        Fun(),
        timer:sleep(100),
        collect([])
    after
        logger:remove_handler(Id),
        unregister(Id),
        logger:set_primary_config(level, maps:get(level, Old))
    end.

collect(Acc) ->
    receive
        {log, #{msg := {report, #{what := live_client_version_mismatch} = R}}} -> collect([R | Acc])
    after 0 -> lists:reverse(Acc)
    end.

stream(Name, Id, Token, Extra) ->
    Sock = connect(Name),
    ok = gen_tcp:send(Sock, ["GET /_weberl/sse/", Id, "?t=", Token, Extra, " HTTP/1.1\r\n"
                             "Host: localhost\r\nAccept: text/event-stream\r\n\r\n"]),
    {ok, Head, _} = read_head(Sock, <<>>),
    ?assert(has(Head, <<"HTTP/1.1 200">>)),
    gen_tcp:close(Sock).

sse_versions() ->
    with_router(routes(), fun(Name) ->
        Expected = weberl_live:client_version(),
        Current = "&v=" ++ integer_to_list(Expected),
        Logged = logged(fun() ->
            [begin
                 {Id, Token} = new_page(Name),
                 stream(Name, Id, Token, Extra)
             end || Extra <- [Current, "&v=0", ""]]
        end),
        ?assertMatch([#{channel := sse, declared := ~"0", expected := Expected},
                      #{channel := sse, declared := undefined, expected := Expected}], Logged)
    end).

ws_version() ->
    with_router(routes(), fun(Name) ->
        Logged = logged(fun() ->
            [begin {ok, Sock, _} = ws_connect(Name, [], Query), ws_close(Sock) end
             || Query <- ["?v=1", "?v=7", ""]]
        end),
        ?assertMatch([#{channel := ws, declared := ~"7"},
                      #{channel := ws, declared := undefined}], Logged)
    end).

request_not_checked() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name),
        Logged = logged(fun() ->
            request(Name, post, "/_weberl/request/" ++ binary_to_list(Id),
                    [{"x-weberl-token", binary_to_list(Token)}],
                    {"application/json", ~"{\"request\":\"x\",\"data\":null}"})
        end),
        ?assertEqual([], Logged)
    end).
