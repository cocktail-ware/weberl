%% Dynamic router paths (HANDOFF decisions 11 and 12): `/agents/:id' and a `[id]' directory,
%% matching with precedence, `weberl_request:params/1', the 400 for a malformed escape, and
%% links verified against routes with parameters.
-module(weberl_dynamic_paths_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_test_util, [with_tmp/1, write_tree/2, view_src/1]).

%% ---------------------------------------------------------------------
%% Patterns

normalize_pattern_test() ->
    ?assertEqual({ok, "/agents/:id"}, weberl_route:normalize_pattern("/agents/:id")),
    ?assertEqual({ok, "/a/:x/b/:y_2"}, weberl_route:normalize_pattern("//a/:x//b/:y_2/")),
    ?assertEqual({ok, "/"}, weberl_route:normalize_pattern("/")),
    ?assertEqual({ok, "/about"}, weberl_route:normalize_pattern("/about")).

invalid_patterns_are_errors_test() ->
    ?assertEqual({error, {invalid_parameter, ":"}}, weberl_route:normalize_pattern("/a/:")),
    ?assertEqual({error, {invalid_parameter, ":Id"}}, weberl_route:normalize_pattern("/a/:Id")),
    ?assertEqual({error, {invalid_parameter, ":1a"}}, weberl_route:normalize_pattern("/a/:1a")),
    ?assertEqual({error, {invalid_parameter, ":id-x"}}, weberl_route:normalize_pattern("/a/:id-x")),
    ?assertEqual({error, {duplicate_parameter, "id"}}, weberl_route:normalize_pattern("/a/:id/b/:id")),
    ?assertEqual({error, {unsupported_segment, "a:b"}}, weberl_route:normalize_pattern("/a:b")),
    ?assertEqual({error, {unsupported_segment, "*"}}, weberl_route:normalize_pattern("/a/*")),
    ?assertEqual({error, must_start_with_slash}, weberl_route:normalize_pattern("a/:id")),
    ?assertEqual({error, not_a_string}, weberl_route:normalize_pattern(agents)),
    %% a static path stays static: normalize_path does not know parameters
    ?assertEqual({error, {unsupported_segment, ":id"}}, weberl_route:normalize_path("/agents/:id")).

pattern_parts_shape_and_dynamic_test() ->
    ?assertEqual([<<"agents">>, {param, id}, <<"logs">>, {param, day}],
                 weberl_route:pattern_parts("/agents/:id/logs/:day")),
    ?assertEqual([], weberl_route:pattern_parts("/")),
    ?assertEqual("/agents/:/logs/:", weberl_route:shape("/agents/:id/logs/:day")),
    ?assertEqual("/agents/:/logs/:", weberl_route:shape("/agents/:a/logs/:b")),
    ?assertEqual("/about", weberl_route:shape("/about")),
    ?assert(weberl_route:is_dynamic("/agents/:id")),
    ?assertNot(weberl_route:is_dynamic("/agents/new")).

request_segments_test() ->
    ?assertEqual({ok, [<<"a">>, <<"b">>]}, weberl_route:request_segments("/a//b/")),
    ?assertEqual({ok, []}, weberl_route:request_segments("/")),
    %% a parameter value may contain `:' and `*'
    ?assertEqual({ok, [<<"agents">>, <<"a:b">>, <<"*">>]}, weberl_route:request_segments("/agents/a:b/*")),
    [?assertEqual(error, weberl_route:request_segments(P))
     || P <- ["/a/../b", "/a/./b", "/a b", "/a\nb", "/a?x", "/a#x", "/a\\b", "a/b", agents]].

decode_segment_test() ->
    ?assertEqual({ok, <<"a b">>}, weberl_route:decode_segment(<<"a%20b">>)),
    ?assertEqual({ok, <<"a/b">>}, weberl_route:decode_segment(<<"a%2Fb">>)),
    ?assertEqual({ok, <<"a/b">>}, weberl_route:decode_segment(<<"a%2fb">>)),
    ?assertEqual({ok, <<"é"/utf8>>}, weberl_route:decode_segment(<<"%C3%A9">>)),
    ?assertEqual({ok, <<"a+b">>}, weberl_route:decode_segment(<<"a+b">>)),
    ?assertEqual({ok, <<"100%">>}, weberl_route:decode_segment(<<"100%25">>)),
    %% decoded once: `%2520' is the text `%20'
    ?assertEqual({ok, <<"%20">>}, weberl_route:decode_segment(<<"%2520">>)),
    [?assertEqual(error, weberl_route:decode_segment(S))
     || S <- [<<"%zz">>, <<"%">>, <<"%4">>, <<"a%">>, <<"%G1">>, <<"%FF">>, <<"%C3">>]].

