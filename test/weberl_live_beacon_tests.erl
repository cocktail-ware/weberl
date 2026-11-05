-module(weberl_live_beacon_tests).
-include_lib("eunit/include/eunit.hrl").

html(Body) -> weberl_response:html(200, Body).

%% The token is random per tag; tests compare with it replaced by a constant.
norm(Bin) ->
    re:replace(Bin, "data-weberl-token=\"[^\"]*\"", "data-weberl-token=\"T\"",
               [global, {return, binary}]).

injected(Body) ->
    R = weberl_live_beacon:inject(html(Body), {<<"ID123">>, one_way}),
    norm(iolist_to_binary(weberl_response:body(R))).

tag() -> norm(weberl_live_beacon:tag(<<"ID123">>, one_way)).

tag_test() ->
    ?assertEqual(<<"<script src=\"/_weberl/engine.js\" defer></script>"
                   "<script src=\"/_weberl/client.js\" data-weberl-page=\"ID123\" "
                   "data-weberl-token=\"T\" data-weberl-kind=\"one_way\" "
                   "data-weberl-fallback=\"poll\" defer></script>">>, tag()),
    ?assertMatch({_, _}, binary:match(weberl_live_beacon:tag(<<"X">>, two_way),
                                      <<"data-weberl-kind=\"two_way\"">>)).

tag_token_test() ->
    Tag = weberl_live_beacon:tag(<<"ID123">>, one_way),
    {match, [Token]} = re:run(Tag, "data-weberl-token=\"([^\"]+)\"",
                              [{capture, all_but_first, binary}]),
    ?assert(weberl_live_guard:verify(<<"ID123">>, sse, Token)),
    ?assertNot(weberl_live_guard:verify(<<"OTHER">>, sse, Token)).

token_channels_follow_the_kind_test() ->
    Tok = fun(Kind) ->
                  {match, [T]} = re:run(weberl_live_beacon:tag(<<"I">>, Kind),
                                        "data-weberl-token=\"([^\"]+)\"",
                                        [{capture, all_but_first, binary}]),
                  T
          end,
    One = Tok(one_way),
    Two = Tok(two_way),
    ?assertEqual([true, true, true, true],
                 [weberl_live_guard:verify(<<"I">>, C, One) || C <- [sse, ws, poll, request]]),
    ?assertEqual([false, true, true, true],
                 [weberl_live_guard:verify(<<"I">>, C, Two) || C <- [sse, ws, poll, request]]).

topics_attribute_test() ->
    Topics = [<<"stock:ACME">>, <<"a\"<b>&">>],
    Tag = weberl_live_beacon:tag(<<"ID">>, two_way, #{topics => Topics, session => false}),
    {match, [Attr]} = re:run(Tag, "data-weberl-topics=\"([^\"]*)\"", [{capture, all_but_first, binary}]),
    %% nothing in the attribute can break out of it
    ?assertEqual(nomatch, re:run(Attr, "[\"<>]")),
    Unescaped = lists:foldl(fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
                            Attr, [{<<"&quot;">>, <<"\"">>}, {<<"&lt;">>, <<"<">>},
                                   {<<"&gt;">>, <<">">>}, {<<"&amp;">>, <<"&">>}]),
    ?assertEqual(Topics, json:decode(Unescaped)),
    %% the token carries them too
    {match, [Token]} = re:run(Tag, "data-weberl-token=\"([^\"]+)\"", [{capture, all_but_first, binary}]),
    ?assertMatch({ok, #{topics := Topics, session := false, kind := two_way}},
                 weberl_live_guard:claims(<<"ID">>, ws, Token)),
    %% no topics, no attribute
    ?assertEqual(nomatch, binary:match(weberl_live_beacon:tag(<<"ID">>, one_way), <<"topics">>)).

fallback_switch_test() ->
    Prev = application:get_env(weberl, live_poll_fallback),
    application:set_env(weberl, live_poll_fallback, [one_way]),
    try
        ?assert(has(weberl_live_beacon:tag(<<"I">>, one_way), <<"fallback=\"poll\"">>)),
        ?assert(has(weberl_live_beacon:tag(<<"I">>, two_way), <<"fallback=\"none\"">>))
    after
        case Prev of
            undefined -> application:unset_env(weberl, live_poll_fallback);
            {ok, V} -> application:set_env(weberl, live_poll_fallback, V)
        end
    end.

has(Bin, Needle) -> binary:match(Bin, Needle) =/= nomatch.

before_body_close_test() ->
    T = tag(),
    ?assertEqual(<<"<html><body><p>x</p>", T/binary, "</body></html>">>,
                 injected(<<"<html><body><p>x</p></body></html>">>)).

case_insensitive_test() ->
    T = tag(),
    ?assertEqual(<<"<BODY>x", T/binary, "</BODY>">>, injected(<<"<BODY>x</BODY>">>)).

last_body_close_wins_test() ->
    T = tag(),
    ?assertEqual(<<"<pre>&lt;/body&gt;</pre></body>a", T/binary, "</body>">>,
                 injected(<<"<pre>&lt;/body&gt;</pre></body>a</body>">>)).

no_body_appends_test() ->
    T = tag(),
    ?assertEqual(<<"<p>fragment</p>", T/binary>>, injected(<<"<p>fragment</p>">>)).

iodata_body_test() ->
    T = tag(),
    ?assertEqual(<<"a", T/binary, "</body>">>, injected([<<"a">>, ["</", "body>"]])).

keeps_status_and_headers_test() ->
    R0 = weberl_response:with_header(<<"x-a">>, <<"1">>, weberl_response:html(201, <<"x">>)),
    R = weberl_live_beacon:inject(R0, {<<"I">>, two_way}),
    ?assertEqual(201, weberl_response:status(R)),
    ?assertEqual({ok, <<"1">>}, weberl_response:header(<<"x-a">>, R)).

injectable_test_() ->
    Resp = fun(S, Type) ->
                   weberl_response:with_header(<<"content-type">>, Type,
                                               weberl_response:new(S, [], <<"x">>))
           end,
    [?_assert(weberl_live_beacon:injectable(weberl_response:html(200, <<"x">>))),
     ?_assert(weberl_live_beacon:injectable(Resp(201, <<"TEXT/HTML">>))),
     ?_assert(weberl_live_beacon:injectable(Resp(200, <<"application/xhtml+xml">>))),
     ?_assertNot(weberl_live_beacon:injectable(weberl_response:text(200, <<"x">>))),
     ?_assertNot(weberl_live_beacon:injectable(weberl_response:html(404, <<"x">>))),
     ?_assertNot(weberl_live_beacon:injectable(weberl_response:html(302, <<"x">>))),
     ?_assertNot(weberl_live_beacon:injectable(weberl_response:new(200, [], <<"x">>)))].
