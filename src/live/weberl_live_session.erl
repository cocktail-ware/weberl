%% @doc One live page session, see `weberl_live'.
%%
%% States: `waiting' (never attached, ends after `live_attach_timeout'),
%% `attached' (a transport process is connected) and `detached' (the
%% transport went away; ends after `live_idle_timeout' unless one attaches).
-module(weberl_live_session).
-behaviour(gen_statem).

-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

-define(SCOPE, weberl_live).
-define(MAX_BUFFER, 100).
-define(DEFAULT_ATTACH_TIMEOUT, 30000).
-define(DEFAULT_IDLE_TIMEOUT, 60000).

-include_lib("kernel/include/logger.hrl").

-record(data, {id :: binary(), owner :: term(), kind :: one_way | two_way,
               handler :: undefined | module(),
               %% what the page's handler mounted (see weberl_view_data), if it did
               view :: undefined | weberl_view_data:t(),
               topics = [] :: [weberl_live:topic()],
               transport :: undefined | pid(),
               monitor :: undefined | reference(),
               buffer = queue:new() :: queue:queue({binary(), binary()}),
               buffered = 0 :: non_neg_integer()}).

start_link(#{id := _, owner := _, kind := _} = Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> handle_event_function.

init(#{id := Id, owner := Owner, kind := Kind} = Args) ->
    ok = pg:join(?SCOPE, {page, Id}, self()),
    ok = pg:join(?SCOPE, {owner, Owner}, self()),
    Handler = maps:get(handler, Args, undefined),
    {ok, waiting, #data{id = Id, owner = Owner, kind = Kind, handler = Handler,
                        topics = maps:get(topics, Args, [])},
     [{state_timeout, timeout(live_attach_timeout, ?DEFAULT_ATTACH_TIMEOUT), expire}]}.

%% attach
handle_event({call, From}, {attach, Pid}, _State, #data{transport = Pid} = Data) ->
    {keep_state, Data, [{reply, From, ok}]};
handle_event({call, From}, {attach, Pid}, _State, Data0) ->
    Data1 = drop_transport(replaced, Data0),
    Mon = erlang:monitor(process, Pid),
    Data2 = flush(Data1#data{transport = Pid, monitor = Mon}),
    {next_state, attached, Data2, [{reply, From, ok}, {state_timeout, infinity, expire}]};
%% synchronous detach (long-poll): after the reply nothing more is sent to Pid
handle_event({call, From}, {release, Pid}, attached, #data{transport = Pid} = Data) ->
    {next_state, detached, release(Data), [{reply, From, ok} | idle_timeout()]};
handle_event({call, From}, {release, _Other}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, {request, Name, Payload}, State, #data{} = Data) ->
    {Result, View} = run_request(Name, Payload, Data),
    {keep_state, apply_view(View, State, Data), [{reply, From, Result}]};

%% the view data (see weberl_view_data)
handle_event({call, From}, {mount, View}, _State, Data) ->
    {keep_state, Data#data{view = View}, [{reply, From, ok}]};
handle_event({call, From}, view, _State, #data{view = undefined}) ->
    {keep_state_and_data, [{reply, From, {error, no_view}}]};
handle_event({call, From}, view, _State, #data{view = View}) ->
    {keep_state_and_data, [{reply, From, {ok, View}}]};
handle_event({call, From}, {assign, Changes}, State, #data{view = View} = Data) when View =/= undefined ->
    {keep_state, apply_view(weberl_view_data:with_assigns(Changes, View), State, Data),
     [{reply, From, ok}]};
handle_event({call, From}, {modify, Fun}, State, #data{view = View} = Data) when View =/= undefined ->
    try Fun(View) of
        New ->
            case weberl_view_data:is_view_data(New) of
                true ->
                    {keep_state, apply_view(New, State, Data), [{reply, From, ok}]};
                false ->
                    ?LOG_ERROR(#{what => live_modify_bad_return, page => Data#data.id, returned => New}),
                    {keep_state_and_data, [{reply, From, {error, failed}}]}
            end
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(#{what => live_modify_failure, page => Data#data.id, class => Class,
                         reason => Reason, stacktrace => Stack}),
            {keep_state_and_data, [{reply, From, {error, failed}}]}
    end;
handle_event({call, From}, {Op, _}, _State, #data{view = undefined}) when Op =:= assign; Op =:= modify ->
    {keep_state_and_data, [{reply, From, {error, no_view}}]};
handle_event({call, From}, info, State, #data{} = D) ->
    {keep_state_and_data,
     [{reply, From, {ok, #{state => State, kind => D#data.kind, handler => D#data.handler, owner => D#data.owner,
                           transport => D#data.transport, buffered => D#data.buffered}}}]};

%% the page was served as a narrower kind (see weberl_response:live/2)
handle_event(cast, {kind, Kind}, _State, Data) ->
    {keep_state, Data#data{kind = Kind}};

%% push
handle_event(cast, {push, Name, Payload}, State, Data) ->
    {keep_state, deliver(Name, Payload, State, Data)};

%% transport ended
handle_event(cast, {detach, Pid}, attached, #data{transport = Pid} = Data) ->
    {next_state, detached, release(Data), idle_timeout()};
handle_event(cast, {detach, _Other}, _State, _Data) ->
    keep_state_and_data;
handle_event(info, {'DOWN', Mon, process, _, _}, attached, #data{monitor = Mon} = Data) ->
    {next_state, detached, release(Data), idle_timeout()};
handle_event(info, {'DOWN', _, process, _, _}, _State, _Data) ->
    keep_state_and_data;

%% end
handle_event(cast, close, _State, Data) ->
    {stop, normal, drop_transport(close, Data)};
handle_event(state_timeout, expire, _State, Data) ->
    {stop, normal, Data};

handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, Data) ->
    _ = drop_transport(close, Data),
    ok.

%% ---------------------------------------------------------------------

%% Run the handler's optional `handle_request/3' in the session process. A
%% crash is logged and reported as `failed'; the session survives.
run_request(Name, Payload, #data{handler = Handler, id = Id, kind = Kind, topics = Topics,
                                 view = View}) ->
    weberl_live_callbacks:request_view(Handler, Name, Payload,
                                       weberl_live_callbacks:context(Id, Kind, Topics, View)).

%% The session now holds `New' (or keeps its view when the callback did not
%% return one). The regions that use an assign that changed are re-rendered
%% and pushed, in template order. A page that had no view yet has nothing to
%% compare with.
apply_view(keep, _State, Data) ->
    Data;
