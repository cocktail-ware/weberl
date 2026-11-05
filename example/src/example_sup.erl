%% The application decides when the Weberl router starts: it is just a child of
%% this supervisor.
-module(example_sup).
-behaviour(supervisor).

-import_record(weberl_config, [router, filesystem_router, listener]).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ViewsRoot = filename:join(code:lib_dir(example), "src/views"),
    Router = #router{
        filesystem = [#filesystem_router{root = ViewsRoot, prefix = "/"}],
        modules = [example_router],
        layouts = [filename:join(code:lib_dir(example), "src/layouts")]
    },
    Listener = #listener{
        adapter = weberl_roadrunner,
        port = application:get_env(example, port, 8080),
        %% GET /static/site.css -> example/priv/static/site.css
        static = [{"/static", {priv, example, "static"}}]
    },
    {ok, {#{strategy => one_for_one},
          [weberl:child_spec(example_web, Router, Listener)]}}.
