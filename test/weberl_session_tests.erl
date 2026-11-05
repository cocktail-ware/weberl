%% Feedback from agentic (item 6): no session helper. The session is one encrypted cookie;
%% these tests cover the cookie, the response functions (including "put, then get returns
%% what I put"), lifetimes and limits, and the whole flow over HTTP.
-module(weberl_session_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

%% ---------------------------------------------------------------------
%% helpers

base() -> weberl_response:html(200, <<"x">>).

%% The cookie a response sets, as {Name, Value}.
session_cookie(Response) ->
    [Cookie] = [C || C <- weberl_response:header_values(Response, "set-cookie"),
                     binary:match(C, <<"weberl_session=">>) =/= nomatch],
    [Pair | Attrs] = binary:split(Cookie, <<"; ">>, [global]),
    [Name, Value] = binary:split(Pair, <<"=">>),
    {Name, Value, Attrs}.

with_request(Cookies, Fun) ->
    weberl_session:run(weberl_test_cookie_adapter:request(Cookies), Fun).

cookie_for(Map) -> cookie_for(Map, os:system_time(second) + 1000).

cookie_for(Map, Expires) ->
    [{<<"weberl_session">>, weberl_session:encode(Map, Expires)}].

with_env(Key, Value, Fun) ->
    Old = application:get_env(weberl, Key),
    application:set_env(weberl, Key, Value),
    try Fun()
    after
        case Old of
            undefined -> application:unset_env(weberl, Key);
            {ok, V} -> application:set_env(weberl, Key, V)
        end
    end.

quiet(Fun) ->
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, maps:get(level, Old)) end.

%% ---------------------------------------------------------------------
%% The cookie

roundtrip_keeps_erlang_terms_test() ->
    Map = #{user_id => 42, <<"name">> => <<"Ana"/utf8>>, roles => [admin, {team, 7}],
            nested => #{a => 1.5}, big => lists:seq(1, 50)},
    Value = weberl_session:encode(Map, infinity),
    ?assertEqual({ok, Map, infinity}, weberl_session:decode(Value)).

the_client_cannot_read_it_test() ->
    Value = weberl_session:encode(#{user_id => 424242, secret => <<"hunter2">>}, infinity),
    ?assertEqual(nomatch, binary:match(Value, <<"hunter2">>)),
    {ok, Raw} = {ok, base64:decode(Value, #{mode => urlsafe, padding => false})},
    ?assertEqual(nomatch, binary:match(Raw, <<"hunter2">>)),
    %% encrypting twice gives different cookies (random IV)
    ?assertNotEqual(Value, weberl_session:encode(#{user_id => 424242, secret => <<"hunter2">>}, infinity)).

tampering_is_rejected_test() ->
    Value = weberl_session:encode(#{user_id => 1}, infinity),
    Flip = fun(I) ->
                   <<Pre:I/binary, C, Post/binary>> = Value,
                   <<Pre/binary, (case C of $A -> $B; _ -> $A end), Post/binary>>
           end,
    [?assertEqual(error, weberl_session:decode(Flip(I))) || I <- [0, 5, 12, 20, 30, byte_size(Value) - 5]],
    ?assertEqual(error, weberl_session:decode(<<>>)),
    ?assertEqual(error, weberl_session:decode(<<"not a cookie at all!">>)),
    ?assertEqual(error, weberl_session:decode(binary:part(Value, 0, 20))).

another_key_cannot_read_it_test() ->
    Value = weberl_session:encode(#{user_id => 1}, infinity),
    with_env(live_secret, <<"another secret, 16+ bytes">>,
             fun() -> ?assertEqual(error, weberl_session:decode(Value)) end),
    ?assertMatch({ok, _, _}, weberl_session:decode(Value)).

an_expired_session_is_rejected_test() ->
    Now = os:system_time(second),
    ?assertEqual(error, weberl_session:decode(weberl_session:encode(#{a => 1}, Now - 1))),
    ?assertMatch({ok, _, _}, weberl_session:decode(weberl_session:encode(#{a => 1}, Now + 60))).

%% ---------------------------------------------------------------------
%% Reading the request's session

request_session_test() ->
    R = weberl_test_cookie_adapter:request(cookie_for(#{user_id => 7, theme => dark})),
    ?assertEqual(#{user_id => 7, theme => dark}, weberl_request:session(R)),
    ?assertEqual({ok, 7}, weberl_request:session_get(R, user_id)),
    ?assertEqual(error, weberl_request:session_get(R, nope)).

no_valid_session_is_an_empty_map_test() ->
    Req = fun(Cookies) -> weberl_test_cookie_adapter:request(Cookies) end,
    ?assertEqual(#{}, weberl_request:session(Req([]))),
    ?assertEqual(#{}, weberl_request:session(Req([{<<"weberl_session">>, <<"garbage">>}]))),
    ?assertEqual(#{}, weberl_request:session(Req(cookie_for(#{a => 1}, os:system_time(second) - 5)))),
    ?assertEqual(#{}, weberl_request:session(Req([{<<"other">>, <<"x">>}]))).

%% ---------------------------------------------------------------------
%% The exact expectation: put, then get on the returned response

put_then_get_on_the_response_test() ->
    with_request(cookie_for(#{user_id => 7, theme => dark}), fun() ->
        R1 = weberl_response:put_session(base(), cart, [1, 2]),
        ?assertEqual({ok, [1, 2]}, weberl_response:session_get(R1, cart)),
        %% what was already in the request's session is still there
        ?assertEqual({ok, 7}, weberl_response:session_get(R1, user_id)),
        ?assertEqual(#{user_id => 7, theme => dark, cart => [1, 2]}, weberl_response:session(R1)),
        R2 = weberl_response:delete_session(R1, theme),
        ?assertEqual(error, weberl_response:session_get(R2, theme)),
        R3 = weberl_response:put_session(R2, cart, [3]),
        ?assertEqual({ok, [3]}, weberl_response:session_get(R3, cart)),
        %% the request's own view is what the browser sent
        ?assertEqual(#{user_id => 7, theme => dark},
                     weberl_request:session(element(2, weberl_session:ambient())))
    end).

an_untouched_response_has_no_session_test() ->
    with_request(cookie_for(#{user_id => 7}), fun() ->
        ?assertEqual(undefined, weberl_response:session(base())),
        ?assertEqual({ok, 7}, weberl_response:session_get(base(), user_id)),
        ?assertEqual(undefined, weberl_response:session(base()))
    end).

set_and_reset_need_no_request_test() ->
    R1 = weberl_response:set_session(base(), #{user_id => 9}),
    ?assertEqual({ok, 9}, weberl_response:session_get(R1, user_id)),
    ?assertEqual(#{}, weberl_response:session(weberl_response:reset_session(R1))),
    %% and the first put after them needs none either
    ?assertEqual({ok, 1}, weberl_response:session_get(weberl_response:put_session(R1, a, 1), a)).

no_request_to_load_from_raises_test() ->
    ?assertError({session_not_loaded, put_session}, weberl_response:put_session(base(), a, 1)),
    ?assertError({session_not_loaded, delete_session}, weberl_response:delete_session(base(), a)),
    ?assertError({session_not_loaded, session_get}, weberl_response:session_get(base(), a)),
    ?assertError({session_not_loaded, session_ttl}, weberl_response:session_ttl(base(), 60)).

load_session_is_explicit_and_idempotent_test() ->
    Req = weberl_test_cookie_adapter:request(cookie_for(#{user_id => 7})),
    R1 = weberl_response:load_session(base(), Req),
    R2 = weberl_response:put_session(R1, a, 1),
    ?assertEqual(#{user_id => 7, a => 1}, weberl_response:session(R2)),
    %% loading again does not discard the changes
    ?assertEqual(#{user_id => 7, a => 1},
                 weberl_response:session(weberl_response:load_session(R2, Req))).

autoload_can_be_switched_off_test() ->
    Req = weberl_test_cookie_adapter:request(cookie_for(#{user_id => 7})),
    with_env(session_autoload, false, fun() ->
        weberl_session:run(Req, fun() ->
            ?assertEqual(none, weberl_session:ambient()),
            ?assertError({session_not_loaded, put_session}, weberl_response:put_session(base(), a, 1)),
            R = weberl_response:put_session(weberl_response:load_session(base(), Req), a, 1),
            ?assertEqual({ok, 7}, weberl_response:session_get(R, user_id))
        end)
    end).

ambient_request_is_restored_test() ->
    Outer = weberl_test_cookie_adapter:request(cookie_for(#{who => outer})),
    Inner = weberl_test_cookie_adapter:request(cookie_for(#{who => inner})),
    ?assertEqual(none, weberl_session:ambient()),
    weberl_session:run(Outer, fun() ->
        weberl_session:run(Inner, fun() ->
            ?assertEqual({ok, inner}, weberl_response:session_get(base(), who))
        end),
        ?assertEqual({ok, outer}, weberl_response:session_get(base(), who))
    end),
    ?assertEqual(none, weberl_session:ambient()),
    %% also when the handler crashes
    ?assertError(boom, weberl_session:run(Outer, fun() -> erlang:error(boom) end)),
    ?assertEqual(none, weberl_session:ambient()).

%% ---------------------------------------------------------------------
%% Writing the cookie (finalize)

finalize(Request, Response) ->
    {ok, R} = weberl_session:finalize(Request, Response),
    R.

an_untouched_session_sets_no_cookie_test() ->
    Req = weberl_test_cookie_adapter:request(cookie_for(#{a => 1})),
    ?assertEqual([], weberl_response:header_values(finalize(Req, base()), "set-cookie")).

a_change_sets_one_cookie_with_the_defaults_test() ->
    Req = weberl_test_cookie_adapter:request(cookie_for(#{a => 1})),
    R = with_request(cookie_for(#{a => 1}),
                     fun() -> weberl_response:put_session(base(), b, 2) end),
    {<<"weberl_session">>, Value, Attrs} = session_cookie(finalize(Req, R)),
    ?assertMatch({ok, #{a := 1, b := 2}, _}, weberl_session:decode(Value)),
    ?assert(lists:member(<<"Path=/">>, Attrs)),
    ?assert(lists:member(<<"HttpOnly">>, Attrs)),
    ?assert(lists:member(<<"SameSite=Lax">>, Attrs)),
    ?assertNot(lists:member(<<"Secure">>, Attrs)).

secure_cookies_test() ->
    with_env(secure_cookies, true, fun() ->
        R = weberl_response:set_session(base(), #{a => 1}),
        {Name, _, Attrs} = begin
                               [C] = weberl_response:header_values(
                                       finalize(weberl_test_cookie_adapter:request([]), R), "set-cookie"),
                               [P | A] = binary:split(C, <<"; ">>, [global]),
                               [N, V] = binary:split(P, <<"=">>),
                               {N, V, A}
                           end,
        ?assertEqual(<<"__Host-weberl_session">>, Name),
        ?assert(lists:member(<<"Secure">>, Attrs))
    end).

reset_deletes_the_cookie_test() ->
    R = weberl_response:reset_session(base()),
    [C] = weberl_response:header_values(finalize(weberl_test_cookie_adapter:request([]), R), "set-cookie"),
    ?assertMatch(<<"weberl_session=; Path=/; Max-Age=0;", _/binary>>, C).

max_age_of(Response, Request) ->
    {_, _, Attrs} = session_cookie(finalize(Request, Response)),
    [<<"Max-Age=", N/binary>>] = [A || <<"Max-Age=", _/binary>> = A <- Attrs],
    binary_to_integer(N).

expiry_of(Response, Request) ->
    {_, Value, _} = session_cookie(finalize(Request, Response)),
    {ok, _, Expires} = weberl_session:decode(Value),
    Expires.

new_sessions_live_two_days_by_default_test() ->
    Req = weberl_test_cookie_adapter:request([]),
    R = weberl_response:set_session(base(), #{a => 1}),
    ?assertEqual(2 * 86400, max_age_of(R, Req)),
    with_env(session_ttl, 3600, fun() -> ?assertEqual(3600, max_age_of(R, Req)) end).

a_changed_session_keeps_its_expiry_test() ->
    Expires = os:system_time(second) + 500,
    Cookies = cookie_for(#{a => 1}, Expires),
    Req = weberl_test_cookie_adapter:request(Cookies),
    R = with_request(Cookies, fun() -> weberl_response:put_session(base(), b, 2) end),
    ?assertEqual(Expires, expiry_of(R, Req)),
    ?assert(max_age_of(R, Req) =< 500),
    ?assert(max_age_of(R, Req) > 490).

a_new_session_gets_a_new_lifetime_test() ->
    Expires = os:system_time(second) + 500,
    Cookies = cookie_for(#{a => 1}, Expires),
    Req = weberl_test_cookie_adapter:request(Cookies),
    %% login = set_session / reset + put: a fresh lifetime, not the old one
    R1 = weberl_response:set_session(base(), #{user_id => 1}),
    R2 = weberl_response:put_session(weberl_response:reset_session(base()), user_id, 1),
    [?assert(max_age_of(R, Req) > 2 * 86400 - 5) || R <- [R1, R2]].

remember_me_test() ->
    Req = weberl_test_cookie_adapter:request([]),
    R = weberl_response:session_ttl(weberl_response:set_session(base(), #{a => 1}), 30 * 86400),
    ?assertEqual(30 * 86400, max_age_of(R, Req)),
    ?assertEqual(os:system_time(second) + 30 * 86400, expiry_of(R, Req)).

a_session_without_server_side_expiry_test() ->
    Req = weberl_test_cookie_adapter:request([]),
    R = weberl_response:session_ttl(weberl_response:set_session(base(), #{a => 1}), infinity),
    ?assertEqual(400 * 86400, max_age_of(R, Req)),
    ?assertEqual(infinity, expiry_of(R, Req)),
    %% and changing it later keeps it that way
    Cookies = cookie_for(#{a => 1}, infinity),
    Req2 = weberl_test_cookie_adapter:request(Cookies),
    R2 = with_request(Cookies, fun() -> weberl_response:put_session(base(), b, 1) end),
    ?assertEqual(infinity, expiry_of(R2, Req2)).

session_ttl_validates_test_() ->
    [?_assertError(badarg, weberl_response:session_ttl(weberl_response:set_session(base(), #{}), T))
     || T <- [0, -1, forever, 1.5]].

%% ---------------------------------------------------------------------
%% Size

size_limits_test() ->
    Req = weberl_test_cookie_adapter:request([]),
    Big = fun(N) -> weberl_response:set_session(base(), #{blob => crypto:strong_rand_bytes(N)}) end,
    %% random bytes do not compress: ~1.33 x for base64
    ?assertMatch({ok, _}, weberl_session:finalize(Req, Big(1000))),
    ?assertMatch({error, {session_too_large, _, 3800}}, weberl_session:finalize(Req, Big(3000))),
    with_env(session_max_bytes, 10000, fun() ->
        ?assertMatch({error, {session_too_large, _, 4096}}, weberl_session:finalize(Req, Big(4000))),
        ?assertMatch({ok, _}, weberl_session:finalize(Req, Big(2900)))
    end),
    with_env(session_max_bytes, 500, fun() ->
        ?assertMatch({error, {session_too_large, _, 500}}, weberl_session:finalize(Req, Big(1000)))
    end).

%% ---------------------------------------------------------------------
%% The whole flow over HTTP

flow_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             start_app()
     end,
     fun(Name) -> weberl:stop(Name) end,
     fun(Name) ->
             [{"log in, stay logged in, change, log out", fun() -> login_flow(Name) end},
              {"a tampered cookie is no session", fun() -> tampered(Name) end},
              {"a page that does not touch the session sets no cookie", fun() -> untouched(Name) end},
              {"remember me", fun() -> remember(Name) end},
              {"a session that is too large is a 500, not a lost login", fun() -> too_large(Name) end}]
     end}.

start_app() ->
    Login = handler("login", """
        handle(R) ->
            weberl_response:put_session(
              weberl_response:reset_session(weberl_response:text(200, <<"in">>)), user_id, 42).
        """),
    Remember = handler("remember", """
        handle(_) ->
            weberl_response:session_ttl(
              weberl_response:set_session(weberl_response:text(200, <<"ok">>), #{user_id => 42}),
              30 * 86400).
        """),
    Me = handler("me", """
        handle(R) ->
            Out = io_lib:format("~0p", [weberl_request:session(R)]),
            weberl_response:text(200, Out).
        """),
    Count = handler("count", """
        handle(R) ->
            N = maps:get(visits, weberl_request:session(R), 0) + 1,
            R1 = weberl_response:put_session(weberl_response:text(200, <<>>), visits, N),
            {ok, V} = weberl_response:session_get(R1, visits),
            weberl_response:with_body(R1, integer_to_binary(V)).
        """),
    Logout = handler("logout", """
        handle(_) -> weberl_response:reset_session(weberl_response:text(200, <<"out">>)).
        """),
    Plain = handler("plain", """
        handle(_) -> weberl_response:text(200, <<"plain">>).
        """),
    Huge = handler("huge", """
        handle(_) ->
            weberl_response:put_session(weberl_response:text(200, <<"x">>), blob,
                                        crypto:strong_rand_bytes(5000)).
        """),
    Name = weberl_test_handlers:unique("session_flow"),
    M = weberl_test_handlers:unique("session_flow_router"),
    load_router(M, [{"/login", Login}, {"/remember", Remember}, {"/me", Me}, {"/count", Count},
                    {"/logout", Logout}, {"/plain", Plain}, {"/huge", Huge}]),
    {ok, _} = weberl:start_link(Name, #router{modules = [M]},
                                #listener{port = 0, ip = {127, 0, 0, 1}}),
    Name.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

get(Name, Path, Cookie) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    Headers = [{"cookie", Cookie} || Cookie =/= none],
    {ok, {{_, Status, _}, H, B}} =
        quiet(fun() -> httpc:request(get, {Url, Headers}, [], [{body_format, binary}]) end),
    {Status, H, B}.

%% "weberl_session=VALUE" from a response's headers
cookie_of(Headers) ->
    [C] = proplists:get_all_values("set-cookie", Headers),
    [Pair | _] = string:split(C, ";"),
    Pair.

login_flow(Name) ->
    {200, H1, <<"in">>} = get(Name, "/login", none),
    Cookie = cookie_of(H1),
    ?assertEqual("weberl_session=", lists:sublist(Cookie, 15)),
    ?assertMatch({200, _, <<"#{user_id => 42}">>}, get(Name, "/me", Cookie)),
    %% a handler changes it and reads it back from the response in the same request
    {200, H2, <<"1">>} = get(Name, "/count", Cookie),
    Cookie2 = cookie_of(H2),
    ?assertMatch({200, _, B} when B =:= <<"#{user_id => 42,visits => 1}">>
                                  orelse B =:= <<"#{visits => 1,user_id => 42}">>,
                 get(Name, "/me", Cookie2)),
    {200, H3, <<"2">>} = get(Name, "/count", Cookie2),
    ?assertNotEqual(Cookie2, cookie_of(H3)),
    %% log out
    {200, H4, <<"out">>} = get(Name, "/logout", Cookie2),
    [Deleted] = proplists:get_all_values("set-cookie", H4),
    ?assertMatch({match, _}, re:run(Deleted, "^weberl_session=; Path=/; Max-Age=0")).

tampered(Name) ->
    {200, H, _} = get(Name, "/login", none),
    "weberl_session=" ++ Value = cookie_of(H),
    Bad = "weberl_session=" ++ [case hd(Value) of $A -> $B; _ -> $A end | tl(Value)],
    ?assertMatch({200, _, <<"#{}">>}, get(Name, "/me", Bad)),
    %% and a handler that writes to it starts from nothing
    {200, _, <<"1">>} = get(Name, "/count", Bad).

untouched(Name) ->
    {200, H, <<"plain">>} = get(Name, "/plain", none),
    ?assertEqual([], proplists:get_all_values("set-cookie", H)),
    {200, H2, _} = get(Name, "/login", none),
    {200, H3, <<"plain">>} = get(Name, "/plain", cookie_of(H2)),
    ?assertEqual([], proplists:get_all_values("set-cookie", H3)).

remember(Name) ->
    {200, H, <<"ok">>} = get(Name, "/remember", none),
    [C] = proplists:get_all_values("set-cookie", H),
    ?assertMatch({match, _}, re:run(C, "Max-Age=259200[0-9];|Max-Age=2592000;")).

too_large(Name) ->
    {Status, H, B} = get(Name, "/huge", none),
    ?assertEqual(500, Status),
    ?assertEqual(<<"Internal Server Error">>, B),
    ?assertEqual([], proplists:get_all_values("set-cookie", H)).
