%% GET /_test/publish?topic=T&event=E&data=D -> publishes D as event E to topic
%% T. An event named "update" also becomes the value a new subscriber of
%% /topics gets as its snapshot. Only the test app serves it.
-module(e2e_publish).
-behaviour(weberl_handler).

-export([handle/1]).

handle(Request) ->
    {ok, Params} = weberl_request:query_params(Request),
    Get = fun(Key, Default) -> case lists:keyfind(Key, 1, Params) of
                                   {_, V} when is_binary(V) -> V;
                                   _ -> Default
                               end end,
    Topic = Get(<<"topic">>, <<"/topics">>),
    Event = Get(<<"event">>, <<"update">>),
    Data = Get(<<"data">>, <<>>),
    Event =:= <<"update">> andalso persistent_term:put({e2e_app, topic_value}, Data),
    ok = weberl_live:publish(Topic, Event, Data),
    weberl_response:text(200, <<"ok">>).
