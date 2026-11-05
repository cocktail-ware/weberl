%% Template blocks: `{: if :}', `{: case :}', `{: for :}' with Erlang expressions and
%% patterns (feedback item 2 from agentic: the nav for signed-in and signed-out users,
%% optional flash and form errors, lists). See HANDOFF "2" for the decisions.
-module(weberl_template_blocks_tests).
-include_lib("eunit/include/eunit.hrl").

unique_view() -> weberl_test_handlers:unique("bview").

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

lex(Source) -> weberl_template_lexer:tokenize(Source, "t.weberl").

%% ---------------------------------------------------------------------
%% Lexer

lexer_statements_test() ->
    ?assertEqual({ok, [{stmt, 1, 'if', <<" @a ">>, 1}, {text, 1, <<"x">>},
                       {stmt, 1, elif, <<" @b ">>, 1}, {stmt, 1, 'else', none, 1},
                       {stmt_end, 1, 'if'}]},
                 lex(<<"{: if @a :}x{: elif @b :}{: else :}{: /if :}">>)),
    ?assertEqual({ok, [{stmt, 1, 'case', <<" @a ">>, 1}, {stmt, 1, 'of', <<" {ok, X} when X > 1 ">>, 1},
                       {stmt_end, 1, 'case'}]},
                 lex(<<"{: case @a :}{: of {ok, X} when X > 1 :}{: /case :}">>)),
    ?assertEqual({ok, [{stmt, 1, 'for', <<" X <- @l, X > 1 ">>, 1}, {stmt, 1, empty, none, 1},
                       {stmt_end, 1, 'for'}]},
                 lex(<<"{: for X <- @l, X > 1 :}{: empty :}{: /for :}">>)).

lexer_statement_lines_test() ->
    %% the tag's line, and the line its text starts on
    ?assertEqual({ok, [{text, 1, <<"a\n">>}, {stmt, 2, 'if', <<"\n  @x\n">>, 2}, {text, 4, <<"b">>}]},
                 lex(<<"a\n{: if\n  @x\n:}b">>)),
    ?assertEqual({ok, [{text, 1, <<"\n">>}, {stmt, 2, 'if', <<" @x ">>, 3}]}, lex(<<"\n{:\n if @x :}">>)).

lexer_statement_errors_test_() ->
    E = fun(Line, Reason) -> {error, {syntax_error, "t.weberl", Line, Reason}} end,
    [?_assertEqual(E(1, {missing_expression, 'if'}), lex(<<"{: if :}">>)),
     ?_assertEqual(E(1, {missing_expression, 'for'}), lex(<<"{: for   :}">>)),
     ?_assertEqual(E(1, {missing_expression, 'of'}), lex(<<"{: of :}">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<" else x ">>}), lex(<<"{: else x :}">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<" /if x ">>}), lex(<<"{: /if x :}">>)),
     ?_assertEqual(E(1, {invalid_block_tag, <<"if(@a)">>}), lex(<<"{:if(@a):}">>)),
     ?_assertEqual(E(2, unterminated_block_tag), lex(<<"a\n{: if @a">>))].

%% ---------------------------------------------------------------------
%% if / elif / else

