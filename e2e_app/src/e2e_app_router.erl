%% Declarative routes of the app under test.
-module(e2e_app_router).
-export([routes/0]).

routes() ->
    [
        {"/health", e2e_health},
        %% what the framework holds (connections, sessions), for assertions
        {"/_test/stats", e2e_stats},
        {"/_test/publish", e2e_publish}
    ].
