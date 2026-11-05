%% Router lifecycle and the Roadrunner adapter, with real HTTP over loopback on
%% ephemeral ports. Requires roadrunner (test profile).
-module(weberl_router_server_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router, listener]).
-on_load(ensure_records/0).

-export([init/1]).

-import(weberl_test_util, [with_tmp/1, write_tree/2, load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

%% ---------------------------------------------------------------------
%% helpers

setup_all() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(roadrunner),
    ok.

teardown_all(_) -> ok.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

router_name() -> weberl_test_handlers:unique("rt").

listener() -> #listener{port = 0, ip = {127, 0, 0, 1}}.

decl_router(Routes) ->
    M = weberl_test_handlers:unique("rtr"),
    load_router(M, Routes),
    #router{modules = [M]}.

get(Name, Path) -> request(get, Name, Path, [], <<>>).

request(Method, Name, Path, Headers, Body) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    Req = case Method of
              get -> {Url, Headers};
              _ -> {Url, Headers, "text/plain", Body}
          end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Req, [], [{body_format, binary}]),
    {Status, RespHeaders, RespBody}.

listener_name(Name) -> list_to_atom("weberl_listener_" ++ atom_to_list(Name)).

assert_stopped(Name) ->
    ?assertEqual(undefined, whereis(Name)),
    ?assertEqual({error, not_running}, weberl:table(Name)),
    ?assertNot(lists:member(listener_name(Name), roadrunner:listeners())).

quiet(Fun) ->
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, maps:get(level, Old)) end.

%% Start expecting failure, as a supervisor would (trapping exits).
start_failing(Name, Router, Listener) ->
    Trap = process_flag(trap_exit, true),
    try
        quiet(fun() ->
                      R = weberl:start_link(Name, Router, Listener),
                      receive {'EXIT', _, _} -> ok after 200 -> ok end,
                      R
              end)
    after
        process_flag(trap_exit, Trap)
    end.

%% ---------------------------------------------------------------------
%% HTTP end to end

http_test_() ->
    {setup, fun setup_all/0, fun teardown_all/1,
     [{"declarative routes, 404, 500, status and headers", fun declarative_end_to_end/0},
      {"filesystem views", fun filesystem_end_to_end/0},
      {"request conversion over the wire", fun request_conversion/0},
      {"binary and text bodies", fun body_kinds/0},
      {"stop releases the listener; restart works", fun stop_and_restart/0},
      {"multiple routers with distinct names", fun multiple_routers/0},
      {"under a supervisor via child_spec", fun supervised/0},
      {"killed router is replaced without a name clash", fun killed_and_restarted/0},
      {"startup failures leave nothing behind", fun failures_leave_nothing/0},
      {"port in use", fun port_in_use/0}]}.

declarative_end_to_end() ->
    Ok = handler("ok", "handle(_) -> weberl_response:html(200, <<\"<b>ok</b>\">>)."),
    Made = handler("made",
                   "handle(_) -> weberl_response:with_header("
                   "weberl_response:text(201, <<\"created\">>), \"x-custom\", \"yes\")."),
    Boom = handler("boom", "handle(_) -> erlang:error(secret_boom)."),
    Name = router_name(),
    {ok, _} = weberl:start_link(Name, decl_router([{"/ok", Ok}, {"/made", Made},
                                                    {"/boom", Boom}]), listener()),
    try
        {200, H1, B1} = get(Name, "/ok"),
        ?assertEqual(<<"<b>ok</b>">>, B1),
        ?assertEqual("text/html; charset=utf-8", proplists:get_value("content-type", H1)),
        {201, H2, B2} = get(Name, "/made"),
        ?assertEqual(<<"created">>, B2),
        ?assertEqual("yes", proplists:get_value("x-custom", H2)),
        ?assertMatch({404, _, <<"Not Found">>}, get(Name, "/nope")),
        {500, _, B5} = quiet(fun() -> get(Name, "/boom") end),
        ?assertEqual(<<"Internal Server Error">>, B5),
        ?assertMatch({200, _, <<"<b>ok</b>">>}, get(Name, "/ok/")),
        {ok, Table} = weberl:table(Name),
        ?assertEqual(["/boom", "/made", "/ok"],
                     [weberl_route:path(R) || R <- weberl:routes(Table)])
    after
        weberl:stop(Name)
    end,
    assert_stopped(Name).

