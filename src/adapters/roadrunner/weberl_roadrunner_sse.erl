%% @doc Server-Sent Events endpoint of a live page (`GET /_weberl/sse/:id').
%%
%% Attaches the connection process to the page's live session (when the page
%% has one), joins the page's topics and then runs Roadrunner's `{loop, ...}'
%% response in that same process, so the session's messages (see `weberl_live')
%% and topic events (see `weberl_live:publish/3') arrive in `handle_info/3' and
%% are written as unnamed SSE messages whose data is JSON: `{"event": Name,
%% "data": Data}' for a page event, `{"topic", "event", "data"}' for a topic
%% event (see `weberl_live_wire'). The snapshots of the page's handler
%% (`handle_subscribe/2') are written first, before any event.
%% No `-behaviour(roadrunner_handler)': Roadrunner stays optional.
-module(weberl_roadrunner_sse).

-export([handle/1, handle_info/3]).

-define(KEEPALIVE_MS, 15000).
-define(RETRY_MS, 2000).

handle(Req) ->
    case weberl_roadrunner_live:authorize(Req, [~"GET"], sse) of
        {ok, Id, Claims} -> connect(Req, Id, Claims);
        {error, Response} -> {Response, Req}
    end.

connect(Req, Id, #{session := Session, topics := Topics} = Claims) ->
    case Session andalso weberl_live:attach(Id, self()) of
        {error, not_found} ->
            {weberl_roadrunner_live:text(404, ~"Not Found"), Req};
        _Attached ->
            ok = weberl_live:register_connection(sse),
            Joined = weberl_live_topics:join(Topics, weberl_live_topics:new()),
            %% written by the first handle_info, before any event
            Pending = weberl_live_callbacks:snapshots(Id, Claims),
            erlang:send_after(?KEEPALIVE_MS, self(), weberl_sse_keepalive),
            self() ! weberl_sse_start,
            Headers = [{~"content-type", ~"text/event-stream"},
                       {~"cache-control", ~"no-cache"},
                       {~"x-accel-buffering", ~"no"}],
            State = #{id => Id, session => Session, topics => Joined,
                      pending => Pending, first => true},
            {{loop, 200, Headers, State}, Req}
    end.

handle_info({weberl_live, Id, {event, Name, Data}}, Push, #{id := Id} = State) ->
    emit(Push, [message(weberl_live_wire:event(Name, Data))], State);
handle_info({weberl_live, Id, _CloseOrReplaced}, _Push, #{id := Id} = State) ->
    {stop, State};
handle_info({weberl_live_topic, Topic, _Name, _Data, Frame}, Push, #{topics := Topics} = State) ->
    case weberl_live_topics:member(Topic, Topics) of
        true -> emit(Push, [message(Frame)], State);
        false -> {ok, State}
    end;
handle_info(weberl_sse_start, Push, State) ->
    emit(Push, [], State);
handle_info(weberl_sse_keepalive, Push, State) ->
    erlang:send_after(?KEEPALIVE_MS, self(), weberl_sse_keepalive),
    emit(Push, [roadrunner_sse:comment(~"keepalive")], State);
handle_info({roadrunner_disconnect, _Reason}, _Push, State) ->
    detach(State),
    {stop, State};
handle_info({roadrunner_drain, _Deadline}, _Push, State) ->
    detach(State),
    {stop, State};
handle_info(_Other, _Push, State) ->
    {ok, State}.

detach(#{session := true, id := Id}) -> weberl_live:detach(Id, self());
detach(_State) -> ok.

message(Json) ->
    roadrunner_sse:event(iolist_to_binary(Json)).

%% Write the snapshots that are still pending, then the chunks.
emit(Push, Chunks, #{pending := Pending} = State) ->
    Snapshots = [message(weberl_live_wire:event(Name, Data)) || {Name, Data} <- Pending],
    case write(Push, Snapshots ++ Chunks, State#{pending := []}) of
        {ok, State2} -> {ok, State2};
        stop -> detach(State), {stop, State}
    end.

%% The first write also tells the browser how long to wait before reconnecting.
write(_Push, [], State) ->
    {ok, State};
write(Push, Chunks, #{first := true} = State) ->
    write(Push, [roadrunner_sse:retry(?RETRY_MS) | Chunks], State#{first := false});
write(Push, Chunks, State) ->
    case Push(Chunks) of
        ok -> {ok, State};
        {error, _} -> stop
    end.
