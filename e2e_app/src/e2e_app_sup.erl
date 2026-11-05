-module(e2e_app_sup).
-behaviour(supervisor).

-import_record(weberl_config, [router, filesystem_router, listener]).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% The same pages (same URLs, same behaviour) in two builds, so the browser specs
%% run unchanged against both (E2E_VARIANT, set by test/e2e/run.sh):
%%   plain    every page is a full HTML template (views_plain)
%%   layouts  the same pages as views of a layout, with their scripts in its
%%            head slot (views_layouts, layouts/main.weberl)
%% views_common are the pages without a template, the same in both.
router("plain", Src) ->
    #router{filesystem = roots(Src, ["views_common", "views_plain"]),
            modules = [e2e_app_router]};
router("layouts", Src) ->
    #router{filesystem = roots(Src, ["views_common", "views_layouts"]),
            modules = [e2e_app_router],
            layouts = [filename:join(Src, "layouts")]};
router(Other, _Src) ->
    error({unknown_e2e_variant, Other}).

roots(Src, Dirs) ->
    [#filesystem_router{root = filename:join(Src, D), prefix = "/"} || D <- Dirs].

init([]) ->
    Src = filename:join(code:lib_dir(e2e_app), "src"),
    Router = router(os:getenv("E2E_VARIANT", "plain"), Src),
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
