%% @doc Supervisor of live sessions. Sessions are `temporary': a crashed
%% session is not restarted (the page's beacon would hold a stale id), the
%% browser simply reloads.
-module(weberl_live_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Child = #{id => weberl_live_session,
              start => {weberl_live_session, start_link, []},
              restart => temporary,
              shutdown => 5000,
              type => worker},
    {ok, {#{strategy => simple_one_for_one}, [Child]}}.
