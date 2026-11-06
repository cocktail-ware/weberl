%% Blocks between the attributes of a tag and inside quoted attribute values (HANDOFF decision 14).
%% The complaint behind them: an optional attribute (`checked', `disabled', a class) forced the author to
%% repeat the whole element in two branches. Between attributes the engine adds the separating spaces; inside
%% a value it adds nothing (a space there is data).
-module(weberl_template_attr_blocks_tests).
-include_lib("eunit/include/eunit.hrl").

tpl(Source) ->
    View = weberl_test_handlers:unique("attrview"),
    {ok, C} = weberl_template:compile_source(View, Source, "t.weberl"),
    ok = weberl_template:load(C),
    View.

render(Source, Assigns) -> iolist_to_binary(weberl_template:render(tpl(Source), Assigns)).

err(Source) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} =
        weberl_template:compile_source(weberl_test_handlers:unique("attrview"), Source, "t.weberl"),
    {Line, Reason}.

%% ---------------------------------------------------------------------
%% Between attributes

an_optional_boolean_attribute_test() ->
    T = <<"<input name=\"x\" {: if @on :}checked{: /if :}>">>,
    ?assertEqual(<<"<input name=\"x\"  checked >">>, render(T, #{on => true})),
    %% not taken, no else: nothing at all is added
    ?assertEqual(<<"<input name=\"x\" >">>, render(T, #{on => false})).

if_else_between_attributes_test() ->
    T = <<"<p {: if @a :}a=\"1\"{: else :}b=\"2\"{: /if :}>x</p>">>,
    ?assertEqual(<<"<p  a=\"1\" >x</p>">>, render(T, #{a => true})),
    ?assertEqual(<<"<p  b=\"2\" >x</p>">>, render(T, #{a => false})),
    T2 = <<"<p {: if @a :}a=\"1\"{: elif @b :}b=\"2\"{: /if :}>">>,
    ?assertEqual(<<"<p  b=\"2\" >">>, render(T2, #{a => false, b => true})),
    ?assertEqual(<<"<p >">>, render(T2, #{a => false, b => false})).

the_next_attribute_is_separated_without_the_author_writing_a_space_test() ->
    %% `hidden' ends the branch with a complete valueless attribute, `id' follows with no space between
    T = <<"<p {: if @a :}hidden{: /if :}id=\"x\">">>,
    ?assertEqual(<<"<p  hidden id=\"x\">">>, render(T, #{a => true})),
    ?assertEqual(<<"<p id=\"x\">">>, render(T, #{a => false})),
    %% several valueless attributes in a branch, and a value attribute then a bare one
    T2 = <<"<input {: if @a :}checked disabled{: /if :}>">>,
    ?assertEqual(<<"<input  checked disabled >">>, render(T2, #{a => true})),
    T3 = <<"<input {: if @a :}class=\"c\" disabled{: /if :}/>">>,
    ?assertEqual(<<"<input  class=\"c\" disabled />">>, render(T3, #{a => true})).

a_block_may_follow_a_finished_valueless_attribute_test() ->
    %% `disabled ' then a block: the tracker is after an attribute name and white space, a new attribute is next
    T = <<"<input disabled {: if @on :}checked{: /if :}>">>,
    ?assertEqual(<<"<input disabled  checked >">>, render(T, #{on => true})),
    ?assertEqual(<<"<input disabled >">>, render(T, #{on => false})),
    %% but not glued to a name that is not finished
    ?assertEqual({1, {block_in_unsupported_context, 'if', tag}},
                 err(<<"<input disabled{: if @on :}checked{: /if :}>">>)).

the_attribute_before_the_block_may_close_its_quote_right_before_it_test() ->
    T = <<"<p id=\"x\"{: if @a :}hidden{: /if :}>">>,
    ?assertEqual(<<"<p id=\"x\" hidden >">>, render(T, #{a => true})).

case_between_attributes_test() ->
    T = <<"<p {: case @kind :}{: of primary :}class=\"p\"{: of {size, N} when N > 3 :}class=\"big\"{: of _ :}{: /case :}>">>,
    ?assertEqual(<<"<p  class=\"p\" >">>, render(T, #{kind => primary})),
    ?assertEqual(<<"<p  class=\"big\" >">>, render(T, #{kind => {size, 4}})),
    %% a clause with an empty body renders the two spaces of its (empty) branch
    ?assertEqual(<<"<p   >">>, render(T, #{kind => other})).

for_between_attributes_test() ->
    T = <<"<p {: for A <- @attrs :}{: if A =:= a :}data-a{: else :}data-b=\"1\"{: /if :}{: /for :}>">>,
    %% each body is wrapped in spaces, and so is the branch of the `if' inside it
    ?assertEqual(<<"<p   data-a    data-b=\"1\"  >">>, render(T, #{attrs => [a, b]})),
    ?assertEqual(<<"<p >">>, render(<<"<p {: for A <- @attrs :}x{: /for :}>">>, #{attrs => []})),
    %% empty
    E = <<"<p {: for A <- @attrs :}x{: empty :}hidden{: /for :}>">>,
    ?assertEqual(<<"<p  hidden >">>, render(E, #{attrs => []})).

a_conditional_url_attribute_is_between_attributes_test() ->
    %% the URL helper checks of the attribute value still apply inside the branch
    T = <<"<a {: if @has :}href=\"{{ weberl_url:ensure_path(@p) }}\"{: /if :}>x</a>">>,
    ?assertEqual(<<"<a  href=\"/x\" >x</a>">>, render(T, #{has => true, p => <<"/x">>})),
    ?assertEqual(<<"<a >x</a>">>, render(T, #{has => false, p => <<"//evil">>})),
    V = tpl(T),
    ?assertError({template_error, {not_a_path, <<"//evil">>}}, weberl_template:render(V, #{has => true, p => <<"//evil">>})),
    %% a plain value in it is still refused (rendered), a literal in it is a compile error
    ?assertMatch({1, {untagged_url, _}}, err(<<"<a {: if @has :}href=\"{{ \"/x\" }}\"{: /if :}>x</a>">>)).

interpolation_inside_a_value_of_an_attribute_in_a_branch_test() ->
    T = <<"<p {: if @a :}title=\"{{ @t }}\"{: /if :}>">>,
    ?assertEqual(<<"<p  title=\"a&quot;b\" >">>, render(T, #{a => true, t => <<"a\"b">>})).

blocks_nest_between_attributes_test() ->
    T = <<"<p {: if @a :}x {: if @b :}y{: /if :}{: /if :}>">>,
    ?assertEqual(<<"<p  x  y  >">>, render(T, #{a => true, b => true})),
    ?assertEqual(<<"<p  x  >">>, render(T, #{a => true, b => false})),
    ?assertEqual(<<"<p >">>, render(T, #{a => false, b => true})).

%% ---------------------------------------------------------------------
%% Inside a quoted value: no spaces are added

class_lists_test() ->
    T = <<"<button class=\"btn {: if @on :}active{: /if :}\">x</button>">>,
    ?assertEqual(<<"<button class=\"btn active\">x</button>">>, render(T, #{on => true})),
    ?assertEqual(<<"<button class=\"btn \">x</button>">>, render(T, #{on => false})),
    ?assertEqual(<<"<button class=\"btn active big\">x</button>">>,
                 render(<<"<button class=\"btn {: if @on :}active {: /if :}big\">x</button>">>, #{on => true})).

a_space_in_a_value_is_data_so_none_is_added_test() ->
    T = <<"<p title=\"Hello{: if @x :}!{: /if :}\">">>,
    ?assertEqual(<<"<p title=\"Hello!\">">>, render(T, #{x => true})),
    ?assertEqual(<<"<p title=\"Hello\">">>, render(T, #{x => false})).

a_loop_in_a_value_test() ->
    T = <<"<p class=\"{: for C <- @cs :}{{ C }} {: /for :}\">">>,
    ?assertEqual(<<"<p class=\"a b \">">>, render(T, #{cs => [a, b]})),
    %% interpolated values are escaped as in any value
    ?assertEqual(<<"<p class=\"a&quot;b \">">>, render(T, #{cs => [<<"a\"b">>]})),
    ?assertEqual(<<"<p class=\"\">">>, render(T, #{cs => []})).

case_in_a_value_test() ->
    T = <<"<p data-state=\"{: case @s :}{: of ok :}fine{: of {error, M} :}bad: {{ M }}{: /case :}\">">>,
    ?assertEqual(<<"<p data-state=\"fine\">">>, render(T, #{s => ok})),
    ?assertEqual(<<"<p data-state=\"bad: x &lt; y\">">>, render(T, #{s => {error, <<"x < y">>}})).

single_quoted_values_work_too_test() ->
    T = <<"<p class='a {: if @on :}b{: /if :}'>">>,
    ?assertEqual(<<"<p class='a b'>">>, render(T, #{on => true})).

%% ---------------------------------------------------------------------
%% A branch ends where the block began

a_branch_may_not_leave_a_value_or_a_tag_open_test() ->
    %% between attributes
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"<p {: if @a :}class=\"x{: /if :}\">">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"<p {: if @a :}a={: /if :}\"x\">">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"<p {: if @a :}hidden>{: /if :}">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"<p {: if @a :}hidden{: else :}a=\"{: /if :}\">">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'for'}}, err(<<"<p {: for X <- @l :}a=\"1{: /for :}\">">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'case'}},
                 err(<<"<p {: case @a :}{: of a :}hidden>{: /case :}">>)),
    %% inside a value: the quote may not close (or the value change) in a branch
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"<p class=\"a {: if @a :}b\" id=\"{: /if :}\">">>)),
    ?assertEqual({1, {block_unbalanced_markup, 'if'}}, err(<<"<p class=\"a {: if @a :}b\">{: /if :}">>)).

only_a_complete_attribute_name_may_end_a_branch_between_attributes_test() ->
    %% the engine adds the space after the branch: a name that is finished is fine
    ?assertMatch(<<_/binary>>, render(<<"<p {: if @a :}checked{: /if :}>">>, #{a => true})),
    ?assertMatch(<<_/binary>>, render(<<"<p {: if @a :}checked {: /if :}>">>, #{a => true})).

%% ---------------------------------------------------------------------
%% What stays refused

blocks_in_url_and_restricted_values_are_refused_test() ->
    [?assertEqual({1, {block_in_restricted_attribute, Attr}},
                  err(<<"<p ", Attr/binary, "=\"{: if @a :}x{: /if :}\">">>))
     || Attr <- [<<"href">>, <<"src">>, <<"action">>, <<"formaction">>, <<"poster">>, <<"cite">>, <<"xlink:href">>,
                 <<"style">>, <<"onclick">>, <<"onload">>, <<"srcset">>, <<"data">>, <<"srcdoc">>, <<"ping">>]],
    ?assertEqual({1, {block_in_restricted_attribute, <<"href">>}},
                 err(<<"<a HREF='{: for X <- @l :}/x{: /for :}'>x</a>">>)),
    ?assertEqual({1, {block_in_restricted_attribute, <<"href">>}},
                 err(<<"<a href=\"/a/{: case @x :}{: of a :}b{: /case :}\">x</a>">>)).

blocks_stay_out_of_other_places_test() ->
    ?assertEqual({1, {block_in_unsupported_context, 'if', tag}}, err(<<"<p class=a{: if @a :}x{: /if :}>">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'if', lt}}, err(<<"<{: if @a :}p{: /if :}>">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'if', tag}}, err(<<"<p data-{: if @a :}x{: /if :}=\"1\">">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'if', <<"script">>}},
                 err(<<"<script>{: if @a :}x{: /if :}</script>">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'if', <<"style">>}},
                 err(<<"<style>{: if @a :}x{: /if :}</style>">>)),
    ?assertEqual({1, {block_in_unsupported_context, 'if', comment}}, err(<<"<!-- {: if @a :}x{: /if :} -->">>)).

between_attributes_there_is_no_interpolation_of_its_own_test() ->
    %% an interpolation there would be an attribute name
    ?assertEqual({1, {interpolation_in_unsupported_context, tag}}, err(<<"<p {: if @a :}{{ @x }}{: /if :}>">>)),
    %% raw interpolation stays refused in a value
    ?assertEqual({1, {raw_interpolation_in_attribute, <<"class">>}},
                 err(<<"<p class=\"{: if @a :}{{{ @x }}}{: /if :}\">">>)).

regions_slots_and_content_stay_in_text_test() ->
    ?assertMatch({1, {region_in_unsupported_context, r, _}},
                 err(<<"<p {: if @a :}{: region r :}{: /region r :}{: /if :}>">>)),
    ?assertMatch({1, {region_in_unsupported_context, r, _}},
                 err(<<"<p class=\"{: if @a :}{: region r :}{: /region r :}{: /if :}\">">>)).

%% ---------------------------------------------------------------------
%% Around the block

text_around_blocks_in_a_tag_is_untouched_test() ->
    T = <<"<div id=\"a\" {: if @x :}hidden{: /if :} class=\"b\">t {{ @n }}</div>">>,
    ?assertEqual(<<"<div id=\"a\"  hidden  class=\"b\">t 1</div>">>, render(T, #{x => true, n => 1})),
    ?assertEqual(<<"<div id=\"a\"  class=\"b\">t 1</div>">>, render(T, #{x => false, n => 1})).

blocks_in_text_are_untouched_test() ->
    %% no spaces are added to a block that stands in text, nor to one in a value
    ?assertEqual(<<"<p>ab</p>">>, render(<<"<p>{: if @x :}a{: /if :}b</p>">>, #{x => true})).

dependencies_of_attribute_blocks_are_the_assigns_they_read_test() ->
    View = tpl(<<"<p {: if @a :}hidden{: /if :} class=\"{: for C <- @cs :}{{ C }}{: /for :}\">">>),
    ?assertEqual([a, cs], maps:get(variables, (weberl_template:generated_module(View)):info())).
