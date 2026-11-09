%% The application decides when the Weberl router starts: it is just a child of
%% this supervisor. In development (`{reload, true}', see config/sys.config) the file
%% reloader is another child: it rebuilds and reloads changed code and calls
%% `weberl:reload/1', so edits to views, templates and layouts show without a restart.
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
    %% the router first: the reloader's hook needs it running
    {ok, {#{strategy => one_for_one},
          [weberl:child_spec(example_web, Router, Listener) | reloader(example_web)]}}.

reloader(Router) ->
    case application:get_env(example, reload, false) of
        true -> [erl_file_reloader:child_spec(reloader_config(Router))];
        false -> []
    end.

%% Paths are relative to the directory the node was started in (the example directory).
reloader_config(Router) ->
    #{watches =>
          [%% sources: build, reload the changed modules (a new view's beam is loaded when
           %% the router reloads)
           {code, #{directories => ["src"], extensions => [".erl", ".hrl"],
                    files => ["rebar.config"],
                    build => {"rebar3", ["compile"]}, load => beams}},
           %% templates and layouts: nothing to build
           {templates, #{directories => ["src/views", "src/layouts"],
                         extensions => [".weberl"]}}],
      %% after every cycle, rebuild the route table and the templates
      on_change => [{weberl, reload, [Router]}]}.
