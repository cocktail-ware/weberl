%% @doc Topic membership of one connection process.
%%
%% A connection (WebSocket handler, SSE loop or long-poll request) is a member
%% of the `pg' group `{topic, Topic}' of the `weberl_live' scope for every topic
%% that at least one of its pages subscribed to, so `weberl_live:publish/3'
%% reaches it with one message however many pages share the topic. The state is
%% a map `Topic => number of pages using it'; a connection joins a group on the
%% first page and leaves it with the last. Membership ends by itself when the
%% process dies.
-module(weberl_live_topics).

-export([new/0, join/2, leave/2, member/2]).
-export_type([t/0]).

-define(SCOPE, weberl_live).

-opaque t() :: #{weberl_live:topic() => pos_integer()}.

-spec new() -> t().
new() -> #{}.

%% @doc One more page of this connection subscribes to `Topics'.
-spec join([weberl_live:topic()], t()) -> t().
join(Topics, State) ->
    lists:foldl(fun join_one/2, State, Topics).

%% @doc A page of this connection no longer needs `Topics'.
-spec leave([weberl_live:topic()], t()) -> t().
leave(Topics, State) ->
    lists:foldl(fun leave_one/2, State, Topics).

%% @doc Does a page of this connection use `Topic'?
-spec member(weberl_live:topic(), t()) -> boolean().
member(Topic, State) ->
    maps:is_key(Topic, State).

join_one(Topic, State) ->
    case State of
        #{Topic := N} ->
            State#{Topic := N + 1};
        _ ->
            ok = pg:join(?SCOPE, {topic, Topic}, self()),
            State#{Topic => 1}
    end.

leave_one(Topic, State) ->
    case State of
        #{Topic := 1} ->
            _ = pg:leave(?SCOPE, {topic, Topic}, self()),
            maps:remove(Topic, State);
        #{Topic := N} ->
            State#{Topic := N - 1};
        _ ->
            State
    end.
