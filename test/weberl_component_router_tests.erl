%% Components with the router: the `components' directories are read when the router starts, are not
%% views' templates, and work in layouts, regions and forms.
-module(weberl_component_router_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

bin(IoData) -> iolist_to_binary(IoData).

panel() -> {"components/panel.weberl", <<"{: param title :}\n<section><h2>{{ @title }}</h2>{: content :}</section>">>}.

view_src(Module, Attrs) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n~s~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, <<\"x\">>).~n", [Module, Attrs])).

%% Writes a view, its template and the extra files; `Components' are the router's directories
%% (relative to the temp dir). `Fun' gets the view and the result of preparing the router.
run(Attrs, Template, Files, Components, Layouts, Fun) ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique("cr")) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl", view_src(V, Attrs)},
                         {"views/" ++ V ++ ".weberl", Template} | Files]),
        File = filename:join(Dir, "views/" ++ V ++ ".erl"),
        {ok, Mod, Binary} = compile:file(File, [binary, return_errors]),
        {module, Mod} = code:load_binary(Mod, File, Binary),
        Router = #router{filesystem = [#filesystem_router{root = filename:join(Dir, "views")}],
                         components = [filename:join(Dir, C) || C <- Components],
                         layouts = [filename:join(Dir, L) || L <- Layouts]},
        {ok, R} = weberl_config:validate(Router),
        {ok, Table} = weberl:build(R),
        Fun(Mod, weberl_views:prepare(R, Table))
    end).

view(Attrs, Template, Files, Components, Layouts, Fun) ->
    run(Attrs, Template, Files, Components, Layouts, fun(V, ok) -> Fun(V) end).

a_view_uses_a_component_from_the_configured_directory_test() ->
    view("", <<"{: component panel, #{title => @t} :}<p>x</p>{: /component :}">>, [panel()], ["components"], [],
         fun(V) ->
                 ?assertEqual(<<"<section><h2>T</h2><p>x</p></section>">>,
                              bin(weberl_template:render(V, #{t => <<"T">>})))
         end).

a_components_directory_inside_the_views_is_not_a_view_template_test() ->
    Inside = {"views/components/panel.weberl", <<"{: param title :}<b>{{ @title }}</b>">>},
    view("", <<"{: component panel, #{title => 1} :}{: /component :}">>, [Inside], ["views/components"], [],
         fun(V) -> ?assertEqual(<<"<b>1</b>">>, bin(weberl_template:render(V, #{}))) end).

a_layout_can_use_a_component_test() ->
    Layout = {"layouts/main.weberl", <<"{: component panel, #{title => \"L\"} :}{: content :}{: /component :}">>},
    view("-weberl_route(#{layout => main}).", <<"<p>v</p>">>, [panel(), Layout], ["components"], ["layouts"],
         fun(V) ->
                 ?assertEqual(<<"<section><h2>L</h2><p>v</p></section>">>, bin(weberl_template:render(V, #{})))
         end).

a_component_in_a_region_follows_the_regions_dependencies_test() ->
    T = <<"{: region r :}{: component panel, #{title => @t} :}{{ @body }}{: /component :}{: /region r :}">>,
    view("", T, [panel()], ["components"], [],
         fun(V) ->
                 {ok, #{r := #{variables := Vars}}} = weberl_template:regions(V),
                 ?assertEqual([body, t], Vars),
                 ?assertEqual(<<"<section><h2>N</h2>B</section>">>,
                              bin(weberl_template:render_region(V, r, #{t => <<"N">>, body => <<"B">>})))
         end).

a_form_in_a_component_inside_a_region_has_no_request_to_ask_test() ->
    Form = {"components/f.weberl", <<"{: form weberl_url:ensure_path(<<\"/x\">>) :}<i></i>{: /form :}">>},
    T = <<"{: region r :}{: component f :}{: /component :}{: /region r :}">>,
    view("", T, [Form], ["components"], [],
         fun(V) ->
                 Out = bin(weberl_template:render_region(V, r, #{})),
                 ?assertMatch({match, _}, re:run(Out, "data-weberl-csrf"))
         end).

an_unknown_component_fails_the_start_test() ->
    run("", <<"{: component nope :}{: /component :}">>, [], [], [],
        fun(_V, Result) ->
                ?assertMatch({error, {invalid_templates, [{_, {syntax_error, _, 1, {unknown_component, <<"nope">>}}}]}},
                             Result)
        end).

a_bad_component_fails_the_start_test() ->
    run("", <<"x">>, [{"components/bad.weberl", <<"{{ @undeclared }}">>}], ["components"], [],
        fun(_V, Result) ->
                ?assertMatch({error, {syntax_error, _, 1, {undeclared_assign, undeclared}}}, Result)
        end).

configuration_test() ->
    ?assertMatch({error, {invalid_config, {components_not_a_list, foo}}},
                 weberl_config:validate(#router{components = foo})),
    ?assertMatch({error, {invalid_config, {components, {invalid_directory, ""}}}},
                 weberl_config:validate(#router{components = [""]})),
    {ok, R} = weberl_config:validate(#router{components = ["c"]}),
    ?assertEqual(["c"], weberl_config:components(R)).
