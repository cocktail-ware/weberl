%% @doc Public entry point: build a route table from configuration and look
%% routes up.
%%
%% Concerns are separate modules: `weberl_config' (records + validation),
%% `weberl_fs' (filesystem discovery), `weberl_decl' (declarative collection),
%% `weberl_table' (assembly, precedence, lookup), `weberl_route' (route record,
%% path normalization).
-module(weberl).

-export([build/1, lookup/2, handler/2, routes/1, shadowed/1]).
-export([start_link/3, child_spec/3, stop/1, table/1, port/1]).

%% @doc Start a router: validate the configuration, build the route table,
%% check the handlers and start the transport listener. The returned process
%% is registered as `Name' and owns the listener; it is meant to run under the
%% caller's own supervisor (see {@link child_spec/3}), which decides when the
%% router starts. Errors are structured `{error, Reason}' and leave nothing
%% running.
%%
%% Configuration uses the native records from `weberl_config'
%% (`router', `listener'). The `weberl' application must be started, or
%% `code:ensure_loaded(weberl_config)' called, before constructing them.
-spec start_link(atom(), term(), term()) -> {ok, pid()} | {error, term()}.
start_link(Name, RouterConfig, ListenerConfig) ->
    weberl_router_server:start_link(Name, RouterConfig, ListenerConfig).

%% @doc Supervisor child specification for {@link start_link/3}.
-spec child_spec(atom(), term(), term()) -> supervisor:child_spec().
child_spec(Name, RouterConfig, ListenerConfig) ->
    weberl_router_server:child_spec(Name, RouterConfig, ListenerConfig).

%% @doc Stop a running router and its listener.
-spec stop(atom()) -> ok.
stop(Name) -> weberl_router_server:stop(Name).

%% @doc The route table of a running router.
-spec table(atom()) -> {ok, weberl_table:t()} | {error, not_running}.
table(Name) -> weberl_router_server:table(Name).

%% @doc The port a running router's listener is bound to (useful with port 0).
-spec port(atom()) -> inet:port_number().
port(Name) -> weberl_router_server:port(Name).

%% @doc Validate configuration, discover filesystem routes, collect
%% declarative routes and assemble the route table.
-spec build(term()) -> {ok, weberl_table:t()} | {error, term()}.
build(Config) ->
    case weberl_config:validate(Config) of
        {ok, Valid} ->
            case discover_all(weberl_config:filesystem(Valid), []) of
                {ok, Fs} ->
                    case weberl_decl:collect(weberl_config:modules(Valid)) of
                        {ok, Decl} ->
                            case weberl_table:assemble(Fs, Decl) of
                                {ok, Table} -> {ok, weberl_table:with_limits(Table, weberl_config:limits(Valid))};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec lookup(term(), weberl_table:t()) -> {ok, weberl_route:t()} | {error, not_found}.
lookup(Path, Table) -> weberl_table:lookup(Path, Table).

-spec handler(term(), weberl_table:t()) -> {ok, module()} | {error, not_found}.
handler(Path, Table) -> weberl_table:handler(Path, Table).

-spec routes(weberl_table:t()) -> [weberl_route:t()].
routes(Table) -> weberl_table:routes(Table).

-spec shadowed(weberl_table:t()) -> [weberl_route:t()].
shadowed(Table) -> weberl_table:shadowed(Table).

discover_all([], Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
discover_all([Fs | Rest], Acc) ->
    case weberl_fs:discover(weberl_config:root(Fs), weberl_config:prefix(Fs)) of
        {ok, Routes} -> discover_all(Rest, [Routes | Acc]);
        {error, _} = Error -> Error
    end.
