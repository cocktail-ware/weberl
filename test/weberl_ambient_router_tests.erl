%% The router a handler runs under: `weberl_url:router_path/1,2' works in handler code
%% (a redirect target, a live page's post/2) without naming the router, and
%% `with_router/2' takes a router name or a route table.
-module(weberl_ambient_router_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util, [handler/1, with_router/2, request/5]).

http_test_() ->
    {setup,
     fun weberl_live_test_util:start_apps/0,
     fun(_) -> ok end,
     [{"a handler checks a path without naming its router", fun handler_checks_a_path/0},
      {"a typo in a handler is an unknown route", fun handler_unknown_route/0},
      {"a live page's handler checks a path", fun live_post_checks_a_path/0},
      {"the ambient router is gone after the request", fun ambient_cleared/0}]}.

%% A handler that redirects to a checked path, or reports what failed.
redirecting() ->
    handler("handle(_) -> "
            "  try weberl_url:router_path(\"/target\") of T -> weberl_response:redirect(T) "
            "  catch error:{template_error, R} -> weberl_response:text(500, io_lib:format(\"~p\", [R])) end.").

routes() ->
    [{"/go", redirecting(), #{csrf => false}},
     {"/typo", handler("handle(_) -> "
                       "  try weberl_url:router_path(\"/missing\") "
                       "  catch error:{template_error, R} -> weberl_response:text(500, io_lib:format(\"~p\", [R])) end."),
      #{csrf => false}},
     {"/target", handler("handle(_) -> weberl_response:text(200, <<\"here\">>).")},
     {"/live", handler("handle(_) -> weberl_response:redirect(weberl_url:router_path(\"/target\"))."),
      #{live => one_way, csrf => false}},
     {"/amb", handler("handle(_) -> weberl_response:text(200, io_lib:format(\"~p\", [weberl_url:ambient_router()])).")}].

%% httpc follows redirects by default; the tests want to see the 303 itself.
no_redirect(Name, Path) ->
    Url = weberl_live_test_util:url(Name, Path),
    {ok, {{_, Status, _}, Headers, Body}} =
        httpc:request(post, {Url, [], "text/plain", <<"x">>}, [{autoredirect, false}],
                      [{body_format, binary}]),
    {Status, Headers, Body}.

handler_checks_a_path() ->
    with_router(routes(), fun(Name) ->
        {Status, Headers, _} = no_redirect(Name, "/go"),
        ?assertEqual(303, Status),
        ?assertEqual("/target", proplists:get_value("location", Headers))
    end).

handler_unknown_route() ->
    with_router(routes(), fun(Name) ->
        {Status, _, Body} = request(Name, post, "/typo", [], {"text/plain", <<"x">>}),
        ?assertEqual(500, Status),
        ?assertEqual(<<"{unknown_route,<<\"/missing\">>}">>, Body)
    end).

live_post_checks_a_path() ->
    with_router(routes(), fun(Name) ->
        {Status, Headers, _} = no_redirect(Name, "/live"),
        ?assertEqual(303, Status),
        ?assertEqual("/target", proplists:get_value("location", Headers))
    end).

ambient_cleared() ->
    with_router(routes(), fun(Name) ->
        {200, _, _} = request(Name, get, "/amb", [], undefined),
        ?assertEqual(undefined, weberl_url:ambient_router())
    end).

%% ---------------------------------------------------------------------

table() ->
    Routes = [weberl_route:new(P, weberl_test_handlers, declarative, weberl_test_handlers)
              || P <- ["/a", "/b"]],
    {ok, T} = weberl_table:assemble([], Routes),
    T.

with_router_takes_a_table_test() ->
    T = table(),
    weberl_url:with_router(T, fun() ->
        ?assertEqual(<<"/a">>, weberl_url:data(weberl_url:router_path("/a"))),
        ?assertError({template_error, {unknown_route, <<"/c">>}}, weberl_url:router_path("/c"))
    end),
    ?assertEqual(undefined, weberl_url:ambient_router()).

the_router_option_takes_a_table_test() ->
    ?assertEqual(<<"/b">>, weberl_url:data(weberl_url:router_path("/b", #{router => table()}))).

a_table_replaces_a_name_test() ->
    weberl_url:with_router(nobody, fun() ->
        weberl_url:with_router(table(), fun() ->
            ?assertEqual(<<"/a">>, weberl_url:data(weberl_url:router_path("/a")))
        end),
        ?assertError({template_error, {router_not_running, nobody}}, weberl_url:router_path("/a"))
    end).

a_bad_router_is_refused_test() ->
    ?assertError(function_clause, weberl_url:with_router("x", fun() -> ok end)),
    ?assertError({template_error, {bad_url_option, {router, "x"}}},
                 weberl_url:router_path("/a", #{router => "x"})).
