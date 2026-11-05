%% Long-poll and POST request transports of live pages, and the handler's
%% handle_request/3, over real HTTP. (The WebSocket has its own module,
%% weberl_live_ws_tests.)
-module(weberl_live_transport_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util,
        [with_router/2, new_page/2, has/2, await_state/2, request/5, jsonp/1]).

transport_test_() ->
    {setup,
     fun() ->
             ok = weberl_live_test_util:start_apps(),
             application:set_env(weberl, live_poll_timeout, 400)
     end,
     fun(_) -> application:unset_env(weberl, live_poll_timeout) end,
     [{"poll: returns buffered events at once", fun poll_buffered/0},
      {"poll: waits for an event, then returns the burst", fun poll_waits/0},
      {"poll: empty after the timeout", fun poll_timeout/0},
      {"poll: nothing is lost between polls", fun poll_gap/0},
      {"poll: reports a closed session", fun poll_closed/0},
      {"poll: token, method and the fallback switch", fun poll_guards/0},
      {"request: reply, ok, ref", fun post_replies/0},
      {"request: errors", fun post_errors/0},
      {"request: guards", fun post_guards/0}]}.

%% ---------------------------------------------------------------------

routes() -> weberl_live_test_util:request_routes().

%% ---------------------------------------------------------------------
%% Long-poll

poll_path(Id, Token) ->
    "/_weberl/poll/" ++ binary_to_list(Id) ++ "?t=" ++ binary_to_list(Token).

poll(Name, Id, Token) ->
    {200, _, Body} = request(Name, get, poll_path(Id, Token), [], undefined),
    json:decode(Body).

poll_buffered() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        ok = weberl_live:push(Id, <<"a">>, <<"1">>),
        ok = weberl_live:push(Id, <<"b">>, <<"2">>),
        ?assertEqual(#{~"events" => [#{~"event" => ~"a", ~"data" => ~"1"},
                                     #{~"event" => ~"b", ~"data" => ~"2"}],
                       ~"closed" => false}, poll(Name, Id, Token)),
        await_state(Id, detached)
    end).

poll_waits() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/two"),
        Self = self(),
        spawn_link(fun() -> Self ! {polled, poll(Name, Id, Token)} end),
        await_state(Id, attached),
        ok = weberl_live:push(Id, <<"x">>, <<"1">>),
        ok = weberl_live:push(Id, <<"y">>, <<"2">>),
        receive {polled, Result} ->
                ?assertEqual([~"x", ~"y"],
                             [maps:get(~"event", E) || E <- maps:get(~"events", Result)])
        after 3000 -> error(poll_did_not_return)
        end
    end).

