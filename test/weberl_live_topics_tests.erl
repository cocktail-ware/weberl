%% Topics: declaring them (weberl_topics/1), publish/3 fan-out, topic-only
%% (session-less) pages and snapshots (handle_subscribe/2) on every transport.
-module(weberl_live_topics_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util,
        [handler/1, with_router/2, new_page/2, request/5, has/2, jsonp/1,
         open_stream/3, read_until/3, ws_connect/2, ws_send/3, ws_recv/2]).

-export([remote_member/2]).

-define(ACME, <<"stock:ACME">>).
-define(NEWS, <<"news">>).

topics_test_() ->
    {setup,
     fun weberl_live_test_util:start_apps/0,
     fun(_) -> ok end,
     [{"topics are validated", fun check_topics/0},
      {"topics: handler callback, defaults, errors", fun resolver/0},
      {"route option session", fun route_option/0},
      {"publish reaches each member connection once", fun publish_fanout/0},
      {"membership is per connection and counted per page", fun membership/0},
      {timeout, 60, {"publish reaches connections on another node", fun cluster_publish/0}},
      {"the page carries its topics; a session-less page has no session", fun markup/0},
      {"ws: subscribe gives the snapshot, then topic events", fun ws_snapshot/0},
      {"ws: pages sharing a topic get one frame", fun ws_one_frame/0},
      {"ws: unsubscribing leaves the topic with the last page", fun ws_unsubscribe/0},
      {"ws: a reconnect gets a fresh snapshot", fun ws_reconnect/0},
      {"ws: requests of a session-less page run with the page context", fun ws_request/0},
      {"http: requests of a session-less page", fun http_request/0},
      {"ws: a crashing handle_subscribe still subscribes", fun ws_crashing_snapshot/0},
      {"ws: a page with a session and topics gets both", fun ws_session_and_topics/0},
      {"sse: snapshot first, then topic events", fun sse/0},
      {"sse: the topic membership ends with the stream", fun sse_leaves/0},
      {"poll: snapshot on request, topic events, membership ends", fun poll/0},
      {"publish_json: the frame carries a value, not a string", fun publish_json_frame/0},
      {"poll: publish_json data is a value", fun poll_json/0}]}.

%% ---------------------------------------------------------------------
%% Handlers and routes

handler_source(Extra) ->
    handler("-export([weberl_topics/1, handle_subscribe/2, handle_request/3]). "
            "handle(_) -> weberl_response:html(200, <<\"<html><body>t</body></html>\">>). "
            "weberl_topics(_) -> [<<\"stock:ACME\">>, <<\"news\">>]. "
            ++ Extra ++
            "handle_request(<<\"ctx\">>, _, Ctx) -> {reply, Ctx}; "
            "handle_request(_, _, _) -> ok.").

