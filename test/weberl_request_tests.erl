-module(weberl_request_tests).
-include_lib("eunit/include/eunit.hrl").

req(Extra) ->
    weberl_request:new(maps:merge(#{method => <<"GET">>, path => "/"}, Extra)).

defaults_test() ->
    R = req(#{}),
    ?assertEqual(<<"GET">>, weberl_request:method(R)),
    ?assertEqual("/", weberl_request:path(R)),
    ?assertEqual([], weberl_request:headers(R)),
    ?assertEqual(<<>>, weberl_request:query(R)),
    ?assertEqual(#{}, weberl_request:params(R)),
    ?assertEqual(undefined, weberl_request:peer(R)),
    ?assertEqual(#{}, weberl_request:meta(R)).

method_uppercased_test() ->
    ?assertEqual(<<"POST">>, weberl_request:method(req(#{method => <<"post">>}))).

headers_lowercased_and_lookup_test() ->
    R = req(#{headers => [{<<"Content-Type">>, <<"text/plain">>}, {<<"X-A">>, <<"1">>}]}),
    ?assertEqual([{<<"content-type">>, <<"text/plain">>}, {<<"x-a">>, <<"1">>}],
                 weberl_request:headers(R)),
    ?assertEqual({ok, <<"text/plain">>}, weberl_request:header(R, "CONTENT-TYPE")),
    ?assertEqual(error, weberl_request:header(R, <<"x-missing">>)).

%% Feedback from agentic (item 4): `header' took the request last while `method',
%% `query_params' and `read_body' take it first. Every request function now takes
%% the request first, and the old order is rejected instead of silently misread.
request_comes_first_in_every_function_test() ->
    R = weberl_request:with_page(req(#{headers => [{<<"x-a">>, <<"1">>}]}), <<"P">>),
    ?assertEqual({ok, <<"1">>}, weberl_request:header(R, <<"x-a">>)),
    ?assertEqual(<<"P">>, weberl_request:page(R)),
    ?assertError(function_clause, weberl_request:header(<<"x-a">>, R)),
    ?assertError(function_clause, weberl_request:with_page(<<"P">>, R)).

query_params_test() ->
    ?assertEqual({ok, []}, weberl_request:query_params(req(#{}))),
    R = req(#{query => <<"a=1&b=hello%20world&flag">>}),
    ?assertEqual({ok, [{<<"a">>, <<"1">>}, {<<"b">>, <<"hello world">>}, {<<"flag">>, true}]},
                 weberl_request:query_params(R)),
    ?assertEqual(<<"a=1&b=hello%20world&flag">>, weberl_request:query(R)).

query_params_invalid_test() ->
    ?assertEqual({error, invalid_query},
                 weberl_request:query_params(req(#{query => <<"a=%zz">>}))).

peer_and_meta_test() ->
    R = req(#{peer => {{127, 0, 0, 1}, 5555}, meta => #{adapter => test}}),
    ?assertEqual({{127, 0, 0, 1}, 5555}, weberl_request:peer(R)),
    ?assertEqual(#{adapter => test}, weberl_request:meta(R)).

body_default_empty_test() ->
    ?assertEqual({ok, <<>>}, weberl_request:read_body(req(#{}))).

body_binary_test() ->
    ?assertEqual({ok, <<"data">>}, weberl_request:read_body(req(#{body => <<"data">>}))).

body_is_lazy_test() ->
    Self = self(),
    R = req(#{body_reader => fun() -> Self ! read, {ok, <<"x">>} end}),
    receive read -> ?assert(false) after 0 -> ok end,
    ?assertEqual({ok, <<"x">>}, weberl_request:read_body(R)),
    receive read -> ok after 0 -> ?assert(false) end.

body_reader_error_test() ->
    R = req(#{body_reader => fun() -> {error, closed} end}),
    ?assertEqual({error, closed}, weberl_request:read_body(R)).

bad_input_test_() ->
    [?_assertError(function_clause, weberl_request:new(#{path => "/"})),
     ?_assertError(function_clause, weberl_request:new(#{method => "GET", path => "/"}))].
