%% @doc One process per started router (`gen_statem', `handle_event_function').
%% It owns the lifecycle: it validates the configuration, builds the route
%% table, checks the handlers, starts the transport listener through the
%% adapter, and stops the listener on terminate. Put it under your own
%% supervisor with `weberl:child_spec/3'.
%%
%% Startup happens in `init/1' so that `start_link/3' can return structured
%% errors. It is all-or-nothing: if any step fails, whatever was already
%% started is stopped and `start_link/3' returns `{error, Reason}'. Like any
%% linked start, a failure also exits the (non-trapping) caller; supervisors
%% trap exits.
%%
%% States: `running' (the only one for now).
-module(weberl_router_server).
-behaviour(gen_statem).

-export([start_link/3, child_spec/3, stop/1, table/1, port/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

-record(data, {name :: atom(), adapter :: module(), ref :: term(), listener_name :: atom()}).

%% ============================================================================
%% Public API
%% ============================================================================

start_link(Name, RouterConfig, ListenerConfig) when is_atom(Name) ->
    gen_statem:start_link({local, Name}, ?MODULE, {Name, RouterConfig, ListenerConfig}, []);
start_link(Name, _, _) ->
    {error, {invalid_router_name, Name}}.

child_spec(Name, RouterConfig, ListenerConfig) ->
    #{id => Name,
      start => {?MODULE, start_link, [Name, RouterConfig, ListenerConfig]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

stop(Name) -> gen_statem:stop(Name).

%% @doc The route table of a running router.
-spec table(atom()) -> {ok, weberl_table:t()} | {error, not_running}.
table(Name) ->
    case persistent_term:get({weberl_router, Name}, undefined) of
        undefined -> {error, not_running};
        Table -> {ok, Table}
    end.

%% @doc The port the router's listener is bound to.
-spec port(atom()) -> inet:port_number().
port(Name) -> gen_statem:call(Name, port).

%% ============================================================================
%% gen_statem callbacks
%% ============================================================================

callback_mode() -> handle_event_function.

init({Name, RouterConfig, ListenerConfig}) ->
    process_flag(trap_exit, true),
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    case start(Name, RouterConfig, ListenerConfig) of
        {ok, Data} -> {ok, running, Data};
        {error, Reason} -> {stop, Reason}
    end.

handle_event({call, From}, port, running, #data{adapter = A, ref = Ref}) ->
    {keep_state_and_data, [{reply, From, A:port(Ref)}]};
handle_event({call, From}, _Other, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]};
handle_event(_Type, _Event, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, #data{name = Name, adapter = A, ref = Ref,
                                 listener_name = ListenerName}) ->
    %% Live sessions end their connections; stopping the listener alone would
    %% leave long-lived (SSE) connections open.
    try weberl_live:close_owner(ListenerName)
    catch _:_ -> ok
    end,
    A:stop_listener(Ref),
    persistent_term:erase({weberl_router, Name}),
    ok.

%% ============================================================================
%% Internal
%% ============================================================================

start(Name, RouterConfig, ListenerConfig) ->
    with(fun() -> weberl_config:validate(RouterConfig) end,
      fun(Router) ->
        with(fun() -> weberl_config:validate_listener(ListenerConfig) end,
          fun(Listener) ->
            with(fun() -> weberl:build(Router) end,
              fun(Table) ->
                with(fun() -> weberl_limits:audit(Table) end,
                  fun(ok) ->
                    with(fun() -> check_handlers(Table) end,
                      fun(ok) ->
                        with(fun() -> weberl_views:prepare(Router, Table) end,
                          fun(ok) -> launch(Name, Listener, Table) end)
                      end)
                  end)
              end)
          end)
      end).

with(Step, Next) ->
    case Step() of
        {ok, V} -> Next(V);
        ok -> Next(ok);
        {error, _} = Error -> Error
    end.

check_handlers(Table) ->
    Handlers = lists:usort([weberl_route:handler(R) || R <- weberl_table:routes(Table)]),
    case [E || H <- Handlers, {error, E} <- [weberl_handler:check(H)]] of
        [] -> ok;
        Errors -> {error, {invalid_handlers, Errors}}
    end.

launch(Name, Listener, Table) ->
    Adapter = weberl_config:listener_adapter(Listener),
    ListenerName = listener_name(Name),
    case Adapter:start_listener(ListenerName, Listener, Table) of
        {ok, Ref} ->
            persistent_term:put({weberl_router, Name}, Table),
            {ok, #data{name = Name, adapter = Adapter, ref = Ref,
                       listener_name = ListenerName}};
        {error, _} = Error ->
            Error
    end.

listener_name(Name) ->
    list_to_atom("weberl_listener_" ++ atom_to_list(Name)).
