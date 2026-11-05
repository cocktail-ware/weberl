%% Views + templates + router + Roadrunner, end to end: GET renders the
%% `.weberl' template associated with the view. Requires roadrunner (test
%% profile).
-module(weberl_views_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2, load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

setup_all() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(roadrunner),
    ok.

teardown_all(_) -> ok.

%% ---------------------------------------------------------------------
%% helpers

listener() -> #listener{port = 0, ip = {127, 0, 0, 1}}.

router_name() -> weberl_test_handlers:unique("vw").

%% A view whose handler renders its template with the given assigns expression.
view_src(Module, AssignsExpr) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1]).~n"
                    "handle(_) ->~n"
                    "    weberl_response:html(200, weberl_template:render(?MODULE, ~s)).~n",
                    [Module, AssignsExpr])).

plain_view_src(Module, Text) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, <<\"~s\">>).~n", [Module, Text])).

compile_load(File) ->
    {ok, Mod, Bin} = compile:file(File, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, File, Bin),
    ok.

view_name(Prefix) -> atom_to_list(weberl_test_handlers:unique(Prefix)) ++ "_view".

get(Name, Path) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    {ok, {{_, Status, _}, Headers, Body}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    {Status, Headers, Body}.

start_failing(Name, Router) ->
    Trap = process_flag(trap_exit, true),
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try
        R = weberl:start_link(Name, Router, listener()),
        receive {'EXIT', _, _} -> ok after 200 -> ok end,
        R
    after
        logger:set_primary_config(level, maps:get(level, Old)),
        process_flag(trap_exit, Trap)
    end.

fs_router(Dir) -> #router{filesystem = [#filesystem_router{root = Dir}]}.

%% ---------------------------------------------------------------------

e2e_test_() ->
    {setup, fun setup_all/0, fun teardown_all/1,
     [{"GET / and /about render templates", fun renders_templates/0},
      {"view without template, template with escaping", fun mixed_views/0},
      {"declarative route next to templated views", fun declarative_next_to_views/0},
      {"missing variable is a 500", fun missing_variable_is_500/0},
      {"unassociated template fails startup", fun unassociated_template/0},
      {"invalid template fails startup, nothing left", fun invalid_template/0},
      {"links are checked against the router's routes", fun links_to_routes/0},
      {"a link to a route that does not exist fails startup", fun link_to_unknown_route/0},
      {"template is not re-read per request", fun not_reread/0},
      {"restart picks up an edited template", fun restart_recompiles/0}]}.

renders_templates() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        About = view_name("about"),
        write_tree(Dir,
                   [{Home ++ ".erl", view_src(Home, "#{title => <<\"Welcome\">>, "
                                                   "description => <<\"Built with Weberl\">>}")},
                    {Home ++ ".weberl", <<"<main class=\"home\">\n    <h1>{{ @title }}</h1>\n"
                                          "    <p>{{ @description }}</p>\n</main>\n">>},
                    {"about/" ++ About ++ ".erl", view_src(About, "#{year => 2026}")},
                    {"about/" ++ About ++ ".weberl", <<"<h1>About</h1><p>Since {{ @year }}</p>">>}]),
        [compile_load(filename:join(Dir, F)) || F <- [Home ++ ".erl", "about/" ++ About ++ ".erl"]],
        Name = router_name(),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        try
            {200, H, B} = get(Name, "/"),
            ?assertEqual(<<"<main class=\"home\">\n    <h1>Welcome</h1>\n"
                           "    <p>Built with Weberl</p>\n</main>\n">>, B),
            ?assertEqual("text/html; charset=utf-8", proplists:get_value("content-type", H)),
            ?assertMatch({200, _, <<"<h1>About</h1><p>Since 2026</p>">>}, get(Name, "/about")),
            ?assertMatch({404, _, _}, get(Name, "/other"))
        after
            weberl:stop(Name)
        end
    end).

mixed_views() ->
    with_tmp(fun(Dir) ->
        Plain = view_name("plain"),
        Esc = view_name("esc"),
        write_tree(Dir,
                   [{Plain ++ ".erl", plain_view_src(Plain, "no template here")},
                    {"esc/" ++ Esc ++ ".erl",
                     view_src(Esc, "#{name => <<\"<script>alert('x')</script>\">>, "
                                   "html => <<\"<em>ok</em>\">>}")},
                    {"esc/" ++ Esc ++ ".weberl", <<"<p title=\"{{ @name }}\">{{ @name }}</p>{{{ @html }}}">>}]),
        [compile_load(filename:join(Dir, F)) || F <- [Plain ++ ".erl", "esc/" ++ Esc ++ ".erl"]],
        Name = router_name(),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        try
            ?assertMatch({200, _, <<"no template here">>}, get(Name, "/")),
            {200, _, B} = get(Name, "/esc"),
            ?assertEqual(<<"<p title=\"&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;\">"
                           "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</p><em>ok</em>">>, B)
        after
            weberl:stop(Name)
        end
    end).

declarative_next_to_views() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        write_tree(Dir, [{Home ++ ".erl", view_src(Home, "#{n => 1}")},
                         {Home ++ ".weberl", <<"home {{ @n }}">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        Health = weberl_test_handlers:unique("health"),
        weberl_test_handlers:load(
          Health, "-module(" ++ atom_to_list(Health) ++ "). -export([handle/1]). "
                  "handle(_) -> weberl_response:text(200, <<\"ok\">>)."),
        RouterMod = weberl_test_handlers:unique("decl"),
        load_router(RouterMod, [{"/health", Health}]),
        Name = router_name(),
        {ok, _} = weberl:start_link(
                    Name, #router{filesystem = [#filesystem_router{root = Dir}],
                                  modules = [RouterMod]}, listener()),
        try
            ?assertMatch({200, _, <<"home 1">>}, get(Name, "/")),
            ?assertMatch({200, _, <<"ok">>}, get(Name, "/health"))
        after
            weberl:stop(Name)
        end
    end).

missing_variable_is_500() ->
    with_tmp(fun(Dir) ->
        V = view_name("miss"),
        write_tree(Dir, [{V ++ ".erl", view_src(V, "#{}")}, {V ++ ".weberl", <<"{{ @nope }}">>}]),
        compile_load(filename:join(Dir, V ++ ".erl")),
        Name = router_name(),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        Old = logger:get_primary_config(),
        logger:set_primary_config(level, none),
        try
            ?assertMatch({500, _, <<"Internal Server Error">>}, get(Name, "/"))
        after
            logger:set_primary_config(level, maps:get(level, Old)),
            weberl:stop(Name)
        end
    end).

unassociated_template() ->
    with_tmp(fun(Dir) ->
        V = view_name("ok"),
        write_tree(Dir, [{V ++ ".erl", plain_view_src(V, "x")},
                         {"orphan_view.weberl", <<"orphan">>},
                         {"sub/readme.weberl", <<"orphan too">>}]),
        compile_load(filename:join(Dir, V ++ ".erl")),
        Name = router_name(),
        Result = start_failing(Name, fs_router(Dir)),
        ?assertEqual({error, {unassociated_templates,
                              [filename:join(Dir, "orphan_view.weberl"),
                               filename:join(Dir, "sub/readme.weberl")]}}, Result),
        ?assertEqual(undefined, whereis(Name)),
        ?assertNot(lists:member(list_to_atom("weberl_listener_" ++ atom_to_list(Name)),
                                roadrunner:listeners()))
    end).

invalid_template() ->
    with_tmp(fun(Dir) ->
        V = view_name("bad"),
        write_tree(Dir, [{V ++ ".erl", plain_view_src(V, "x")},
                         {V ++ ".weberl", <<"<p>ok</p>\n<p>{{ oops</p>">>}]),
        compile_load(filename:join(Dir, V ++ ".erl")),
        Name = router_name(),
        Result = start_failing(Name, fs_router(Dir)),
        File = filename:join(Dir, V ++ ".weberl"),
        ?assertMatch({error, {invalid_templates,
                              [{_, {syntax_error, File, 2, unterminated_interpolation}}]}},
                     Result),
        ?assertEqual(undefined, whereis(Name)),
        ?assertNot(weberl_template:has_template(list_to_atom(V)))
    end).

%% The home page links to `/about' and to `/docs/<page>' (routes of the same router):
%% the router start verifies them against its table, and rendering needs no router.
links_to_routes() ->
    with_tmp(fun(Dir) ->
        Home = view_name("lhome"),
        About = view_name("labout"),
        Intro = view_name("lintro"),
        write_tree(Dir,
                   [{Home ++ ".erl", view_src(Home, "#{page => <<\"intro\">>, id => <<\"a b/c\">>}")},
                    {Home ++ ".weberl",
                     <<"<a href=\"{{ weberl_url:router_path(\"/about\") }}\">about</a>"
                       "<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\", #{no_warn => true}) }}\">docs</a>"
                       "<a href=\"/items/{{ weberl_url:component(@id) }}\">item</a>">>},
                    {"about/" ++ About ++ ".erl", plain_view_src(About, "about")},
                    {"docs/intro/" ++ Intro ++ ".erl", plain_view_src(Intro, "intro")}]),
        [compile_load(filename:join(Dir, F)) || F <- [Home ++ ".erl", "about/" ++ About ++ ".erl",
                                                      "docs/intro/" ++ Intro ++ ".erl"]],
        Name = router_name(),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        try
            ?assertMatch({200, _, <<"<a href=\"/about\">about</a>"
                                    "<a href=\"/docs/intro\">docs</a>"
                                    "<a href=\"/items/a%20b%2Fc\">item</a>">>},
                         get(Name, "/"))
        after
            weberl:stop(Name)
        end
    end).

