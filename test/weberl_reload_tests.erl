%% `weberl:reload/1': routes and templates are rebuilt from the files while the router
%% keeps running (the same listener, the same port), and a reload that cannot succeed
%% leaves the old table in service. Over real HTTP, like `weberl_views_tests'.
-module(weberl_reload_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

reload_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             ok
     end,
     fun(_) -> ok end,
     [{"an edited template is served after a reload, without a restart", fun edited_template/0},
      {"a new view appears and a deleted one is gone", fun added_and_removed_views/0},
      {"a template that does not compile keeps the old page", fun broken_template_keeps_old/0},
      {"a link to a route that was removed fails the reload", fun removed_route_fails_links/0},
      {"the listener, its port and its open connections stay", fun listener_stays/0},
      {"a router that is not running", fun not_running/0},
      {"reloading twice in a row works", fun twice/0}]}.

%% ---------------------------------------------------------------------

listener() -> #listener{port = 0, ip = {127, 0, 0, 1}}.

router_name() -> weberl_test_handlers:unique("rl").

view_name(Prefix) -> atom_to_list(weberl_test_handlers:unique(Prefix)) ++ "_view".

%% A view that renders its template with `#{}'.
view_src(Module) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, weberl_template:render(?MODULE, #{})).~n",
                    [Module])).

compile_load(File) ->
    {ok, Mod, Bin} = compile:file(File, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, File, Bin),
    ok.

get(Name, Path) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    {ok, {{_, Status, _}, _Headers, Body}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    {Status, Body}.

start(Dir) ->
    Name = router_name(),
    {ok, _} = weberl:start_link(Name, #router{filesystem = [#filesystem_router{root = Dir}]}, listener()),
    Name.

quiet(Fun) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, Level) end.

%% ---------------------------------------------------------------------

edited_template() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        write_tree(Dir, [{Home ++ ".erl", view_src(Home)}, {Home ++ ".weberl", <<"<p>one</p>">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        Name = start(Dir),
        try
            ?assertEqual({200, <<"<p>one</p>">>}, get(Name, "/")),
            write_tree(Dir, [{Home ++ ".weberl", <<"<p>two</p>">>}]),
            %% not picked up by itself
            ?assertEqual({200, <<"<p>one</p>">>}, get(Name, "/")),
            ?assertEqual(ok, weberl:reload(Name)),
            ?assertEqual({200, <<"<p>two</p>">>}, get(Name, "/"))
        after
            weberl:stop(Name)
        end
    end).

added_and_removed_views() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        Extra = view_name("extra"),
        write_tree(Dir, [{Home ++ ".erl", view_src(Home)}, {Home ++ ".weberl", <<"home">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        Name = start(Dir),
        try
            ?assertMatch({404, _}, get(Name, "/extra")),
            write_tree(Dir, [{"extra/" ++ Extra ++ ".erl", view_src(Extra)},
                             {"extra/" ++ Extra ++ ".weberl", <<"extra page">>}]),
            compile_load(filename:join(Dir, "extra/" ++ Extra ++ ".erl")),
            ?assertEqual(ok, weberl:reload(Name)),
            %% the view's path comes from its directory and (file) name
            ?assertEqual({200, <<"extra page">>}, get(Name, "/extra")),
            ok = file:delete(filename:join(Dir, "extra/" ++ Extra ++ ".erl")),
            ok = file:delete(filename:join(Dir, "extra/" ++ Extra ++ ".weberl")),
            ?assertEqual(ok, weberl:reload(Name)),
            ?assertMatch({404, _}, get(Name, "/extra")),
            ?assertEqual({200, <<"home">>}, get(Name, "/"))
        after
            weberl:stop(Name)
        end
    end).


broken_template_keeps_old() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        write_tree(Dir, [{Home ++ ".erl", view_src(Home)}, {Home ++ ".weberl", <<"<p>fine</p>">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        Name = start(Dir),
        try
            write_tree(Dir, [{Home ++ ".weberl", <<"<p>{{ @oops </p>">>}]),
            ?assertMatch({error, {invalid_templates, _}}, quiet(fun() -> weberl:reload(Name) end)),
            ?assertEqual({200, <<"<p>fine</p>">>}, get(Name, "/")),
            %% and the next, good, edit works
            write_tree(Dir, [{Home ++ ".weberl", <<"<p>fixed</p>">>}]),
            ?assertEqual(ok, weberl:reload(Name)),
            ?assertEqual({200, <<"<p>fixed</p>">>}, get(Name, "/"))
        after
            weberl:stop(Name)
        end
    end).

%% A link is verified against the table when templates compile: remove the route it
%% points to and the reload is refused, with the old table and templates still serving.
removed_route_fails_links() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        About = view_name("about"),
        write_tree(Dir,
                   [{Home ++ ".erl", view_src(Home)},
                    {Home ++ ".weberl", iolist_to_binary(
                                          ["<a href=\"{{ weberl_url:router_path(\"/gone", 
                                           "\") }}\">x</a>"])},
                    {"gone/" ++ About ++ ".erl", view_src(About)},
                    {"gone/" ++ About ++ ".weberl", <<"about">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        compile_load(filename:join(Dir, "gone/" ++ About ++ ".erl")),
        Name = start(Dir),
        try
            ?assertMatch({200, _}, get(Name, "/gone")),
            ok = file:delete(filename:join(Dir, "gone/" ++ About ++ ".erl")),
            ok = file:delete(filename:join(Dir, "gone/" ++ About ++ ".weberl")),
            ?assertMatch({error, {invalid_templates, _}}, quiet(fun() -> weberl:reload(Name) end)),
            ?assertMatch({200, _}, get(Name, "/gone"))
        after
            weberl:stop(Name)
        end
    end).

listener_stays() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        write_tree(Dir, [{Home ++ ".erl", view_src(Home)}, {Home ++ ".weberl", <<"v1">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        Name = start(Dir),
        try
            Port = weberl:port(Name),
            %% a keep-alive connection opened before the reload
            {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
            ok = gen_tcp:send(Sock, "GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
            {ok, First} = gen_tcp:recv(Sock, 0, 2000),
            ?assertMatch({_, _}, binary:match(First, <<"v1">>)),
            write_tree(Dir, [{Home ++ ".weberl", <<"v2">>}]),
            ?assertEqual(ok, weberl:reload(Name)),
            ?assertEqual(Port, weberl:port(Name)),
            ok = gen_tcp:send(Sock, "GET / HTTP/1.1\r\nHost: x\r\n\r\n"),
            {ok, Second} = gen_tcp:recv(Sock, 0, 2000),
            ?assertMatch({_, _}, binary:match(Second, <<"v2">>)),
            gen_tcp:close(Sock)
        after
            weberl:stop(Name)
        end
    end).

not_running() ->
    ?assertEqual({error, not_running}, weberl:reload(no_such_router_running)).

twice() ->
    with_tmp(fun(Dir) ->
        Home = view_name("home"),
        write_tree(Dir, [{Home ++ ".erl", view_src(Home)}, {Home ++ ".weberl", <<"a">>}]),
        compile_load(filename:join(Dir, Home ++ ".erl")),
        Name = start(Dir),
        try
            [begin
                 write_tree(Dir, [{Home ++ ".weberl", Text}]),
                 ?assertEqual(ok, weberl:reload(Name)),
                 ?assertEqual({200, Text}, get(Name, "/"))
             end || Text <- [<<"b">>, <<"c">>, <<"d">>]]
        after
            weberl:stop(Name)
        end
    end).
