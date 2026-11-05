%% Layouts: `{: content :}' in a layout, a view's template put into it.
-module(weberl_template_layout_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [with_tmp/1, write_tree/2]).

unique() -> weberl_test_handlers:unique("lview").

layout(Dir, Source) ->
    ok = file:write_file(filename:join(Dir, "main.weberl"), Source),
    {ok, L} = weberl_template:parse_layout(filename:join(Dir, "main.weberl")),
    L.

layout_error(Source) ->
    with_tmp(fun(Dir) ->
        ok = file:write_file(filename:join(Dir, "main.weberl"), Source),
        weberl_template:parse_layout(filename:join(Dir, "main.weberl"))
    end).

compile(Layout, Source) ->
    View = unique(),
    case weberl_template:compile_source(View, Source, "page.weberl", Layout) of
        {ok, C} -> ok = weberl_template:load(C), View;
        {error, _} = Error -> Error
    end.

bin(IoData) -> iolist_to_binary(IoData).

%% ---------------------------------------------------------------------
%% lexer and plain templates

lexer_test_() ->
    [?_assertEqual({ok, [{text, 1, <<"a ">>}, {content, 1}, {text, 1, <<" b">>}]},
                   weberl_template_lexer:tokenize(<<"a {: content :} b">>, "t.weberl")),
     ?_assertEqual({error, {syntax_error, "t.weberl", 1, {invalid_block_tag, <<" content x ">>}}},
                   weberl_template_lexer:tokenize(<<"{: content x :}">>, "t.weberl"))].

content_outside_a_layout_test() ->
    ?assertEqual({error, {syntax_error, "t.weberl", 2, content_outside_layout}},
                 weberl_template:compile_source(unique(), <<"a\n{: content :}">>, "t.weberl")),
    %% a view cannot use it either, with a layout
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"<body>{: content :}</body>">>),
        ?assertMatch({error, {syntax_error, "page.weberl", 1, content_outside_layout}},
                     compile(L, <<"{: content :}">>))
    end).

%% ---------------------------------------------------------------------
%% layout files

layout_validation_test_() ->
    [?_assertMatch({error, {missing_content, _}}, layout_error(<<"<body></body>">>)),
     ?_assertMatch({error, {multiple_content, _, [1, 2]}},
                   layout_error(<<"{: content :}\n{: content :}">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {content_in_unsupported_context, _}}},
                   layout_error(<<"<script>{: content :}</script>">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {content_in_unsupported_context, _}}},
                   layout_error(<<"<div class=\"{: content :}\">">>)),
     ?_assertMatch({error, {syntax_error, _, 1, unterminated_interpolation}},
                   layout_error(<<"{{ title {: content :}">>)),
     ?_assertMatch({error, {read_failed, "/nonexistent/x.weberl", enoent}},
                   weberl_template:parse_layout("/nonexistent/x.weberl"))].

%% ---------------------------------------------------------------------
%% composition

renders_view_inside_layout_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"<title>{{ title }}</title><nav>{{ user }}</nav>{: content :}<footer/>">>),
        V = compile(L, <<"<h1>{{ title }}</h1>">>),
        ?assertEqual(<<"<title>Hi</title><nav>ann</nav><h1>Hi</h1><footer/>">>,
                     bin(weberl_template:render(V, #{title => <<"Hi">>, user => <<"ann">>})))
    end).

variables_of_both_are_required_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{{ user }}{: content :}">>),
        V = compile(L, <<"{{ title }}">>),
        ?assertError({template_error, {missing_variable, V, user}},
                     weberl_template:render(V, #{title => <<"x">>})),
        ?assertEqual([title, user], maps:get(variables, (generated(V)):info()))
    end).

generated(V) -> weberl_template:generated_module(V).

view_is_still_checked_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: content :}">>),
        ?assertMatch({error, {syntax_error, "page.weberl", 1, {interpolation_in_unsupported_context, _}}},
                     compile(L, <<"<script>{{ x }}</script>">>))
    end).

regions_of_layout_and_view_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: region nav :}<b>{{ user }}</b>{: /region nav :}{: content :}">>),
        V = compile(L, <<"{: region body :}{{ text }}{: /region body :}">>),
        {ok, Regions} = weberl_template:regions(V),
        ?assertEqual([body, nav], lists:sort(maps:keys(Regions))),
        ?assertEqual(<<"<b>ann</b>">>, bin(weberl_template:render_region(V, nav, #{user => <<"ann">>}))),
        ?assertEqual(<<"t">>, bin(weberl_template:render_region(V, body, #{text => <<"t">>}))),
        ?assertEqual(<<"<weberl-region name=\"nav\"><b>ann</b></weberl-region>"
                       "<weberl-region name=\"body\">t</weberl-region>">>,
                     bin(weberl_template:render(V, #{user => <<"ann">>, text => <<"t">>})))
    end).

content_inside_a_layout_region_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: region page :}[{: content :}]{: /region page :}">>),
        V = compile(L, <<"{: region inner :}x{: /region inner :}">>),
        ?assertEqual(<<"[<weberl-region name=\"inner\">x</weberl-region>]">>,
                     bin(weberl_template:render_region(V, page, #{})))
    end).

duplicate_region_across_files_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: region a :}{: /region a :}{: content :}">>),
        ?assertMatch({error, {duplicate_region, a, _, "page.weberl"}},
                     compile(L, <<"{: region a :}{: /region a :}">>))
    end).

%% ---------------------------------------------------------------------
%% slots and fills

slot_layout() ->
    <<"<head>{: slot head :}<title>default</title>{: /slot head :}</head>"
      "<body>{: content :}{: slot foot :}{: /slot foot :}</body>">>.

slots_lexer_test_() ->
    [?_assertEqual({ok, [{block_open, 1, slot, head, #{}}, {block_close, 1, slot, head},
                         {block_open, 1, fill, head, #{}}, {block_close, 1, fill, head}]},
                   weberl_template_lexer:tokenize(
                     <<"{: slot head :}{: /slot head :}{: fill head :}{: /fill head :}">>, "t.weberl")),
     ?_assertEqual({error, {syntax_error, "t.weberl", 1, {invalid_block_tag, <<" slot content ">>}}},
                   weberl_template_lexer:tokenize(<<"{: slot content :}">>, "t.weberl")),
     ?_assertEqual({error, {syntax_error, "t.weberl", 1, {invalid_block_tag, <<" fill Head ">>}}},
                   weberl_template_lexer:tokenize(<<"{: fill Head :}">>, "t.weberl"))].

default_and_filled_slot_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, slot_layout()),
        Plain = compile(L, <<"<p>hi</p>">>),
        ?assertEqual(<<"<head><title>default</title></head><body><p>hi</p></body>">>,
                     bin(weberl_template:render(Plain, #{}))),
        Filled = compile(L, <<"{: fill head :}<title>{{ t }}</title>{: /fill head :}<p>hi</p>"
                              "{: fill foot :}<i>{{ n }}</i>{: /fill foot :}">>),
        ?assertEqual(<<"<head><title>T</title></head><body><p>hi</p><i>1</i></body>">>,
                     bin(weberl_template:render(Filled, #{t => <<"T">>, n => 1})))
    end).

only_fills_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, slot_layout()),
        V = compile(L, <<"{: fill head :}H{: /fill head :}">>),
        ?assertEqual(<<"<head>H</head><body></body>">>, bin(weberl_template:render(V, #{})))
    end).

replaced_default_needs_no_variables_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: slot s :}{{ d }}{: /slot s :}{: content :}">>),
        V = compile(L, <<"{: fill s :}x{: /fill s :}">>),
        ?assertEqual(<<"x">>, bin(weberl_template:render(V, #{}))),
        ?assertEqual([], maps:get(variables, (generated(V)):info())),
        P = compile(L, <<"y">>),
        ?assertEqual([d], maps:get(variables, (generated(P)):info()))
    end).

slot_inside_layout_region_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: region bar :}{: slot s :}d{: /slot s :}{: /region bar :}{: content :}">>),
        V = compile(L, <<"{: fill s :}{{ x }}{: /fill s :}">>),
        ?assertEqual(<<"v">>, bin(weberl_template:render_region(V, bar, #{x => <<"v">>})))
    end).

region_in_fill_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, <<"{: slot s :}{: /slot s :}{: content :}">>),
        V = compile(L, <<"{: fill s :}{: region r :}{{ x }}{: /region r :}{: /fill s :}">>),
        {ok, #{r := #{variables := [x]}}} = weberl_template:regions(V),
        ?assertEqual(<<"1">>, bin(weberl_template:render_region(V, r, #{x => 1})))
    end).

slot_errors_test() ->
    with_tmp(fun(Dir) ->
        L = layout(Dir, slot_layout()),
        E = fun(Line, Reason) -> {error, {syntax_error, "page.weberl", Line, Reason}} end,
        ?assertEqual(E(1, {unknown_fill, nope, filename:join(Dir, "main.weberl")}),
                     compile(L, <<"{: fill nope :}x{: /fill nope :}">>)),
        ?assertEqual(E(1, {duplicate_fill, head, 1}),
                     compile(L, <<"{: fill head :}{: /fill head :}{: fill head :}{: /fill head :}">>)),
        ?assertEqual(E(1, {fill_not_top_level, head}),
                     compile(L, <<"{: region r :}{: fill head :}{: /fill head :}{: /region r :}">>)),
        ?assertEqual(E(1, {unclosed_fill, head}), compile(L, <<"{: fill head :}">>)),
        ?assertEqual(E(1, {mismatched_fill_end, head, foot}),
                     compile(L, <<"{: fill head :}{: /fill foot :}">>)),
        ?assertEqual(E(1, {mismatched_block_end, {fill, head}, {region, head}}),
                     compile(L, <<"{: fill head :}{: /region head :}">>)),
        ?assertEqual(E(1, {unbalanced_markup, fill, head}),
                     compile(L, <<"{: fill head :}<div{: /fill head :}">>)),
        ?assertEqual(E(1, {content_unbalanced_markup, tag}), compile(L, <<"<div ">>)),
        ?assertEqual(E(1, {slot_outside_layout, head}),
                     compile(L, <<"{: slot head :}{: /slot head :}">>)),
        ?assertEqual(E(1, {interpolation_in_unsupported_context, <<"script">>}),
                     compile(L, <<"{: fill head :}<script>{{ x }}</script>{: /fill head :}">>))
    end).

standalone_template_errors_test() ->
    E = fun(Src) -> weberl_template:compile_source(unique(), Src, "t.weberl") end,
    ?assertEqual({error, {syntax_error, "t.weberl", 1, {fill_without_layout, a}}},
                 E(<<"{: fill a :}{: /fill a :}">>)),
    ?assertEqual({error, {syntax_error, "t.weberl", 1, {slot_outside_layout, a}}},
                 E(<<"{: slot a :}{: /slot a :}">>)).

layout_file_slot_errors_test_() ->
    [?_assertMatch({error, {syntax_error, _, 1, {slot_in_slot, b}}},
                   layout_error(<<"{: slot a :}{: slot b :}{: /slot b :}{: /slot a :}{: content :}">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {content_in_slot, a}}},
                   layout_error(<<"{: slot a :}{: content :}{: /slot a :}">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {duplicate_slot, a, 1}}},
                   layout_error(<<"{: slot a :}{: /slot a :}{: slot a :}{: /slot a :}{: content :}">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {fill_in_layout, a}}},
                   layout_error(<<"{: content :}{: fill a :}{: /fill a :}">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {in_unsupported_context, slot, a, _}}},
                   layout_error(<<"<div class=\"{: slot a :}{: /slot a :}\">{: content :}">>)),
     ?_assertMatch({error, {syntax_error, _, 1, {unbalanced_markup, slot, a}}},
                   layout_error(<<"{: slot a :}<b{: /slot a :}{: content :}">>))].

%% ---------------------------------------------------------------------
%% selection by metadata, through a router

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

view_src(Module, Meta) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([handle/1, weberl_metadata/0]).~n"
                    "weberl_metadata() -> ~s.~n"
                    "handle(_) ->~n"
                    "    weberl_response:html(200, weberl_template:render(?MODULE, #{t => <<\"T\">>})).~n",
                    [Module, Meta])).

compile_load(File) ->
    {ok, Mod, Bin} = compile:file(File, [binary, return_errors]),
    {module, Mod} = code:load_binary(Mod, File, Bin),
    ok.

prepare(Dir, Layouts) ->
    Router = #router{filesystem = [#filesystem_router{root = filename:join(Dir, "views")}],
                     layouts = Layouts},
    {ok, R} = weberl_config:validate(Router),
    {ok, Table} = weberl:build(R),
    weberl_views:prepare(R, Table).

views_test_() ->
    {foreach, fun() -> ok end, fun(_) -> ok end,
     [{"layout from metadata", fun metadata_layout/0},
      {"view without layout stays standalone", fun standalone/0},
      {"layout below the views root is not an unassociated template", fun layout_in_views/0},
      {"unknown layout", fun unknown_layout/0},
      {"layout metadata without a template", fun no_template/0},
      {"duplicate layout names", fun duplicate_layouts/0},
      {"invalid layout", fun invalid_layout/0}]}.

setup(Name, Meta, Tpl, Layouts) ->
    V = atom_to_list(weberl_test_handlers:unique(Name)) ++ "_view",
    {V, [{"views/" ++ V ++ ".erl", view_src(V, Meta)}, {"views/" ++ V ++ ".weberl", Tpl} | Layouts]}.

metadata_layout() ->
    with_tmp(fun(Dir) ->
        {V, Files} = setup("m", "#{layout => main}", <<"<p>{{ t }}</p>">>,
                           [{"layouts/main.weberl", <<"<body>{: content :}</body>">>}]),
        write_tree(Dir, Files),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        ok = prepare(Dir, [filename:join(Dir, "layouts")]),
        ?assertEqual(<<"<body><p>T</p></body>">>,
                     bin(weberl_template:render(list_to_atom(V), #{t => <<"T">>})))
    end).

standalone() ->
    with_tmp(fun(Dir) ->
        {V, Files} = setup("s", "#{}", <<"<p>{{ t }}</p>">>,
                           [{"layouts/main.weberl", <<"<body>{: content :}</body>">>}]),
        write_tree(Dir, Files),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        ok = prepare(Dir, [filename:join(Dir, "layouts")]),
        ?assertEqual(<<"<p>T</p>">>, bin(weberl_template:render(list_to_atom(V), #{t => <<"T">>})))
    end).

layout_in_views() ->
    with_tmp(fun(Dir) ->
        {V, Files} = setup("v", "#{layout => main}", <<"<p>{{ t }}</p>">>,
                           [{"views/layouts/main.weberl", <<"<body>{: content :}</body>">>}]),
        write_tree(Dir, Files),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        ok = prepare(Dir, [filename:join(Dir, "views/layouts")]),
        ?assertEqual(<<"<body><p>T</p></body>">>,
                     bin(weberl_template:render(list_to_atom(V), #{t => <<"T">>})))
    end).

unknown_layout() ->
    with_tmp(fun(Dir) ->
        {V, Files} = setup("u", "#{layout => nope}", <<"x">>, []),
        write_tree(Dir, Files),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        View = list_to_atom(V),
        ?assertEqual({error, {invalid_templates, [{View, {unknown_layout, nope}}]}},
                     prepare(Dir, []))
    end).

no_template() ->
    with_tmp(fun(Dir) ->
        V = atom_to_list(weberl_test_handlers:unique("n")) ++ "_view",
        write_tree(Dir, [{"views/" ++ V ++ ".erl",
                          iolist_to_binary(io_lib:format(
                            "-module(~s).~n-export([handle/1, weberl_metadata/0]).~n"
                            "weberl_metadata() -> #{layout => main}.~n"
                            "handle(_) -> weberl_response:html(200, <<\"x\">>).~n", [V]))},
                         {"layouts/main.weberl", <<"{: content :}">>}]),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        ?assertEqual({error, {invalid_templates, [{list_to_atom(V), layout_without_template}]}},
                     prepare(Dir, [filename:join(Dir, "layouts")]))
    end).

duplicate_layouts() ->
    with_tmp(fun(Dir) ->
        {V, Files} = setup("d", "#{}", <<"x">>,
                           [{"l1/main.weberl", <<"{: content :}">>}, {"l2/main.weberl", <<"{: content :}">>}]),
        write_tree(Dir, Files),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        ?assertMatch({error, {duplicate_layouts, [{main, [_, _]}]}},
                     prepare(Dir, [filename:join(Dir, "l1"), filename:join(Dir, "l2")]))
    end).

invalid_layout() ->
    with_tmp(fun(Dir) ->
        {V, Files} = setup("i", "#{}", <<"x">>, [{"layouts/main.weberl", <<"no marker">>}]),
        write_tree(Dir, Files),
        compile_load(filename:join(Dir, "views/" ++ V ++ ".erl")),
        ?assertMatch({error, {invalid_layouts, [{main, {missing_content, _}}]}},
                     prepare(Dir, [filename:join(Dir, "layouts")]))
    end).