if_else_test() ->
    T = <<"{: if @on :}yes{: else :}no{: /if :}">>,
    ?assertEqual(<<"yes">>, render(T, #{on => true})),
    ?assertEqual(<<"no">>, render(T, #{on => false})).

if_without_else_renders_nothing_test() ->
    ?assertEqual(<<"[]">>, render(<<"[{: if @on :}x{: /if :}]">>, #{on => false})),
    ?assertEqual(<<"[x]">>, render(<<"[{: if @on :}x{: /if :}]">>, #{on => true})).

elif_chain_test() ->
    T = <<"{: if @n =:= 1 :}one{: elif @n =:= 2 :}two{: elif @n > 2 :}many{: else :}none{: /if :}">>,
    ?assertEqual([<<"one">>, <<"two">>, <<"many">>, <<"none">>],
                 [render(T, #{n => N}) || N <- [1, 2, 3, 0]]).

the_agentic_nav_test() ->
    Nav = <<"<nav>{: if @user =/= undefined andalso @role =:= admin :}"
            "<a href=\"/admin\">Admin</a>"
            "{: elif @user =/= undefined :}<a href=\"/account\">Account</a>"
            "{: else :}<a href=\"/login\">Log in</a>{: /if :}</nav>">>,
    ?assertEqual(<<"<nav><a href=\"/admin\">Admin</a></nav>">>, render(Nav, #{user => <<"ana">>, role => admin})),
    ?assertEqual(<<"<nav><a href=\"/account\">Account</a></nav>">>, render(Nav, #{user => <<"bo">>, role => user})),
    ?assertEqual(<<"<nav><a href=\"/login\">Log in</a></nav>">>, render(Nav, #{user => undefined, role => undefined})).

the_agentic_optional_error_test() ->
    T = <<"<form>{: if @error =/= undefined :}<p class=\"form-error\">{{ @error }}</p>{: /if :}</form>">>,
    ?assertEqual(<<"<form></form>">>, render(T, #{error => undefined})),
    ?assertEqual(<<"<form><p class=\"form-error\">Bad &lt;password&gt;</p></form>">>,
                 render(T, #{error => <<"Bad <password>">>})).

conditions_must_be_booleans_test() ->
    V = tpl(<<"a\n{: if @v :}x{: /if :}">>),
    %% the error carries the line of the condition
    ?assertEqual({not_boolean, V, 2, <<"yes">>},
                 render_error(fun() -> weberl_template:render(V, #{v => <<"yes">>}) end)),
    ?assertEqual({not_boolean, V, 2, undefined},
                 render_error(fun() -> weberl_template:render(V, #{v => undefined}) end)),
    ?assertEqual({not_boolean, V, 2, 0}, render_error(fun() -> weberl_template:render(V, #{v => 0}) end)),
    %% also in an elif
    V2 = tpl(<<"{: if @a :}x{: elif @b :}y{: /if :}">>),
    ?assertEqual({not_boolean, V2, 1, nope},
                 render_error(fun() -> weberl_template:render(V2, #{a => false, b => nope}) end)).

only_the_taken_branch_is_evaluated_test() ->
    %% the other conditions and branches do not run (no missing assign)
    ?assertEqual(<<"x">>, render(<<"{: if @a :}x{: elif @missing :}y{: /if :}">>, #{a => true})),
    ?assertEqual(<<"b">>, render(<<"{: if @a :}{{ @missing }}{: else :}b{: /if :}">>, #{a => false})).

missing_assign_in_a_condition_is_named_test() ->
    V = tpl(<<"{: if @flag :}x{: /if :}">>),
    ?assertEqual({missing_variable, V, flag}, render_error(fun() -> weberl_template:render(V, #{}) end)).

nested_blocks_test() ->
    T = <<"{: if @a :}A{: if @b :}B{: else :}b{: /if :}{: else :}a{: /if :}">>,
    ?assertEqual([<<"AB">>, <<"Ab">>, <<"a">>],
                 [render(T, #{a => true, b => true}), render(T, #{a => true, b => false}),
                  render(T, #{a => false, b => true})]).

multi_line_condition_test() ->
    T = <<"{: if @a\n   andalso @b :}both{: /if :}">>,
    ?assertEqual(<<"both">>, render(T, #{a => true, b => true})),
    ?assertEqual(<<>>, render(T, #{a => true, b => false})).

%% ---------------------------------------------------------------------
%% case / of

case_binds_and_matches_test() ->
    T = <<"{: case @flash :}{: of undefined :}{: of {error, Msg} :}<p class=\"e\">{{ Msg }}</p>"
          "{: of {info, Msg} when is_binary(Msg) :}<p>{{ Msg }}</p>{: /case :}">>,
    ?assertEqual(<<>>, render(T, #{flash => undefined})),
    ?assertEqual(<<"<p class=\"e\">Bad &amp; wrong</p>">>, render(T, #{flash => {error, <<"Bad & wrong">>}})),
    ?assertEqual(<<"<p>Saved</p>">>, render(T, #{flash => {info, <<"Saved">>}})).

case_guards_and_wildcard_test() ->
    T = <<"{: case @n :}{: of N when N < 0 :}neg{: of 0 :}zero{: of _ :}pos{: /case :}">>,
    ?assertEqual([<<"neg">>, <<"zero">>, <<"pos">>], [render(T, #{n => N}) || N <- [-1, 0, 7]]).

case_with_no_matching_clause_test() ->
    V = tpl(<<"x\n{: case @v :}{: of a :}A{: /case :}">>),
    ?assertEqual({case_clause, V, 2, b}, render_error(fun() -> weberl_template:render(V, #{v => b}) end)).

%% A guard cannot call a function, so what the guards read is fetched before the case.
case_guards_may_read_assigns_test() ->
    T = <<"{: case @n :}{: of N when N > @limit :}big{: of N when N =:= @limit :}at{: of _ :}small{: /case :}">>,
    ?assertEqual([<<"big">>, <<"at">>, <<"small">>],
                 [render(T, #{n => N, limit => 5}) || N <- [9, 5, 1]]),
    %% two cases in a row reading the same assign are fine
    T2 = <<"{: case @a :}{: of X when X > @l :}1{: of _ :}0{: /case :}"
           "{: case @b :}{: of Y when Y > @l :}1{: of _ :}0{: /case :}">>,
    ?assertEqual(<<"10">>, render(T2, #{a => 9, b => 1, l => 5})),
    %% the guards' assigns are read first: a missing one is an error even when the
    %% first clause would have matched
    V = tpl(<<"{: case @n :}{: of 1 :}one{: of N when N > @limit :}big{: /case :}">>),
    ?assertEqual({missing_variable, V, limit},
                 render_error(fun() -> weberl_template:render(V, #{n => 1}) end)).

case_may_have_whitespace_before_the_first_of_test() ->
    ?assertEqual(<<"A">>, render(<<"{: case @v :}\n  {: of a :}A{: /case :}">>, #{v => a})).

case_errors_test() ->
    ?assertEqual({1, content_before_first_of}, err(<<"{: case @v :}text{: of a :}A{: /case :}">>)),
    ?assertEqual({1, content_before_first_of}, err(<<"{: case @v :}{{ @v }}{: of a :}A{: /case :}">>)),
    ?assertEqual({1, case_without_of}, err(<<"{: case @v :}{: /case :}">>)),
    ?assertMatch({1, {assign_in_pattern, x}}, err(<<"{: case @v :}{: of @x :}A{: /case :}">>)),
    ?assertMatch({1, {invalid_expression, _, _}}, err(<<"{: case @v :}{: of a b :}A{: /case :}">>)).

%% ---------------------------------------------------------------------
%% for / empty

for_renders_each_test() ->
    T = <<"<ul>{: for X <- @items :}<li>{{ X }}</li>{: /for :}</ul>">>,
    ?assertEqual(<<"<ul><li>a</li><li>b</li></ul>">>, render(T, #{items => [a, b]})),
    ?assertEqual(<<"<ul></ul>">>, render(T, #{items => []})).

for_with_patterns_and_filters_test() ->
    T = <<"{: for #{name := Name, active := true} <- @agents :}[{{ Name }}]{: /for :}">>,
    Agents = [#{name => <<"a">>, active => true}, #{name => <<"b">>, active => false},
              #{name => <<"c">>, active => true}, #{other => 1}],
    ?assertEqual(<<"[a][c]">>, render(T, #{agents => Agents})),
    T2 = <<"{: for N <- @ns, N rem 2 =:= 0, N > @min :}{{ N }},{: /for :}">>,
    ?assertEqual(<<"4,6,">>, render(T2, #{ns => [1, 2, 3, 4, 5, 6], min => 2})).

for_empty_test() ->
    T = <<"{: for A <- @agents :}<li>{{ A }}</li>{: empty :}<li>No agents yet</li>{: /for :}">>,
    ?assertEqual(<<"<li>No agents yet</li>">>, render(T, #{agents => []})),
    ?assertEqual(<<"<li>x</li>">>, render(T, #{agents => [x]})),
    %% empty means no results after filtering, not an empty list
    T2 = <<"{: for N <- @ns, N > 5 :}{{ N }}{: empty :}none{: /for :}">>,
    ?assertEqual(<<"none">>, render(T2, #{ns => [1, 2]})).

for_with_several_generators_and_nesting_test() ->
    T = <<"{: for Row <- @rows :}<tr>{: for C <- Row :}<td>{{ C }}</td>{: /for :}</tr>{: /for :}">>,
    ?assertEqual(<<"<tr><td>1</td><td>2</td></tr><tr><td>3</td></tr>">>, render(T, #{rows => [[1, 2], [3]]})),
    T2 = <<"{: for X <- [1, 2], Y <- [a, b] :}{{ X }}{{ Y }} {: /for :}">>,
    ?assertEqual(<<"1a 1b 2a 2b ">>, render(T2, #{})).

for_map_and_binary_generators_test() ->
    %% (a map's iteration order is Erlang's, not something to rely on)
    ?assertEqual(<<"a=1;">>,
                 render(<<"{: for K := V <- @m :}{{ K }}={{ V }};{: /for :}">>, #{m => #{a => 1}})),
    ?assertEqual(<<"b=2;">>,
                 render(<<"{: for K := V <- @m, V > 1 :}{{ K }}={{ V }};{: /for :}">>, #{m => #{a => 1, b => 2}})),
    ?assertEqual(<<"[104][105]">>, render(<<"{: for <<C>> <= @bin :}[{{ C }}]{: /for :}">>, #{bin => <<"hi">>})).

blocks_can_use_the_outer_locals_test() ->
    T = <<"{: for #{id := Id, tags := Tags} <- @items :}{{ Id }}:"
          "{: for Tag <- Tags :}{{ Tag }}{: if Id > 1 :}!{: /if :} {: /for :}|{: /for :}">>,
    ?assertEqual(<<"1:a b |2:c! |">>,
                 render(T, #{items => [#{id => 1, tags => [a, b]}, #{id => 2, tags => [c]}]})).

the_condition_of_a_filter_can_raise_test() ->
    V = tpl(<<"{: for X <- @l, X > @min :}{{ X }}{: /for :}">>),
    ?assertEqual({missing_variable, V, min},
                 render_error(fun() -> weberl_template:render(V, #{l => [1]}) end)).

a_value_that_is_not_a_list_is_erlangs_error_test() ->
    V = tpl(<<"{: for X <- @l :}{{ X }}{: /for :}">>),
    ?assertError({bad_generator, notalist}, weberl_template:render(V, #{l => notalist})).

%% render/2 raises (a handler's 500); the try_ variants, which a live page uses to
%% re-render a region, return the failure so one bad value does not end the session.
the_try_variants_return_a_failing_expression_test() ->
    V = tpl(<<"{: region r :}{: for X <- @l :}{{ X }}{: /for :}{: /region r :}">>),
    ?assertEqual({error, {render_failed, error, {bad_generator, notalist}}},
                 weberl_template:try_render(V, #{l => notalist})),
    ?assertEqual({error, {render_failed, error, {bad_generator, notalist}}},
                 weberl_template:try_render_region(V, r, #{l => notalist})),
    ?assertEqual({error, {render_failed, error, badarith}},
                 weberl_template:try_render(tpl(<<"{{ 1 div @z }}">>), #{z => 0})),
    %% template errors keep their own shape
    ?assertEqual({error, {missing_variable, V, l}}, weberl_template:try_render(V, #{})),
    ?assertEqual(<<"<weberl-region name=\"r\">12</weberl-region>">>,
                 iolist_to_binary(element(2, weberl_template:try_render(V, #{l => [1, 2]})))).

for_errors_test() ->
    ?assertMatch({1, {invalid_expression, _, _}}, err(<<"{: for X <- :}a{: /for :}">>)),
    ?assertEqual({1, {rebound_variable, 'X'}}, err(<<"{: for X <- @a, X <- @b :}a{: /for :}">>)),
    ?assertMatch({1, {assign_in_pattern, x}}, err(<<"{: for @x <- @a :}a{: /for :}">>)).

%% ---------------------------------------------------------------------
%% Scope

locals_do_not_leak_test() ->
    ?assertEqual({1, {unbound_variable, 'X'}}, err(<<"{: for X <- @l :}{{ X }}{: /for :}{{ X }}">>)),
    ?assertEqual({1, {unbound_variable, 'M'}},
                 err(<<"{: case @a :}{: of {ok, M} :}{{ M }}{: of _ :}{{ M }}{: /case :}">>)),
    ?assertEqual({1, {unbound_variable, 'X'}},
                 err(<<"{: for X <- @l :}a{: empty :}{{ X }}{: /for :}">>)),
    ?assertEqual({1, {unbound_variable, 'Y'}}, err(<<"{: if Y :}a{: /if :}">>)).

an_already_bound_name_is_an_error_test() ->
    ?assertEqual({1, {rebound_variable, 'X'}},
                 err(<<"{: for X <- @a :}{: for X <- @b :}1{: /for :}{: /for :}">>)),
    ?assertEqual({1, {rebound_variable, 'M'}},
                 err(<<"{: case @a :}{: of {ok, M} :}{: case @b :}{: of M :}x{: /case :}{: /case :}">>)),
    %% siblings may reuse a name
    ?assertEqual(<<"1.2.">>, render(<<"{: for X <- [1] :}{{ X }}.{: /for :}{: for X <- [2] :}{{ X }}.{: /for :}">>, #{})).

guards_use_what_the_clause_binds_and_the_outer_locals_test() ->
    T = <<"{: for Max <- [3] :}{: case @n :}{: of N when N > Max :}big{: of _ :}small{: /case :}{: /for :}">>,
    ?assertEqual([<<"big">>, <<"small">>], [render(T, #{n => 5}), render(T, #{n => 1})]),
    ?assertEqual({1, {unbound_variable, 'Max'}},
                 err(<<"{: case @n :}{: of N when N > Max :}big{: /case :}">>)).

%% ---------------------------------------------------------------------
%% Structure errors

block_structure_errors_test() ->
    ?assertEqual({1, {unclosed_block, 'if'}}, err(<<"{: if @a :}x">>)),
    ?assertEqual({2, {unclosed_block, 'for'}}, err(<<"a\n{: for X <- @l :}x">>)),
    ?assertEqual({1, {unexpected_block_end, 'if'}}, err(<<"x{: /if :}">>)),
    ?assertEqual({1, {mismatched_block_end, {'if', none}, {'for', none}}}, err(<<"{: if @a :}x{: /for :}">>)),
    %% an end tag for something other than the block on top
    ?assertEqual({1, {mismatched_block_end, {'if', none}, {region, r}}},
                 err(<<"{: region r :}{: if @a :}x{: /region r :}">>)),
    ?assertEqual({1, {mismatched_block_end, {region, r}, {'if', none}}},
                 err(<<"{: if @a :}{: region r :}x{: /if :}">>)).

misplaced_branch_tags_test() ->
    ?assertEqual({1, {misplaced_block_tag, 'else'}}, err(<<"{: else :}">>)),
    ?assertEqual({1, {misplaced_block_tag, elif}}, err(<<"{: if @a :}{: else :}{: elif @b :}{: /if :}">>)),
    ?assertEqual({1, {misplaced_block_tag, 'else'}}, err(<<"{: if @a :}{: else :}{: else :}{: /if :}">>)),
    ?assertEqual({1, {misplaced_block_tag, 'of'}}, err(<<"{: if @a :}{: of x :}{: /if :}">>)),
    ?assertEqual({1, {misplaced_block_tag, empty}}, err(<<"{: if @a :}{: empty :}{: /if :}">>)),
    ?assertEqual({1, {misplaced_block_tag, 'else'}}, err(<<"{: for X <- @l :}{: else :}{: /for :}">>)),
    ?assertEqual({1, {misplaced_block_tag, empty}},
                 err(<<"{: for X <- @l :}{: empty :}{: empty :}{: /for :}">>)),
    %% a tag of the block, but inside another block opened since
    ?assertEqual({1, {misplaced_block_tag, 'else'}},
                 err(<<"{: if @a :}{: region r :}{: else :}{: /region r :}{: /if :}">>)).

%% ---------------------------------------------------------------------
%% Where blocks may stand (HTML text only; each branch ends in text)

blocks_only_in_html_text_test() ->
    ?assertEqual({1, {block_in_unsupported_context, 'if', tag}}, err(<<"<p {: if @a :}x{: /if :}>">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'for', attribute_value}},
                 err(<<"<p class=\"{: for X <- @l :}a{: /for :}\">">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'case', <<"script">>}},
                 err(<<"<script>{: case @a :}{: of a :}1{: /case :}</script>">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'if', comment}}, err(<<"<!-- {: if @a :}x{: /if :} -->">>)).

every_branch_has_to_end_in_text_test() ->
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"{: if @a :}<b{: /if :}>">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"{: if @a :}ok{: else :}<b class={: /if :}">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'for'}}, err(<<"{: for X <- @l :}<b{: /for :}">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'for'}}, err(<<"{: for X <- @l :}ok{: empty :}<b{: /for :}">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'case'}},
                 err(<<"{: case @a :}{: of a :}<b{: /case :}">>)).

elements_need_not_balance_across_branches_test() ->
    %% only tag syntax is checked, as in a region: the author keeps elements balanced
    T = <<"{: if @a :}<div>{: else :}<div class=\"x\">{: /if :}text</div>">>,
    ?assertEqual(<<"<div>text</div>">>, render(T, #{a => true})),
    ?assertEqual(<<"<div class=\"x\">text</div>">>, render(T, #{a => false})).

interpolation_inside_blocks_keeps_the_html_rules_test() ->
    ?assertEqual({1, {interpolation_in_restricted_attribute, <<"style">>}},
                 err(<<"{: if @a :}<p style=\"{{ @u }}\">x</p>{: /if :}">>)),
    ?assertEqual(<<"<a title=\"t\">x</a>">>,
                 render(<<"{: for T <- @ts :}<a title=\"{{ T }}\">x</a>{: /for :}">>, #{ts => [t]})).

fills_and_slots_do_not_stand_in_blocks_test() ->
    ?assertEqual({1, {fill_not_top_level, h}}, err(<<"{: if @a :}{: fill h :}x{: /fill h :}{: /if :}">>)),
    ?assertEqual({1, {fill_not_top_level, h}}, err(<<"{: for X <- @l :}{: fill h :}x{: /fill h :}{: /for :}">>)).

%% ---------------------------------------------------------------------
%% Regions and blocks

a_region_may_stand_in_a_branch_test() ->
    T = <<"{: if @show :}{: region r :}<b>{{ @x }}</b>{: /region r :}{: else :}-{: /if :}">>,
    ?assertEqual(<<"<weberl-region name=\"r\"><b>1</b></weberl-region>">>, render(T, #{show => true, x => 1})),
    ?assertEqual(<<"-">>, render(T, #{show => false, x => 1})),
    V = tpl(T),
    %% the region renders alone, whatever the condition says
    ?assertEqual(<<"<b>2</b>">>, iolist_to_binary(weberl_template:render_region(V, r, #{x => 2}))),
    {ok, Regions} = weberl_template:regions(V),
    ?assertMatch(#{r := #{variables := [x]}}, Regions).

a_region_may_contain_blocks_and_depends_on_their_assigns_test() ->
    %% the pattern to make a conditional live: put the block inside a region
    T = <<"{: region nav :}{: if @user =/= undefined :}in{: else :}out{: /if :}"
          "{: for A <- @agents :}[{{ A }}]{: /for :}{: /region nav :}">>,
    V = tpl(T),
    {ok, #{nav := #{variables := Vars}}} = weberl_template:regions(V),
    ?assertEqual([agents, user], Vars),
    ?assertEqual(<<"out[a][b]">>,
                 iolist_to_binary(weberl_template:render_region(V, nav, #{user => undefined, agents => [a, b]}))),
    ?assertEqual(<<"in">>,
                 iolist_to_binary(weberl_template:render_region(V, nav, #{user => x, agents => []}))).

a_region_cannot_use_a_local_bound_outside_it_test() ->
    ?assertEqual({1, {region_uses_outer_variable, r, 'Msg'}},
                 err(<<"{: case @f :}{: of {error, Msg} :}{: region r :}{{ Msg }}{: /region r :}{: /case :}">>)),
    ?assertEqual({1, {region_uses_outer_variable, r, 'X'}},
                 err(<<"{: case @a :}{: of X :}{: region r :}{: if X :}a{: /if :}{: /region r :}{: /case :}">>)),
    %% a local that nothing binds anywhere is plainly unbound
    ?assertEqual({1, {unbound_variable, 'Z'}}, err(<<"{: region r :}{{ Z }}{: /region r :}">>)),
    %% what the region binds itself is fine
    ?assertEqual(<<"<weberl-region name=\"r\">ab</weberl-region>">>,
                 render(<<"{: region r :}{: for X <- [a, b] :}{{ X }}{: /for :}{: /region r :}">>, #{})).

no_region_in_the_body_of_a_for_test() ->
    ?assertEqual({1, {region_in_for, r}},
                 err(<<"{: for X <- @l :}{: region r :}{{ X }}{: /region r :}{: /for :}">>)),
    ?assertEqual({1, {region_in_for, r}},
                 err(<<"{: for X <- @l :}{: if X :}{: region r :}a{: /region r :}{: /if :}{: /for :}">>)),
    %% the empty branch is rendered at most once
    ?assertEqual(<<"<weberl-region name=\"r\">none</weberl-region>">>,
                 render(<<"{: for X <- @l :}{{ X }}{: empty :}{: region r :}none{: /region r :}{: /for :}">>,
                        #{l => []})).

region_names_stay_unique_across_branches_test() ->
    ?assertEqual({1, {duplicate_region, r, 1}},
                 err(<<"{: if @a :}{: region r :}a{: /region r :}{: else :}{: region r :}b{: /region r :}{: /if :}">>)).

%% ---------------------------------------------------------------------
%% Dependencies

assigns_in_every_part_of_a_block_are_dependencies_test() ->
    V = tpl(<<"{: if @a :}{: elif @b :}{: else :}{{ @c }}{: /if :}"
              "{: case @d :}{: of X when X > @e :}{{ @f }}{: /case :}"
              "{: for Y <- @g, Y > @h :}{{ @i }}{: empty :}{{ @j }}{: /for :}">>),
    ?assertEqual([a, b, c, d, e, f, g, h, i, j],
                 maps:get(variables, (weberl_template:generated_module(V)):info())).

locals_are_not_dependencies_test() ->
    V = tpl(<<"{: for X <- @l :}{{ X }}{: /for :}">>),
    ?assertEqual([l], maps:get(variables, (weberl_template:generated_module(V)):info())).

%% ---------------------------------------------------------------------
%% Layouts and blocks

layout(Dir, Source) ->
    File = filename:join(Dir, "main.weberl"),
    ok = file:write_file(File, Source),
    weberl_template:parse_layout(File).

with_layout(LayoutSource, Fun) ->
    weberl_test_util:with_tmp(fun(Dir) ->
        {ok, L} = layout(Dir, LayoutSource),
        Fun(L)
    end).

in_layout(L, Source) ->
    View = unique_view(),
    {ok, C} = weberl_template:compile_source(View, Source, "v.weberl", L),
    ok = weberl_template:load(C),
    View.

layout_error(LayoutSource) ->
    weberl_test_util:with_tmp(fun(Dir) ->
        {error, {syntax_error, _, Line, Reason}} = layout(Dir, LayoutSource),
        {Line, Reason}
    end).

view_error(L, Source) ->
    {error, {syntax_error, File, Line, Reason}} =
        weberl_template:compile_source(unique_view(), Source, "v.weberl", L),
    {File, Line, Reason}.

a_layout_with_blocks_around_the_content_and_slots_test() ->
    with_layout(<<"<nav>{: if @user =/= undefined :}in{: else :}out{: /if :}</nav>"
                  "{: slot head :}H{: /slot head :}<main>{: content :}</main>">>,
                fun(L) ->
                        V = in_layout(L, <<"{: fill head :}<title>{{ @t }}</title>{: /fill head :}<p>{{ @user }}</p>">>),
                        ?assertEqual(<<"<nav>in</nav><title>T</title><main><p>ana</p></main>">>,
                                     iolist_to_binary(weberl_template:render(V, #{user => <<"ana">>, t => <<"T">>}))),
                        ?assertEqual(<<"<nav>out</nav><title>T</title><main><p>undefined</p></main>">>,
                                     iolist_to_binary(weberl_template:render(V, #{user => undefined, t => <<"T">>})))
                end).

the_content_and_a_slot_may_stand_in_a_branch_test() ->
    with_layout(<<"{: if @show :}<main>{: content :}</main>{: else :}hidden{: /if :}"
                  "{: case @mode :}{: of full :}{: slot extra :}default{: /slot extra :}{: of _ :}-{: /case :}">>,
                fun(L) ->
                        V = in_layout(L, <<"{: fill extra :}EXTRA{: /fill extra :}body {{ @n }}">>),
                        R = fun(A) -> iolist_to_binary(weberl_template:render(V, A)) end,
                        ?assertEqual(<<"<main>body 1</main>EXTRA">>, R(#{show => true, mode => full, n => 1})),
                        ?assertEqual(<<"hidden-">>, R(#{show => false, mode => other, n => 1})),
                        %% the default of a slot in a branch, when the view fills nothing
                        V2 = in_layout(L, <<"body">>),
                        ?assertEqual(<<"<main>body</main>default">>,
                                     iolist_to_binary(weberl_template:render(V2, #{show => true, mode => full})))
                end).

the_content_marker_still_stands_once_test() ->
    weberl_test_util:with_tmp(fun(Dir) ->
        ?assertMatch({error, {multiple_content, _, [1, 1]}},
                     layout(Dir, <<"{: if @w :}{: content :}{: else :}{: content :}{: /if :}">>))
    end).

neither_content_nor_slots_stand_in_a_for_test() ->
    ?assertEqual({1, content_in_for}, layout_error(<<"{: for X <- @l :}{: content :}{: /for :}">>)),
    ?assertEqual({1, content_in_for}, layout_error(<<"{: content :}{: for X <- @l :}{: if X :}{: content :}{: /if :}{: /for :}">>)),
    ?assertEqual({1, {slot_in_for, s}},
                 layout_error(<<"{: content :}{: for X <- @l :}{: slot s :}a{: /slot s :}{: /for :}">>)),
    ?assertEqual({1, {slot_in_for, s}},
                 layout_error(<<"{: content :}{: for X <- @l :}a{: empty :}{: slot s :}a{: /slot s :}{: /for :}">>)).

a_fill_has_to_be_top_level_in_a_view_with_a_layout_test() ->
    with_layout(<<"{: slot h :}d{: /slot h :}{: content :}">>,
                fun(L) ->
                        ?assertEqual({"v.weberl", 1, {fill_not_top_level, h}},
                                     view_error(L, <<"{: if @a :}{: fill h :}x{: /fill h :}{: /if :}">>))
                end).

regions_in_layout_branches_and_the_views_regions_share_names_test() ->
    with_layout(<<"{: if @a :}{: region nav :}<b>{{ @user }}</b>{: /region nav :}{: /if :}{: content :}">>,
                fun(L) ->
                        V = in_layout(L, <<"{: region body :}{{ @text }}{: /region body :}">>),
                        {ok, Regions} = weberl_template:regions(V),
                        ?assertMatch(#{nav := #{variables := [user]}, body := #{variables := [text]}}, Regions),
                        ?assertEqual(<<"<b>ana</b>">>,
                                     iolist_to_binary(weberl_template:render_region(V, nav, #{user => <<"ana">>}))),
                        %% a view region with the layout's name (even inside a branch) is a clash
                        ?assertMatch({error, {duplicate_region, nav, _, _}},
                                     weberl_template:compile_source(unique_view(),
                                                                    <<"{: region nav :}x{: /region nav :}">>,
                                                                    "v.weberl", L))
                end).

a_name_bound_by_the_layout_and_the_view_is_an_error_test() ->
    %% each file is fine alone; the view sits inside the layout's `of X' branch
    with_layout(<<"{: case @a :}{: of X :}{: content :}{: /case :}">>,
                fun(L) ->
                        ?assertEqual({"v.weberl", 1, {rebound_variable, 'X'}},
                                     view_error(L, <<"{: for X <- @l :}{{ X }}{: /for :}">>)),
                        %% another name is fine
                        V = in_layout(L, <<"{: for Y <- @l :}{{ Y }}{: /for :}">>),
                        ?assertEqual(<<"12">>, iolist_to_binary(weberl_template:render(V, #{a => 0, l => [1, 2]})))
                end).

layout_dependencies_include_its_conditions_test() ->
    with_layout(<<"{: if @user :}x{: /if :}{: content :}">>,
                fun(L) ->
                        V = in_layout(L, <<"{{ @t }}">>),
                        ?assertEqual([t, user], maps:get(variables, (weberl_template:generated_module(V)):info()))
                end).
