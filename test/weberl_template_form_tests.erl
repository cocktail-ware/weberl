%% `{: form Action [, Opts] :}' ... `{: /form :}' (feedback from agentic, migration notes 2 and 3): the
%% template opens and closes the form and the framework supplies the CSRF token of the running request.
-module(weberl_template_form_tests).
-include_lib("eunit/include/eunit.hrl").

tpl(Source) ->
    View = weberl_test_handlers:unique("formview"),
    {ok, C} = weberl_template:compile_source(View, Source, "t.weberl"),
    ok = weberl_template:load(C),
    View.

err(Source) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} =
        weberl_template:compile_source(weberl_test_handlers:unique("formview"), Source, "t.weberl"),
    {Line, Reason}.

%% Render as dispatch would: the token is forgotten first, the request is ambient, and the response
%% gets what the page used (cookie, headers) afterwards.
render(Source, Assigns) -> render(Source, Assigns, []).

render(Source, Assigns, Cookies) ->
    Request = weberl_test_cookie_adapter:request(Cookies),
    View = tpl(Source),
    ok = weberl_csrf:begin_request(),
    Out = weberl_session:run(Request, fun() -> iolist_to_binary(weberl_template:render(View, Assigns)) end),
    {Out, weberl_csrf:finalize(weberl_response:html(200, Out))}.

tokens(Html) ->
    case re:run(Html, "name=\"_csrf\" value=\"([^\"]*)\"", [global, {capture, [1], binary}]) of
        {match, Found} -> [T || [T] <- Found];
        nomatch -> []
    end.

-define(LOGIN, "{: form weberl_url:ensure_path(<<\"/login\">>) :}").

%% ---------------------------------------------------------------------

