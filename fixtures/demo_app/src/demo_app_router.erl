-module(demo_app_router).
-export([routes/0]).

routes() ->
    [
        {"/health", health_handler},
        {"/api/users", generic_api_handler},
        {"/api/posts", generic_api_handler},
        %% Shadowed by the filesystem route for /about.
        {"/about", legacy_about_handler}
    ].
