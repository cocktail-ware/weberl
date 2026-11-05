%% Integration through the fixture consuming application in
%% fixtures/demo_app: compiled with ordinary compile:file/2 (no custom
%% options), then routed through the public API.
-module(weberl_integration_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_test_util, [with_tmp/1, fixture_dir/1]).

fixture_compiles_and_routes_test() ->
    with_tmp(fun(Out) ->
        App = fixture_dir("demo_app"),
        Sources = lists:sort(filelib:wildcard(filename:join([App, "src", "**", "*.erl"]))),
        ?assertEqual(7, length(Sources)),
        lists:foreach(
          fun(File) ->
                  ?assertMatch({ok, _}, compile:file(File, [return_errors, {outdir, Out}]))
          end, Sources),
        true = code:add_patha(Out),
        {ok, T} = demo_app:table(App),
        Pairs = [{weberl_route:path(R), weberl_route:handler(R), weberl_route:origin(R)}
                 || R <- weberl:routes(T)],
        ?assertEqual([{"/", home_view, filesystem},
                      {"/about", company_information_view, filesystem},
                      {"/api/posts", generic_api_handler, declarative},
                      {"/api/users", generic_api_handler, declarative},
                      {"/blog", blog_view, filesystem},
                      {"/blog/posts", posts_view, filesystem},
                      {"/health", health_handler, declarative},
                      {"/users", users_view, filesystem}], Pairs),
        ?assertEqual([{"/about", legacy_about_handler}],
                     [{weberl_route:path(S), weberl_route:handler(S)}
                      || S <- weberl:shadowed(T)]),
        ?assertEqual({ok, posts_view}, weberl:handler("/blog/posts", T)),
        true = code:del_path(Out)
    end).
