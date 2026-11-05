-module(weberl_response_tests).
-include_lib("eunit/include/eunit.hrl").

html_test() ->
    R = weberl_response:html(200, <<"<p>hi</p>">>),
    ?assertEqual(200, weberl_response:status(R)),
    ?assertEqual({ok, <<"text/html; charset=utf-8">>}, weberl_response:header(R, "Content-Type")),
    ?assertEqual(<<"<p>hi</p>">>, weberl_response:body(R)).

text_test() ->
    R = weberl_response:text(201, "hello"),
    ?assertEqual(201, weberl_response:status(R)),
    ?assertEqual({ok, <<"text/plain; charset=utf-8">>}, weberl_response:header(R, <<"content-type">>)).

binary_test() ->
    R = weberl_response:binary(200, <<0, 1, 2>>),
    ?assertEqual({ok, <<"application/octet-stream">>}, weberl_response:header(R, "content-type")),
    ?assertEqual(<<0, 1, 2>>, weberl_response:body(R)).

iodata_body_test() ->
    R = weberl_response:html(200, [<<"a">>, ["b", $c]]),
    ?assertEqual(<<"abc">>, iolist_to_binary(weberl_response:body(R))).

custom_status_test() ->
    ?assertEqual(418, weberl_response:status(weberl_response:text(418, <<"tea">>))).

with_header_adds_and_replaces_test() ->
    R0 = weberl_response:html(200, <<>>),
    R1 = weberl_response:with_header(R0, "X-Custom", "one"),
    R2 = weberl_response:with_header(R1, <<"x-custom">>, <<"two">>),
    ?assertEqual({ok, <<"two">>}, weberl_response:header(R2, "X-CUSTOM")),
    ?assertEqual(1, length([H || {<<"x-custom">>, _} = H <- weberl_response:headers(R2)])),
    R3 = weberl_response:with_header(R2, "Content-Type", "text/css"),
    ?assertEqual({ok, <<"text/css">>}, weberl_response:header(R3, "content-type")).

%% Feedback from agentic (item 4): same rule as `weberl_request', the response comes
%% first, so a chain reads `with_header(with_body(R, B), N, V)' and the old order fails.
response_comes_first_in_every_function_test() ->
    R = weberl_response:with_header(weberl_response:with_body(weberl_response:text(200, <<"a">>), <<"b">>),
                                    "x-a", "1"),
    ?assertEqual(<<"b">>, weberl_response:body(R)),
    ?assertEqual({ok, <<"1">>}, weberl_response:header(R, "x-a")),
    ?assertError(function_clause, weberl_response:header("x-a", R)),
    ?assertError(function_clause, weberl_response:with_header("x-a", "1", R)),
    ?assertError(function_clause, weberl_response:with_body(<<"b">>, R)).

new_normalizes_headers_test() ->
    R = weberl_response:new(204, [{"Cache-Control", "no-store"}], <<>>),
    ?assertEqual([{<<"cache-control">>, <<"no-store">>}], weberl_response:headers(R)).

header_missing_test() ->
    ?assertEqual(error, weberl_response:header(weberl_response:text(200, <<>>), "x-nope")).

badarg_test_() ->
    [?_assertError(badarg, weberl_response:html(99, <<>>)),
     ?_assertError(badarg, weberl_response:html(600, <<>>)),
     ?_assertError(badarg, weberl_response:html(ok, <<>>)),
     ?_assertError(badarg, weberl_response:html(200, an_atom)),
     ?_assertError(badarg, weberl_response:html(200, [an_atom])),
     ?_assertError(badarg, weberl_response:new(200, [{x, <<"v">>}], <<>>)),
     ?_assertError(badarg, weberl_response:with_header(weberl_response:text(200, <<>>), "x", 5))].

normalize_test() ->
    R = weberl_response:text(200, <<"x">>),
    ?assertEqual({ok, R}, weberl_response:normalize(R)),
    ?assertEqual({error, {invalid_handler_return, ok}}, weberl_response:normalize(ok)),
    ?assertEqual({error, {invalid_handler_return, <<"body">>}},
                 weberl_response:normalize(<<"body">>)).
