%% @doc Live pages: server-pushed events to the browser of a rendered page.
%%
%% A route declared `one_way' or `two_way' (see `weberl_route:live/1') gets a
%% live session each time it is rendered: a `weberl_live_session' process
%% identified by an unguessable page id (a capability: whoever knows it can
%% attach to the session). Dispatch exposes the id to the handler
%% (`weberl_request:page/1'), injects the beacon script into the HTML
%% response, and the beacon (`priv/client.js') connects back to the server.
%% The handler passes the id to whatever will push updates later:
%%
%% ```
%% handle(Request) ->
%%     PageId = weberl_request:page(Request),
%%     ticker:subscribe(PageId),
%%     weberl_response:html(200, weberl_template:render(?MODULE, #{})).
%%
%% %% later, from any process:
%% weberl_live:push(PageId, <<"tick">>, <<"12:00">>).
%% '''
%%
%% == Transport protocol ==
%% The session talks to the attached transport process (one per page, the
%% adapter's connection handler) with plain messages, so adapters stay
%% independent of the session internals:
%% <ul>
%%   <li>`{weberl_live, PageId, {event, Name :: binary(), Data :: binary()}}'
%%       deliver one event;</li>
%%   <li>`{weberl_live, PageId, close}' the session ended: finish the
%%       connection;</li>
%%   <li>`{weberl_live, PageId, replaced}' another transport attached: finish
%%       the connection.</li>
%% </ul>
%% A transport calls {@link attach/2} when it starts and {@link detach/2} when
%% it ends.
%%
%% == Lifetime ==
%% A session that is never attached ends after `live_attach_timeout' (default
%% 30000 ms, application env of `weberl'). After the transport goes away it
%% waits `live_idle_timeout' (default 60000 ms) for a reconnect. Events pushed
%% while no transport is attached are buffered (the newest 100) and delivered
%% on the next attach. Stopping a router closes the sessions of its listener.
-module(weberl_live).

-export([open/2, open/3, new_page_id/0, downgrade/2, push/3, publish/3, publish_json/3, attach/2, detach/2, release/2, request/3,
         close/1, close_owner/1, whereis/1, info/1, poll_enabled/1, channels/1,
         check_topics/1, topics/2, client_path/0, engine_path/0, client_version/0,
         sse_path/1, update/3, update_topic/4, update_topic/5, region_event/3, region_event/4,
         mount/3, mount/4, assign/2, modify/2, view/1, register_connection/1, stats/0]).
-export_type([page_id/0, topic/0]).

-include_lib("kernel/include/logger.hrl").

-define(SCOPE, weberl_live).
%% The event that carries a region update (data: JSON {"region", "html"}).
-define(REGION_EVENT, <<"weberl:region">>).
-define(MAX_TOPICS, 32).
-define(MAX_TOPIC_BYTES, 256).

-type page_id() :: binary().
%% A topic is a UTF-8 binary, e.g. `<<"stock:ACME">>'.
-type topic() :: binary().

%% @doc Start a session for a page of kind `Kind' belonging to `Owner' (the
%% listener name, so the sessions can be closed with the listener).
-spec open(term(), one_way | two_way) -> {ok, page_id()} | {error, term()}.
open(Owner, Kind) ->
    open(Owner, Kind, #{}).

%% @doc Like {@link open/2}. Options: `handler' (the page's handler module;
%% its optional `handle_request/3' receives what the client sends, see
%% `weberl_handler') and `topics' (told to the handler in the page context).
-spec open(term(), one_way | two_way, #{handler => module(), topics => [topic()]}) ->
    {ok, page_id()} | {error, term()}.
open(Owner, Kind, Opts) when (Kind =:= one_way orelse Kind =:= two_way), is_map(Opts) ->
    PageId = new_id(),
    Args = maps:merge(maps:with([handler, topics], Opts),
                      #{id => PageId, owner => Owner, kind => Kind}),
    try supervisor:start_child(weberl_live_sup, [Args]) of
        {ok, _Pid} -> {ok, PageId};
        {error, _} = Error -> Error
    catch
        exit:{noproc, _} -> {error, live_unavailable}
    end.

%% @doc Publish a named event to every connection whose pages subscribed to
%% `Topic', on this node and on every node connected to it (fire-and-forget:
%% nothing is buffered or replayed, a client that is not connected misses it).
%% The frame is encoded once and the same binary goes to every connection
%% process, which writes it to its socket (see `weberl_live_wire'). Connections
%% are found in the `pg' group `{topic, Topic}' of the `weberl_live' scope, which
%% `pg' keeps in sync between connected nodes, see `weberl_live_topics'.
%% (Pages with a session stay local to the node that rendered them.)
-spec publish(topic(), binary(), iodata()) -> ok.
publish(Topic, Name, Data) when is_binary(Topic), is_binary(Name) ->
    Payload = iolist_to_binary(Data),
    Frame = iolist_to_binary(weberl_live_wire:topic_event(Topic, Name, Payload)),
    Message = {weberl_live_topic, Topic, Name, Payload, Frame},
    _ = [Pid ! Message || Pid <- pg:get_members(?SCOPE, {topic, Topic})],
    ok.

%% @doc Like {@link publish/3} for structured data: `Term' is encoded as JSON
%% (`json:encode/1': maps, lists, binaries, numbers, booleans, `null') and the
%% browser receives the decoded value, not a string to parse again:
%% `Weberl.on("tasks", function (data) { data.running ... })', and `event.detail'
%% of `weberl:tasks' is the value. A term JSON cannot hold raises `badarg'/an
%% error from `json:encode/1' in the caller, nothing is sent.
-spec publish_json(topic(), binary(), term()) -> ok.
publish_json(Topic, Name, Term) when is_binary(Topic), is_binary(Name) ->
    Json = iolist_to_binary(json:encode(Term)),
    Frame = iolist_to_binary(weberl_live_wire:topic_event_json(Topic, Name, Json)),
    Message = {weberl_live_topic, Topic, Name, {json, Json}, Frame},
    _ = [Pid ! Message || Pid <- pg:get_members(?SCOPE, {topic, Topic})],
    ok.

%% @doc Re-render one region of the page's template with `Assigns' and push the
%% new content to the browser, which swaps it in (the `weberl:region' event,
%% handled by `priv/client.js'). The page's handler is the view whose template
%% has the region, and `Assigns' need only hold the variables that region uses
%% (nothing is remembered between calls). Returns `ok' once the event is queued,
%% `{error, Reason}' (also logged) when the page is not found
%% (`not_found'), has no handler or template, or the render fails
%% (`{unknown_region, View, Region}', `{missing_variable, View, Name}', ...);
%% nothing is pushed then.
-spec update(page_id(), atom(), map()) -> ok | {error, term()}.
update(PageId, Region, Assigns) when is_atom(Region), is_map(Assigns) ->
    case info(PageId) of
        {ok, #{handler := Handler}} when Handler =/= undefined ->
            %% the layout the page was mounted with (a page that mounted nothing has the default)
            Opts = case view(PageId) of
                       {ok, ViewData} -> weberl_view_data:render_opts(ViewData);
                       {error, _} -> #{}
                   end,
            case region_event(Handler, Region, Assigns, Opts) of
                {ok, {Name, Payload}} -> push(PageId, Name, Payload);
                {error, Reason} -> region_failed(Reason, #{page => PageId, region => Region})
            end;
        {ok, _} ->
            region_failed(no_handler, #{page => PageId, region => Region});
        {error, _} = Error ->
            Error
    end.

%% @doc Like {@link update/3} for the pages that follow a topic (a page without
%% a session reaches its view through its token, so the caller names the
%% view): the region is rendered once and published to every page subscribed
%% to `Topic', on any node.
-spec update_topic(topic(), module(), atom(), map()) -> ok | {error, term()}.
update_topic(Topic, View, Region, Assigns) ->
    update_topic(Topic, View, Region, Assigns, #{}).

%% @doc Like {@link update_topic/4}, rendering with the layout in `Opts' (`#{layout => Name}'):
%% a page without a session has no record that remembers its layout, so the caller names it.
%% Every page that follows the topic gets this one rendering.
-spec update_topic(topic(), module(), atom(), map(), weberl_template:render_opts()) -> ok | {error, term()}.
update_topic(Topic, View, Region, Assigns, Opts) when is_binary(Topic), is_atom(View), is_atom(Region),
                                                      is_map(Assigns), is_map(Opts) ->
    case region_event(View, Region, Assigns, Opts) of
        {ok, {Name, Payload}} -> publish(Topic, Name, Payload);
        {error, Reason} -> region_failed(Reason, #{topic => Topic, region => Region})
    end.

%% @doc The event (name and data) that makes the browser swap in a region
%% rendered from `Assigns'; the session uses it too.
-spec region_event(module(), atom(), map()) -> {ok, {binary(), binary()}} | {error, term()}.
region_event(View, Region, Assigns) ->
    region_event(View, Region, Assigns, #{}).

-spec region_event(module(), atom(), map(), weberl_template:render_opts()) ->
    {ok, {binary(), binary()}} | {error, term()}.
region_event(View, Region, Assigns, Opts) ->
    case weberl_template:try_render_region(View, Region, Assigns, Opts) of
        {ok, Html} ->
            Payload = iolist_to_binary(json:encode(#{region => Region, html => iolist_to_binary(Html)})),
            {ok, {?REGION_EVENT, Payload}};
        {error, _} = Error ->
            Error
    end.

%% @doc Mount the page of `Request' (a request of a live route, as dispatch
%% gives it to `handle/1'): render the template of `View' (normally the handler
%% itself, `?MODULE') from the assigns of `ViewData' and, when the page has a
%% session, keep the whole record there for the life of the page (see
%% `weberl_view_data'). A page without a session (a session-less one, or one
%% served as `normal') is just rendered and the record is dropped. Returns the
%% rendered page. A later `mount/3' for the same page replaces the record.
-spec mount(module(), weberl_request:t(), weberl_view_data:t()) -> iodata().
mount(View, Request, ViewData) ->
    true = weberl_view_data:is_view_data(ViewData) orelse erlang:error(badarg),
    _ = case weberl_request:page(Request) of
            undefined -> ok;
            PageId -> session_call(PageId, {mount, ViewData})
        end,
    weberl_template:render(View, weberl_view_data:assigns(ViewData), weberl_view_data:render_opts(ViewData)).

%% @doc Like {@link mount/3}, rendering the page with the layout in `Opts' (`#{layout => Name}', one
%% the view's route allows, see `weberl_template:render/3'). The session remembers it with the
%% record, so the page's regions are re-rendered with the same layout.
-spec mount(module(), weberl_request:t(), weberl_view_data:t(), weberl_template:render_opts()) -> iodata().
mount(View, Request, ViewData, #{layout := Layout}) ->
    mount(View, Request, weberl_view_data:with_layout(Layout, ViewData));
mount(View, Request, ViewData, #{}) ->
    mount(View, Request, ViewData).

%% @doc Merge `Changes' into the page's assigns and re-render and push the
%% regions that use a variable whose value changed. `{error, no_view}' when
%% the page has not mounted a view, `{error, not_found}' for an unknown page.
-spec assign(page_id(), map()) -> ok | {error, not_found | no_view}.
assign(PageId, Changes) when is_map(Changes) ->
    session_call(PageId, {assign, Changes}).

%% @doc Change the page's view data with `Fun' (it runs inside the session, so
%% keep it short and pure) and re-render the regions affected by the assigns it
%% changed. `Fun' gets the record and returns the new one; `{error, failed}'
%% (logged) if it crashes or returns something else.
-spec modify(page_id(), fun((weberl_view_data:t()) -> weberl_view_data:t())) ->
    ok | {error, not_found | no_view | failed}.
modify(PageId, Fun) when is_function(Fun, 1) ->
    session_call(PageId, {modify, Fun}).

%% @doc The view data the session of the page holds.
-spec view(page_id()) -> {ok, weberl_view_data:t()} | {error, not_found | no_view}.
view(PageId) ->
    session_call(PageId, view).

session_call(PageId, Msg) ->
    case ?MODULE:whereis(PageId) of
        {ok, Pid} ->
            try gen_statem:call(Pid, Msg, 5000)
            catch exit:{Reason, _} when Reason =:= noproc; Reason =:= normal; Reason =:= shutdown ->
                    {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end.

region_failed(Reason, Context) ->
    ?LOG_ERROR(Context#{what => live_region_update_failed, reason => Reason}),
    {error, Reason}.

%% @doc Push a named event to the page. Buffered if no transport is attached.
-spec push(page_id(), binary(), iodata()) -> ok | {error, not_found}.
push(PageId, Name, Data) when is_binary(Name) ->
    cast(PageId, {push, Name, iolist_to_binary(Data)}).

%% @doc Attach a transport process; any previous transport is told it was
%% replaced and buffered events are delivered.
-spec attach(page_id(), pid()) -> ok | {error, not_found}.
attach(PageId, Transport) when is_pid(Transport) ->
    case ?MODULE:whereis(PageId) of
        {ok, Pid} ->
            try gen_statem:call(Pid, {attach, Transport})
            catch exit:{Reason, _} when Reason =:= noproc; Reason =:= normal;
                                        Reason =:= shutdown ->
                    {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc The transport ended. Ignored if `Transport' is not the attached one.
-spec detach(page_id(), pid()) -> ok.
detach(PageId, Transport) ->
    _ = cast(PageId, {detach, Transport}),
    ok.

%% @doc Like {@link detach/2} but synchronous: when it returns, no further
%% event is sent to `Transport', so whatever is in its mailbox is everything
%% (long-poll relies on this to not lose events between polls).
-spec release(page_id(), pid()) -> ok.
release(PageId, Transport) ->
    case ?MODULE:whereis(PageId) of
        {ok, Pid} ->
            try gen_statem:call(Pid, {release, Transport})
            catch exit:_ -> ok
            end;
        {error, _} ->
            ok
    end.

%% @doc A request from the page's client (`Name', `Data' decoded from JSON).
%% It runs the handler's `handle_request/3' inside the session. `unsupported'
%% means the handler has no such callback, `failed' that it crashed.
-spec request(page_id(), binary(), term()) ->
    {ok, noreply | {reply, term()}} | {error, not_found | unsupported | failed}.
request(PageId, Name, Data) when is_binary(Name) ->
    case ?MODULE:whereis(PageId) of
        {ok, Pid} ->
            try gen_statem:call(Pid, {request, Name, Data}, 15000)
            catch exit:_ -> {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Tell the session its page was served as a narrower kind (dispatch calls
%% this for a downgrade, see `weberl_response:live/2'); callbacks then see it in
%% their page context.
-spec downgrade(page_id(), one_way | two_way) -> ok.
downgrade(PageId, Kind) when Kind =:= one_way; Kind =:= two_way ->
    _ = cast(PageId, {kind, Kind}),
    ok.

%% @doc End the session (the transport is told to close).
-spec close(page_id()) -> ok.
close(PageId) ->
    _ = cast(PageId, close),
    ok.

%% @doc End every session that belongs to `Owner'.
-spec close_owner(term()) -> ok.
close_owner(Owner) ->
    [gen_statem:cast(Pid, close) || Pid <- pg:get_local_members(?SCOPE, {owner, Owner})],
    ok.

-spec whereis(page_id()) -> {ok, pid()} | {error, not_found}.
whereis(PageId) ->
    case pg:get_local_members(?SCOPE, {page, PageId}) of
        [Pid | _] -> {ok, Pid};
        [] -> {error, not_found}
    end.

%% @doc Session state summary, for diagnostics and tests.
-spec info(page_id()) -> {ok, map()} | {error, not_found}.
info(PageId) ->
    case ?MODULE:whereis(PageId) of
        {ok, Pid} ->
            try gen_statem:call(Pid, info)
            catch exit:_ -> {error, not_found}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc May pages of this kind fall back to long-poll? Application env of
%% `weberl': `live_poll_fallback', a list of kinds (default both). Set it to
%% `[one_way]' to remove the fallback for `two_way' pages: the beacon is told
%% and the poll endpoint refuses them.
-spec poll_enabled(one_way | two_way) -> boolean().
poll_enabled(Kind) ->
    lists:member(Kind, application:get_env(weberl, live_poll_fallback, [one_way, two_way])).

%% @doc The channels a page of this kind may use; they are what its token
%% (see `weberl_live_guard') allows. `one_way': its own stream, the shared
%% WebSocket (a browser hub carries all its tabs' pages on one socket, even
%% `one_way' ones, which the server still only pushes to) and requests over
%% POST; `two_way': WebSocket and requests. Both add `poll' while the fallback
%% is on.
-spec channels(one_way | two_way) -> [weberl_live_guard:channel()].
channels(Kind) ->
    Primary = case Kind of one_way -> [sse, ws, request]; two_way -> [ws, request] end,
    case poll_enabled(Kind) of
        true -> [poll | Primary];
        false -> Primary
    end.

%% @doc Validate the topics of a page before they are signed into its token:
%% a list of at most 32 non-empty UTF-8 binaries of at most 256 bytes each
%% (the token travels in a URL, so it has to stay small).
-spec check_topics(term()) -> ok | {error, term()}.
check_topics(Topics) when is_list(Topics), length(Topics) =< ?MAX_TOPICS ->
    case [T || T <- Topics, not valid_topic(T)] of
        [] -> ok;
        [Bad | _] -> {error, {invalid_topic, Bad}}
    end;
check_topics(Topics) when is_list(Topics) ->
    {error, {too_many_topics, length(Topics)}};
check_topics(Other) ->
    {error, {topics_not_a_list, Other}}.

valid_topic(T) when is_binary(T), byte_size(T) > 0, byte_size(T) =< ?MAX_TOPIC_BYTES ->
    is_binary(unicode:characters_to_binary(T));
valid_topic(_) ->
    false.

%% @doc The topics a page of `Route' rendering `Request' subscribes to: what the
%% handler's optional `weberl_topics/1' returns, otherwise the default (none for
%% a page with a session, the route's path for a session-less one, which has
%% nothing else to receive). Validated with {@link check_topics/1}; duplicates
%% are dropped. Dispatch calls this on every render; tests can call it to
%% assert what a request would subscribe to.
-spec topics(weberl_route:t(), weberl_request:t()) -> {ok, [topic()]} | {error, term()}.
topics(Route, Request) ->
    Handler = weberl_route:handler(Route),
    Result = case erlang:function_exported(Handler, weberl_topics, 1) of
                 false -> {ok, default_topics(Route)};
                 true ->
                     try {ok, Handler:weberl_topics(Request)}
                     catch Class:Reason -> {error, {weberl_topics_failed, Class, Reason}}
                     end
             end,
    case Result of
        {ok, Topics} ->
            case check_topics(Topics) of
                ok -> {ok, lists:uniq(Topics)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

default_topics(Route) ->
    case weberl_route:session(Route) of
        true -> [];
        false -> [unicode:characters_to_binary(weberl_route:path(Route))]
    end.

%% @doc A fresh, unguessable page id (also used by pages without a session).
-spec new_page_id() -> page_id().
new_page_id() ->
    new_id().

%% @doc URL of the beacon script.
-spec client_path() -> string().
client_path() -> "/_weberl/client.js".

%% @doc URL of the transport engine script (loaded before the beacon).
-spec engine_path() -> string().
engine_path() -> "/_weberl/engine.js".

%% @doc Record the calling process as a live connection of this kind (`ws' or
%% `sse'), for {@link stats/0}. It ends with the process.
-spec register_connection(ws | sse) -> ok.
register_connection(Kind) when Kind =:= ws; Kind =:= sse ->
    ok = pg:join(?SCOPE, {connection, Kind}, self()).

%% @doc What this node holds right now, for diagnostics and the browser tests:
%% `sessions' (live pages with a session), `websockets' and `streams' (open
%% connections of those transports; with a shared hub, many tabs make one).
-spec stats() -> #{sessions := non_neg_integer(), websockets := non_neg_integer(),
                   streams := non_neg_integer()}.
stats() ->
    Count = fun(Group) -> length(pg:get_local_members(?SCOPE, Group)) end,
    #{sessions => length([G || {page, _} = G <- pg:which_groups(?SCOPE),
                               pg:get_local_members(?SCOPE, G) =/= []]),
      websockets => Count({connection, ws}),
      streams => Count({connection, sse})}.

%% @doc The version of the browser scripts this server speaks to (`VERSION' in
%% `priv/engine.js'). Connections declare theirs in the `v' query parameter; the
%% adapters log the ones that differ.
-spec client_version() -> pos_integer().
client_version() -> 1.

%% @doc URL of the SSE endpoint of a page.
-spec sse_path(page_id()) -> string().
sse_path(PageId) -> "/_weberl/sse/" ++ binary_to_list(PageId).

cast(PageId, Msg) ->
    case ?MODULE:whereis(PageId) of
        {ok, Pid} -> gen_statem:cast(Pid, Msg);
        {error, _} = Error -> Error
    end.

new_id() ->
    base64:encode(crypto:strong_rand_bytes(16), #{mode => urlsafe, padding => false}).
