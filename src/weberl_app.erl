%% @doc Application callback. Starts nothing of its own: it only makes the
%% native records in `weberl_config' constructible, then starts an empty
%% supervisor (OTP requires a top process for an application with a callback).
%%
%% Routers are started by the consuming application, see `weberl:start_link/3'.
%%
%% Native records can only be built once their defining module is loaded; in
%% interactive mode nothing loads it implicitly. A consumer that lists `weberl'
%% in its `applications' gets the load before its own code runs. Otherwise
%% call `code:ensure_loaded(weberl_config)' before constructing records.
-module(weberl_app).
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1]).

start(_Type, _Args) ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok = weberl_live_guard:init(),
    supervisor:start_link({local, weberl_sup}, ?MODULE, []).

stop(_State) -> ok.

%% `weberl_live' is the `pg' scope that finds live sessions by page id and
%% owner; it must start before the session supervisor.
init([]) ->
    Children = [#{id => weberl_live_pg,
                  start => {pg, start_link, [weberl_live]},
                  type => worker},
                #{id => weberl_live_sup,
                  start => {weberl_live_sup, start_link, []},
                  type => supervisor}],
    {ok, {#{strategy => one_for_one}, Children}}.