poll_timeout() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        ?assertEqual(#{~"events" => [], ~"closed" => false}, poll(Name, Id, Token)),
        ?assertMatch({ok, #{state := detached}}, weberl_live:info(Id))
    end).

poll_gap() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        ok = weberl_live:push(Id, <<"first">>, <<"1">>),
        ?assertMatch(#{~"events" := [_]}, poll(Name, Id, Token)),
        %% between polls: buffered, delivered by the next poll
        ok = weberl_live:push(Id, <<"second">>, <<"2">>),
        ok = weberl_live:push(Id, <<"third">>, <<"3">>),
        #{~"events" := Events} = poll(Name, Id, Token),
        ?assertEqual([~"second", ~"third"], [maps:get(~"event", E) || E <- Events])
    end).

poll_closed() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        Self = self(),
        spawn_link(fun() -> Self ! {polled, poll(Name, Id, Token)} end),
        await_state(Id, attached),
        weberl_live:close(Id),
        receive {polled, Result} ->
                ?assertEqual(#{~"events" => [], ~"closed" => true}, Result)
        after 3000 -> error(poll_did_not_return)
        end,
        %% the session is gone: the next poll finds nothing
        ?assertMatch({404, _, _}, request(Name, get, poll_path(Id, Token), [], undefined))
    end).

poll_guards() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        Base = "/_weberl/poll/" ++ binary_to_list(Id),
        ?assertMatch({403, _, _}, request(Name, get, Base, [], undefined)),
        ?assertMatch({403, _, _}, request(Name, get, Base ++ "?t=nope", [], undefined)),
        ?assertMatch({403, _, _}, request(Name, get, poll_path(Id, Token),
                                          [{"origin", "http://evil.example"}], undefined)),
        ?assertMatch({405, _, _}, request(Name, post, poll_path(Id, Token), [],
                                          {"text/plain", <<>>})),
        %% header credential
        ?assertMatch({200, _, _}, request(Name, get, Base, [{"x-weberl-token",
                                                             binary_to_list(Token)}], undefined)),
        %% the fallback can be turned off per kind
        {BeforeId, BeforeToken} = new_page(Name, "/two"),
        application:set_env(weberl, live_poll_fallback, [one_way]),
        try
            %% a page rendered now carries no poll channel in its token
            {TwoId, TwoToken} = new_page(Name, "/two"),
            ?assertMatch({403, _, _}, request(Name, get, poll_path(TwoId, TwoToken), [], undefined)),
            %% a page rendered before the switch is refused by the endpoint
            ?assertMatch({404, _, _}, request(Name, get, poll_path(BeforeId, BeforeToken), [], undefined)),
            ?assertMatch({200, _, _}, request(Name, get, poll_path(Id, Token), [], undefined))
        after
            application:unset_env(weberl, live_poll_fallback)
        end
    end).

%% ---------------------------------------------------------------------
%% POST /_weberl/request/:id

request_path(Id) -> "/_weberl/request/" ++ binary_to_list(Id).

post(Name, Id, Token, Body) ->
    {Status, _, RespBody} =
        request(Name, post, request_path(Id), [{"x-weberl-token", binary_to_list(Token)}],
                {"application/json", Body}),
    {Status, case RespBody of <<>> -> <<>>; _ -> json:decode(RespBody) end}.

post_replies() ->
    with_router(routes(), fun(Name) ->
        %% one_way pages send requests over POST; two_way pages may too
        [begin
             {Id, Token} = new_page(Name, Path),
             ?assertEqual({200, #{~"reply" => #{~"echoed" => ~"hi"}, ~"ref" => 3}},
                          post(Name, Id, Token, jsonp(#{request => echo, data => hi, ref => 3}))),
             ?assertEqual({200, #{~"ok" => true}},
                          post(Name, Id, Token, jsonp(#{request => ignore})))
         end || Path <- ["/one", "/two"]],
        %% a handler can push through the page's session
        {Id2, Token2} = new_page(Name, "/one"),
        ?assertMatch({200, _}, post(Name, Id2, Token2, jsonp(#{request => push, data => ~"p"}))),
        ?assertMatch({ok, #{buffered := 1}}, weberl_live:info(Id2))
    end).

post_errors() ->
    weberl_live_test_util:quiet(fun post_errors_/0).

post_errors_() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        ?assertEqual({400, #{~"error" => ~"bad_request"}}, post(Name, Id, Token, <<"{nope">>)),
        ?assertEqual({400, #{~"error" => ~"bad_request"}}, post(Name, Id, Token, <<"[1]">>)),
        ?assertEqual({400, #{~"error" => ~"bad_request"}},
                     post(Name, Id, Token, jsonp(#{request => <<>>}))),
        ?assertEqual({500, #{~"error" => ~"failed", ~"ref" => ~"x"}},
                     post(Name, Id, Token, jsonp(#{request => boom, ref => ~"x"}))),
        ?assertMatch({200, _}, post(Name, Id, Token, jsonp(#{request => echo}))),
        {BareId, BareToken} = new_page(Name, "/bare"),
        ?assertEqual({501, #{~"error" => ~"unsupported"}},
                     post(Name, BareId, BareToken, jsonp(#{request => echo})))
    end).

post_guards() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/one"),
        Body = jsonp(#{request => echo}),
        {403, _, _} = request(Name, post, request_path(Id), [], {"application/json", Body}),
        {403, _, _} = request(Name, post, request_path(Id), [{"x-weberl-token", "bad"}],
                              {"application/json", Body}),
        {403, _, _} = request(Name, post, request_path(Id),
                              [{"x-weberl-token", binary_to_list(Token)},
                               {"origin", "http://evil.example"}], {"application/json", Body}),
        {405, _, _} = request(Name, get, request_path(Id) ++ "?t=" ++ binary_to_list(Token),
                              [], undefined),
        %% a token is bound to its page
        {OtherId, _} = new_page(Name, "/one"),
        {403, _, _} = request(Name, post, request_path(OtherId),
                              [{"x-weberl-token", binary_to_list(Token)}],
                              {"application/json", Body}),
        ?assert(has(Body, <<"echo">>))
    end).
