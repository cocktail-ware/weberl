-module(weberl_live_guard_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ALL, [sse, ws, poll, request]).

token_roundtrip_test() ->
    Token = weberl_live_guard:issue(<<"page1">>, ?ALL),
    ?assert(is_binary(Token)),
    [?assert(weberl_live_guard:verify(<<"page1">>, C, Token)) || C <- ?ALL].

token_is_bound_to_the_page_test() ->
    Token = weberl_live_guard:issue(<<"page1">>, ?ALL),
    ?assertNot(weberl_live_guard:verify(<<"page2">>, sse, Token)).

token_is_bound_to_its_channels_test() ->
    Token = weberl_live_guard:issue(<<"p">>, [sse, request]),
    ?assert(weberl_live_guard:verify(<<"p">>, sse, Token)),
    ?assert(weberl_live_guard:verify(<<"p">>, request, Token)),
    ?assertNot(weberl_live_guard:verify(<<"p">>, ws, Token)),
    ?assertNot(weberl_live_guard:verify(<<"p">>, poll, Token)),
    ?assertNot(weberl_live_guard:verify(<<"p">>, sse, weberl_live_guard:issue(<<"p">>, []))).

channels_cannot_be_widened_test() ->
    %% flip the channel byte of a token that only allows sse to "all": the MAC
    %% covers it, so the token is rejected for every channel
    Token = weberl_live_guard:issue(<<"p">>, [sse]),
    Raw = base64:decode(Token, #{mode => urlsafe, padding => false}),
    <<Salt:8/binary, _Mask, Mac/binary>> = Raw,
    Widened = base64:encode(<<Salt/binary, 15, Mac/binary>>, #{mode => urlsafe, padding => false}),
    [?assertNot(weberl_live_guard:verify(<<"p">>, C, Widened)) || C <- ?ALL].

claims_roundtrip_test() ->
    Claims = #{kind => two_way, session => false, handler => ?MODULE,
               topics => [<<"stock:ACME">>, <<"caf\xc3\xa9">>]},
    Token = weberl_live_guard:issue(<<"p">>, ?ALL, Claims),
    ?assertEqual({ok, Claims}, weberl_live_guard:claims(<<"p">>, ws, Token)),
    ?assertEqual(error, weberl_live_guard:claims(<<"other">>, ws, Token)),
    ?assertEqual(error, weberl_live_guard:claims(<<"p">>, ws, weberl_live_guard:issue(<<"p">>, [sse]))).

claims_default_test() ->
    Token = weberl_live_guard:issue(<<"p">>, [sse]),
    ?assertEqual({ok, #{kind => one_way, session => true, handler => undefined, topics => []}},
                 weberl_live_guard:claims(<<"p">>, sse, Token)).

claims_cannot_be_changed_test() ->
    %% a token for no topics, with a topic spliced in, no longer verifies
    Token = weberl_live_guard:issue(<<"p">>, ?ALL, #{topics => []}),
    Raw = base64:decode(Token, #{mode => urlsafe, padding => false}),
    <<Salt:8/binary, Mask, Flags, 0:16, 0, Mac:32/binary>> = Raw,
    Forged = base64:encode(<<Salt/binary, Mask, Flags, 0:16, 1, 3:16, "abc", Mac/binary>>,
                           #{mode => urlsafe, padding => false}),
    ?assertEqual(error, weberl_live_guard:claims(<<"p">>, sse, Forged)).

tokens_are_salted_test() ->
    ?assertNotEqual(weberl_live_guard:issue(<<"p">>, ?ALL), weberl_live_guard:issue(<<"p">>, ?ALL)).

url_safe_test() ->
    Tokens = [weberl_live_guard:issue(<<"p">>, ?ALL) || _ <- lists:seq(1, 50)],
    [?assertEqual(nomatch, re:run(T, "[^A-Za-z0-9_-]")) || T <- Tokens].

malformed_tokens_test_() ->
    [?_assertNot(weberl_live_guard:verify(<<"p">>, sse, T))
     || T <- [<<>>, <<"x">>, <<"!!!!">>, undefined, 42,
              binary:copy(<<"A">>, 43), binary:copy(<<"A">>, 200)]].

tampered_token_test() ->
    Token = weberl_live_guard:issue(<<"p">>, ?ALL),
    %% first character: the last one carries padding bits the decoder ignores
    <<First, Rest/binary>> = Token,
    Tampered = <<(case First of $A -> $B; _ -> $A end), Rest/binary>>,
    ?assertNot(weberl_live_guard:verify(<<"p">>, sse, Tampered)).

configured_secret_test() ->
    Prev = application:get_env(weberl, live_secret),
    Token = weberl_live_guard:issue(<<"p">>, ?ALL),
    application:set_env(weberl, live_secret, <<"0123456789abcdef-secret">>),
    try
        %% tokens of the generated secret do not verify under the configured one
        ?assertNot(weberl_live_guard:verify(<<"p">>, sse, Token)),
        Own = weberl_live_guard:issue(<<"p">>, ?ALL),
        ?assert(weberl_live_guard:verify(<<"p">>, sse, Own))
    after
        case Prev of
            undefined -> application:unset_env(weberl, live_secret);
            {ok, V} -> application:set_env(weberl, live_secret, V)
        end
    end,
    ?assert(weberl_live_guard:verify(<<"p">>, sse, Token)).

short_secret_is_ignored_test() ->
    Prev = application:get_env(weberl, live_secret),
    application:set_env(weberl, live_secret, <<"short">>),
    try
        Token = weberl_live_guard:issue(<<"p">>, ?ALL),
        ?assert(weberl_live_guard:verify(<<"p">>, sse, Token))
    after
        case Prev of
            undefined -> application:unset_env(weberl, live_secret);
            {ok, V} -> application:set_env(weberl, live_secret, V)
        end
    end.

origin_test_() ->
    H = fun(Extra) -> [{<<"host">>, <<"example.com:8080">>} | Extra] end,
    [?_assert(weberl_live_guard:origin_ok(H([]))),
     ?_assert(weberl_live_guard:origin_ok(H([{<<"origin">>, <<"http://example.com:8080">>}]))),
     ?_assert(weberl_live_guard:origin_ok(H([{<<"origin">>, <<"https://EXAMPLE.com:8080">>}]))),
     ?_assertNot(weberl_live_guard:origin_ok(H([{<<"origin">>, <<"http://evil.example">>}]))),
     ?_assertNot(weberl_live_guard:origin_ok(H([{<<"origin">>, <<"http://example.com">>}]))),
     ?_assertNot(weberl_live_guard:origin_ok(H([{<<"origin">>, <<"null">>}]))),
     ?_assertNot(weberl_live_guard:origin_ok([{<<"origin">>, <<"http://example.com">>}]))].