the_block_writes_the_tags_and_the_token_test() ->
    {Out, Resp} = render(<<?LOGIN, "<input name=\"u\">{: /form :}">>, #{}),
    ?assertMatch({match, _}, re:run(Out, "^<form method=\"post\" action=\"/login\"><input type=\"hidden\" "
                                         "name=\"_csrf\" value=\"[^\"]+\" data-weberl-csrf><input name=\"u\"></form>$")),
    %% no cookie yet: the response sets it, with the same token, and is not cached
    [SetCookie] = weberl_response:header_values(Resp, <<"set-cookie">>),
    [Token] = tokens(Out),
    ?assertNotEqual(nomatch, binary:match(SetCookie, <<"weberl_csrf=", Token/binary>>)),
    ?assertEqual({ok, <<"private, no-store">>}, weberl_response:header(Resp, <<"cache-control">>)),
    ?assertEqual({ok, <<"same-origin">>}, weberl_response:header(Resp, <<"referrer-policy">>)).

a_known_cookie_is_reused_and_not_set_again_test() ->
    {Out1, Resp1} = render(<<?LOGIN, "{: /form :}">>, #{}),
    [SetCookie] = weberl_response:header_values(Resp1, <<"set-cookie">>),
    [<<"weberl_csrf=", Value/binary>> | _] = binary:split(SetCookie, <<";">>),
    {Out2, Resp2} = render(<<?LOGIN, "{: /form :}">>, #{}, [{<<"weberl_csrf">>, Value}]),
    ?assertEqual(tokens(Out1), tokens(Out2)),
    ?assertEqual([], weberl_response:header_values(Resp2, <<"set-cookie">>)),
    %% the page carries a per-browser token: it must not be cached
    ?assertEqual({ok, <<"private, no-store">>}, weberl_response:header(Resp2, <<"cache-control">>)).

several_forms_share_one_fresh_token_test() ->
    {Out, Resp} = render(<<?LOGIN, "{: /form :}", ?LOGIN, "{: /form :}">>, #{}),
    [T1, T2] = tokens(Out),
    ?assertEqual(T1, T2),
    ?assertEqual(1, length(weberl_response:header_values(Resp, <<"set-cookie">>))).

a_page_without_a_form_gets_nothing_test() ->
    {_, Resp} = render(<<"<p>hi</p>">>, #{}),
    ?assertEqual([], weberl_response:header_values(Resp, <<"set-cookie">>)),
    ?assertEqual(error, weberl_response:header(Resp, <<"cache-control">>)).

protect_and_the_block_use_the_same_token_test() ->
    Request = weberl_test_cookie_adapter:request([]),
    View = tpl(<<?LOGIN, "{: /form :}">>),
    ok = weberl_csrf:begin_request(),
    Resp0 = weberl_session:run(Request, fun() ->
        weberl_csrf:protect(Request, fun(Token) ->
            Html = iolist_to_binary(weberl_template:render(View, #{})),
            ?assertEqual([Token], tokens(Html)),
            weberl_response:html(200, Html)
        end)
    end),
    Resp = weberl_csrf:finalize(Resp0),
    ?assertEqual(1, length(weberl_response:header_values(Resp, <<"set-cookie">>))).

%% ---------------------------------------------------------------------
%% Options

options_test() ->
    %% a safe method has no token, csrf => false none either
    {Get, _} = render(<<"{: form weberl_url:ensure_path(<<\"/s\">>), #{method => get} :}{: /form :}">>, #{}),
    ?assertEqual(<<"<form method=\"get\" action=\"/s\"></form>">>, Get),
    {Off, RespOff} = render(<<"{: form weberl_url:ensure_path(<<\"/hook\">>), #{csrf => false} :}{: /form :}">>, #{}),
    ?assertEqual(<<"<form method=\"post\" action=\"/hook\"></form>">>, Off),
    ?assertEqual([], weberl_response:header_values(RespOff, <<"set-cookie">>)),
    %% extra attributes; a comma inside the action expression is not the separator
    {Attrs, _} = render(<<"{: form weberl_url:ensure_path(iolist_to_binary([<<\"/a\">>, <<\"b\">>])), "
                          "#{attrs => [{<<\"class\">>, <<\"x y\">>}]} :}{: /form :}">>, #{}),
    ?assertMatch({match, _}, re:run(Attrs, "^<form method=\"post\" action=\"/ab\" class=\"x y\">")).

multipart_puts_the_token_in_the_action_test() ->
    {Out, Resp} = render(<<"{: form weberl_url:ensure_path(<<\"/up\">>), #{enctype => multipart} :}{: /form :}">>, #{}),
    {match, [Token]} = re:run(Out, "action=\"/up\\?_csrf=([^\"]+)\"", [{capture, [1], binary}]),
    ?assertNotEqual(nomatch, binary:match(Out, <<"enctype=\"multipart/form-data\"">>)),
    ?assertEqual([], tokens(Out)),
    [SetCookie] = weberl_response:header_values(Resp, <<"set-cookie">>),
    {weberl_url, component, Encoded} = weberl_url:component(<<"x">>),
    ?assertEqual(<<"x">>, Encoded),
    ?assertNotEqual(nomatch, binary:match(SetCookie, binary:replace(Token, <<"%2E">>, <<".">>))).

assigns_in_the_action_and_the_options_test() ->
    {Out, _} = render(<<"{: form weberl_url:ensure_path(@to), #{method => @method} :}{: /form :}">>,
                      #{to => <<"/go">>, method => get}),
    ?assertEqual(<<"<form method=\"get\" action=\"/go\"></form>">>, Out).

bad_options_are_template_errors_test() ->
    View = tpl(<<"{: form weberl_url:ensure_path(<<\"/x\">>), #{nope => 1} :}{: /form :}">>),
    ?assertError({template_error, {bad_form_options, View, 1, #{nope := 1}}},
                 weberl_template:render(View, #{})),
    View2 = tpl(<<"{: form weberl_url:ensure_path(@to), @o :}{: /form :}">>),
    ?assertError({template_error, {bad_form_options, View2, 1, not_a_map}},
                 weberl_template:render(View2, #{to => <<"/x">>, o => not_a_map})).

%% ---------------------------------------------------------------------
%% Structure and where it may stand

inside_blocks_test() ->
    T = <<"{: for I <- @ids :}", ?LOGIN, "{: if I > 1 :}<b>x</b>{: /if :}{: /form :}{: /for :}">>,
    {Out, _} = render(T, #{ids => [1, 2]}),
    ?assertEqual(2, length(tokens(Out))),
    ?assertEqual(2, length(binary:matches(Out, <<"</form>">>))).

a_form_does_not_nest_test() ->
    ?assertEqual({1, form_in_form}, err(<<?LOGIN, ?LOGIN, "{: /form :}{: /form :}">>)).

unclosed_and_unexpected_test() ->
    ?assertEqual({1, {unclosed_block, form}}, err(<<?LOGIN, "x">>)),
    ?assertEqual({1, {unexpected_block_end, form}}, err(<<"x{: /form :}">>)),
    ?assertMatch({1, {mismatched_block_end, _, _}}, err(<<?LOGIN, "{: if true :}{: /form :}{: /if :}">>)),
    ?assertMatch({1, {mismatched_block_end, {form, none}, _}}, err(<<?LOGIN, "{: /if :}">>)),
    ?assertEqual({1, {missing_expression, form}}, err(<<"{: form :}{: /form :}">>)),
    ?assertEqual({1, {missing_expression, form}}, err(<<"{: form weberl_url:ensure_path(<<\"/x\">>), :}{: /form :}">>)).

only_in_text_and_balanced_test() ->
    ?assertEqual({1, {form_in_unsupported_context, tag}},
                 err(<<"<p {: form weberl_url:ensure_path(<<\"/x\">>) :}{: /form :}>">>)),
    ?assertEqual({1, {form_in_unsupported_context, attribute_value}},
                 err(<<"<p class=\"{: form weberl_url:ensure_path(<<\"/x\">>) :}{: /form :}\">">>)),
    ?assertEqual({1, form_unbalanced_markup}, err(<<?LOGIN, "<p class=\"{: /form :}">>)).

the_action_has_to_be_a_checked_url_test() ->
    %% like href="{{ ... }}": a bare string is not a url value
    ?assertMatch({1, {untagged_url, _}}, err(<<"{: form \"/login\" :}{: /form :}">>)),
    ?assertMatch({1, {not_a_path, _}}, err(<<"{: form weberl_url:ensure_path(<<\"//evil\">>) :}{: /form :}">>)),
    %% at render time a value that is not one
    View = tpl(<<"{: form @a :}{: /form :}">>),
    ?assertError({template_error, {untagged_url, View, 1, <<"/x">>}}, weberl_template:render(View, #{a => <<"/x">>})).

an_unbound_variable_in_the_head_is_refused_test() ->
    ?assertEqual({1, {unbound_variable, 'X'}}, err(<<"{: form weberl_url:ensure_path(X) :}{: /form :}">>)).

%% ---------------------------------------------------------------------
%% No request: regions rendered for other browsers

a_form_outside_a_request_is_an_error_test() ->
    View = tpl(<<?LOGIN, "{: /form :}">>),
    ?assertError({template_error, {csrf_token_unavailable, View, 1}}, weberl_template:render(View, #{})).

a_region_without_a_request_leaves_the_field_for_the_browser_test() ->
    View = tpl(<<"{: region nav :}", ?LOGIN, "{: /form :}{: /region nav :}">>),
    Html = iolist_to_binary(weberl_template:render_region(View, nav, #{})),
    ?assertEqual(<<"<form method=\"post\" action=\"/login\"><input type=\"hidden\" name=\"_csrf\" value=\"\" "
                   "data-weberl-csrf></form>">>, Html),
    %% the full render of the same page, with a request, has the token
    {Out, _} = render(<<"{: region nav :}", ?LOGIN, "{: /form :}{: /region nav :}">>, #{}),
    ?assertMatch([<<_, _/binary>>], tokens(Out)),
    %% a multipart form cannot be filled in later: its token is in the action
    View2 = tpl(<<"{: region r :}{: form weberl_url:ensure_path(<<\"/up\">>), #{enctype => multipart} :}"
                  "{: /form :}{: /region r :}">>),
    ?assertError({template_error, {csrf_token_unavailable, View2, 1}},
                 weberl_template:render_region(View2, r, #{})).

%% ---------------------------------------------------------------------
%% The beacon hands the page's token to the browser (for the forms of regions)

the_beacon_carries_the_token_of_a_page_with_a_form_test() ->
    Request = weberl_test_cookie_adapter:request([]),
    View = tpl(<<?LOGIN, "{: /form :}">>),
    ok = weberl_csrf:begin_request(),
    Tag = weberl_session:run(Request, fun() ->
        [Token] = tokens(iolist_to_binary(weberl_template:render(View, #{}))),
        Beacon = weberl_live_beacon:tag(<<"page1">>, one_way),
        ?assertNotEqual(nomatch, binary:match(Beacon, <<"data-weberl-csrf=\"", Token/binary, "\"">>)),
        Beacon
    end),
    ok = weberl_csrf:begin_request(),
    %% a page that rendered no form says nothing
    Plain = weberl_live_beacon:tag(<<"page2">>, one_way),
    ?assertEqual(nomatch, binary:match(Plain, <<"data-weberl-csrf">>)),
    ?assertMatch(<<_, _/binary>>, Tag).
