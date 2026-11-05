%% Feedback from agentic (item 5): "Layout is only selectable through weberl_metadata/0, not
%% through the -weberl_route(...) attribute next to -weberl_page(...); one place would be
%% more predictable." A view selects its layout in its route options, and that is the only
%% way (weberl_metadata/0 was removed: nothing else used it).
-module(weberl_route_layout_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2, load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

bin(IoData) -> iolist_to_binary(IoData).

%% A view with the given attributes and, optionally, a leftover weberl_metadata/0 (which
%% nothing reads any more).
view_src(Module, Attrs, Meta) ->
    MetaFun = case Meta of
                  none -> "";
                  _ -> io_lib:format("weberl_metadata() -> ~s.~n", [Meta])
              end,
    Exports = case Meta of none -> "[handle/1]"; _ -> "[handle/1, weberl_metadata/0]" end,
    iolist_to_binary(
      io_lib:format("-module(~s).~n~s~n-export(~s).~n~s"
                    "handle(_) ->~n"
                    "    weberl_response:html(200, weberl_template:render(?MODULE, #{t => <<\"T\">>})).~n",
                    [Module, Attrs, Exports, MetaFun])).

compile_load(File) ->
    {ok, Mod, Bin} = compile:file(File, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, File, Bin),
    ok.

prepare(Dir, Layouts) ->
    Router = #router{filesystem = [#filesystem_router{root = filename:join(Dir, "views")}],
                     layouts = Layouts},
    prepare_router(Router).

prepare_router(Router) ->
    case weberl_config:validate(Router) of
        {ok, R} ->
            case weberl:build(R) of
                {ok, Table} -> {Table, weberl_views:prepare(R, Table)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Writes one view (with its template) and a layout, loads the view, prepares the router.
%% Returns {ViewModule, Table, Result}.
run(Name, Attrs, Meta) ->
    run(Name, Attrs, Meta, [{"layouts/main.weberl", <<"<body>{: content :}</body>">>},
                            {"layouts/admin.weberl", <<"<admin>{: content :}</admin>">>}]).

run(Name, Attrs, Meta, Layouts) ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique(Name)) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl", view_src(V, Attrs, Meta)},
                         {"views/" ++ V ++ ".weberl", <<"<p>{{ t }}</p>">>} | Layouts]),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        {Table, Result} = prepare(Dir, [filename:join(Dir, "layouts")]),
        {list_to_atom(V), Table, Result}
    end).

route_of(View, Table) ->
    [R] = [R || R <- weberl:routes(Table), weberl_route:handler(R) =:= View],
    R.

%% ---------------------------------------------------------------------
%% One place: -weberl_route

route_attribute_selects_the_layout_test() ->
    {V, Table, ok} = run("a", "-weberl_route(#{layout => main}).", none),
    ?assertEqual(<<"<body><p>T</p></body>">>, bin(weberl_template:render(V, #{t => <<"T">>}))),
    ?assertEqual({ok, main}, weberl_route:layout(route_of(V, Table))),
    ?assertEqual({ok, main}, weberl_template:layout(V)).

the_layout_sits_next_to_the_page_kind_test() ->
    {V, Table, ok} = run("k", "-weberl_page(one_way).\n-weberl_route(#{layout => admin, csrf => origin}).", none),
    Route = route_of(V, Table),
    ?assertEqual(one_way, weberl_route:live(Route)),
    ?assertEqual(origin, weberl_route:csrf(Route)),
    ?assertEqual({ok, admin}, weberl_route:layout(Route)),
    ?assertEqual(<<"<admin><p>T</p></admin>">>, bin(weberl_template:render(V, #{t => <<"T">>}))).

no_layout_is_standalone_test() ->
    {V, Table, ok} = run("n", "-weberl_route(#{live => normal}).", none),
    ?assertEqual(none, weberl_route:layout(route_of(V, Table))),
    ?assertEqual({ok, none}, weberl_template:layout(V)),
    ?assertEqual(<<"<p>T</p>">>, bin(weberl_template:render(V, #{t => <<"T">>}))).

%% ---------------------------------------------------------------------
%% weberl_metadata/0 is gone

%% A view that still exports it is not an error, but it selects nothing: the page stays
%% standalone, so a missed migration shows up as a missing layout, not as a crash.
a_leftover_metadata_function_selects_nothing_test() ->
    {V, Table, ok} = run("m", "", "#{layout => main}"),
    ?assertEqual(none, weberl_route:layout(route_of(V, Table))),
    ?assertEqual({ok, none}, weberl_template:layout(V)),
    ?assertEqual(<<"<p>T</p>">>, bin(weberl_template:render(V, #{t => <<"T">>}))).

the_handler_module_has_no_metadata_api_test() ->
    ?assertEqual(false, erlang:function_exported(weberl_handler, metadata, 1)).

%% ---------------------------------------------------------------------
%% Errors

unknown_layout_in_the_route_test() ->
    {V, _, Result} = run("u", "-weberl_route(#{layout => nope}).", none),
    ?assertEqual({error, {invalid_templates, [{V, {unknown_layout, nope}}]}}, Result).

layout_without_a_template_test() ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique("t")) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl", view_src(V, "-weberl_route(#{layout => main}).", none)},
                         {"layouts/main.weberl", <<"{: content :}">>}]),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        {_, Result} = prepare(Dir, [filename:join(Dir, "layouts")]),
        ?assertEqual({error, {invalid_templates, [{list_to_atom(V), layout_without_template}]}}, Result)
    end).

invalid_layout_option_test_() ->
    [?_assertEqual({error, {invalid_layout, "main"}}, weberl_route:check_opts(#{layout => "main"})),
     ?_assertEqual({error, {invalid_layout, 5}}, weberl_route:check_opts(#{layout => 5})),
     ?_assertEqual({ok, #{layout => main}}, weberl_route:check_opts(#{layout => main}))].

invalid_layout_attribute_in_a_view_test() ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique("i")) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl", view_src(V, "-weberl_route(#{layout => \"main\"}).", none)}]),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        Router = #router{filesystem = [#filesystem_router{root = filename:join(Dir, "views")}]},
        {ok, R} = weberl_config:validate(Router),
        ?assertMatch({error, {invalid_route_attribute, _, {invalid_layout, "main"}}}, weberl:build(R))
    end).

%% Only filesystem views have templates, so a declarative route cannot name a layout.
declarative_route_cannot_name_a_layout_test() ->
    Handler = weberl_test_handlers:unique("decl"),
    weberl_test_handlers:load(
      Handler, "-module(" ++ atom_to_list(Handler) ++ "). -export([handle/1]). "
               "handle(_) -> weberl_response:text(200, <<\"x\">>)."),
    Routes = weberl_test_handlers:unique("decl_routes"),
    load_router(Routes, [{"/x", Handler, #{layout => main}}]),
    {Table, Result} = prepare_router(#router{modules = [Routes]}),
    ?assert(Table =/= error),
    ?assertEqual({error, {invalid_templates, [{Handler, layout_needs_a_filesystem_view}]}}, Result).

%% ---------------------------------------------------------------------
%% weberl_template:layout/1

layout_of_a_view_without_template_test() ->
    V = weberl_test_handlers:unique("notpl"),
    ?assertEqual({error, {no_template, V}}, weberl_template:layout(V)).
