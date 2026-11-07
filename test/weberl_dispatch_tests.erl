-module(weberl_dispatch_tests).
-include_lib("eunit/include/eunit.hrl").

load(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

req(Path) -> weberl_request:new(#{method => <<"GET">>, path => Path}).

table(Fs, Decl) ->
    {ok, T} = weberl_table:assemble(
                [weberl_route:new(P, M, filesystem, "f.erl") || {P, M} <- Fs],
                [weberl_route:new(P, M, declarative, router) || {P, M} <- Decl]),
    T.

success_and_mapping_test() ->
    A = load("a", "handle(_) -> weberl_response:html(200, <<\"A\">>)."),
    B = load("b", "handle(_) -> weberl_response:text(200, <<\"B\">>)."),
    T = table([{"/a", A}], [{"/b", B}]),
    RA = weberl_dispatch:dispatch(req("/a"), T),
    RB = weberl_dispatch:dispatch(req("/b"), T),
    ?assertEqual(<<"A">>, weberl_response:body(RA)),
    ?assertEqual(<<"B">>, weberl_response:body(RB)).

path_is_normalized_test() ->
    A = load("a", "handle(_) -> weberl_response:text(200, <<\"A\">>)."),
    T = table([{"/a", A}], []),
    ?assertEqual(200, weberl_response:status(weberl_dispatch:dispatch(req("//a/"), T))).

handler_receives_request_test() ->
    A = load("echo", "handle(R) -> weberl_response:text(200, weberl_request:path(R))."),
    T = table([{"/echo", A}], []),
    R = weberl_dispatch:dispatch(req("/echo"), T),
    ?assertEqual("/echo", binary_to_list(iolist_to_binary(weberl_response:body(R)))).

custom_status_and_headers_test() ->
    A = load("c", "handle(_) -> weberl_response:with_header("
                  "weberl_response:text(201, <<\"made\">>), \"x-k\", \"v\")."),
    R = weberl_dispatch:dispatch(req("/c"), table([{"/c", A}], [])),
    ?assertEqual(201, weberl_response:status(R)),
    ?assertEqual({ok, <<"v">>}, weberl_response:header(R, "x-k")).

not_found_test() ->
    T = table([], []),
    R = weberl_dispatch:dispatch(req("/nope"), T),
    ?assertEqual(404, weberl_response:status(R)),
    ?assertEqual(<<"Not Found">>, weberl_response:body(R)).

invalid_path_is_not_found_test() ->
    R = weberl_dispatch:dispatch(req("no-slash"), table([], [])),
    ?assertEqual(404, weberl_response:status(R)).

exception_is_500_without_leak_test_() ->
    {setup, fun mute/0, fun unmute/1,
     fun(_) ->
        [{Name,
          fun() ->
                  M = load("f", Body),
                  R = weberl_dispatch:dispatch(req("/f"), table([{"/f", M}], [])),
                  ?assertEqual(500, weberl_response:status(R)),
                  ?assertEqual(<<"Internal Server Error">>, weberl_response:body(R))
          end} || {Name, Body} <-
                      [{"error", "handle(_) -> erlang:error(secret_boom)."},
                       {"throw", "handle(_) -> throw(secret_boom)."},
                       {"exit", "handle(_) -> exit(secret_boom)."},
                       {"badmatch", "handle(_) -> {ok, _} = secret_boom, ok."}]]
     end}.

invalid_return_is_500_test_() ->
    {setup, fun mute/0, fun unmute/1,
     fun(_) ->
        [{Name,
          fun() ->
                  M = load("r", Body),
                  R = weberl_dispatch:dispatch(req("/r"), table([{"/r", M}], [])),
                  ?assertEqual(500, weberl_response:status(R))
          end} || {Name, Body} <-
                      [{"atom", "handle(_) -> ok."},
                       {"binary", "handle(_) -> <<\"raw\">>."},
                       {"tuple", "handle(_) -> {200, [], <<\"x\">>}."}]]
     end}.

unloadable_handler_is_500_test_() ->
    {setup, fun mute/0, fun unmute/1,
     fun(_) ->
        fun() ->
                T = table([{"/g", no_such_weberl_module}], []),
                ?assertEqual(500, weberl_response:status(weberl_dispatch:dispatch(req("/g"), T)))
        end
     end}.

failure_is_logged_with_context_test_() ->
    {setup,
     fun() ->
             ok = logger:add_handler(weberl_test_h, weberl_test_log_handler,
                                     #{config => #{sink => weberl_log_sink}, level => error}),
             Old = logger:get_primary_config(),
             ok = logger:set_primary_config(level, error),
             Old
     end,
     fun(Old) ->
             logger:remove_handler(weberl_test_h),
             logger:set_primary_config(level, maps:get(level, Old))
     end,
     fun(_) ->
             fun() ->
                     register(weberl_log_sink, self()),
                     M = load("l", "handle(_) -> erlang:error(logged)."),
                     weberl_dispatch:dispatch(req("/l"), table([{"/l", M}], [])),
                     receive
                         {log, #{msg := {report, #{what := handler_failure} = Rep}}} ->
                             ?assertEqual(M, maps:get(handler, Rep)),
                             ?assertEqual("/l", maps:get(path, Rep)),
                             ?assertEqual(<<"GET">>, maps:get(method, Rep)),
                             ?assertEqual(error, maps:get(class, Rep)),
                             ?assertEqual(logged, maps:get(reason, Rep)),
                             ?assert(is_list(maps:get(stacktrace, Rep)))
                     after 1000 ->
                             ?assert(false)
                     end,
                     unregister(weberl_log_sink)
             end
     end}.

mute() ->
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    Old.

unmute(Old) ->
    logger:set_primary_config(level, maps:get(level, Old)).

route_data_test() ->
    H = load("data", "handle(R) -> weberl_response:text(200, "
                     "atom_to_binary(maps:get(action, weberl_request:route_data(R), none)))."),
    Upd = weberl_route:new("/update", H, declarative, router, #{data => #{action => update}}),
    Del = weberl_route:new("/delete", H, declarative, router, #{data => #{action => delete}}),
    Plain = weberl_route:new("/plain", H, declarative, router),
    {ok, T} = weberl_table:assemble([], [Upd, Del, Plain]),
    Body = fun(P) -> weberl_response:body(weberl_dispatch:dispatch(req(P), T)) end,
    ?assertEqual(<<"update">>, Body("/update")),
    ?assertEqual(<<"delete">>, Body("/delete")),
    ?assertEqual(<<"none">>, Body("/plain")),
    %% a request that did not come through dispatch has none
    ?assertEqual(#{}, weberl_request:route_data(req("/x"))),
    ?assertEqual({ok, #{data => {any, [term]}}}, weberl_route:check_opts(#{data => {any, [term]}})).
