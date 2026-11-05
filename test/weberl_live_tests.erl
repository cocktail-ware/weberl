%% Live sessions: lifecycle, buffering, replacement, expiry.
-module(weberl_live_tests).
-include_lib("eunit/include/eunit.hrl").

live_test_() ->
    {foreach,
     fun() ->
             {ok, _} = application:ensure_all_started(weberl),
             ok
     end,
     fun(_) ->
             application:unset_env(weberl, live_attach_timeout),
             application:unset_env(weberl, live_idle_timeout)
     end,
     [fun(_) -> {"open registers a session", fun open_registers/0} end,
      fun(_) -> {"ids are unique and url safe", fun ids/0} end,
      fun(_) -> {"events pushed before attach are buffered, then delivered", fun buffered/0} end,
      fun(_) -> {"events pushed while attached are delivered", fun delivered/0} end,
      fun(_) -> {"buffer keeps the newest 100", fun buffer_cap/0} end,
      fun(_) -> {"a new transport replaces the old one", fun replaced/0} end,
      fun(_) -> {"detach then reattach", fun detach_reattach/0} end,
      fun(_) -> {"a dead transport detaches the session", fun transport_dies/0} end,
      fun(_) -> {"never attached sessions expire", fun attach_timeout/0} end,
      fun(_) -> {"detached sessions expire", fun idle_timeout/0} end,
      fun(_) -> {"close notifies the transport and ends the session", fun close_session/0} end,
      fun(_) -> {"close_owner only closes that owner's sessions", fun close_owner/0} end,
      fun(_) -> {"unknown page ids", fun unknown/0} end]}.

%% ---------------------------------------------------------------------

owner() -> list_to_atom("owner_" ++ integer_to_list(erlang:unique_integer([positive]))).

open() -> open(owner()).
open(Owner) ->
    {ok, Id} = weberl_live:open(Owner, one_way),
    Id.

await_gone(Id) -> await_gone(Id, 40).
await_gone(Id, 0) -> ?assertEqual({error, not_found}, weberl_live:whereis(Id));
await_gone(Id, N) ->
    case weberl_live:whereis(Id) of
        {error, not_found} -> ok;
        {ok, _} -> timer:sleep(25), await_gone(Id, N - 1)
    end.

state(Id) ->
    {ok, #{state := S}} = weberl_live:info(Id),
    S.

msgs(Id) -> msgs(Id, []).
msgs(Id, Acc) ->
    receive {weberl_live, Id, M} -> msgs(Id, [M | Acc])
    after 100 -> lists:reverse(Acc)
    end.

%% A transport process that forwards what it receives to the test process.
forwarder() ->
    Me = self(),
    spawn(fun F() -> receive M -> Me ! {fwd, self(), M}, F() end end).

%% ---------------------------------------------------------------------

open_registers() ->
    Owner = owner(),
    {ok, Id} = weberl_live:open(Owner, two_way),
    ?assertMatch({ok, _}, weberl_live:whereis(Id)),
    ?assertMatch({ok, #{state := waiting, kind := two_way, owner := Owner,
                        transport := undefined, buffered := 0}},
                 weberl_live:info(Id)).

ids() ->
    Ids = [open() || _ <- lists:seq(1, 50)],
    ?assertEqual(50, length(lists:usort(Ids))),
    [?assertMatch({match, _}, re:run(Id, "^[A-Za-z0-9_-]{22}$")) || Id <- Ids].

buffered() ->
    Id = open(),
    ok = weberl_live:push(Id, <<"a">>, <<"1">>),
    ok = weberl_live:push(Id, <<"b">>, ["2", <<"x">>]),
    ?assertMatch({ok, #{buffered := 2}}, weberl_live:info(Id)),
    ok = weberl_live:attach(Id, self()),
    ?assertEqual([{event, <<"a">>, <<"1">>}, {event, <<"b">>, <<"2x">>}], msgs(Id)),
    ?assertMatch({ok, #{state := attached, buffered := 0}}, weberl_live:info(Id)).

delivered() ->
    Id = open(),
    ok = weberl_live:attach(Id, self()),
    ok = weberl_live:push(Id, <<"tick">>, <<"hi">>),
    ?assertEqual([{event, <<"tick">>, <<"hi">>}], msgs(Id)).

buffer_cap() ->
    Id = open(),
    [ok = weberl_live:push(Id, <<"n">>, integer_to_binary(N)) || N <- lists:seq(1, 150)],
    ok = weberl_live:attach(Id, self()),
    Got = [binary_to_integer(D) || {event, _, D} <- msgs(Id)],
    ?assertEqual(lists:seq(51, 150), Got).

replaced() ->
    Id = open(),
    First = forwarder(),
    ok = weberl_live:attach(Id, First),
    ok = weberl_live:attach(Id, self()),
    receive {fwd, First, {weberl_live, Id, replaced}} -> ok
    after 500 -> ?assert(false)
    end,
    ok = weberl_live:push(Id, <<"e">>, <<"d">>),
    ?assertEqual([{event, <<"e">>, <<"d">>}], msgs(Id)),
    %% The old transport's detach is ignored.
    weberl_live:detach(Id, First),
    ?assertEqual(attached, state(Id)).

detach_reattach() ->
    Id = open(),
    ok = weberl_live:attach(Id, self()),
    weberl_live:detach(Id, self()),
    ?assertEqual(detached, state(Id)),
    ok = weberl_live:push(Id, <<"while">>, <<"away">>),
    ok = weberl_live:attach(Id, self()),
    ?assertEqual([{event, <<"while">>, <<"away">>}], msgs(Id)),
    ?assertEqual(attached, state(Id)).

transport_dies() ->
    Id = open(),
    T = spawn(fun() -> receive stop -> ok end end),
    ok = weberl_live:attach(Id, T),
    ?assertEqual(attached, state(Id)),
    exit(T, kill),
    timer:sleep(50),
    ?assertEqual(detached, state(Id)).

attach_timeout() ->
    application:set_env(weberl, live_attach_timeout, 50),
    Id = open(),
    await_gone(Id).

idle_timeout() ->
    application:set_env(weberl, live_idle_timeout, 50),
    Id = open(),
    ok = weberl_live:attach(Id, self()),
    weberl_live:detach(Id, self()),
    await_gone(Id).

close_session() ->
    Id = open(),
    ok = weberl_live:attach(Id, self()),
    ok = weberl_live:close(Id),
    ?assertEqual([close], msgs(Id)),
    await_gone(Id).

close_owner() ->
    A = owner(),
    B = owner(),
    A1 = open(A),
    A2 = open(A),
    B1 = open(B),
    ok = weberl_live:close_owner(A),
    await_gone(A1),
    await_gone(A2),
    ?assertMatch({ok, _}, weberl_live:whereis(B1)).

unknown() ->
    Id = <<"nope">>,
    ?assertEqual({error, not_found}, weberl_live:push(Id, <<"a">>, <<"b">>)),
    ?assertEqual({error, not_found}, weberl_live:attach(Id, self())),
    ?assertEqual({error, not_found}, weberl_live:info(Id)),
    ?assertEqual(ok, weberl_live:detach(Id, self())),
    ?assertEqual(ok, weberl_live:close(Id)).