link_to_unknown_route() ->
    with_tmp(fun(Dir) ->
        V = view_name("ltypo"),
        write_tree(Dir, [{V ++ ".erl", plain_view_src(V, "x")},
                         {V ++ ".weberl", <<"<p>ok</p>\n<a href=\"{{ weberl_url:router_path(\"/abuot\") }}\">x</a>">>}]),
        compile_load(filename:join(Dir, V ++ ".erl")),
        Name = router_name(),
        Result = start_failing(Name, fs_router(Dir)),
        File = filename:join(Dir, V ++ ".weberl"),
        ?assertMatch({error, {invalid_templates,
                              [{_, {syntax_error, File, 2, {unknown_route, <<"/abuot">>}}}]}},
                     Result),
        ?assertEqual(undefined, whereis(Name))
    end).

not_reread() ->
    with_tmp(fun(Dir) ->
        V = view_name("cached"),
        write_tree(Dir, [{V ++ ".erl", view_src(V, "#{v => 1}")}, {V ++ ".weberl", <<"v={{ @v }}">>}]),
        compile_load(filename:join(Dir, V ++ ".erl")),
        Name = router_name(),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        try
            ?assertMatch({200, _, <<"v=1">>}, get(Name, "/")),
            ok = file:write_file(filename:join(Dir, V ++ ".weberl"), <<"changed {{ @v }}">>),
            ?assertMatch({200, _, <<"v=1">>}, get(Name, "/")),
            ok = file:delete(filename:join(Dir, V ++ ".weberl")),
            ?assertMatch({200, _, <<"v=1">>}, get(Name, "/"))
        after
            weberl:stop(Name)
        end
    end).

restart_recompiles() ->
    with_tmp(fun(Dir) ->
        V = view_name("redo"),
        TplFile = filename:join(Dir, V ++ ".weberl"),
        write_tree(Dir, [{V ++ ".erl", view_src(V, "#{}")}, {V ++ ".weberl", <<"first">>}]),
        compile_load(filename:join(Dir, V ++ ".erl")),
        Name = router_name(),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        ?assertMatch({200, _, <<"first">>}, get(Name, "/")),
        weberl:stop(Name),
        ok = file:write_file(TplFile, <<"second">>),
        {ok, _} = weberl:start_link(Name, fs_router(Dir), listener()),
        try
            ?assertMatch({200, _, <<"second">>}, get(Name, "/"))
        after
            weberl:stop(Name)
        end
    end).
