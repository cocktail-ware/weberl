%% Declarative routes, next to the ones discovered from src/views.
-module(example_router).
-export([routes/0]).

routes() ->
    [
        {"/health", example_health}
    ].