routes() ->
    H = handler_source("handle_subscribe(<<\"stock:ACME\">>, _) -> "
                       "  {snapshot, <<\"snap\">>, <<\"ACME-state\">>}; "
                       "handle_subscribe(_, _) -> ok. "),
    Boom = handler_source("handle_subscribe(_, _) -> error(boom). "),
    [{"/topic", H, #{live => two_way, session => false}},
     {"/mixed", H, #{live => two_way}},
     {"/sse", H, #{live => one_way, session => false}},
     {"/boom", Boom, #{live => two_way, session => false}}].

%% ---------------------------------------------------------------------
%% Unit

check_topics() ->
    ?assertEqual(ok, weberl_live:check_topics([])),
    ?assertEqual(ok, weberl_live:check_topics([?ACME, <<"caf\xc3\xa9">>])),
    ?assertEqual(ok, weberl_live:check_topics([binary:copy(<<"a">>, 256)])),
    ?assertEqual(ok, weberl_live:check_topics([integer_to_binary(N) || N <- lists:seq(1, 32)])),
    [?assertMatch({error, _}, weberl_live:check_topics(Bad))
     || Bad <- [[<<>>], [a_topic], ["list"], [binary:copy(<<"a">>, 257)], [<<255, 255>>],
                [integer_to_binary(N) || N <- lists:seq(1, 33)], not_a_list]].

request(Path) -> weberl_request:new(#{method => <<"GET">>, path => Path}).

route(Handler, Path, Opts) -> weberl_route:new(Path, Handler, declarative, router, Opts).

resolver() ->
    Plain = handler("handle(_) -> weberl_response:text(200, <<\"x\">>)."),
    With = handler("-export([weberl_topics/1]). handle(_) -> weberl_response:text(200, <<\"x\">>). "
                   "weberl_topics(Req) -> [<<\"a\">>, list_to_binary(weberl_request:path(Req)), <<\"a\">>]."),
    Bad = handler("-export([weberl_topics/1]). handle(_) -> weberl_response:text(200, <<\"x\">>). "
                  "weberl_topics(_) -> [not_binary]."),
    Crash = handler("-export([weberl_topics/1]). handle(_) -> weberl_response:text(200, <<\"x\">>). "
                    "weberl_topics(_) -> error(boom)."),
    Req = request("/p"),
    %% defaults: none with a session, the route path without one
    ?assertEqual({ok, []}, weberl_live:topics(route(Plain, "/p", #{live => one_way}), Req)),
    ?assertEqual({ok, [<<"/p">>]},
                 weberl_live:topics(route(Plain, "/p", #{live => one_way, session => false}), Req)),
    %% the callback decides, per request, and duplicates are dropped
    ?assertEqual({ok, [<<"a">>, <<"/p">>]},
                 weberl_live:topics(route(With, "/p", #{live => two_way}), Req)),
    ?assertMatch({error, {invalid_topic, not_binary}},
                 weberl_live:topics(route(Bad, "/p", #{live => two_way}), Req)),
    ?assertMatch({error, {weberl_topics_failed, error, boom}},
                 weberl_live:topics(route(Crash, "/p", #{live => two_way}), Req)).

route_option() ->
    ?assertEqual({ok, #{live => one_way, session => false}},
                 weberl_route:check_opts(#{live => one_way, session => false})),
    ?assertEqual({ok, #{live => one_way, session => true}},
                 weberl_route:check_opts(#{live => one_way, session => true})),
    ?assertMatch({error, {invalid_session, perhaps}},
                 weberl_route:check_opts(#{live => one_way, session => perhaps})),
    ?assertMatch({error, session_option_needs_a_live_page},
                 weberl_route:check_opts(#{session => false})),
    ?assert(weberl_route:session(route(x, "/p", #{live => one_way}))),
    ?assertNot(weberl_route:session(route(x, "/p", #{live => one_way, session => false}))).

%% A process standing in for a connection: joins the topics of "pages" and
%% forwards what it receives to the test.
connection(Test) ->
    spawn(fun() -> connection_loop(Test, weberl_live_topics:new()) end).

%% Run Fun with N such connections, killed afterwards (they would stay in the
%% topic groups and disturb the other tests).
with_connections(N, Fun) ->
    Conns = [connection(self()) || _ <- lists:seq(1, N)],
    try apply(Fun, Conns) after [exit(C, kill) || C <- Conns] end.

connection_loop(Test, Topics) ->
    receive
        {join, Ts} -> connection_loop(Test, weberl_live_topics:join(Ts, Topics));
        {leave, Ts} -> connection_loop(Test, weberl_live_topics:leave(Ts, Topics));
        {sync, Ref} -> Test ! {synced, Ref}, connection_loop(Test, Topics);
        {weberl_live_topic, _, _, _, _} = Msg -> Test ! {got, self(), Msg}, connection_loop(Test, Topics)
    end.

sync(Conn) ->
    Ref = make_ref(),
    Conn ! {sync, Ref},
    receive {synced, Ref} -> ok after 1000 -> error(sync_timeout) end.

received(Conn) ->
    receive {got, Conn, Msg} -> {ok, Msg} after 100 -> none end.

publish_fanout() ->
    with_connections(3, fun(A, B, Idle) ->
        A ! {join, [?ACME]}, B ! {join, [?ACME, ?NEWS]}, Idle ! {join, [?NEWS]},
        [sync(C) || C <- [A, B, Idle]],
        ok = weberl_live:publish(?ACME, <<"price">>, [<<"1">>, <<"23">>]),
        {ok, {weberl_live_topic, ?ACME, <<"price">>, <<"123">>, Frame}} = received(A),
        ?assertEqual(#{~"topic" => ?ACME, ~"event" => ~"price", ~"data" => ~"123"},
                     json:decode(Frame)),
        %% the very same binary goes to every member
        ?assertMatch({ok, {weberl_live_topic, ?ACME, <<"price">>, <<"123">>, Frame}}, received(B)),
        ?assertEqual(none, received(Idle)),
        %% nobody listens: fine
        ?assertEqual(ok, weberl_live:publish(<<"nobody">>, <<"x">>, <<"y">>))
    end).

publish_json_frame() ->
    with_connections(2, fun(A, Idle) ->
        A ! {join, [?ACME]}, Idle ! {join, [?NEWS]},
        [sync(C) || C <- [A, Idle]],
        Term = #{running => 2, names => [<<"a">>, <<"b\"">>], ok => true, none => null},
        ok = weberl_live:publish_json(?ACME, <<"tasks">>, Term),
        {ok, {weberl_live_topic, ?ACME, <<"tasks">>, {json, _}, Frame}} = received(A),
        ?assertEqual(#{~"topic" => ?ACME, ~"event" => ~"tasks",
                       ~"data" => #{~"running" => 2, ~"names" => [~"a", ~"b\""], ~"ok" => true,
                                    ~"none" => null}},
                     json:decode(Frame)),
        ?assertEqual(none, received(Idle)),
        %% a string stays a string, and a term JSON cannot hold sends nothing
        ok = weberl_live:publish_json(?ACME, <<"s">>, <<"x">>),
        {ok, {_, _, _, _, F2}} = received(A),
        ?assertEqual(~"x", maps:get(~"data", json:decode(F2))),
        ?assertError({unsupported_type, _}, weberl_live:publish_json(?ACME, <<"bad">>, self())),
        ?assertEqual(none, received(A))
    end).

membership() ->
    with_connections(1, fun(C) ->
        %% two pages on one connection use the topic: one membership, one message
        C ! {join, [?ACME]}, C ! {join, [?ACME]}, sync(C),
        ?assertEqual([C], pg:get_local_members(weberl_live, {topic, ?ACME})),
        ok = weberl_live:publish(?ACME, <<"e">>, <<"1">>),
        ?assertMatch({ok, _}, received(C)),
        ?assertEqual(none, received(C)),
        %% one page leaves: still a member; the last leaves: gone
        C ! {leave, [?ACME]}, sync(C),
        ?assertEqual([C], pg:get_local_members(weberl_live, {topic, ?ACME})),
        C ! {leave, [?ACME]}, sync(C),
        ?assertEqual([], pg:get_local_members(weberl_live, {topic, ?ACME})),
        ok = weberl_live:publish(?ACME, <<"e">>, <<"2">>),
        ?assertEqual(none, received(C))
    end).

poll_json() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/sse"),
        Path = "/_weberl/poll/" ++ binary_to_list(Id),
        Headers = [{"x-weberl-token", binary_to_list(Token)}],
        Self = self(),
        spawn_link(fun() -> Self ! {polled, request(Name, get, Path, Headers, undefined)} end),
        await_members(?ACME, 1),
        ok = weberl_live:publish_json(?ACME, <<"tasks">>, #{running => 3}),
        {200, _, Body} = receive {polled, R} -> R after 3000 -> error(poll_timeout) end,
        ?assertEqual(#{~"events" => [#{~"topic" => ?ACME, ~"event" => ~"tasks",
                                       ~"data" => #{~"running" => 3}}],
                       ~"closed" => false}, json:decode(Body)),
        await_members(?ACME, 0)
    end).

%% A second Erlang node (a `peer') runs the weberl application and a stand-in
%% connection; publishing here reaches it because `pg' shares the group.
cluster_publish() ->
    %% distribution needs the port mapper daemon; this is a no-op if it runs
    _ = os:cmd("epmd -daemon"),
    case net_kernel:start([weberl_topics_test, shortnames]) of
        Started when element(1, Started) =:= ok; Started =:= {error, {already_started, self()}} ->
            cluster_publish_();
        {error, Reason} ->
            %% no distribution in this environment: nothing to test here
            ?debugFmt("cluster test skipped, cannot start distribution: ~p", [Reason])
    end.

cluster_publish_() ->
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(),
                                         args => ["-pa" | code:get_path()]}),
    try
        {ok, _} = erpc:call(Node, application, ensure_all_started, [weberl]),
        Remote = erpc:call(Node, erlang, spawn, [?MODULE, remote_member, [self(), ?ACME]]),
        ?assertEqual(Node, node(Remote)),
        await_cluster_member(Remote, 40),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"42">>),
        receive
            {remote_got, {weberl_live_topic, ?ACME, <<"price">>, <<"42">>, _Frame}} -> ok
        after 3000 -> error(remote_member_got_nothing)
        end
    after
        peer:stop(Peer)
    end.

await_cluster_member(_Remote, 0) -> error(remote_member_not_visible);
await_cluster_member(Remote, N) ->
    case lists:member(Remote, pg:get_members(weberl_live, {topic, ?ACME})) of
        true -> ok;
        false -> timer:sleep(50), await_cluster_member(Remote, N - 1)
    end.

%% Runs on the peer node (exported for that): a connection stand-in.
remote_member(Test, Topic) ->
    _ = weberl_live_topics:join([Topic], weberl_live_topics:new()),
    remote_loop(Test).

remote_loop(Test) ->
    receive Msg -> Test ! {remote_got, Msg}, remote_loop(Test) end.

%% ---------------------------------------------------------------------
%% Over HTTP

markup() ->
    with_router(routes(), fun(Name) ->
        {200, _, Page} = weberl_live_test_util:get(Name, "/topic"),
        {match, [Attr]} = re:run(Page, "data-weberl-topics=\"([^\"]*)\"",
                                 [{capture, all_but_first, binary}]),
        Json = binary:replace(Attr, <<"&quot;">>, <<"\"">>, [global]),
        ?assertEqual([?ACME, ?NEWS], json:decode(Json)),
        {Id, Token} = new_page(Name, "/topic"),
        %% the token vouches for the claims; there is no session behind the page
        ?assertEqual({error, not_found}, weberl_live:whereis(Id)),
        ?assertMatch({ok, #{session := false, kind := two_way, topics := [?ACME, ?NEWS]}},
                     weberl_live_guard:claims(Id, ws, Token)),
        {MixedId, _} = new_page(Name, "/mixed"),
        ?assertMatch({ok, _}, weberl_live:whereis(MixedId))
    end).

json_frame(Sock, Buf) ->
    {{text, Payload}, Rest} = ws_recv(Sock, Buf),
    {json:decode(Payload), Rest}.

send(Sock, Map) -> ok = ws_send(Sock, text, jsonp(Map)).

%% Subscribe a page; returns {Frames, Buf} where Frames are the frames the
%% server answered with (the subscribed marker and then the snapshots),
%% `Snapshots' of them being expected after the marker.
subscribe(Sock, Buf, {Id, Token}, Snapshots) ->
    send(Sock, #{op => subscribe, page => Id, token => Token}),
    {Answer, Buf1} = json_frame(Sock, Buf),
    ?assertEqual(#{~"page" => Id, ~"subscribed" => true}, Answer),
    lists:mapfoldl(fun(_, B) -> json_frame(Sock, B) end, Buf1, lists:seq(1, Snapshots)).

snapshot(Id) ->
    #{~"page" => Id, ~"event" => ~"snap", ~"data" => ~"ACME-state"}.

topic_frame(Topic, Name, Data) ->
    #{~"topic" => Topic, ~"event" => Name, ~"data" => Data}.

%% The members of a topic group, once the expected number is reached.
await_members(Topic, N) -> await_members(Topic, N, 40).
await_members(Topic, N, 0) -> ?assertEqual(N, length(pg:get_local_members(weberl_live, {topic, Topic})));
await_members(Topic, N, Tries) ->
    case length(pg:get_local_members(weberl_live, {topic, Topic})) of
        N -> ok;
        _ -> timer:sleep(25), await_members(Topic, N, Tries - 1)
    end.

ws_snapshot() ->
    with_router(routes(), fun(Name) ->
        {ok, Sock, Buf} = ws_connect(Name, []),
        {Id, _} = Page = new_page(Name, "/topic"),
        {[Snap], Buf1} = subscribe(Sock, Buf, Page, 1),
        ?assertEqual(snapshot(Id), Snap),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"101">>),
        ok = weberl_live:publish(?NEWS, <<"headline">>, <<"hi">>),
        {F1, Buf2} = json_frame(Sock, Buf1),
        {F2, _} = json_frame(Sock, Buf2),
        ?assertEqual(topic_frame(?ACME, ~"price", ~"101"), F1),
        ?assertEqual(topic_frame(?NEWS, ~"headline", ~"hi"), F2),
        gen_tcp:close(Sock),
        %% the connection ending ends its memberships
        await_members(?ACME, 0)
    end).

ws_one_frame() ->
    with_router(routes(), fun(Name) ->
        {ok, Sock, Buf} = ws_connect(Name, []),
        {Id1, _} = P1 = new_page(Name, "/topic"),
        {Id2, _} = P2 = new_page(Name, "/topic"),
        {[S1], B1} = subscribe(Sock, Buf, P1, 1),
        {[S2], B2} = subscribe(Sock, B1, P2, 1),
        ?assertEqual([snapshot(Id1), snapshot(Id2)], [S1, S2]),
        await_members(?ACME, 1),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"1">>),
        ok = weberl_live:publish(?NEWS, <<"headline">>, <<"after">>),
        %% one frame for the first topic, then straight on to the next
        {F1, B3} = json_frame(Sock, B2),
        {F2, _} = json_frame(Sock, B3),
        ?assertEqual(topic_frame(?ACME, ~"price", ~"1"), F1),
        ?assertEqual(topic_frame(?NEWS, ~"headline", ~"after"), F2),
        gen_tcp:close(Sock)
    end).

ws_unsubscribe() ->
    with_router(routes(), fun(Name) ->
        {ok, Sock, Buf} = ws_connect(Name, []),
        {Id1, _} = P1 = new_page(Name, "/topic"),
        {Id2, _} = P2 = new_page(Name, "/topic"),
        {_, B1} = subscribe(Sock, Buf, P1, 1),
        {_, B2} = subscribe(Sock, B1, P2, 1),
        send(Sock, #{op => unsubscribe, page => Id1}),
        timer:sleep(50),
        %% the other page still uses the topic
        await_members(?ACME, 1),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"1">>),
        {F, B3} = json_frame(Sock, B2),
        ?assertEqual(topic_frame(?ACME, ~"price", ~"1"), F),
        send(Sock, #{op => unsubscribe, page => Id2}),
        await_members(?ACME, 0),
        await_members(?NEWS, 0),
        %% the socket itself stays open for new pages
        {_, _} = subscribe(Sock, B3, P1, 1),
        await_members(?ACME, 1),
        gen_tcp:close(Sock)
    end).

ws_reconnect() ->
    with_router(routes(), fun(Name) ->
        {Id, _} = Page = new_page(Name, "/topic"),
        {ok, Sock1, Buf1} = ws_connect(Name, []),
        {[Snap1], _} = subscribe(Sock1, Buf1, Page, 1),
        gen_tcp:close(Sock1),
        await_members(?ACME, 0),
        %% the same page on a new connection: subscribed again, snapshot again
        {ok, Sock2, Buf2} = ws_connect(Name, []),
        {[Snap2], _} = subscribe(Sock2, Buf2, Page, 1),
        ?assertEqual([snapshot(Id), snapshot(Id)], [Snap1, Snap2]),
        gen_tcp:close(Sock2)
    end).

ws_request() ->
    with_router(routes(), fun(Name) ->
        {ok, Sock, Buf} = ws_connect(Name, []),
        {Id, _} = Page = new_page(Name, "/topic"),
        {_, Buf1} = subscribe(Sock, Buf, Page, 1),
        send(Sock, #{op => request, page => Id, request => ctx, ref => ~"c"}),
        {Answer, _} = json_frame(Sock, Buf1),
        ?assertEqual(#{~"page" => Id, ~"ref" => ~"c",
                       ~"reply" => #{~"page" => Id, ~"kind" => ~"two_way",
                                     ~"topics" => [?ACME, ?NEWS]}}, Answer),
        gen_tcp:close(Sock)
    end).

http_request() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/sse"),
        Path = "/_weberl/request/" ++ binary_to_list(Id),
        Headers = [{"x-weberl-token", binary_to_list(Token)}],
        {200, _, Body} = request(Name, post, Path, Headers,
                                 {"application/json", jsonp(#{request => ctx, ref => 1})}),
        ?assertEqual(#{~"ref" => 1,
                       ~"reply" => #{~"page" => Id, ~"kind" => ~"one_way",
                                     ~"topics" => [?ACME, ?NEWS]}}, json:decode(Body)),
        {200, _, Body2} = request(Name, post, Path, Headers,
                                  {"application/json", jsonp(#{request => other})}),
        ?assertEqual(#{~"ok" => true}, json:decode(Body2))
    end).

ws_crashing_snapshot() ->
    weberl_live_test_util:quiet(fun() ->
        with_router(routes(), fun(Name) ->
            {ok, Sock, Buf} = ws_connect(Name, []),
            Page = new_page(Name, "/boom"),
            {[], Buf1} = subscribe(Sock, Buf, Page, 0),
            ok = weberl_live:publish(?ACME, <<"price">>, <<"7">>),
            {F, _} = json_frame(Sock, Buf1),
            ?assertEqual(topic_frame(?ACME, ~"price", ~"7"), F),
            gen_tcp:close(Sock)
        end)
    end).

ws_session_and_topics() ->
    with_router(routes(), fun(Name) ->
        {ok, Sock, Buf} = ws_connect(Name, []),
        {Id, _} = Page = new_page(Name, "/mixed"),
        {[Snap], Buf1} = subscribe(Sock, Buf, Page, 1),
        ?assertEqual(snapshot(Id), Snap),
        ok = weberl_live:push(Id, <<"mine">>, <<"private">>),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"5">>),
        {F1, Buf2} = json_frame(Sock, Buf1),
        {F2, _} = json_frame(Sock, Buf2),
        ?assertEqual([#{~"page" => Id, ~"event" => ~"mine", ~"data" => ~"private"},
                      topic_frame(?ACME, ~"price", ~"5")],
                     lists:sort(fun(A, _) -> maps:is_key(~"page", A) end, [F1, F2])),
        gen_tcp:close(Sock)
    end).

sse() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/sse"),
        {Sock, Head, Rest} = open_stream(Name, Id, Token),
        ?assert(has(Head, <<"HTTP/1.1 200">>)),
        {ok, Data} = read_until(Sock, Rest, <<"ACME-state">>),
        ?assert(has(Data, <<"data: {\"data\":\"ACME-state\",\"event\":\"snap\"}\n\n">>)),
        await_members(?ACME, 1),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"9">>),
        {ok, Data2} = read_until(Sock, <<>>, <<"\"price\"">>),
        ?assert(has(Data2, <<"\"topic\":\"stock:ACME\"">>)),
        ?assert(has(Data2, <<"\"data\":\"9\"">>)),
        gen_tcp:close(Sock)
    end).

sse_leaves() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/sse"),
        {Sock, _, _} = open_stream(Name, Id, Token),
        await_members(?ACME, 1),
        gen_tcp:close(Sock),
        await_members(?ACME, 0)
    end).

poll() ->
    with_router(routes(), fun(Name) ->
        {Id, Token} = new_page(Name, "/sse"),
        Path = "/_weberl/poll/" ++ binary_to_list(Id),
        Headers = [{"x-weberl-token", binary_to_list(Token)}],
        %% asking for the snapshot returns at once with it
        {200, _, Body} = request(Name, get, Path ++ "?snapshot=1", Headers, undefined),
        ?assertEqual(#{~"events" => [#{~"event" => ~"snap", ~"data" => ~"ACME-state"}],
                       ~"closed" => false}, json:decode(Body)),
        %% the poll left the topics
        ?assertEqual([], pg:get_local_members(weberl_live, {topic, ?ACME})),
        %% a plain poll waits for a topic event
        Self = self(),
        spawn_link(fun() -> Self ! {polled, request(Name, get, Path, Headers, undefined)} end),
        await_members(?ACME, 1),
        ok = weberl_live:publish(?ACME, <<"price">>, <<"3">>),
        {200, _, Body2} = receive {polled, R} -> R after 3000 -> error(poll_timeout) end,
        ?assertEqual(#{~"events" => [#{~"topic" => ?ACME, ~"event" => ~"price", ~"data" => ~"3"}],
                       ~"closed" => false}, json:decode(Body2)),
        await_members(?ACME, 0)
    end).

%% The prefix weberl_ belongs to the browser scripts (weberl_connected, weberl_closed...).
reserved_event_names_test() ->
    ?assertError({reserved_event_name, <<"weberl_closed">>}, weberl_live:publish(<<"t">>, <<"weberl_closed">>, <<"x">>)),
    ?assertError({reserved_event_name, <<"weberl_x">>}, weberl_live:publish_json(<<"t">>, <<"weberl_x">>, #{})),
    ?assertError({reserved_event_name, <<"weberl_x">>}, weberl_live:push(<<"p">>, <<"weberl_x">>, <<"x">>)),
    %% the region event has a colon, not an underscore, and other names are free
    ?assertEqual(ok, weberl_live:publish(<<"t">>, <<"weberl:region">>, <<"{}">>)),
    ?assertEqual(ok, weberl_live:publish(<<"t">>, <<"connected">>, <<"x">>)).
