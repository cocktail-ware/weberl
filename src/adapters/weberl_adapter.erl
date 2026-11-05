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
%%   <li>`validate_static/1' (optional): check static mount options. Mounts are
%%       served by the adapter before the route table is consulted.</li>
%% </ul>
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
%% Optional: static asset mounts. Receives the normalized
%% `[{UrlPrefix, Source, Opts}]' from the listener record and checks the
%% adapter-specific `Opts'. An adapter that does not export this rejects any
%% listener configured with `static' mounts.
-callback validate_static([{string(), term(), map()}]) -> ok | {error, term()}.

-optional_callbacks([validate_static/1]).
