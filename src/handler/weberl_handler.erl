%% @doc Handler behaviour and startup checks.
%%
%% A handler is any module exporting `handle/1': it receives a
%% `weberl_request' and must return a `weberl_response'. Filesystem views and
%% declarative handlers use the same contract.
%%
%% Per-module settings (the page kind, CSRF mode, layout...) are route options:
%% `-weberl_route(Opts).' in a filesystem view, the third element of a declarative
%% route (see {@link weberl_route:check_opts/1}).
-module(weberl_handler).

-export([check/1]).

-callback handle(weberl_request:t()) -> weberl_response:t().
%% Optional, for live (`one_way' / `two_way') pages: the page's client sent a
%% request (`weberl.request(Name, Data)' in the beacon, or a POST to
%% `/_weberl/request/:id'). `Data' is the decoded JSON value, `Page' the page
%% context (see {@link page_context/0}). For a page with a session it runs
%% inside the session, otherwise in the process that received the request; in
%% both cases it blocks that process, so keep it short and push slow results
%% later with `weberl_live:push/3' or `weberl_live:publish/3'. `{reply, Json}'
%% answers the client's request (`Json' is any term `json:encode/1' accepts);
%% `ok' answers with nothing. A crash is logged and the client gets a failure;
%% the session survives. On a page with a session the handler may also return
%% the new view data, `{ok, ViewData}' or `{reply, Json, ViewData}': the session
%% keeps it and re-renders and pushes the regions that use an assign whose
%% value changed. On a page without a session the returned record has nowhere
%% to live and is dropped.
-callback handle_request(Name :: binary(), Data :: term(), Page :: page_context()) ->
    ok | {reply, term()} | {ok, weberl_view_data:t()} | {reply, term(), weberl_view_data:t()}.
%% Optional, for live pages: the topics this page subscribes to (see
%% `weberl_live'), computed per request, so they may include per-user topics
%% such as `<<"user:42:inbox">>'. Without it a page with a session has no
%% topics and a session-less one has its route path as its only topic. The
%% result is validated (`weberl_live:check_topics/1') and signed into the
%% page's token; an invalid result is a logged 500.
-callback weberl_topics(weberl_request:t()) -> [weberl_live:topic()].
%% Optional, for live pages with topics: a client's subscription to `Topic'
%% took effect (the connection already joined the topic's group), so what it
%% reads next is current. It runs again whenever that client (re)subscribes:
%% on a new connection, on a reconnect and, for long-poll, after a gap. A
%% `{snapshot, Name, Data}' result is sent to that client only, as an event, so
%% it can catch up on what it missed; `ok' sends nothing. It runs in the
%% connection process, blocking it (and the other pages of that connection)
%% while it runs, so keep it short. A crash is logged and the subscription
%% continues without a snapshot. `{snapshot_json, Name, Term}' sends a value, as
%% {@link weberl_live:publish_json/3} does: `Term' is encoded as JSON once and the
%% browser receives it decoded, not as a string (a term JSON cannot hold is a logged
%% failure, like a crash).
-callback handle_subscribe(Topic :: weberl_live:topic(), Page :: page_context()) ->
    {snapshot, Name :: binary(), Data :: iodata()} | {snapshot_json, Name :: binary(), Term :: term()} | ok.
-optional_callbacks([handle_request/3, weberl_topics/1, handle_subscribe/2]).
%% What a callback is told about the page: its id, kind and topics, taken from
%% the verified token. There is no user data in it: put what a callback needs
%% to know into the topic names. The context of `handle_request/3' of a page
%% with a session also has `view', the `weberl_view_data' the page mounted
%% (`weberl_live:mount/3'), if it did: what the HTTP request knew (the user,
%% say) kept for the live connection. `handle_subscribe/2' runs in the
%% connection process and gets no `view'; `weberl_live:view/1' reads it from the
%% session (the page id is the session's identity).
-type page_context() :: #{page := weberl_live:page_id(),
                          kind := one_way | two_way,
                          topics := [weberl_live:topic()],
                          view => weberl_view_data:t()}.
-export_type([page_context/0]).

%% @doc Check that a module can serve as a handler: it loads, exports
%% `handle/1'.
-spec check(module()) -> ok | {error, term()}.
check(Module) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, handle, 1) of
                true -> ok;
                false -> {error, {invalid_handler, Module, missing_callback_handle_1}}
            end;
        {error, Reason} ->
            {error, {invalid_handler, Module, {not_loadable, Reason}}}
    end.
