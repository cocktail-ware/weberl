%% Regions in templates: `{: region name :} ... {: /region name :}'.
-module(weberl_template_regions_tests).
-include_lib("eunit/include/eunit.hrl").

tpl(Source) ->
    View = weberl_test_handlers:unique("rview"),
    {ok, C} = weberl_template:compile_source(View, Source, "t.weberl"),
    ok = weberl_template:load(C),
    View.

err(Source) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} =
        weberl_template:compile_source(weberl_test_handlers:unique("rview"), Source, "t.weberl"),
    {Line, Reason}.

bin(IoData) -> iolist_to_binary(IoData).

%% ---------------------------------------------------------------------
%% lexer

lex(Src) -> weberl_template_lexer:tokenize(Src, "t.weberl").

lexer_test_() ->
    E = fun(Line, Reason) -> {error, {syntax_error, "t.weberl", Line, Reason}} end,
    [?_assertEqual({ok, [{text, 1, <<"a ">>}, {block_open, 1, region, cart, #{}},
                         {text, 1, <<" b ">>}, {block_close, 1, region, cart}]},
                   lex(<<"a {: region cart :} b {: /region cart :}">>)),
     ?_assertEqual({ok, [{block_open, 1, region, rows, #{tag => <<"tbody">>}}]},
                   lex(<<"{:  region  rows  tag=tbody  :}">>)),
     ?_assertEqual({ok, [{text, 1, <<"{: region x :}">>}]}, lex(<<"\\{: region x :}">>)),
     ?_assertEqual({ok, [{block_open, 1, region, a, #{}}, {text, 3, <<"\n">>}, {interp, 4, escaped, <<" @x ">>}]},
                   lex(<<"{: region\n a\n :}\n{{ @x }}">>)),
     ?_assertEqual(E(1, unterminated_block_tag), lex(<<"{: region a">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<" if x ">>}), lex(<<"{: if x :}">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<" region ">>}), lex(<<"{: region :}">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<" region Cart ">>}), lex(<<"{: region Cart :}">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<" region a color=red ">>}),
                   lex(<<"{: region a color=red :}">>)),
     ?_assertEqual(E(1, {invalid_region_tag, <<"script">>}), lex(<<"{: region a tag=script :}">>)),
     ?_assertEqual(E(1, {invalid_region_tag, <<"img">>}), lex(<<"{: region a tag=img :}">>)),
     ?_assertEqual(E(1, {invalid_region_tag, <<"Div">>}), lex(<<"{: region a tag=Div :}">>))].

%% ---------------------------------------------------------------------
%% rendering

wrapper_test() ->
    V = tpl(<<"<h1>{{ @title }}</h1>{: region cart :}<ul>{{ @items }}</ul>{: /region cart :}<p>end</p>">>),
    ?assertEqual(<<"<h1>T</h1><weberl-region name=\"cart\"><ul>a</ul></weberl-region><p>end</p>">>,
                 bin(weberl_template:render(V, #{title => <<"T">>, items => <<"a">>}))).

other_tag_test() ->
    V = tpl(<<"<table>{: region rows tag=tbody :}<tr><td>{{ @x }}</td></tr>{: /region rows :}</table>">>),
    ?assertEqual(<<"<table><tbody data-weberl-region=\"rows\"><tr><td>1</td></tr></tbody></table>">>,
                 bin(weberl_template:render(V, #{x => 1}))).

render_region_test() ->
    V = tpl(<<"{{ @a }}{: region cart :}<ul>{{ @items }}</ul>{: /region cart :}">>),
    %% only the region's own variables are needed, and no wrapper is written
    ?assertEqual(<<"<ul>x &lt; y</ul>">>,
                 bin(weberl_template:render_region(V, cart, #{items => <<"x < y">>}))),
    ?assertEqual({error, {missing_variable, V, items}},
                 weberl_template:try_render_region(V, cart, #{})),
    ?assertEqual({error, {unknown_region, V, nope}},
                 weberl_template:try_render_region(V, nope, #{items => 1})).

render_region_errors_test() ->
    ?assertError({template_error, {no_template, no_such_view_xyz}},
                 weberl_template:render_region(no_such_view_xyz, cart, #{})),
    V = tpl(<<"{: region a :}x{: /region a :}">>),
    ?assertError({template_error, {invalid_assigns, V, []}}, weberl_template:render_region(V, a, [])).

nested_regions_test() ->
    V = tpl(<<"{: region outer :}<div>{{ @a }}{: region inner :}<b>{{ @b }}</b>{: /region inner :}</div>"
              "{: /region outer :}">>),
    Assigns = #{a => 1, b => 2},
    ?assertEqual(<<"<div>1<weberl-region name=\"inner\"><b>2</b></weberl-region></div>">>,
                 bin(weberl_template:render_region(V, outer, Assigns))),
    ?assertEqual(<<"<b>2</b>">>, bin(weberl_template:render_region(V, inner, #{b => 2}))),
    ?assertEqual(<<"<weberl-region name=\"outer\"><div>1<weberl-region name=\"inner\"><b>2</b>"
                   "</weberl-region></div></weberl-region>">>,
                 bin(weberl_template:render(V, Assigns))).

regions_info_test() ->
    V = tpl(<<"{{ @title }}{: region a :}{{ @x }}{: region b tag=ul :}{{ @y }}{: /region b :}{: /region a :}"
              "{: region c :}static{: /region c :}">>),
    {ok, Regions} = weberl_template:regions(V),
    ?assertMatch(#{a := #{tag := default, line := 1, variables := [x, y]},
                   b := #{tag := <<"ul">>, variables := [y]},
                   c := #{variables := []}}, Regions),
    ?assertEqual([a, b, c], lists:sort(maps:keys(Regions))),
    ?assertMatch(#{variables := [title, x, y]}, (weberl_template:generated_module(V)):info()),
    ?assertEqual({error, {no_template, no_such_view_xyz}}, weberl_template:regions(no_such_view_xyz)).

regions_do_not_change_other_syntax_test() ->
    V = tpl(<<"\\{: a :} {{ @x }} {: region r :}{{{ @y }}}{: /region r :}">>),
    ?assertEqual(<<"{: a :} 1 <weberl-region name=\"r\">&</weberl-region>">>,
                 bin(weberl_template:render(V, #{x => 1, y => <<"&">>}))).

%% ---------------------------------------------------------------------
%% errors

errors_test_() ->
    [?_assertEqual({1, {unclosed_region, a}}, err(<<"{: region a :}x">>)),
     ?_assertEqual({2, {mismatched_region_end, b, a}},
                   err(<<"{: region a :}\n{: region b :}x{: /region a :}">>)),
     ?_assertEqual({2, {unclosed_region, b}}, err(<<"{: region a :}\n{: region b :}x">>)),
     ?_assertEqual({1, {unexpected_region_end, a}}, err(<<"x{: /region a :}">>)),
     ?_assertEqual({1, {mismatched_region_end, a, b}}, err(<<"{: region a :}x{: /region b :}">>)),
     ?_assertEqual({2, {duplicate_region, a, 1}},
                   err(<<"{: region a :}x{: /region a :}\n{: region a :}y{: /region a :}">>)),
     %% regions begin and end in HTML text
     ?_assertEqual({1, {region_in_unsupported_context, r, attribute_value}},
                   err(<<"<a title=\"{: region r :}x{: /region r :}\">">>)),
     ?_assertEqual({1, {region_in_unsupported_context, r, tag}},
                   err(<<"<a {: region r :}x{: /region r :}>">>)),
     ?_assertEqual({1, {region_in_unsupported_context, r, <<"script">>}},
                   err(<<"<script>{: region r :}x{: /region r :}</script>">>)),
     ?_assertEqual({1, {region_in_unsupported_context, r, comment}},
                   err(<<"<!-- {: region r :}x{: /region r :} -->">>)),
     ?_assertEqual({1, {region_unbalanced_markup, r}}, err(<<"{: region r :}<a href=\"x{: /region r :}\">">>)),
     %% the checks of interpolation still apply inside a region
     ?_assertEqual({1, {interpolation_in_unsupported_context, <<"script">>}},
                   err(<<"{: region r :}<script>{{ @x }}</script>{: /region r :}">>))].
