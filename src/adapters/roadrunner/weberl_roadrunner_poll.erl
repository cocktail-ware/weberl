%% @doc Long-poll endpoint of a live page (`GET /_weberl/poll/:id').
%%
%% The fallback transport for browsers or networks where the stream or the
%% WebSocket does not work. Each request attaches the connection process to the
%% session (when the page has one) and joins the page's topics, waits up to
%% `live_poll_timeout' (application env of `weberl', default 25000 ms) for an
%% event, then returns everything that arrived as `{"events": [...], "closed":
%% Bool}' and detaches. An entry of `events' is `{"event": Name, "data": Data}'
%% for a page event or `{"topic": Topic, "event": Name, "data": Data}' for a
%% topic event. Between polls a session buffers (see `weberl_live'), so a page
%% with a session loses nothing as long as it polls again within
%% `live_idle_timeout'; topic events published between two polls are lost, as
%% for any client that is not connected. A second poll replaces a poll still in
%% progress (which returns no events). `closed' tells the client the session
%% ended: stop polling.
%%
%% With the query parameter `snapshot=1' the answer starts with the snapshots
%% of the page's handler (`handle_subscribe/2') and returns at once: the client
%% sends it on its first poll and on the first one after a gap, not on every
%% poll.
%%
%% Refused (404) for kinds that have the fallback turned off, see
%% `weberl_live:poll_enabled/1'.
-module(weberl_roadrunner_poll).

-export([handle/1]).

-define(DEFAULT_TIMEOUT, 25000).
%% After the first event, wait this long for more so a burst is one response.
-define(LINGER_MS, 20).

handle(Req) ->
    case weberl_roadrunner_live:authorize(Req, [~"GET"], poll) of
        {ok, Id, #{kind := Kind} = Claims} ->
            case weberl_live:poll_enabled(Kind) of
                true -> poll(Req, Id, Claims);
                false -> {weberl_roadrunner_live:text(404, ~"Not Found"), Req}
            end;
        {error, Response} ->
            {Response, Req}
    end.

poll(Req, Id, #{session := Session, topics := TopicList} = Claims) ->
    case Session andalso weberl_live:attach(Id, self()) of
        {error, not_found} ->
            {weberl_roadrunner_live:text(404, ~"Not Found"), Req};
        _Attached ->
            Topics = weberl_live_topics:join(TopicList, weberl_live_topics:new()),
            Snapshots = snapshots(Req, Id, Claims),
            Timeout = case Snapshots of
                          [] -> application:get_env(weberl, live_poll_timeout, ?DEFAULT_TIMEOUT);
                          _ -> 0
                      end,
            {Events, Closed} = collect(Id, Topics, Timeout),
            Session andalso weberl_live:release(Id, self()),
            %% Releasing is synchronous: whatever the session sent before it is
            %% already in the mailbox.
            {More, Closed2} = drain(Id, Topics),
            %% The process serves the next request of this connection: leave the
            %% topics and drop what was published to them meanwhile.
            _ = weberl_live_topics:leave(TopicList, Topics),
            flush_topic_events(),
            Body = #{events => [event(E) || E <- Snapshots ++ Events ++ More],
                     closed => Closed orelse Closed2},
            {weberl_roadrunner_live:json(200, Body), Req}
    end.

snapshots(Req, Id, Claims) ->
    case lists:keyfind(~"snapshot", 1, roadrunner_req:parse_qs(Req)) of
        {_, ~"1"} -> [{page, Name, Data} || {Name, Data} <- weberl_live_callbacks:snapshots(Id, Claims)];
        _ -> []
    end.

%% Block for the first message, then take what follows within the linger.
collect(Id, Topics, Timeout) ->
    case next(Id, Topics, Timeout) of
        {event, E} -> linger(Id, Topics, [E]);
        closed -> {[], true};
        _ -> {[], false}
    end.

linger(Id, Topics, Acc) ->
    case next(Id, Topics, ?LINGER_MS) of
        {event, E} -> linger(Id, Topics, [E | Acc]);
        closed -> {lists:reverse(Acc), true};
        _ -> {lists:reverse(Acc), false}
    end.

drain(Id, Topics) ->
    case next(Id, Topics, 0) of
        {event, E} -> {More, Closed} = drain(Id, Topics), {[E | More], Closed};
        closed -> {More, _} = drain(Id, Topics), {More, true};
        replaced -> drain(Id, Topics);
        timeout -> {[], false}
    end.

%% The next message that matters to this poll. Topic events of topics the page
%% no longer uses (a stale message from an earlier poll) are skipped.
next(Id, Topics, Timeout) ->
    receive
        {weberl_live, Id, {event, Name, Data}} -> {event, {page, Name, Data}};
        {weberl_live, Id, close} -> closed;
        {weberl_live, Id, replaced} -> replaced;
        {weberl_live_topic, Topic, Name, Data, _Frame} ->
            case weberl_live_topics:member(Topic, Topics) of
                true -> {event, {topic, Topic, Name, Data}};
                false -> next(Id, Topics, Timeout)
            end
    after Timeout ->
        timeout
    end.

flush_topic_events() ->
    receive
        {weberl_live_topic, _, _, _, _} -> flush_topic_events()
    after 0 ->
        ok
    end.

event({page, Name, Data}) -> #{event => Name, data => Data};
event({topic, Topic, Name, {json, Json}}) -> #{topic => Topic, event => Name, data => json:decode(Json)};
event({topic, Topic, Name, Data}) -> #{topic => Topic, event => Name, data => Data}.
