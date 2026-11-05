%% Static asset serving through the Roadrunner adapter, over real HTTP.
-module(weberl_static_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2, load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

setup_all() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(roadrunner),
    ok.

http_test_() ->
    {setup, fun setup_all/0, fun(_) -> ok end,
     [{"serves files with content type", fun serves_files/0},
      {"missing file and traversal are 404", fun missing_and_traversal/0},
      {"routes and root still reach the route table", fun routes_unaffected/0},
      {"etag and conditional request", fun etag_304/0},
      {"cache_control option", fun cache_control/0},
      {"several mounts and priv sources", fun several_mounts/0},
      {"invalid static config fails start", fun invalid_config_fails/0}]}.

%% ---------------------------------------------------------------------

start(Static, Routes, Fun) ->
    Name = weberl_test_handlers:unique("st"),
    RouterMod = weberl_test_handlers:unique("str"),
    load_router(RouterMod, Routes),
    Listener = #listener{port = 0, ip = {127, 0, 0, 1}, static = Static},
    {ok, Pid} = weberl:start_link(Name, #router{modules = [RouterMod]}, Listener),
    try Fun(Name) after
        unlink(Pid),
        weberl:stop(Name)
    end.

handler(Body) ->
    Mod = weberl_test_handlers:unique("sth"),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

get(Name, Path) -> get(Name, Path, []).

get(Name, Path, Headers) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    {ok, {{_, Status, _}, RespHeaders, Body}} =
        httpc:request(get, {Url, Headers}, [], [{body_format, binary}]),
    {Status, RespHeaders, Body}.

header(Name, Headers) -> proplists:get_value(Name, Headers).

assets(Dir) ->
    write_tree(Dir, [{dir, "css"},
                     {"app.js", "console.log(1);"},
                     {"css/site.css", "body{}"},
                     {"secret.txt", "outside"}]).

%% ---------------------------------------------------------------------

serves_files() ->
    with_tmp(fun(Tmp) ->
        Dir = filename:join(Tmp, "pub"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        assets(Dir),
        start([{"/static", Dir}], [], fun(Name) ->
            {200, H1, B1} = get(Name, "/static/app.js"),
            ?assertEqual(<<"console.log(1);">>, B1),
            ?assertMatch("text/javascript" ++ _, header("content-type", H1)),
            {200, H2, B2} = get(Name, "/static/css/site.css"),
            ?assertEqual(<<"body{}">>, B2),
            ?assertMatch("text/css" ++ _, header("content-type", H2))
        end)
    end).

missing_and_traversal() ->
    with_tmp(fun(Tmp) ->
        Dir = filename:join(Tmp, "pub"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        assets(Dir),
        ok = file:write_file(filename:join(Tmp, "outside.txt"), "nope"),
        start([{"/static", Dir}], [], fun(Name) ->
            ?assertMatch({404, _, _}, get(Name, "/static/nope.js")),
            ?assertMatch({404, _, _}, get(Name, "/static/css")),
            ?assertMatch({404, _, _}, get(Name, "/static/../outside.txt")),
            ?assertMatch({404, _, _}, get(Name, "/static/%2e%2e/outside.txt"))
        end)
    end).

routes_unaffected() ->
    with_tmp(fun(Tmp) ->
        Dir = filename:join(Tmp, "pub"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        assets(Dir),
        Root = handler("handle(_) -> weberl_response:text(200, <<\"root\">>)."),
        Hi = handler("handle(_) -> weberl_response:text(200, <<\"hi\">>)."),
        start([{"/static", Dir}], [{"/", Root}, {"/hi", Hi}], fun(Name) ->
            ?assertMatch({200, _, <<"root">>}, get(Name, "/")),
            ?assertMatch({200, _, <<"hi">>}, get(Name, "/hi")),
            ?assertMatch({404, _, <<"Not Found">>}, get(Name, "/other"))
        end)
    end).

etag_304() ->
    with_tmp(fun(Tmp) ->
        Dir = filename:join(Tmp, "pub"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        assets(Dir),
        start([{"/static", Dir}], [], fun(Name) ->
            {200, H, _} = get(Name, "/static/app.js"),
            ETag = header("etag", H),
            ?assertNotEqual(undefined, ETag),
            ?assertMatch({304, _, <<>>},
                         get(Name, "/static/app.js", [{"if-none-match", ETag}]))
        end)
    end).

cache_control() ->
    with_tmp(fun(Tmp) ->
        Dir = filename:join(Tmp, "pub"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        assets(Dir),
        start([{"/static", Dir, #{cache_control => "public, max-age=60"}}], [],
              fun(Name) ->
                  {200, H, _} = get(Name, "/static/app.js"),
                  ?assertEqual("public, max-age=60", header("cache-control", H))
              end)
    end).

several_mounts() ->
    with_tmp(fun(Tmp) ->
        A = filename:join(Tmp, "a"),
        B = filename:join(Tmp, "b"),
        ok = filelib:ensure_dir(filename:join(A, "x")),
        ok = filelib:ensure_dir(filename:join(B, "x")),
        ok = file:write_file(filename:join(A, "one.txt"), "one"),
        ok = file:write_file(filename:join(B, "two.txt"), "two"),
        start([{"/a", A}, {"/b", B}], [], fun(Name) ->
            ?assertMatch({200, _, <<"one">>}, get(Name, "/a/one.txt")),
            ?assertMatch({200, _, <<"two">>}, get(Name, "/b/two.txt")),
            ?assertMatch({404, _, _}, get(Name, "/a/two.txt"))
        end),
        %% {priv, App, Sub}: a throwaway application directory on the code path
        %% (code:priv_dir/1 resolves it from the ebin directory).
        PrivRoot = filename:join(Tmp, "privapp"),
        Ebin = filename:join(PrivRoot, "ebin"),
        ok = filelib:ensure_dir(filename:join(Ebin, "x")),
        ok = filelib:ensure_dir(filename:join([PrivRoot, "priv", "web", "x"])),
        ok = file:write_file(filename:join([PrivRoot, "priv", "web", "p.txt"]), "priv"),
        true = code:add_path(Ebin),
        try
            start([{"/p", {priv, privapp, "web"}}], [], fun(Name) ->
                ?assertMatch({200, _, <<"priv">>}, get(Name, "/p/p.txt"))
            end)
        after
            code:del_path(Ebin)
        end
    end).

invalid_config_fails() ->
    Name = weberl_test_handlers:unique("stbad"),
    Listener = #listener{port = 0, static = [{"/", "x"}]},
    Trap = process_flag(trap_exit, true),
    Old = maps:get(level, logger:get_primary_config()),
    logger:set_primary_config(level, none),
    try
        ?assertMatch({error, {invalid_config, {listener, {static, 1, _}}}},
                     weberl:start_link(Name, #router{}, Listener))
    after
        logger:set_primary_config(level, Old),
        process_flag(trap_exit, Trap)
    end.