filesystem_end_to_end() ->
    with_tmp(fun(Dir) ->
        Home = atom_to_list(weberl_test_handlers:unique("home")) ++ "_view",
        About = atom_to_list(weberl_test_handlers:unique("about")) ++ "_view",
        HomeFile = Home ++ ".erl",
        AboutFile = filename:join("about", About ++ ".erl"),
        write_tree(Dir, [{HomeFile, view_src(Home, "home page")},
                         {AboutFile, view_src(About, "about page")}]),
        [compile_load(filename:join(Dir, F)) || F <- [HomeFile, AboutFile]],
        Name = router_name(),
        {ok, _} = weberl:start_link(
                    Name, #router{filesystem = [#filesystem_router{root = Dir}]}, listener()),
        try
            ?assertMatch({200, _, <<"home page">>}, get(Name, "/")),
            ?assertMatch({200, _, <<"about page">>}, get(Name, "/about")),
            ?assertMatch({404, _, _}, get(Name, "/missing"))
        after
            weberl:stop(Name)
        end
    end).

view_src(Module, Text) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, <<\"~s\">>).~n",
                    [Module, Text])).

compile_load(File) ->
    {ok, Mod, Bin} = compile:file(File, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, File, Bin),
    ok.

request_conversion() ->
    Echo = handler("echo", """
        handle(R) ->
            {ok, Body} = weberl_request:read_body(R),
            {ok, QP} = weberl_request:query_params(R),
            {ok, H} = weberl_request:header(R, <<"x-test">>),
            {IP, _Port} = weberl_request:peer(R),
            Meta = weberl_request:meta(R),
            Out = io_lib:format("~s|~s|~p|~s|~s|~w|~w|~w",
                    [weberl_request:method(R), weberl_request:path(R), QP, H, Body,
                     IP, maps:get(adapter, Meta), weberl_request:params(R)]),
            weberl_response:text(200, Out).
        """),
    Name = router_name(),
    {ok, _} = weberl:start_link(Name, decl_router([{"/echo", Echo, #{csrf => false}}]), listener()),
    try
        {200, _, Out} = request(post,Name, "/echo?a=1&b=x%20y", [{"X-Test", "val"}], <<"payload">>),
        ?assertEqual(<<"POST|/echo|[{<<\"a\">>,<<\"1\">>},{<<\"b\">>,<<\"x y\">>}]|val|payload|"
                       "{127,0,0,1}|weberl_roadrunner|#{}">>, Out),
        {200, _, Out2} = request(get, Name, "/echo", [{"x-test", "v2"}], <<>>),
        ?assertMatch(<<"GET|/echo|[]|v2||", _/binary>>, Out2)
    after
        weberl:stop(Name)
    end.

body_kinds() ->
    Bin = handler("bin", "handle(_) -> weberl_response:binary(200, <<0, 255, 1>>)."),
    Txt = handler("txt", "handle(_) -> weberl_response:text(200, [<<\"he\">>, \"llo\"])."),
    Name = router_name(),
    {ok, _} = weberl:start_link(Name, decl_router([{"/bin", Bin}, {"/txt", Txt}]), listener()),
    try
        {200, H1, B1} = get(Name, "/bin"),
        ?assertEqual(<<0, 255, 1>>, B1),
        ?assertEqual("application/octet-stream", proplists:get_value("content-type", H1)),
        {200, H2, B2} = get(Name, "/txt"),
        ?assertEqual(<<"hello">>, B2),
        ?assertEqual("text/plain; charset=utf-8", proplists:get_value("content-type", H2))
    after
        weberl:stop(Name)
    end.

stop_and_restart() ->
    Ok = handler("ok", "handle(_) -> weberl_response:text(200, <<\"up\">>)."),
    Name = router_name(),
    Router = decl_router([{"/", Ok}]),
    {ok, _} = weberl:start_link(Name, Router, listener()),
    ?assertMatch({200, _, <<"up">>}, get(Name, "/")),
    Port = weberl:port(Name),
    ok = weberl:stop(Name),
    assert_stopped(Name),
    %% new connections are refused (connections already open are not closed)
    ?assertEqual({error, econnrefused}, gen_tcp:connect({127, 0, 0, 1}, Port, [], 1000)),
    {ok, _} = weberl:start_link(Name, Router, listener()),
    try
        ?assertMatch({200, _, <<"up">>}, get(Name, "/"))
    after
        weberl:stop(Name)
    end,
    assert_stopped(Name).

multiple_routers() ->
    A = handler("a", "handle(_) -> weberl_response:text(200, <<\"A\">>)."),
    B = handler("b", "handle(_) -> weberl_response:text(200, <<\"B\">>)."),
    N1 = router_name(),
    N2 = router_name(),
    {ok, _} = weberl:start_link(N1, decl_router([{"/x", A}]), listener()),
    {ok, _} = weberl:start_link(N2, decl_router([{"/x", B}]), listener()),
    try
        ?assertNotEqual(weberl:port(N1), weberl:port(N2)),
        ?assertMatch({200, _, <<"A">>}, get(N1, "/x")),
        ?assertMatch({200, _, <<"B">>}, get(N2, "/x")),
        weberl:stop(N1),
        assert_stopped(N1),
        ?assertMatch({200, _, <<"B">>}, get(N2, "/x"))
    after
        stop_if_running(N1),
        weberl:stop(N2)
    end.

%% supervisor callback
init([Spec]) -> {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Spec]}}.

supervised() ->
    Ok = handler("ok", "handle(_) -> weberl_response:text(200, <<\"sup\">>)."),
    Name = router_name(),
    Spec = weberl:child_spec(Name, decl_router([{"/", Ok}]), listener()),
    ?assertMatch(#{id := Name, restart := permanent, type := worker}, Spec),
    {ok, Sup} = supervisor:start_link(?MODULE, [Spec]),
    try
        ?assertMatch({200, _, <<"sup">>}, get(Name, "/")),
        ok = supervisor:terminate_child(Sup, Name),
        assert_stopped(Name)
    after
        unlink(Sup),
        exit(Sup, shutdown),
        wait_down(Sup)
    end.

killed_and_restarted() ->
    Ok = handler("ok", "handle(_) -> weberl_response:text(200, <<\"again\">>)."),
    Name = router_name(),
    {ok, Sup} = supervisor:start_link(
                  ?MODULE, [weberl:child_spec(Name, decl_router([{"/", Ok}]), listener())]),
    try
        Pid1 = whereis(Name),
        ?assertMatch({200, _, <<"again">>}, get(Name, "/")),
        quiet(fun() ->
                      exit(Pid1, kill),
                      wait_until(fun() ->
                                         P = whereis(Name),
                                         is_pid(P) andalso P =/= Pid1
                                 end)
              end),
        %% the stale listener was replaced, not duplicated
        ?assertEqual([listener_name(Name)],
                     [L || L <- roadrunner:listeners(), L =:= listener_name(Name)]),
        ?assertMatch({200, _, <<"again">>}, get(Name, "/"))
    after
        unlink(Sup),
        exit(Sup, shutdown),
        wait_down(Sup)
    end,
    assert_stopped(Name).

failures_leave_nothing() ->
    Before = lists:sort(roadrunner:listeners()),
    Mod = weberl_test_handlers:unique("nohandler"),
    weberl_test_handlers:load(Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([other/0]). other() -> ok."),
    Cases =
        [{"invalid router", {invalid_config, {not_a_router, nope}}, nope, listener()},
         {"invalid listener",
          {invalid_config, {listener, {invalid_port, 70000}}},
          decl_router([]), #listener{port = 70000}},
         {"handler without handle/1",
          {invalid_handlers, [{invalid_handler, Mod, missing_callback_handle_1}]},
          decl_router([{"/x", Mod}]), listener()},
         {"handler not loadable",
          {invalid_handlers, [{invalid_handler, no_such_weberl_handler_mod,
                               {not_loadable, nofile}}]},
          decl_router([{"/y", no_such_weberl_handler_mod}]), listener()}],
    lists:foreach(
      fun({Label, Expected, Router, Listener}) ->
              Name = router_name(),
              Result = start_failing(Name, Router, Listener),
              ?assertMatch({error, _}, Result),
              {error, Reason} = Result,
              ?assertMatch({Label, Expected}, {Label, normalize_reason(Reason)}),
              assert_stopped(Name),
              ?assertEqual(Before, lists:sort(roadrunner:listeners()))
      end, Cases).

normalize_reason({invalid_handlers, Errors}) ->
    {invalid_handlers,
     [case E of
          {invalid_handler, M, {not_loadable, _}} -> {invalid_handler, M, {not_loadable, nofile}};
          Other -> Other
      end || E <- Errors]};
normalize_reason(Other) -> Other.

port_in_use() ->
    Ok = handler("ok", "handle(_) -> weberl_response:text(200, <<\"first\">>)."),
    A = router_name(),
    B = router_name(),
    {ok, _} = weberl:start_link(A, decl_router([{"/", Ok}]), listener()),
    try
        Port = weberl:port(A),
        Result = start_failing(B, decl_router([{"/", Ok}]),
                               #listener{port = Port, ip = {127, 0, 0, 1}}),
        ?assertMatch({error, {listener_start_failed, _}}, Result),
        assert_stopped(B),
        ?assertMatch({200, _, <<"first">>}, get(A, "/")),
        %% same router name twice
        Trap = process_flag(trap_exit, true),
        try
            ?assertMatch({error, {already_started, _}},
                         weberl:start_link(A, decl_router([{"/", Ok}]), listener()))
        after
            process_flag(trap_exit, Trap)
        end,
        ?assertMatch({200, _, <<"first">>}, get(A, "/"))
    after
        weberl:stop(A)
    end.

invalid_name_test() ->
    ?assertEqual({error, {invalid_router_name, "nope"}},
                 weberl:start_link("nope", #router{}, #listener{port = 0})).

%% ---------------------------------------------------------------------
%% Request/response conversion without a network

convert_request_test() ->
    Req = #{method => <<"PUT">>, target => <<"/a/b?x=1">>, path => <<"/a/b">>,
            version => {1, 1},
            headers => [{<<"host">>, <<"h">>}, {<<"x-k">>, <<"v">>}],
            body => [<<"he">>, <<"llo">>],
            peer => {{10, 0, 0, 1}, 4444}},
    W = weberl_roadrunner_convert:request(Req),
    ?assertEqual(<<"PUT">>, weberl_request:method(W)),
    ?assertEqual("/a/b", weberl_request:path(W)),
    ?assertEqual(<<"x=1">>, weberl_request:query(W)),
    ?assertEqual({ok, <<"v">>}, weberl_request:header(W, "x-k")),
    ?assertEqual({{10, 0, 0, 1}, 4444}, weberl_request:peer(W)),
    ?assertEqual(#{}, weberl_request:params(W)),
    ?assertEqual({ok, <<"hello">>}, weberl_request:read_body(W)),
    ?assertEqual(weberl_roadrunner, maps:get(adapter, weberl_request:meta(W))).

convert_non_utf8_path_test() ->
    Req = #{method => <<"GET">>, target => <<"/\xff">>, path => <<"/\xff">>,
            version => {1, 1}, headers => []},
    W = weberl_roadrunner_convert:request(Req),
    ?assertEqual([$/, 255], weberl_request:path(W)).

convert_response_test() ->
    R = weberl_response:with_header(weberl_response:html(202, <<"b">>), "X-A", "1"),
    ?assertEqual({202, [{<<"x-a">>, <<"1">>}, {<<"content-type">>, <<"text/html; charset=utf-8">>}],
                  <<"b">>},
                 weberl_roadrunner_convert:response(R)).

%% ---------------------------------------------------------------------
%% Adapter options and availability

adapter_validate_options_test_() ->
    [?_assertEqual(ok, weberl_roadrunner:validate_options(#{})),
     ?_assertEqual(ok, weberl_roadrunner:validate_options(
                         #{max_content_length => 0, request_timeout => 10, tls => [],
                           protocols => [http1, http2]})),
     ?_assertEqual({error, {unknown_options, [port]}},
                   weberl_roadrunner:validate_options(#{port => 1})),
     ?_assertEqual({error, {invalid_option, request_timeout, -5}},
                   weberl_roadrunner:validate_options(#{request_timeout => -5})),
     ?_assertEqual({error, {options_not_a_map, []}}, weberl_roadrunner:validate_options([]))].

%% ---------------------------------------------------------------------
%% Application start makes native records constructible

app_loads_records_test() ->
    _ = application:stop(weberl),
    code:purge(weberl_config),
    code:delete(weberl_config),
    code:purge(weberl_config),
    ?assertEqual(false, code:is_loaded(weberl_config)),
    {ok, _} = application:ensure_all_started(weberl),
    try
        ?assertMatch({file, _}, code:is_loaded(weberl_config)),
        ?assertMatch({ok, _}, weberl_config:validate_listener(#listener{port = 1}))
    after
        application:stop(weberl)
    end.

%% ---------------------------------------------------------------------

stop_if_running(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _ -> weberl:stop(Name)
    end.

wait_until(Fun) -> wait_until(Fun, 100).
wait_until(Fun, 0) -> ?assert(Fun());
wait_until(Fun, N) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Fun, N - 1)
    end.

wait_down(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, _, _, _} -> ok after 5000 -> error(timeout) end.
