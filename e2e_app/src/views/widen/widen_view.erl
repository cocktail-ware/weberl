%% GET /widen  -- a one_way route whose handler asks for two_way: a bug of the
%% handler, answered with a 500.
-module(widen_view).
-behaviour(weberl_handler).
-weberl_page(one_way).

-export([handle/1]).

handle(_Request) ->
    weberl_response:live(
      weberl_response:html(200, <<"<!DOCTYPE html><html><body><h1>Widen</h1></body></html>">>),
      two_way).
