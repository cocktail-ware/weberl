%% GET /downgrade[?kind=normal|one_way|two_way]  -- a two_way route whose
%% handler narrows the page to the kind in the query.
-module(downgrade_view).
-behaviour(weberl_handler).
-weberl_page(two_way).

-export([handle/1]).

handle(Request) ->
    Response = weberl_response:html(200, <<"<!DOCTYPE html><html><body><h1>Downgrade</h1></body></html>">>),
    {ok, Params} = weberl_request:query_params(Request),
    case lists:keyfind(<<"kind">>, 1, Params) of
        {_, Kind} -> weberl_response:live(Response, binary_to_existing_atom(Kind));
        false -> Response
    end.
