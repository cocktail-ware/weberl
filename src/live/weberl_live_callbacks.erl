%% @doc Runs a handler's live callbacks (`handle_request/3', `handle_subscribe/2')
%% on behalf of whichever process holds the page: the session for a page with
%% one, otherwise the connection process. A callback that crashes or returns
%% something unexpected is logged; the caller only learns that it failed.
-module(weberl_live_callbacks).

-include_lib("kernel/include/logger.hrl").

-export([request/4, request_view/4, subscribe/3, snapshots/2, context/3, context/4]).

%% @doc The page context passed to the callbacks (`weberl_handler:page_context()').
-spec context(weberl_live:page_id(), one_way | two_way, [weberl_live:topic()]) ->
    weberl_handler:page_context().
context(PageId, Kind, Topics) ->
    #{page => PageId, kind => Kind, topics => Topics}.

%% @doc The context of a page whose session holds `View' (`undefined': none
%% yet, the context then has no `view').
-spec context(weberl_live:page_id(), one_way | two_way, [weberl_live:topic()],
              undefined | weberl_view_data:t()) -> weberl_handler:page_context().
context(PageId, Kind, Topics, undefined) ->
    context(PageId, Kind, Topics);
context(PageId, Kind, Topics, View) ->
    (context(PageId, Kind, Topics))#{view => View}.

%% @doc Run `Handler:handle_request(Name, Data, Context)'. For a page with no
%% session: a view the callback returns has nowhere to live and is dropped.
-spec request(module() | undefined, binary(), term(), weberl_handler:page_context()) ->
    {ok, noreply | {reply, term()}} | {error, unsupported | failed}.
request(Handler, Name, Data, Context) ->
    {Result, _View} = request_view(Handler, Name, Data, Context),
    Result.

%% @doc Like {@link request/4}, also telling what the callback did with the
%% page's view data: `keep' (not touched) or the new record it returned.
-spec request_view(module() | undefined, binary(), term(), weberl_handler:page_context()) ->
    {{ok, noreply | {reply, term()}} | {error, unsupported | failed},
     keep | weberl_view_data:t()}.
request_view(Handler, Name, Data, Context) ->
    case Handler =/= undefined andalso erlang:function_exported(Handler, handle_request, 3) of
        false ->
            {{error, unsupported}, keep};
        true ->
            try Handler:handle_request(Name, Data, Context) of
                ok -> {{ok, noreply}, keep};
                {reply, Reply} -> {{ok, {reply, Reply}}, keep};
                {ok, View} -> returned(Handler, Name, {ok, noreply}, View);
                {reply, Reply, View} -> returned(Handler, Name, {ok, {reply, Reply}}, View);
                Other -> bad_return(Handler, Name, Other)
            catch
                Class:Reason:Stack ->
                    ?LOG_ERROR(#{what => live_request_failure, handler => Handler,
                                 request => Name, class => Class, reason => Reason,
                                 stacktrace => Stack}),
                    {{error, failed}, keep}
            end
    end.

returned(Handler, Name, Result, View) ->
    case weberl_view_data:is_view_data(View) of
        true -> {Result, View};
        false -> bad_return(Handler, Name, View)
    end.

bad_return(Handler, Name, Other) ->
    ?LOG_ERROR(#{what => live_request_bad_return, handler => Handler,
                 request => Name, returned => Other}),
    {{error, failed}, keep}.

%% @doc The snapshots a page that just (re)subscribed receives, in topic order:
%% `handle_subscribe/2' of the token's handler for each of its topics.
-spec snapshots(weberl_live:page_id(), weberl_live_guard:claims()) -> [{binary(), binary()}].
snapshots(PageId, #{kind := Kind, handler := Handler, topics := Topics}) ->
    Context = context(PageId, Kind, Topics),
    [{Name, Data} || Topic <- Topics,
                     {snapshot, Name, Data} <- [subscribe(Handler, Topic, Context)]].

%% @doc Run `Handler:handle_subscribe(Topic, Context)'; `{snapshot, Name, Data}'
%% when the handler has one to send, `none' otherwise (no callback, `ok', or a
%% failure, which is logged).
-spec subscribe(module() | undefined, weberl_live:topic(), weberl_handler:page_context()) ->
    {snapshot, binary(), binary()} | none.
subscribe(Handler, Topic, Context) ->
    case Handler =/= undefined andalso erlang:function_exported(Handler, handle_subscribe, 2) of
        false ->
            none;
        true ->
            try Handler:handle_subscribe(Topic, Context) of
                ok ->
                    none;
                {snapshot, <<"weberl_", _/binary>>, _} = Other ->
                    %% the prefix belongs to the browser scripts, see weberl_live:push/3
                    ?LOG_ERROR(#{what => live_subscribe_bad_return, handler => Handler,
                                 topic => Topic, returned => Other, reason => reserved_event_name}),
                    none;
                {snapshot, Name, Data} when is_binary(Name) ->
                    {snapshot, Name, iolist_to_binary(Data)};
                Other ->
                    ?LOG_ERROR(#{what => live_subscribe_bad_return, handler => Handler,
                                 topic => Topic, returned => Other}),
                    none
            catch
                Class:Reason:Stack ->
                    ?LOG_ERROR(#{what => live_subscribe_failure, handler => Handler,
                                 topic => Topic, class => Class, reason => Reason,
                                 stacktrace => Stack}),
                    none
            end
    end.
