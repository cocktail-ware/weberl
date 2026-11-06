%% Runtime layouts (HANDOFF.md, decision 15): a view is rendered with a layout chosen per render
%% among the ones its route allows (`layout' is the default, `layouts' lists others, `none' is
%% the bare view); every allowed pair is compiled when the router starts, and a live page
%% remembers its layout.
-module(weberl_runtime_layout_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

bin(IoData) -> iolist_to_binary(IoData).

main() -> {"layouts/main.weberl", <<"<main>{: content :}</main>">>}.
admin() -> {"layouts/admin.weberl", <<"<admin>{: content :}</admin>">>}.

view_src(Module, Attrs) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n~s~n-export([handle/1]).~n"
                    "handle(_) -> weberl_response:html(200, <<\"x\">>).~n", [Module, Attrs])).

%% Writes one view with the template, the layouts, loads the view and prepares the router.
%% {View, Result}; the view stays loaded for `Fun'.
run(Attrs, Template, Layouts, Fun) ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique("rt")) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl", view_src(V, Attrs)},
                         {"views/" ++ V ++ ".weberl", Template} | Layouts]),
        File = filename:join(Dir, "views/" ++ V ++ ".erl"),
        {ok, Mod, Binary} = compile:file(File, [binary, return_errors]),
        {module, Mod} = code:load_binary(Mod, File, Binary),
        Router = #router{filesystem = [#filesystem_router{root = filename:join(Dir, "views")}],
                         layouts = [filename:join(Dir, "layouts")]},
        {ok, R} = weberl_config:validate(Router),
        {ok, Table} = weberl:build(R),
        Fun(Mod, weberl_views:prepare(R, Table))
    end).

ok_view(Attrs, Template, Layouts, Fun) ->
    run(Attrs, Template, Layouts, fun(V, ok) -> Fun(V) end).

failing(Attrs, Template, Layouts) ->
    run(Attrs, Template, Layouts, fun(_V, Result) -> Result end).

%% ---------------------------------------------------------------------
%% rendering

default_is_what_render_2_gives_test() ->
    ok_view("-weberl_route(#{layout => main, layouts => [admin, none]}).", <<"<p>{{ @t }}</p>">>,
            [main(), admin()],
            fun(V) ->
                ?assertEqual(<<"<main><p>x</p></main>">>, bin(weberl_template:render(V, #{t => <<"x">>}))),
                ?assertEqual(<<"<main><p>x</p></main>">>,
                             bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => main})))
            end).

another_layout_is_chosen_per_render_test() ->
    ok_view("-weberl_route(#{layout => main, layouts => [admin, none]}).", <<"<p>{{ @t }}</p>">>,
            [main(), admin()],
            fun(V) ->
                ?assertEqual(<<"<admin><p>x</p></admin>">>,
                             bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => admin}))),
                ?assertEqual(<<"<p>x</p>">>,
                             bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => none}))),
                ?assertEqual({ok, <<"<admin><p>x</p></admin>">>},
                             begin {ok, H} = weberl_template:try_render(V, #{t => <<"x">>}, #{layout => admin}),
                                   {ok, bin(H)} end)
            end).

a_default_of_none_can_still_be_wrapped_test() ->
    ok_view("-weberl_route(#{layouts => [admin]}).", <<"<p>{{ @t }}</p>">>, [main(), admin()],
            fun(V) ->
                ?assertEqual(<<"<p>x</p>">>, bin(weberl_template:render(V, #{t => <<"x">>}))),
                ?assertEqual(<<"<p>x</p>">>, bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => none}))),
                ?assertEqual(<<"<admin><p>x</p></admin>">>,
                             bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => admin})))
            end).

all_allows_every_discovered_layout_test() ->
    ok_view("-weberl_route(#{layout => main, layouts => all}).", <<"<p>{{ @t }}</p>">>, [main(), admin()],
            fun(V) ->
                ?assertEqual({ok, [main, admin]}, weberl_template:layouts(V)),
                ?assertEqual(<<"<admin><p>x</p></admin>">>,
                             bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => admin}))),
                %% `none' is only there when it is listed
                ?assertError({template_error, {unknown_layout, V, none}},
                             weberl_template:render(V, #{t => <<"x">>}, #{layout => none}))
            end).

%% ---------------------------------------------------------------------
%% what is allowed

a_layout_the_route_does_not_allow_raises_test() ->
    ok_view("-weberl_route(#{layout => main}).", <<"<p>{{ @t }}</p>">>, [main(), admin()],
            fun(V) ->
                ?assertEqual({ok, [main]}, weberl_template:layouts(V)),
                ?assertError({template_error, {unknown_layout, V, admin}},
                             weberl_template:render(V, #{t => <<"x">>}, #{layout => admin})),
                ?assertError({template_error, {unknown_layout, V, nope}},
                             weberl_template:render(V, #{t => <<"x">>}, #{layout => nope})),
                ?assertError({template_error, {unknown_layout, V, <<"admin">>}},
                             weberl_template:render(V, #{t => <<"x">>}, #{layout => <<"admin">>})),
                ?assertEqual({error, {unknown_layout, V, admin}},
                             weberl_template:try_render(V, #{t => <<"x">>}, #{layout => admin}))
            end).

introspection_reports_default_and_allowed_set_test() ->
    ok_view("-weberl_route(#{layout => admin, layouts => [none, main]}).", <<"<p>{{ @t }}</p>">>,
            [main(), admin()],
            fun(V) ->
                ?assertEqual({ok, admin}, weberl_template:layout(V)),
                ?assertEqual({ok, [admin, main, none]}, weberl_template:layouts(V))
            end).

a_view_without_a_template_has_no_layouts_test() ->
    ?assertEqual({error, {no_template, weberl_no_such_view}}, weberl_template:layouts(weberl_no_such_view)),
    ?assertError({template_error, {no_template, weberl_no_such_view}},
                 weberl_template:render(weberl_no_such_view, #{}, #{layout => main})).

%% ---------------------------------------------------------------------
%% checked when the router starts

an_unknown_layout_in_the_set_fails_the_start_test() ->
    {error, {invalid_templates, [{_V, {unknown_layout, nope}}]}} =
        failing("-weberl_route(#{layout => main, layouts => [nope]}).", <<"<p>{{ @t }}</p>">>, [main()]).

a_fill_a_layout_has_no_slot_for_fails_the_start_test() ->
    Slotted = {"layouts/slotted.weberl", <<"<head>{: slot head :}{: /slot head :}</head>{: content :}">>},
    {error, {invalid_templates, [{_V, {syntax_error, _File, _Line, {unknown_fill, head, _Layout}}}]}} =
        failing("-weberl_route(#{layout => slotted, layouts => [main]}).",
                <<"{: fill head :}<b>h</b>{: /fill head :}<p>{{ @t }}</p>">>, [main(), Slotted]).

fills_cannot_be_rendered_bare_test() ->
    Slotted = {"layouts/slotted.weberl", <<"<head>{: slot head :}{: /slot head :}</head>{: content :}">>},
    {error, {invalid_templates, [{_V, {syntax_error, _File, _Line, {fill_without_layout, head}}}]}} =
        failing("-weberl_route(#{layout => slotted, layouts => [none]}).",
                <<"{: fill head :}<b>h</b>{: /fill head :}<p>{{ @t }}</p>">>, [Slotted]).

fills_work_in_every_layout_that_has_the_slot_test() ->
    Slotted = {"layouts/slotted.weberl", <<"<head>{: slot head :}{: /slot head :}</head>{: content :}">>},
    Other = {"layouts/other.weberl", <<"<top>{: slot head :}default{: /slot head :}</top>{: content :}">>},
    ok_view("-weberl_route(#{layout => slotted, layouts => [other]}).",
            <<"{: fill head :}<b>h</b>{: /fill head :}<p>{{ @t }}</p>">>, [Slotted, Other],
            fun(V) ->
                ?assertEqual(<<"<head><b>h</b></head><p>x</p>">>, bin(weberl_template:render(V, #{t => <<"x">>}))),
                ?assertEqual(<<"<top><b>h</b></top><p>x</p>">>,
                             bin(weberl_template:render(V, #{t => <<"x">>}, #{layout => other})))
            end).

a_region_name_used_by_one_layout_and_the_view_fails_the_start_test() ->
    Clash = {"layouts/clash.weberl", <<"{: region r :}c{: /region r :}{: content :}">>},
    {error, {invalid_templates, [{_V, {duplicate_region, r, _L, _F}}]}} =
        failing("-weberl_route(#{layout => main, layouts => [clash]}).",
                <<"{: region r :}<p>{{ @t }}</p>{: /region r :}">>, [main(), Clash]).

layouts_need_a_template_test() ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique("rt")) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl", view_src(V, "-weberl_route(#{layouts => [main]}).")},
                         main()]),
        File = filename:join(Dir, "views/" ++ V ++ ".erl"),
        {ok, Mod, Binary} = compile:file(File, [binary, return_errors]),
        {module, Mod} = code:load_binary(Mod, File, Binary),
        Router = #router{filesystem = [#filesystem_router{root = filename:join(Dir, "views")}],
                         layouts = [filename:join(Dir, "layouts")]},
        {ok, R} = weberl_config:validate(Router),
        {ok, Table} = weberl:build(R),
        ?assertEqual({error, {invalid_templates, [{Mod, layout_without_template}]}},
                     weberl_views:prepare(R, Table))
    end).

%% ---------------------------------------------------------------------
%% route options

layouts_option_is_checked_test() ->
    ?assertEqual({ok, #{layouts => [a, b]}}, weberl_route:check_opts(#{layouts => [a, b]})),
    ?assertEqual({ok, #{layouts => all}}, weberl_route:check_opts(#{layouts => all})),
    ?assertEqual({error, {invalid_layouts, [a, "b"]}}, weberl_route:check_opts(#{layouts => [a, "b"]})),
    ?assertEqual({error, {invalid_layouts, main}}, weberl_route:check_opts(#{layouts => main})).

%% ---------------------------------------------------------------------
%% regions

layout_regions_exist_only_in_the_pairs_that_use_the_layout_test() ->
    Side = {"layouts/side.weberl", <<"<aside>{: region side :}{{ @who }}{: /region side :}</aside>{: content :}">>},
    ok_view("-weberl_route(#{layout => main, layouts => [side, none]}).",
            <<"{: region body :}<p>{{ @t }}</p>{: /region body :}">>, [main(), Side],
            fun(V) ->
                ?assertMatch({ok, #{body := _}}, weberl_template:regions(V)),
                {ok, WithSide} = weberl_template:regions(V, #{layout => side}),
                ?assertEqual([body, side], lists:sort(maps:keys(WithSide))),
                ?assertEqual({ok, [body]}, begin {ok, B} = weberl_template:regions(V, #{layout => none}),
                                                 {ok, maps:keys(B)} end),
                ?assertEqual(<<"bob">>, bin(weberl_template:render_region(V, side, #{who => <<"bob">>}, #{layout => side}))),
                ?assertError({template_error, {unknown_region, V, side}},
                             weberl_template:render_region(V, side, #{who => <<"bob">>})),
                ?assertEqual({error, {unknown_region, V, side}},
                             weberl_template:try_render_region(V, side, #{who => <<"b">>}, #{layout => none})),
                ?assertEqual({error, {unknown_layout, V, admin}}, weberl_template:regions(V, #{layout => admin})),
                %% a region of the view is the same in each pair
                ?assertEqual(<<"<p>x</p>">>,
                             bin(weberl_template:render_region(V, body, #{t => <<"x">>}, #{layout => side})))
            end).

%% ---------------------------------------------------------------------
%% live pages

live_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(weberl), ok end, fun(_) -> ok end,
     [{"mount/4 renders with the layout and the page's regions follow it", fun live_mount/0},
      {"a page mounted with the default does not get a region of another layout", fun live_default/0},
      {"update/3 and a rebuilt record keep the page's layout", fun live_update/0},
      {"update_topic/5 renders with the layout it is given", fun live_topic/0}]}.

live_layouts() ->
    [main(), {"layouts/side.weberl",
              <<"<aside>{: region side :}{{ @who }}{: /region side :}</aside>{: content :}">>}].

live_view(Fun) ->
    ok_view("-weberl_route(#{layout => main, layouts => [side]}).",
            <<"{: region body :}<p>{{ @t }}</p>{: /region body :}">>, live_layouts(), Fun).

open_page(V) ->
    {ok, Id} = weberl_live:open(rt_owner, one_way, #{handler => V}),
    ok = weberl_live:attach(Id, self()),
    {Id, weberl_request:with_page(weberl_request:new(#{method => <<"GET">>, path => "/p"}), Id)}.

region(Id) ->
    receive
        {weberl_live, Id, {event, <<"weberl:region">>, Data}} ->
            #{~"region" := R, ~"html" := H} = json:decode(Data),
            {binary_to_atom(R), H}
    after 300 -> timeout
    end.

live_mount() ->
    live_view(fun(V) ->
        {Id, Request} = open_page(V),
        Data = weberl_view_data:new(#{t => <<"x">>, who => <<"ann">>}),
        Html = bin(weberl_live:mount(V, Request, Data, #{layout => side})),
        ?assertEqual(<<"<aside><weberl-region name=\"side\">ann</weberl-region></aside>"
                       "<weberl-region name=\"body\"><p>x</p></weberl-region>">>, Html),
        ?assertEqual({ok, side}, begin {ok, VD} = weberl_live:view(Id),
                                       {ok, weberl_view_data:layout(VD)} end),
        ok = weberl_live:assign(Id, #{who => <<"bob">>}),
        ?assertEqual({side, <<"bob">>}, region(Id)),
        ok = weberl_live:assign(Id, #{t => <<"y">>}),
        ?assertEqual({body, <<"<p>y</p>">>}, region(Id))
    end).

live_default() ->
    live_view(fun(V) ->
        {Id, Request} = open_page(V),
        Html = bin(weberl_live:mount(V, Request, weberl_view_data:new(#{t => <<"x">>, who => <<"ann">>}))),
        ?assertEqual(<<"<main><weberl-region name=\"body\"><p>x</p></weberl-region></main>">>, Html),
        ok = weberl_live:assign(Id, #{who => <<"bob">>}),
        ?assertEqual(timeout, region(Id)),
        ok = weberl_live:assign(Id, #{t => <<"y">>}),
        ?assertEqual({body, <<"<p>y</p>">>}, region(Id))
    end).

live_update() ->
    live_view(fun(V) ->
        {Id, Request} = open_page(V),
        _ = weberl_live:mount(V, Request, weberl_view_data:new(#{t => <<"x">>, who => <<"ann">>}), #{layout => side}),
        %% update/3 renders from the layout of the page, so a region only that layout has works
        ok = weberl_live:update(Id, side, #{who => <<"cy">>}),
        ?assertEqual({side, <<"cy">>}, region(Id)),
        %% a callback that builds a record afresh does not reset the layout
        ok = weberl_live:modify(Id, fun(_) -> weberl_view_data:new(#{t => <<"x">>, who => <<"dee">>}) end),
        ?assertEqual({side, <<"dee">>}, region(Id)),
        ?assertEqual({ok, side}, begin {ok, VD} = weberl_live:view(Id),
                                       {ok, weberl_view_data:layout(VD)} end)
    end).

live_topic() ->
    live_view(fun(V) ->
        Topic = <<"rt-topic">>,
        ok = pg:join(weberl_live, {topic, Topic}, self()),
        try
            ?assertEqual(ok, weberl_live:update_topic(Topic, V, side, #{who => <<"eve">>}, #{layout => side})),
            receive
                {weberl_live_topic, Topic, <<"weberl:region">>, Payload, _Frame} ->
                    ?assertEqual(#{~"region" => ~"side", ~"html" => ~"eve"}, json:decode(Payload))
            after 500 -> ?assert(false)
            end,
            %% the default pair has no such region
            weberl_live_test_util:quiet(fun() ->
                ?assertEqual({error, {unknown_region, V, side}},
                             weberl_live:update_topic(Topic, V, side, #{who => <<"eve">>}))
            end)
        after
            pg:leave(weberl_live, {topic, Topic}, self())
        end
    end).