%% ---------------------------------------------------------------------
%% The table

route(Path, Handler) -> weberl_route:new(Path, Handler, declarative, router).
fs_route(Path, Handler) -> weberl_route:new(Path, Handler, filesystem, "f.erl").

table(Routes) ->
    {ok, T} = weberl_table:assemble([], Routes),
    T.

match(Path, Table) ->
    case weberl_table:match(Path, Table) of
        {ok, R, Params} -> {weberl_route:handler(R), Params};
        {error, _} = E -> E
    end.

a_parameter_matches_exactly_one_segment_test() ->
    T = table([route("/agents/:id", agent)]),
    ?assertEqual({agent, #{id => <<"7">>}}, match("/agents/7", T)),
    ?assertEqual({agent, #{id => <<"7">>}}, match("/agents/7/", T)),
    ?assertEqual({error, not_found}, match("/agents", T)),
    ?assertEqual({error, not_found}, match("/agents/", T)),
    ?assertEqual({error, not_found}, match("/agents/7/x", T)),
    ?assertEqual({error, not_found}, match("/other/7", T)).

parameters_are_named_and_raw_test() ->
    T = table([route("/a/:x/b/:y", ab)]),
    ?assertEqual({ab, #{x => <<"1">>, y => <<"2">>}}, match("/a/1/b/2", T)),
    %% not decoded by the table: dispatch does that
    ?assertEqual({ab, #{x => <<"a%20b">>, y => <<"%2F">>}}, match("/a/a%20b/b/%2F", T)),
    ?assertEqual({ab, #{x => <<"a:b">>, y => <<"*">>}}, match("/a/a:b/b/*", T)).

a_static_route_wins_over_a_parameter_test() ->
    T = table([route("/agents/:id", agent), route("/agents/new", new)]),
    ?assertEqual({new, #{}}, match("/agents/new", T)),
    ?assertEqual({agent, #{id => <<"newer">>}}, match("/agents/newer", T)),
    ?assertEqual({agent, #{id => <<"7">>}}, match("/agents/7", T)).

the_first_segment_where_routes_differ_decides_test() ->
    T = table([route("/a/b/:y", by), route("/a/:x/c", xc)]),
    ?assertEqual({by, #{y => <<"c">>}}, match("/a/b/c", T)),
    ?assertEqual({by, #{y => <<"d">>}}, match("/a/b/d", T)),
    ?assertEqual({xc, #{x => <<"z">>}}, match("/a/z/c", T)),
    ?assertEqual({error, not_found}, match("/a/z/d", T)).

a_static_branch_that_dead_ends_falls_back_to_the_parameter_test() ->
    T = table([route("/a/b/x", bx), route("/a/:p/c", pc)]),
    ?assertEqual({bx, #{}}, match("/a/b/x", T)),
    ?assertEqual({pc, #{p => <<"b">>}}, match("/a/b/c", T)).

routes_sharing_a_node_keep_their_own_parameter_names_test() ->
    T = table([route("/u/:x/a", ua), route("/u/:y/b", ub)]),
    ?assertEqual({ua, #{x => <<"1">>}}, match("/u/1/a", T)),
    ?assertEqual({ub, #{y => <<"1">>}}, match("/u/1/b", T)).

the_root_and_static_routes_are_unchanged_test() ->
    T = table([route("/", home), route("/about", about), route("/agents/:id", agent)]),
    ?assertEqual({home, #{}}, match("/", T)),
    ?assertEqual({about, #{}}, match("//about/", T)),
    ?assertEqual({error, not_found}, match("/nope", T)),
    ?assertEqual({error, not_found}, match("/a/../about", T)).

lookup_stays_static_only_test() ->
    T = table([route("/about", about), route("/agents/:id", agent)]),
    ?assertMatch({ok, _}, weberl_table:lookup("/about", T)),
    ?assertEqual({error, not_found}, weberl_table:lookup("/agents/7", T)),
    ?assertEqual({error, not_found}, weberl_table:lookup("/agents/:id", T)).

a_table_without_parameter_routes_matches_statics_test() ->
    T = table([route("/about", about)]),
    ?assertEqual({about, #{}}, match("/about", T)),
    ?assertEqual({error, not_found}, match("/about/x", T)).

routes_of_the_same_shape_conflict_test() ->
    ?assertMatch({error, {duplicate_routes, declarative, [{"/a/:", _}]}},
                 weberl_table:assemble([], [route("/a/:x", one), route("/a/:y", two)])),
    ?assertMatch({error, {duplicate_routes, filesystem, [{"/a/:", _}]}},
                 weberl_table:assemble([fs_route("/a/:x", one), fs_route("/a/:y", two)], [])),
    %% different shapes do not conflict
    ?assertMatch({ok, _}, weberl_table:assemble([], [route("/a/:x", one), route("/a/:x/b", two),
                                                     route("/a/b", three)])).

a_filesystem_route_shadows_a_declarative_one_of_the_same_shape_test() ->
    {ok, T} = weberl_table:assemble([fs_route("/a/:x", fs)], [route("/a/:y", decl), route("/b/:z", other)]),
    ?assertEqual({fs, #{x => <<"1">>}}, match("/a/1", T)),
    ?assertEqual({other, #{z => <<"1">>}}, match("/b/1", T)),
    ?assertEqual(["/a/:y"], [weberl_route:path(R) || R <- weberl_table:shadowed(T)]).

%% ---------------------------------------------------------------------
%% Where routes come from

a_bracket_directory_is_a_parameter_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"home_view.erl", view_src(home_view)},
                       {"agents/agents_view.erl", view_src(agents_view)},
                       {"agents/[id]/agent_view.erl", view_src(agent_view)},
                       {"agents/[id]/logs/[day]/log_view.erl", view_src(log_view)},
                       {"agents/new/new_agent_view.erl", view_src(new_agent_view)}]),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        ?assertEqual([{"/", home_view}, {"/agents", agents_view}, {"/agents/:id", agent_view},
                      {"/agents/:id/logs/:day", log_view}, {"/agents/new", new_agent_view}],
                     lists:sort([{weberl_route:path(R), weberl_route:handler(R)} || R <- Rs]))
    end).

a_bracket_directory_with_a_bad_name_is_an_error_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"agents/[Id]/agent_view.erl", view_src(agent_view)}]),
        ?assertMatch({error, {invalid_route_path, _, {invalid_parameter, ":Id"}}}, weberl_fs:discover(D, "/"))
    end),
    with_tmp(fun(D) ->
        write_tree(D, [{"agents/[]/agent_view.erl", view_src(agent_view)}]),
        ?assertMatch({error, {invalid_route_path, _, {invalid_parameter, ":"}}}, weberl_fs:discover(D, "/"))
    end),
    with_tmp(fun(D) ->
        write_tree(D, [{"a/[x]/b/[x]/v_view.erl", view_src(v_view)}]),
        ?assertMatch({error, {invalid_route_path, _, {duplicate_parameter, "x"}}}, weberl_fs:discover(D, "/"))
    end).

a_directory_that_is_not_a_bracket_name_stays_static_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"a[b/v_view.erl", view_src(v_view)}]),
        {ok, [R]} = weberl_fs:discover(D, "/"),
        ?assertEqual("/a[b", weberl_route:path(R))
    end).

a_declarative_route_takes_a_parameter_test() ->
    Mod = weberl_test_handlers:unique("dynrouter"),
    weberl_test_handlers:load(Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([routes/0]). "
                              "routes() -> [{\"/agents/:id\", agent_handler}, {\"/health\", health_handler}].\n"),
    {ok, Rs} = weberl_decl:collect_module(Mod),
    ?assertEqual(["/agents/:id", "/health"], [weberl_route:path(R) || R <- Rs]),
    Bad = weberl_test_handlers:unique("dynrouter"),
    weberl_test_handlers:load(Bad, "-module(" ++ atom_to_list(Bad) ++ "). -export([routes/0]). "
                              "routes() -> [{\"/agents/:Id\", agent_handler}].\n"),
    ?assertMatch({error, {invalid_route, Bad, _, {invalid_path, {invalid_parameter, ":Id"}}}},
                 weberl_decl:collect_module(Bad)).

%% ---------------------------------------------------------------------
%% Dispatch: params in the request

load(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

req(Path) -> weberl_request:new(#{method => <<"GET">>, path => Path}).

body(Response) -> iolist_to_binary(weberl_response:body(Response)).

the_handler_gets_decoded_params_test() ->
    H = load("agent", "handle(R) -> #{id := Id} = weberl_request:params(R), weberl_response:text(200, Id)."),
    T = table([route("/agents/:id", H)]),
    ?assertEqual(<<"7">>, body(weberl_dispatch:dispatch(req("/agents/7"), T))),
    ?assertEqual(<<"a b">>, body(weberl_dispatch:dispatch(req("/agents/a%20b"), T))),
    %% a %2F stays inside one value
    ?assertEqual(<<"a/b">>, body(weberl_dispatch:dispatch(req("/agents/a%2Fb"), T))),
    ?assertEqual(<<"é"/utf8>>, body(weberl_dispatch:dispatch(req("/agents/%C3%A9"), T))),
    ?assertEqual(<<"100%">>, body(weberl_dispatch:dispatch(req("/agents/100%25"), T))),
    ?assertEqual(<<"%20">>, body(weberl_dispatch:dispatch(req("/agents/%2520"), T))),
    ?assertEqual(404, weberl_response:status(weberl_dispatch:dispatch(req("/agents"), T))),
    ?assertEqual(404, weberl_response:status(weberl_dispatch:dispatch(req("/agents/7/x"), T))).

a_static_route_has_no_params_test() ->
    H = load("about", "handle(R) -> weberl_response:text(200, integer_to_binary(map_size(weberl_request:params(R))))."),
    T = table([route("/about", H)]),
    ?assertEqual(<<"0">>, body(weberl_dispatch:dispatch(req("/about"), T))).

a_malformed_escape_in_a_parameter_is_a_400_test() ->
    H = load("agent400", "handle(_) -> weberl_response:text(200, <<\"reached\">>)."),
    T = table([route("/agents/:id", H), route("/about", H)]),
    weberl_live_test_util:quiet(fun() ->
        [begin
             R = weberl_dispatch:dispatch(req(P), T),
             ?assertEqual({P, 400}, {P, weberl_response:status(R)}),
             ?assertEqual(<<"Bad Request">>, body(R))
         end || P <- ["/agents/%zz", "/agents/100%", "/agents/a%4", "/agents/%FF", "/agents/%C3"]]
    end),
    %% not a route at all: still a 404, the path is not looked into
    ?assertEqual(404, weberl_response:status(weberl_dispatch:dispatch(req("/nope/%zz"), T))),
    ?assertEqual(<<"reached">>, body(weberl_dispatch:dispatch(req("/about"), T))).

a_static_route_wins_in_dispatch_test() ->
    New = load("new", "handle(_) -> weberl_response:text(200, <<\"new\">>)."),
    Agent = load("agent2", "handle(R) -> weberl_response:text(200, maps:get(id, weberl_request:params(R)))."),
    T = table([route("/agents/:id", Agent), route("/agents/new", New)]),
    ?assertEqual(<<"new">>, body(weberl_dispatch:dispatch(req("/agents/new"), T))),
    ?assertEqual(<<"7">>, body(weberl_dispatch:dispatch(req("/agents/7"), T))).

%% ---------------------------------------------------------------------
%% Links to routes with parameters

links_table() ->
    table([route("/", home), route("/agents", agents), route("/agents/new", new),
           route("/agents/:id", agent), route("/agents/:id/logs", logs),
           route("/docs/intro", intro), route("/docs/api", api)]).

compile(Src) ->
    weberl_template:compile_source(weberl_test_handlers:unique("dynlink"), Src, "t.weberl", none,
                                   #{routes => links_table()}).

err(Result) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} = Result,
    {Line, Reason}.

render(Src, Assigns) ->
    View = weberl_test_handlers:unique("dynlink"),
    {ok, C} = weberl_template:compile_source(View, Src, "t.weberl", none, #{routes => links_table()}),
    ok = weberl_template:load(C),
    iolist_to_binary(weberl_template:render(View, Assigns)).

ahref(Route) ->
    iolist_to_binary(["<a href=\"{{ weberl_url:router_path(", Route, ") }}\">x</a>"]).

a_literal_link_is_verified_against_a_parameter_route_test() ->
    ?assertMatch({ok, _}, compile(ahref("\"/agents/7\""))),
    ?assertEqual([], weberl_template:warnings(element(2, compile(ahref("\"/agents/7\""))))),
    ?assertEqual(<<"<a href=\"/agents/7\">x</a>">>, render(ahref("\"/agents/7\""), #{})),
    ?assertEqual(<<"<a href=\"/agents/7/logs\">x</a>">>, render(ahref("\"/agents/7/logs\""), #{})),
    ?assertEqual({1, {unknown_route, <<"/agents/7/x">>}}, err(compile(ahref("\"/agents/7/x\"")))),
    ?assertEqual({1, {unknown_route, <<"/other/7">>}}, err(compile(ahref("\"/other/7\"")))).

a_placeholder_where_the_route_has_a_parameter_needs_no_warning_test() ->
    {ok, C} = compile(ahref("\"/agents/{{ @id }}\"")),
    ?assertEqual([], weberl_template:warnings(C)),
    {ok, D} = compile(ahref("\"/agents/{{ @id }}/logs\"")),
    ?assertEqual([], weberl_template:warnings(D)),
    ?assertEqual(<<"<a href=\"/agents/a%20b%2Fc\">x</a>">>, render(ahref("\"/agents/{{ @id }}\""), #{id => <<"a b/c">>})),
    ?assertEqual(<<"<a href=\"/agents/42/logs\">x</a>">>, render(ahref("\"/agents/{{ @id }}/logs\""), #{id => 42})),
    %% a value that is `new' is still the route /agents/:id (and /agents/new): both are routes
    ?assertEqual(<<"<a href=\"/agents/new\">x</a>">>, render(ahref("\"/agents/{{ @id }}\""), #{id => <<"new">>})).

a_placeholder_where_the_route_is_static_still_warns_test() ->
    {ok, C} = compile(ahref("\"/docs/{{ @page }}\"")),
    ?assertEqual([{warning, "t.weberl", 1, {dynamic_route_segment, <<"/docs/{{ @page }}">>}}],
                 weberl_template:warnings(C)),
    %% the first segment is static: warns, although the second is a parameter
    {ok, E} = compile(ahref("\"/{{ @a }}/{{ @b }}\"")),
    ?assertMatch([{warning, _, 1, {dynamic_route_segment, _}}], weberl_template:warnings(E)),
    {ok, F} = compile(ahref("\"/docs/{{ @page }}\", #{no_warn => true}")),
    ?assertEqual([], weberl_template:warnings(F)).

a_placeholder_needs_a_route_of_its_shape_test() ->
    ?assertEqual({1, {unknown_route, <<"/agents/{{ @id }}/x">>}}, err(compile(ahref("\"/agents/{{ @id }}/x\"")))),
    ?assertEqual({1, {unknown_route, <<"/agents/{{ @a }}/{{ @b }}/{{ @c }}">>}},
                 err(compile(ahref("\"/agents/{{ @a }}/{{ @b }}/{{ @c }}\"")))).

the_embedded_routes_decide_at_render_time_test() ->
    %% /agents/{{ @id }}/logs matches only /agents/:id/logs; the check is a match on its pattern
    Src = ahref("\"/agents/{{ @id }}/logs\""),
    View = weberl_test_handlers:unique("dynlink"),
    {ok, C} = weberl_template:compile_source(View, Src, "t.weberl", none, #{routes => links_table()}),
    ok = weberl_template:load(C),
    R = fun(Id) -> weberl_template:render(View, #{id => Id}) end,
    ?assertEqual(<<"<a href=\"/agents/7/logs\">x</a>">>, iolist_to_binary(R(<<"7">>))),
    ?assertEqual({empty_segment, <<>>}, try R(<<>>) catch error:{template_error, Re} -> Re end),
    %% a slash in the value is encoded: it cannot reach /agents/7/logs through two segments
    ?assertEqual(<<"<a href=\"/agents/7%2Flogs/logs\">x</a>">>, iolist_to_binary(R(<<"7/logs">>))).

a_static_segment_with_a_placeholder_inside_is_checked_by_text_test() ->
    ?assertMatch({ok, _}, compile(ahref("\"/docs/i{{ @p }}\", #{no_warn => true}"))),
    ?assertEqual({1, {unknown_route, <<"/docs/z{{ @p }}">>}}, err(compile(ahref("\"/docs/z{{ @p }}\"")))).
