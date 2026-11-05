%% @doc Multiplexed WebSocket endpoint (`GET /_weberl/ws').
%%
%% One socket serves any number of live pages (a hub shares a connection
%% between tabs): each page subscribes with its id and token, and every frame
%% names its page (format in `weberl_live_wire'). The connection process is the
%% attached transport of each subscribed page, so a page's session pushes
%% straight into this process; a session that ends, or is taken over by another
%% connection, only closes that page, not the socket.
%%
%% Upgrades without credentials (they are per page, at subscribe time) are
%% bounded: a socket that has not subscribed any page within
%% `live_subscribe_timeout' (application env of `weberl', default 10000 ms) is
%% closed. Token and channel (`ws') are verified on every subscribe; requests
%% are only accepted for pages subscribed on this socket.
%%
%% Implements the `roadrunner_ws_handler' callbacks without declaring the
%% behaviour, so Roadrunner stays optional at compile time.
-module(weberl_roadrunner_ws).

-export([handle/1, init/1, handle_frame/2, handle_info/2, handle_drain/2, terminate/2]).

-define(DEFAULT_SUBSCRIBE_TIMEOUT, 10000).

%% State: `pages' maps each subscribed page to the claims of its token,
%% `topics' is the connection's topic membership (`weberl_live_topics').
handle(Req) ->
    case weberl_roadrunner_live:connect(Req, [~"GET"]) of
        ok ->
            State = #{pages => #{}, topics => weberl_live_topics:new(), ever_subscribed => false},
            {{websocket, ?MODULE, State}, Req};
        {error, Response} ->
            {Response, Req}
    end.

init(State) ->
    ok = weberl_live:register_connection(ws),
    Timeout = application:get_env(weberl, live_subscribe_timeout, ?DEFAULT_SUBSCRIBE_TIMEOUT),
    erlang:send_after(Timeout, self(), weberl_ws_subscribe_deadline),
    {ok, State}.

handle_frame(#{opcode := text, payload := Payload}, State) ->
    case weberl_live_wire:decode_frame(iolist_to_binary(Payload)) of
        {ok, Frame} -> client_frame(Frame, State);
        {error, bad_request} -> {reply, [text(#{error => ~"bad_request"})], State}
    end;
handle_frame(_Binary, State) ->
    {close, 1003, ~"text frames only", State}.

handle_info({weberl_live, Id, {event, Name, Data}}, #{pages := Pages} = State) ->
    case maps:is_key(Id, Pages) of
        true -> {reply, [{text, weberl_live_wire:event(Id, Name, Data)}], State};
        false -> {ok, State}
    end;
handle_info({weberl_live, Id, Why}, #{pages := Pages} = State)
  when Why =:= close; Why =:= replaced ->
    case maps:is_key(Id, Pages) of
        true ->
            Reason = case Why of close -> ~"closed"; replaced -> ~"replaced" end,
            {reply, [page(Id, #{closed => Reason})], forget(Id, State)};
        false ->
            {ok, State}
    end;
%% A topic event: one frame, whatever number of pages here use the topic.
handle_info({weberl_live_topic, Topic, _Name, _Data, Frame}, #{topics := Topics} = State) ->
    case weberl_live_topics:member(Topic, Topics) of
        true -> {reply, [{text, Frame}], State};
        false -> {ok, State}
    end;
handle_info(weberl_ws_subscribe_deadline, #{ever_subscribed := false} = State) ->
    {close, 1008, ~"no page subscribed", State};
handle_info(_Other, State) ->
    {ok, State}.

%% The listener is draining: close so the client reconnects elsewhere.
handle_drain(_Deadline, State) ->
    {close, 1001, ~"going away", State}.

terminate(_Reason, #{pages := Pages}) ->
    %% topic membership ends with the process; sessions are told
    [weberl_live:detach(Id, self()) || {Id, #{session := true}} <- maps:to_list(Pages)],
    ok.

%% ---------------------------------------------------------------------

client_frame({subscribe, Id, Token}, State) ->
    case weberl_live_guard:claims(Id, ws, Token) of
        error -> {reply, [page(Id, #{error => ~"forbidden"})], State};
        {ok, Claims} -> subscribe(Id, Claims, State)
    end;
client_frame({unsubscribe, Id}, #{pages := Pages} = State) ->
    case Pages of
        #{Id := #{session := Session}} ->
            Session andalso weberl_live:release(Id, self()),
            %% released: whatever the session sent before is already in the
            %% mailbox and is dropped by handle_info (the page is not subscribed)
            {ok, forget(Id, State)};
        _ ->
            {ok, State}
    end;
client_frame({request, Id, Request}, #{pages := Pages} = State) ->
    case Pages of
        #{Id := Claims} ->
            {_Status, Answer} = weberl_live_wire:run_request(Id, Claims, Request),
            {reply, [page(Id, Answer)], State};
        _ ->
            Ref = maps:with([ref], Request),
            {reply, [page(Id, Ref#{error => ~"forbidden"})], State}
    end.

%% The token is good: attach the session (if the page has one), join the
%% topics once for this connection and give the page its snapshots. Subscribing
%% a page again (same socket) replaces its claims and sends fresh snapshots.
subscribe(Id, #{session := Session, topics := Topics} = Claims,
          #{pages := Pages, topics := Joined} = State) ->
    case Session andalso weberl_live:attach(Id, self()) of
        {error, not_found} ->
            {reply, [page(Id, #{error => ~"not_found"})], State};
        _Attached ->
            Left = case Pages of
                       #{Id := #{topics := Old}} -> weberl_live_topics:leave(Old, Joined);
                       _ -> Joined
                   end,
            State2 = State#{pages := Pages#{Id => Claims},
                            topics := weberl_live_topics:join(Topics, Left),
                            ever_subscribed := true},
            Snapshots = [{text, weberl_live_wire:event(Id, Name, Data)}
                         || {Name, Data} <- weberl_live_callbacks:snapshots(Id, Claims)],
            {reply, [page(Id, #{subscribed => true}) | Snapshots], State2}
    end.

%% The page is over for this connection: drop it and the topics it used.
forget(Id, #{pages := Pages, topics := Joined} = State) ->
    case Pages of
        #{Id := #{topics := Topics}} ->
            State#{pages := maps:remove(Id, Pages), topics := weberl_live_topics:leave(Topics, Joined)};
        _ ->
            State
    end.

page(Id, Fields) -> {text, weberl_live_wire:frame(Id, Fields)}.

text(Map) -> {text, json:encode(Map)}.
