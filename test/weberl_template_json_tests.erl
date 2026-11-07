%% `{: json Expr :}' (feedback from agentic, task interface 2): hand data to a script without a
%% `data-state' workaround. Allowed in the content of a data script and in a quoted attribute value.
-module(weberl_template_json_tests).
-include_lib("eunit/include/eunit.hrl").

tpl(Source) ->
    View = weberl_test_handlers:unique("jsonview"),
    {ok, C} = weberl_template:compile_source(View, Source, "t.weberl"),
    ok = weberl_template:load(C),
    View.

render(Source, Assigns) -> iolist_to_binary(weberl_template:render(tpl(Source), Assigns)).

err(Source) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} =
        weberl_template:compile_source(weberl_test_handlers:unique("jsonview"), Source, "t.weberl"),
    {Line, Reason}.

%% The text between the first `>' and the last `</script>'.
inner(Out) ->
    [_, Rest] = binary:split(Out, <<">">>),
    binary:part(Rest, 0, byte_size(Rest) - byte_size(<<"</script>">>)).

%% ---------------------------------------------------------------------
%% Data scripts

a_data_script_gets_the_json_test() ->
    T = <<"<script type=\"application/json\" id=\"s\">{: json @state :}</script>">>,
    Out = render(T, #{state => #{running => 2, names => [<<"a">>, <<"b">>], ok => true, none => null}}),
    Json = inner(Out),
    ?assertEqual(#{~"running" => 2, ~"names" => [~"a", ~"b"], ~"ok" => true, ~"none" => null},
                 json:decode(Json)).

other_data_types_test() ->
    [begin
         T = <<"<script type=\"", Type/binary, "\">{: json @v :}</script>">>,
         ?assertEqual(<<"<script type=\"", Type/binary, "\">[1,2]</script>">>, render(T, #{v => [1, 2]}))
     end || Type <- [~"application/ld+json", ~"importmap", ~"speculationrules", ~"application/vnd.x+json",
                     ~"Application/JSON", ~"  application/json "]].

the_value_cannot_close_the_script_or_open_a_comment_test() ->
    T = <<"<script type=\"application/json\">{: json @v :}</script>">>,
    Evil = <<"</script><script>alert(1)</script><!-- & \xe2\x80\xa8 \xe2\x80\xa9">>,
    Out = render(T, #{v => #{k => Evil}}),
    Inner = inner(Out),
    ?assertEqual(nomatch, binary:match(Inner, [<<"<">>, <<">">>, <<"&">>, <<226, 128, 168>>, <<226, 128, 169>>])),
    %% and it still says exactly what it was given
    ?assertEqual(#{~"k" => Evil}, json:decode(Inner)).

an_expression_works_test() ->
    T = <<"<script type=\"application/json\">{: json #{n => @n + 1, who => string:uppercase(@who)} :}</script>">>,
    Out = render(T, #{n => 1, who => <<"ana">>}),
    ?assertMatch({match, _}, re:run(Out, "\"n\":2")),
    ?assertMatch({match, _}, re:run(Out, "\"who\":\"ANA\"")).

inside_a_block_and_a_region_test() ->
    T = <<"{: if @on :}<script type=\"application/json\">{: json @v :}</script>{: /if :}">>,
    ?assertEqual(<<"<script type=\"application/json\">1</script>">>, render(T, #{on => true, v => 1})),
    ?assertEqual(<<>>, render(T, #{on => false, v => 1})).

%% ---------------------------------------------------------------------
%% Attributes

an_attribute_value_is_html_escaped_test() ->
    T = <<"<div data-state=\"{: json @v :}\"></div>">>,
    ?assertEqual(<<"<div data-state=\"{&quot;a&quot;:&quot;&lt;b&gt; &amp; &#39;c&#39;&quot;}\"></div>">>,
                 render(T, #{v => #{a => <<"<b> & 'c'">>}})),
    T2 = <<"<div data-state='{: json @v :}'></div>">>,
    ?assertEqual(<<"<div data-state='[1]'></div>">>, render(T2, #{v => [1]})).

%% ---------------------------------------------------------------------
%% Where it is refused

not_in_text_test() ->
    ?assertEqual({1, {json_not_allowed_here, text}}, err(<<"<p>{: json @v :}</p>">>)).

not_in_an_executable_script_test() ->
    ?assertEqual({1, {json_not_allowed_here, <<"script">>}}, err(<<"<script>var x = {: json @v :};</script>">>)),
    ?assertEqual({1, {json_not_allowed_here, <<"script">>}},
                 err(<<"<script type=\"text/javascript\">{: json @v :}</script>">>)),
    %% an unquoted type is not read as data
    ?assertEqual({1, {json_not_allowed_here, <<"script">>}},
                 err(<<"<script type=application/json>{: json @v :}</script>">>)).

the_first_type_wins_test() ->
    ?assertEqual({1, {json_not_allowed_here, <<"script">>}},
                 err(<<"<script type=\"text/javascript\" type=\"application/json\">{: json @v :}</script>">>)).

not_in_restricted_attributes_test() ->
    ?assertEqual({1, {json_not_allowed_here, <<"onclick">>}}, err(<<"<a onclick=\"{: json @v :}\">x</a>">>)),
    ?assertEqual({1, {json_not_allowed_here, <<"href">>}}, err(<<"<a href=\"{: json @v :}\">x</a>">>)),
    ?assertEqual({1, {json_not_allowed_here, <<"style">>}}, err(<<"<p style=\"{: json @v :}\">x</p>">>)).

not_in_the_script_type_test() ->
    ?assertMatch({1, _}, err(<<"<script type=\"{: json @v :}\"></script>">>)),
    ?assertEqual({1, {interpolation_in_restricted_attribute, <<"type">>}},
                 err(<<"<script type=\"{{ @t }}\"></script>">>)).

plain_interpolation_stays_refused_in_a_data_script_test() ->
    ?assertEqual({1, {interpolation_in_unsupported_context, <<"script">>}},
                 err(<<"<script type=\"application/json\">{{ @v }}</script>">>)).

a_json_tag_needs_an_expression_test() ->
    ?assertEqual({1, {missing_expression, json}}, err(<<"<script type=\"application/json\">{: json :}</script>">>)).

%% ---------------------------------------------------------------------
%% Render-time errors

a_term_json_cannot_hold_is_a_template_error_test() ->
    T = <<"<div data-state=\"{: json @v :}\"></div>">>,
    View = tpl(T),
    ?assertError({template_error, {unsupported_value, View, <<"@v">>, {a, b}}},
                 weberl_template:render(View, #{v => {a, b}})),
    ?assertError({template_error, {missing_variable, View, v}}, weberl_template:render(View, #{})).

%% a script that has a `src' is still a script that runs code: its URL policy did not change
a_script_with_a_type_keeps_its_local_only_src_test() ->
    ?assertMatch({_, _}, err(<<"<script type=\"module\" src=\"{{ weberl_url:url(@u) }}\"></script>">>)).
