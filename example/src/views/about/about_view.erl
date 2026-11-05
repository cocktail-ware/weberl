%% GET /about  -- the URL comes from the directory, not from the module name.
-module(about_view).
-behaviour(weberl_handler).
-weberl_route(#{layout => main}).

-export([handle/1]).

handle(_Request) ->
    weberl_response:html(
      200,
      weberl_template:render(?MODULE, #{title =><<"About">>, since => 2026})).
