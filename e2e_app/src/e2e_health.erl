-module(e2e_health).
-behaviour(weberl_handler).

-export([handle/1]).

handle(_Request) ->
    weberl_response:text(200, <<"ok">>).
