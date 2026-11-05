%% GET /regions  -- regions of every kind, all rendered from one assign (`n').
%% The request "bump" increments it, so the session re-renders all three.
-module(regions_view).
-behaviour(weberl_handler).
-weberl_page(two_way).

-export([handle/1, handle_request/3]).

handle(Request) ->
    weberl_response:html(200, weberl_live:mount(?MODULE, Request, weberl_view_data:new(#{n => 0}))).

handle_request(<<"bump">>, _Data, #{view := View}) ->
    #{n := N} = weberl_view_data:assigns(View),
    {reply, N + 1, weberl_view_data:with_assigns(#{n => N + 1}, View)}.
