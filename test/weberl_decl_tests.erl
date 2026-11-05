-module(weberl_decl_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_test_util, [unique/1, load_router/2, load_crashing_router/1,
                           load_plain_module/1]).

pairs(Routes) ->
    [{weberl_route:path(R), weberl_route:handler(R)} || R <- Routes].

ok_router_test() ->
    M = unique("decl_ok"),
    load_router(M, [{"/health", health_handler},
                    {"/api/users", generic_api_handler},
                    {"/api/posts", generic_api_handler}]),
    {ok, Rs} = weberl_decl:collect([M]),
    ?assertEqual([{"/health", health_handler},
                  {"/api/users", generic_api_handler},
                  {"/api/posts", generic_api_handler}], pairs(Rs)),
    [R | _] = Rs,
    ?assertEqual(declarative, weberl_route:origin(R)),
    ?assertEqual(M, weberl_route:source(R)).

paths_are_normalized_test() ->
    M = unique("decl_norm"),
    load_router(M, [{"/a/b/", h}]),
    {ok, Rs} = weberl_decl:collect([M]),
    ?assertEqual([{"/a/b", h}], pairs(Rs)).

multiple_modules_in_order_test() ->
    M1 = unique("decl_m1"),
    M2 = unique("decl_m2"),
    load_router(M1, [{"/one", h1}]),
    load_router(M2, [{"/two", h2}]),
    {ok, Rs} = weberl_decl:collect([M2, M1]),
    ?assertEqual([{"/two", h2}, {"/one", h1}], pairs(Rs)).

no_modules_test() ->
    ?assertEqual({ok, []}, weberl_decl:collect([])).

invalid_path_test() ->
    M = unique("decl_badpath"),
    load_router(M, [{"nope", h}]),
    ?assertEqual({error, {invalid_route, M, {"nope", h}, {invalid_path, must_start_with_slash}}},
                 weberl_decl:collect([M])).

invalid_handler_test() ->
    M = unique("decl_badhandler"),
    load_router(M, [{"/a", "not_an_atom"}]),
    ?assertMatch({error, {invalid_route, M, {"/a", "not_an_atom"}, {invalid_handler, _}}},
                 weberl_decl:collect([M])).

malformed_entry_test() ->
    M = unique("decl_malformed"),
    load_router(M, [foo]),
    ?assertEqual({error, {invalid_route, M, foo, malformed_entry}}, weberl_decl:collect([M])).

routes_not_a_list_test() ->
    M = unique("decl_notlist"),
    load_router(M, not_a_list),
    ?assertEqual({error, {invalid_routes_return, M, not_a_list}}, weberl_decl:collect([M])).

crashing_router_test() ->
    M = unique("decl_crash"),
    load_crashing_router(M),
    ?assertMatch({error, {routes_failed, M, {error, boom}}}, weberl_decl:collect([M])).

missing_routes_function_test() ->
    M = unique("decl_noroutes"),
    load_plain_module(M),
    ?assertEqual({error, {missing_routes_function, M}}, weberl_decl:collect([M])).

module_not_found_test() ->
    ?assertMatch({error, {router_module_not_loadable, weberl_no_such_module, _}},
                 weberl_decl:collect([weberl_no_such_module])).
