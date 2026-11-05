%% `{{ Expr }}': interpolation is an Erlang expression; an assign is only `@name'; a bare
%% `name' is the atom `name'. (Template blocks come next; see HANDOFF "2".)
-module(weberl_template_expr_tests).
-include_lib("eunit/include/eunit.hrl").

unique_view() -> weberl_test_handlers:unique("xview").

tpl(Source) ->
    View = unique_view(),
    {ok, C} = weberl_template:compile_source(View, Source, "t.weberl"),
    ok = weberl_template:load(C),
    View.

render(Source, Assigns) -> iolist_to_binary(weberl_template:render(tpl(Source), Assigns)).

render_error(Fun) ->
    try Fun() of _ -> no_error
    catch error:{template_error, Reason} -> Reason end.

err(Source) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} =
        weberl_template:compile_source(unique_view(), Source, "t.weberl"),
    {Line, Reason}.

%% ---------------------------------------------------------------------
%% Assigns are @name; a bare name is an atom

an_assign_is_written_with_an_at_sign_test() ->
    ?assertEqual(<<"Ana">>, render(<<"{{ @name }}">>, #{name => <<"Ana">>})),
    ?assertEqual(<<"Ana">>, render(<<"{{@name}}">>, #{name => <<"Ana">>})),
    ?assertEqual(<<"<b>Ana</b>">>, render(<<"<b>{{{ @name }}}</b>">>, #{name => <<"Ana">>})).

a_bare_name_is_the_atom_and_renders_as_its_name_test() ->
    %% the complaint behind the change: no shorthand, so `name' is not the assign `name'
    ?assertEqual(<<"name">>, render(<<"{{ name }}">>, #{name => <<"Ana">>})),
    ?assertEqual(<<"name">>, render(<<"{{ name }}">>, #{})),
    ?assertEqual(<<"title and Ana">>, render(<<"{{ title }} and {{ @n }}">>, #{n => <<"Ana">>})),
    ?assertEqual(<<"name">>, render(<<"{{{ name }}}">>, #{})).

atoms_render_as_their_name_test() ->
    [?assertEqual(Expected, render(<<"{{ @v }}">>, #{v => Atom}))
     || {Atom, Expected} <- [{true, <<"true">>}, {false, <<"false">>}, {undefined, <<"undefined">>},
                             {some_atom, <<"some_atom">>}, {'with space', <<"with space">>}]],
    ?assertEqual(<<"true">>, render(<<"{{ true }}">>, #{})).

%% ---------------------------------------------------------------------
%% Expressions

any_erlang_expression_test() ->
    ?assertEqual(<<"3">>, render(<<"{{ @n + 1 }}">>, #{n => 2})),
    ?assertEqual(<<"ANA">>, render(<<"{{ string:uppercase(@w) }}">>, #{w => <<"ana">>})),
    ?assertEqual(<<"3">>, render(<<"{{ length(@items) }}">>, #{items => [a, b, c]})),
    ?assertEqual(<<"0.3">>, render(<<"{{ @n / 10 }}">>, #{n => 3})),
    ?assertEqual(<<"0.7">>, render(<<"{{ erlang:round(@n * 10) / 10 }}">>, #{n => 0.7})),
    ?assertEqual(<<"b">>, render(<<"{{ case @ok of true -> a; false -> b end }}">>, #{ok => false})),
    ?assertEqual(<<"x-1">>, render(<<"{{ [\"x-\", integer_to_list(@n)] }}">>, #{n => 1})).

expression_results_are_escaped_unless_raw_test() ->
    ?assertEqual(<<"&lt;b&gt;">>, render(<<"{{ [<<\"<\">>, \"b>\"] }}">>, #{})),
    ?assertEqual(<<"<b>">>, render(<<"{{{ [<<\"<\">>, \"b>\"] }}}">>, #{})),
    ?assertEqual(<<"a &amp; b">>, render(<<"{{ @a }} &amp; {{ @b }}">>, #{a => <<"a">>, b => <<"b">>})),
    ?assertEqual(<<"&quot;q&quot;">>, render(<<"{{ @q }}">>, #{q => <<"\"q\"">>})).

an_at_sign_in_a_literal_is_not_an_assign_test() ->
    ?assertEqual(<<"a@b">>, render(<<"{{ \"a@b\" }}">>, #{})),
    ?assertEqual(<<"user@host">>, render(<<"{{ user@host }}">>, #{})).

%% ---------------------------------------------------------------------
%% Where a tag ends (HANDOFF decision 10): the Erlang inside is read, not searched for `}}'

nested_maps_need_no_space_before_the_closing_braces_test() ->
    ?assertEqual(<<"1">>, render(<<"{{ maps:get(j, maps:get(k, #{k => #{j => 1}})) }}">>, #{})),
    ?assertEqual(<<"1">>, render(<<"{{ maps:get(j, maps:get(k, #{k => #{j => 1} })) }}">>, #{})),
    ?assertEqual(<<"1">>, render(<<"{{{ maps:get(j, maps:get(k, #{k => #{j => 1}})) }}}">>, #{})),
    %% the tag's own braces right after a map
    ?assertEqual(<<"1">>, render(<<"{{ maps:get(k, #{k => 1}) }}">>, #{})),
    ?assertEqual(<<"2">>, render(<<"{{ maps:size(#{a => #{}, b => 1})}}">>, #{})).

tuples_inside_tuples_end_where_the_author_means_test() ->
    ?assertEqual(<<"b">>, render(<<"{{ element(2, element(1, {{a, b}, c})) }}">>, #{})),
    ?assertEqual(<<"c">>, render(<<"{{ element(2, {{a, b}, c}) }}">>, #{})).

closing_braces_in_strings_do_not_end_the_tag_test() ->
    ?assertEqual(<<"a }} b">>, render(<<"{{ \"a }} b\" }}">>, #{})),
    ?assertEqual(<<"a {{ b">>, render(<<"{{ \"a {{ b\" }}">>, #{})),
    ?assertEqual(<<"x}}y">>, render(<<"{{{ \"x}}y\" }}}">>, #{})),
    ?assertEqual(<<"}}">>, render(<<"{{ '}}' }}">>, #{})),
    %% a string with braces inside a tuple inside a tag, then text with a second tag
    ?assertEqual(<<"true {{|2">>,
                 render(<<"{{ element(2, element(1, {{a, \"true {{\"}, 1})) }}|{{ 1 + 1 }}">>, #{})).

character_literals_and_escapes_do_not_end_the_tag_test() ->
    ?assertEqual(<<"125">>, render(<<"{{ $} }}">>, #{})),
    ?assertEqual(<<"34">>, render(<<"{{ $\" }}">>, #{})),
    ?assertEqual(<<"a\"b">>, render(<<"{{{ \"a\\\"b\" }}}">>, #{})).

a_comment_inside_a_tag_hides_the_closing_braces_until_its_line_ends_test() ->
    ?assertEqual(<<"3">>, render(<<"{{ 1 + 2 % }} not the end\n }}">>, #{})).

an_unbalanced_closing_bracket_is_named_with_its_line_test() ->
    ?assertEqual({1, unbalanced_brace}, err(<<"{{ a} }}">>)),
    ?assertEqual({3, unbalanced_brace}, err(<<"x\ny\n{{ (a }} {{ b }}">>)),
    ?assertEqual({2, unbalanced_brace}, err(<<"{{ {a,\n b) }}">>)),
    ?assertEqual({1, unbalanced_brace}, err(<<"{{{ a} }}} {{ b }}">>)),
    %% a raw tag closed with two braces is missing one
    ?assertEqual({1, unterminated_raw_interpolation}, err(<<"{{{ @x }} text">>)).

an_unterminated_string_is_named_with_its_line_test() ->
    ?assertEqual({1, unterminated_string}, err(<<"{{ \"abc }}">>)),
    ?assertEqual({2, unterminated_string}, err(<<"x\n{{ 'abc }}\ny">>)),
    ?assertEqual({3, unterminated_string}, err(<<"{{ [1,\n 2,\n \"x ] }}">>)).

an_open_tag_without_an_end_is_still_unterminated_test() ->
    ?assertEqual({1, unterminated_interpolation}, err(<<"{{ a + ">>)),
    ?assertEqual({1, unterminated_raw_interpolation}, err(<<"{{{ a + ">>)).

block_tags_end_at_the_first_closing_mark_outside_the_erlang_inside_test() ->
    ?assertEqual(<<"a">>, render(<<"{: if \":}\" =:= \":}\" :}a{: /if :}">>, #{})),
    ?assertEqual(<<"x">>, render(<<"{: case {$:, $:} :}{: of {$:, $:} :}x{: /case :}">>, #{})),
    ?assertEqual({1, unterminated_string}, err(<<"{: if \"a :} :}b{: /if :}">>)).

an_expression_with_a_string_containing_angle_brackets_test() ->
    ?assertEqual(<<"1 &lt; 2">>, render(<<"{{ \"1 < 2\" }}">>, #{})).

%% ---------------------------------------------------------------------
%% Errors

a_missing_assign_is_named_even_inside_an_expression_test() ->
    V = tpl(<<"{{ length(@items) }}">>),
    ?assertEqual({missing_variable, V, items}, render_error(fun() -> weberl_template:render(V, #{}) end)),
    V2 = tpl(<<"{{ @a + @b }}">>),
    ?assertEqual({missing_variable, V2, b}, render_error(fun() -> weberl_template:render(V2, #{a => 1}) end)).

an_unrenderable_result_names_the_expression_test() ->
    V = tpl(<<"{{ {@a, @b} }}">>),
    ?assertEqual({unsupported_value, V, <<"{@a, @b}">>, {1, 2}},
                 render_error(fun() -> weberl_template:render(V, #{a => 1, b => 2}) end)),
    V2 = tpl(<<"{{ @m }}">>),
    ?assertEqual({unsupported_value, V2, <<"@m">>, #{}},
                 render_error(fun() -> weberl_template:render(V2, #{m => #{}}) end)).

an_expression_that_raises_is_not_swallowed_test() ->
    V = tpl(<<"{{ 1 div @zero }}">>),
    ?assertError(badarith, weberl_template:render(V, #{zero => 0})).

syntax_errors_carry_the_template_line_test() ->
    ?assertMatch({2, {invalid_expression, <<" 1 + ">>, _}}, err(<<"a\n{{ 1 + }}">>)),
    %% inside a multi-line expression: the line of the offending token
    ?assertMatch({3, {invalid_expression, _, _}}, err(<<"{{\n @a +\n *\n}}">>)),
    ?assertMatch({4, {invalid_expression, _, _}}, err(<<"x\ny\nz\n{{ @a @b }}">>)).

more_than_one_expression_is_an_error_test() ->
    ?assertEqual({1, {not_a_single_expression, <<" 1, 2 ">>}}, err(<<"{{ 1, 2 }}">>)).

an_unbound_local_is_an_error_until_a_block_binds_it_test() ->
    ?assertEqual({1, {unbound_variable, 'Name'}}, err(<<"{{ Name }}">>)),
    ?assertEqual({2, {unbound_variable, 'X'}}, err(<<"\n{{ @a + X }}">>)).

reserved_names_are_refused_test() ->
    ?assertEqual({1, {reserved_variable, '_Weberl_x'}}, err(<<"{{ _Weberl_x }}">>)).

html_context_rules_apply_to_expressions_test() ->
    ?assertEqual({1, {interpolation_in_restricted_attribute, <<"style">>}},
                 err(<<"<p style=\"{{ @a + 1 }}\">x</p>">>)),
    ?assertEqual({1, {interpolation_in_unsupported_context, tag}}, err(<<"<p {{ @a }}>x</p>">>)),
    ?assertEqual({1, {interpolation_in_unsupported_context, <<"script">>}},
                 err(<<"<script>{{ @a }}</script>">>)),
    %% fine in text and in quoted attribute values
    ?assertEqual(<<"<p title=\"3\">3</p>">>, render(<<"<p title=\"{{ @n + 1 }}\">{{ @n + 1 }}</p>">>, #{n => 2})),
    ?assertEqual({1, {raw_interpolation_in_attribute, <<"title">>}}, err(<<"<p title=\"{{{ @a }}}\">x</p>">>)).

%% ---------------------------------------------------------------------
%% Dependencies: the assigns an expression reads

regions_depend_on_the_assigns_their_expressions_read_test() ->
    V = tpl(<<"{{ @title }}{: region r :}{{ @a + length(@b) }}{: /region r :}"
              "{: region s :}{{ name }}{: /region s :}">>),
    Regions = (weberl_template:generated_module(V)):info(),
    ?assertMatch(#{regions := #{r := #{variables := [a, b]}, s := #{variables := []}}}, Regions),
    ?assertEqual([a, b, title], maps:get(variables, Regions)).

a_region_renders_alone_from_its_own_assigns_test() ->
    V = tpl(<<"{{ @title }}{: region r :}{{ @a * 2 }}{: /region r :}">>),
    ?assertEqual(<<"6">>, iolist_to_binary(weberl_template:render_region(V, r, #{a => 3}))).
