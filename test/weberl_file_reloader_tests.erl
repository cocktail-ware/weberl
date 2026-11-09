%% Weberl with `erl_file_reloader' (a separate library that Weberl does not use itself):
%% edit a template, edit a view's source or add a view, and the page changes with no
%% restart and no explicit `weberl:reload/1' call; the reloader's hook makes it.
-module(weberl_file_reloader_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

file_reloader_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             ok
     end,
     fun(_) -> ok end,
     [{timeout, 60, {"an edited template is served", fun edited_template/0}},
      {timeout, 60, {"an edited view source is served", fun edited_view/0}},
      {timeout, 60, {"a new view appears", fun new_view/0}}]}.

%% ---------------------------------------------------------------------

listener() -> #listener{port = 0, ip = {127, 0, 0, 1}}.

view_name(Prefix) -> atom_to_list(weberl_test_handlers:unique(Prefix)) ++ "_view".

%% A view that answers with `Text' (so editing its source changes the page).
view_src(Module, Text) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, <<\"~s\">>).~n", [Module, Text])).

%% A view that renders its template.
template_view_src(Module) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, weberl_template:render(?MODULE, #{})).~n",
                    [Module])).

ebin(Dir) -> filename:join([Dir, "_build", "default", "lib", "app", "ebin"]).

%% What a project's build does, for the views in the directory.
build_script() ->
    "mkdir -p _build/default/lib/app/ebin && "
    "erlc -o _build/default/lib/app/ebin $(find . -name '*_view.erl' -not -path './_build/*')".

build() -> {"sh", ["-c", build_script()]}.

build_and_load(Dir, Module) ->
    ?assertEqual("", os:cmd("cd " ++ Dir ++ " && " ++ build_script())),
    {module, _} = code:load_abs(filename:join(ebin(Dir), atom_to_list(Module))),
    ok.

get(Name, Path) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    {ok, {{_, Status, _}, _Headers, Body}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    {Status, Body}.

%% Poll until the page is as expected: the reload is asynchronous.
eventually(Name, Path, Expected) -> eventually(Name, Path, Expected, 100).

eventually(Name, Path, Expected, 0) ->
    ?assertEqual(Expected, get(Name, Path));
eventually(Name, Path, Expected, Left) ->
    case get(Name, Path) of
        Expected -> ok;
        _ -> timer:sleep(50), eventually(Name, Path, Expected, Left - 1)
    end.

%% Weberl serving `Dir', and the reloader watching it with weberl:reload as its hook.
with_site(Files, Module, Fun) ->
    with_tmp(fun(Dir) ->
        write_tree(Dir, Files),
        build_and_load(Dir, Module),
        Name = weberl_test_handlers:unique("fr"),
        {ok, _} = weberl:start_link(Name, #router{filesystem = [#filesystem_router{root = Dir}]},
                                    listener()),
        {ok, _} = erl_file_reloader:start_link(
                    #{root => Dir, interval_ms => 25, debounce_ms => 60,
                      watches => [{code, #{directories => ["."], extensions => [".erl"],
                                           build => build(), load => beams}},
                                  {templates, #{directories => ["."],
                                                extensions => [".weberl"]}}],
                      on_change => [{weberl, reload, [Name]}]}),
        try
            Fun(Dir, Name)
        after
            erl_file_reloader:stop(),
            weberl:stop(Name),
            code:purge(Module), code:delete(Module), code:purge(Module)
        end
    end).

%% ---------------------------------------------------------------------

edited_template() ->
    Home = view_name("home"),
    with_site([{Home ++ ".erl", template_view_src(Home)}, {Home ++ ".weberl", <<"<p>one</p>">>}],
              list_to_atom(Home),
              fun(Dir, Name) ->
                  ?assertEqual({200, <<"<p>one</p>">>}, get(Name, "/")),
                  write_tree(Dir, [{Home ++ ".weberl", <<"<p>two</p>">>}]),
                  eventually(Name, "/", {200, <<"<p>two</p>">>})
              end).

edited_view() ->
    Home = view_name("home"),
    with_site([{Home ++ ".erl", view_src(Home, "before")}], list_to_atom(Home),
              fun(Dir, Name) ->
                  ?assertEqual({200, <<"before">>}, get(Name, "/")),
                  write_tree(Dir, [{Home ++ ".erl", view_src(Home, "after")}]),
                  eventually(Name, "/", {200, <<"after">>})
              end).

new_view() ->
    Home = view_name("home"),
    Extra = view_name("extra"),
    with_site([{Home ++ ".erl", view_src(Home, "home")}], list_to_atom(Home),
              fun(Dir, Name) ->
                  ?assertMatch({404, _}, get(Name, "/extra")),
                  write_tree(Dir, [{"extra/" ++ Extra ++ ".erl", view_src(Extra, "extra page")}]),
                  try
                      eventually(Name, "/extra", {200, <<"extra page">>}),
                      ?assertEqual({200, <<"home">>}, get(Name, "/"))
                  after
                      Mod = list_to_atom(Extra),
                      code:purge(Mod), code:delete(Mod), code:purge(Mod)
                  end
              end).