apply_view(New, _State, #data{view = undefined} = Data) ->
    Data#data{view = New};
apply_view(New0, State, #data{view = Old, handler = Handler} = Data0) ->
    %% a record built afresh by a callback keeps the layout the page was mounted with
    New = case weberl_view_data:layout(New0) of
              undefined -> case weberl_view_data:layout(Old) of
                               undefined -> New0;
                               Layout -> weberl_view_data:with_layout(Layout, New0)
                           end;
              _ -> New0
          end,
    Data = Data0#data{view = New},
    case weberl_view_data:changed_assigns(Old, New) of
        [] -> Data;
        Changed -> rerender(Changed, Handler, weberl_view_data:assigns(New), State, Data)
    end.

rerender(_Changed, undefined, _Assigns, _State, Data) ->
    Data;
rerender(Changed, Handler, Assigns, State, #data{view = View} = Data) ->
    Opts = weberl_view_data:render_opts(View),
    case weberl_template:regions(Handler, Opts) of
        {ok, Regions} ->
            Affected = [{Line, Name} || {Name, #{variables := Vars, line := Line}} <- maps:to_list(Regions),
                                        lists:any(fun(V) -> lists:member(V, Changed) end, Vars)],
            lists:foldl(fun({_Line, Region}, Acc) -> push_region(Handler, Region, Assigns, Opts, State, Acc) end,
                        Data, lists:sort(Affected));
        {error, _} ->
            Data
    end.

push_region(Handler, Region, Assigns, Opts, State, #data{id = Id} = Data) ->
    case weberl_live:region_event(Handler, Region, Assigns, Opts) of
        {ok, {Name, Payload}} ->
            deliver(Name, Payload, State, Data);
        {error, Reason} ->
            ?LOG_ERROR(#{what => live_region_update_failed, page => Id, region => Region, reason => Reason}),
            Data
    end.

%% Send an event to the transport, or keep it for the next one.
deliver(Name, Payload, attached, #data{id = Id, transport = Pid} = Data) ->
    Pid ! {weberl_live, Id, {event, Name, Payload}},
    Data;
deliver(Name, Payload, _State, Data) ->
    enqueue({Name, Payload}, Data).

idle_timeout() ->
    [{state_timeout, timeout(live_idle_timeout, ?DEFAULT_IDLE_TIMEOUT), expire}].

timeout(Key, Default) ->
    application:get_env(weberl, Key, Default).

%% Tell the current transport (if any) why it ends, and forget it.
drop_transport(_Why, #data{transport = undefined} = Data) ->
    Data;
drop_transport(Why, #data{id = Id, transport = Pid, monitor = Mon} = Data) ->
    erlang:demonitor(Mon, [flush]),
    Pid ! {weberl_live, Id, Why},
    Data#data{transport = undefined, monitor = undefined}.

%% Forget the transport without notifying it (it is already gone).
release(#data{monitor = Mon} = Data) ->
    erlang:demonitor(Mon, [flush]),
    Data#data{transport = undefined, monitor = undefined}.

enqueue(Event, #data{buffer = Q, buffered = N} = Data) when N >= ?MAX_BUFFER ->
    {_, Q1} = queue:out(Q),
    Data#data{buffer = queue:in(Event, Q1)};
enqueue(Event, #data{buffer = Q, buffered = N} = Data) ->
    Data#data{buffer = queue:in(Event, Q), buffered = N + 1}.

flush(#data{id = Id, transport = Pid, buffer = Q} = Data) ->
    [Pid ! {weberl_live, Id, {event, Name, Payload}} || {Name, Payload} <- queue:to_list(Q)],
    Data#data{buffer = queue:new(), buffered = 0}.
