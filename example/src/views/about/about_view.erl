%% GET /about  -- the URL comes from the directory, not from the module name.
-module(about_view).
-behaviour(weberl_handler).

-export([handle/1, weberl_metadata/0]).

weberl_metadata() -> #{layout => main}.

handle(_Request) ->
    weberl_response:html(
      200,
      weberl_template:render(?MODULE, #{title =><<"About">>, since => 2026})).
