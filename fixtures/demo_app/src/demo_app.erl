%% Example consumer of weberl.
-module(demo_app).
-export([config/1, table/1]).

-import_record(weberl_config, [router, filesystem_router]).

%% AppDir: directory containing this application's src/.
config(AppDir) ->
    #router{
        filesystem = [#filesystem_router{root = filename:join(AppDir, "src/views"),
                                         prefix = "/"}],
        modules = [demo_app_router]
    }.

table(AppDir) ->
    weberl:build(config(AppDir)).
