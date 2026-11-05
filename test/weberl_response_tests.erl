-module(weberl_response_tests).
-include_lib("eunit/include/eunit.hrl").

html_test() ->
    R = weberl_response:html(200, <<"<p>hi</p>">>),
    ?assertEqual(200, weberl_response:status(R)),
    ?assertEqual({ok, <<"text/html; charset=utf-8">>}, weberl_response:header("Content-Type", R)),
    ?assertEqual(<<"<p>hi</p>">>, weberl_response:body(R)).

text_test() ->
    R = weberl_response:text(201, "hello"),
    ?assertEqual(201, weberl_response:status(R)),
    ?assertEqual({ok, <<"text/plain; charset=utf-8">>}, weberl_response:header(<<"content-type">>, R)).

binary_test() ->
    R = weberl_response:binary(200, <<0, 1, 2>>),
    ?assertEqual({ok, <<"application/octet-stream">>}, weberl_response:header("content-type", R)),
    ?assertEqual(<<0, 1, 2>>, weberl_response:body(R)).

iodata_body_test() ->
    R = weberl_response:html(200, [<<"a">>, ["b", $c]]),
    ?assertEqual(<<"abc">>, iolist_to_binary(weberl_response:body(R))).

custom_status_test() ->
    ?assertEqual(418, weberl_response:status(weberl_response:text(418, <<"tea">>))).

with_header_adds_and_replaces_test() ->
    R0 = weberl_response:html(200, <<>>),
    R1 = weberl_response:with_header("X-Custom", "one", R0),
    R2 = weberl_response:with_header(<<"x-custom">>, <<"two">>, R1),
    ?assertEqual({ok, <<"two">>}, weberl_response:header("X-CUSTOM", R2)),
    ?assertEqual(1, length([H || {<<"x-custom">>, _} = H <- weberl_response:headers(R2)])),
    R3 = weberl_response:with_header("Content-Type", "text/css", R2),
    ?assertEqual({ok, <<"text/css">>}, weberl_response:header("content-type", R3)).

new_normalizes_headers_test() ->
    R = weberl_response:new(204, [{"Cache-Control", "no-store"}], <<>>),
    ?assertEqual([{<<"cache-control">>, <<"no-store">>}], weberl_response:headers(R)).

header_missing_test() ->
    ?assertEqual(error, weberl_response:header("x-nope", weberl_response:text(200, <<>>))).

badarg_test_() ->
    [?_assertError(badarg, weberl_response:html(99, <<>>)),
     ?_assertError(badarg, weberl_response:html(600, <<>>)),
     ?_assertError(badarg, weberl_response:html(ok, <<>>)),
     ?_assertError(badarg, weberl_response:html(200, an_atom)),
     ?_assertError(badarg, weberl_response:html(200, [an_atom])),
     ?_assertError(badarg, weberl_response:new(200, [{x, <<"v">>}], <<>>)),
     ?_assertError(badarg, weberl_response:with_header("x", 5, weberl_response:text(200, <<>>)))].

normalize_test() ->
    R = weberl_response:text(200, <<"x">>),
    ?assertEqual({ok, R}, weberl_response:normalize(R)),
    ?assertEqual({error, {invalid_handler_return, ok}}, weberl_response:normalize(ok)),
    ?assertEqual({error, {invalid_handler_return, <<"body">>}},
                 weberl_response:normalize(<<"body">>)).
