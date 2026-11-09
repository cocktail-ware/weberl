%% @doc Transport adapter contract.
%%
%% An adapter starts a listener that feeds incoming requests to
%% `weberl_dispatch:dispatch/2' with the route table it was given, and converts
%% between the transport's request/response and `weberl_request' /
%% `weberl_response'. Selecting an adapter is just naming its module in the
%% `listener' record.
%%
%% Callbacks:
%% <ul>
%%   <li>`validate_options/1': check the adapter-specific `options' map before
%%       anything is started. Return `{error, Reason}' for unknown or invalid
%%       keys.</li>
%%   <li>`start_listener/3': `Name' is a unique atom chosen by weberl (distinct
%%       from the router's own name). Return an opaque reference.
%%       Failures are `{error, Reason}'; `{adapter_unavailable, Dep}' means the
%%       transport library is not installed. Since `Name' is unique per router,
%%       a listener already registered under it is a leftover from a router
%%       process that was killed without cleaning up: replace it.</li>
%%   <li>`stop_listener/1': stop the listener and release its resources.
%%       Stopping a listener that is already gone is not an error.</li>
%%   <li>`port/1': the port the listener actually bound (useful with port 0).</li>
%%   <li>`cookies/1': the `{Name, Value}' pairs of the request's `Cookie' header(s).</li>
%%   <li>`form/1': the decoded form of the request body (see below).</li>
%%   <li>`multipart/1': the raw parts of a `multipart/form-data' body (see below).</li>
%%   <li>`validate_static/1' (optional): check static mount options. Mounts are
%%       served by the adapter before the route table is consulted.</li>
%% </ul>
%%
%% `cookies/1' and `form/1' receive the `weberl_request' the adapter built; the
%% transport's own request is whatever the adapter put in the request's `meta'
%% (`raw', for Roadrunner). They exist so that parsing, size limits and body
%% buffering stay with the transport that owns them, while
%% `weberl_request:cookies/1' and `weberl_request:form/1' give every application
%% one function, whatever the adapter. Building responses (cookies, redirects) is
%% transport independent and lives in `weberl_response'; an adapter only has to
%% send repeated response headers (several `set-cookie') as separate headers.
-module(weberl_adapter).

-export_type([ref/0]).

-type ref() :: term().

-callback validate_options(map()) -> ok | {error, term()}.
%% The second argument is a validated `weberl_config' `listener' record; read it
%% with `weberl_config:listener_port/1', `listener_ip/1' and `listener_options/1'.
-callback start_listener(Name :: atom(), Listener :: term(), weberl_table:t()) ->
    {ok, ref()} | {error, term()}.
-callback stop_listener(ref()) -> ok | {error, term()}.
-callback port(ref()) -> inet:port_number().
%% `[{Name, Value}]' in wire order; `[]' when the request has no cookies.
-callback cookies(weberl_request:t()) -> [{binary(), binary()}].
%% The body of a `application/x-www-form-urlencoded' request as decoded pairs
%% (a field without `=' is `{Name, true}'). Other content types: `{error,
%% unsupported_content_type}', or `{error, no_content_type}' when absent;
%% an unreadable body is the transport's `{error, Reason}'.
-callback form(weberl_request:t()) ->
    {ok, [{binary(), binary() | true}]} | {error, term()}.
%% The parts of a `multipart/form-data' body, raw: `[{Headers, Body}]' with header names
%% lowercased and the bodies as sent. `weberl_multipart' reads the `Content-Disposition' and
%% applies the limits, so an adapter only splits the body. Other content types: `{error,
%% unsupported_content_type}' (or `{error, no_content_type}'); a body that is not valid
%% multipart: `{error, malformed_multipart}'; an unreadable body is the transport's
%% `{error, Reason}'.
-callback multipart(weberl_request:t()) ->
    {ok, [{[{binary(), binary()}], binary()}]} | {error, term()}.
%% Optional: static asset mounts. Receives the normalized
%% `[{UrlPrefix, Source, Opts}]' from the listener record and checks the
%% adapter-specific `Opts'. An adapter that does not export this rejects any
%% listener configured with `static' mounts.
-callback validate_static([{string(), term(), map()}]) -> ok | {error, term()}.

%% Optional: replace the route table of a running listener without restarting it
%% (`weberl:reload/1'). Receives the listener's reference, the same validated
%% listener record as `start_listener/3' and the new table. It must be atomic: on
%% `{error, _}' the listener keeps serving the table it had, and connections that are
%% open stay open. An adapter that does not export this makes `weberl:reload/1'
%% answer `{error, {reload_unsupported, Adapter}}'.
-callback reload_routes(ref(), Listener :: term(), weberl_table:t()) -> ok | {error, term()}.
-optional_callbacks([validate_static/1, reload_routes/3]).
