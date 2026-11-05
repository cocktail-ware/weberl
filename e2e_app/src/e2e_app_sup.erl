-module(e2e_app_sup).
-behaviour(supervisor).

-import_record(weberl_config, [router, filesystem_router, listener]).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ViewsRoot = filename:join(code:lib_dir(e2e_app), "src/views"),
    Router = #router{
        filesystem = [#filesystem_router{root = ViewsRoot, prefix = "/"}],
        modules = [e2e_app_router]
    },
    Port = list_to_integer(os:getenv("E2E_PORT", "8443")),
    Listener = #listener{
        adapter = weberl_roadrunner,
        port = Port,
        options = #{tls => [{certfile, os:getenv("E2E_CERT", "/app/test/node/certs/server.pem")},
                            {keyfile, os:getenv("E2E_KEY", "/app/test/node/certs/server.key")}],
                    protocols => [http1, http2]},
        static = [{"/static", {priv, e2e_app, "static"}}]
    },
    {ok, {#{strategy => one_for_one},
          [weberl:child_spec(e2e_web, Router, Listener)]}}.
