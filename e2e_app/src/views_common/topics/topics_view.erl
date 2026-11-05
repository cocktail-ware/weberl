%% GET /topics  -- a page without a session that follows a topic (its default
%% topic, the route path "/topics"). A new subscriber gets the current value as
%% a snapshot; /_test/publish changes it and publishes the update.
-module(topics_view).
-behaviour(weberl_handler).
-weberl_page(one_way).
-weberl_route(#{session => false}).

-export([handle/1, handle_subscribe/2]).

handle(_Request) ->
    weberl_response:html(200, <<"<!DOCTYPE html><html><body><h1>Topics</h1></body></html>">>).

handle_subscribe(<<"/topics">>, _Page) ->
    {snapshot, <<"snapshot">>, persistent_term:get({e2e_app, topic_value}, <<"initial">>)};
handle_subscribe(_Topic, _Page) ->
    ok.
