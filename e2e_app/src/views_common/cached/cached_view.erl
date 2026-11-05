%% GET /cached  -- a live page whose handler sets its own cache-control, which is
%% kept (the framework only logs that it allows shared caching).
-module(cached_view).
-behaviour(weberl_handler).
-weberl_page(one_way).

-export([handle/1]).

handle(_Request) ->
    weberl_response:with_header(
      <<"cache-control">>, <<"public, max-age=60">>,
      weberl_response:html(200, <<"<!DOCTYPE html><html><body><h1>Cached</h1></body></html>">>)).
