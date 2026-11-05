%% GET /_test/stats -> {"sessions": N, "websockets": N, "streams": N}: what this
%% node holds right now (weberl_live:stats/0). With ?handler=Module it also has
%% "sessions_of": how many of the sessions belong to pages of that handler. Only
%% the test app serves it.
-module(e2e_stats).
-behaviour(weberl_handler).

-export([handle/1]).

handle(Request) ->
    Stats = weberl_live:stats(),
    {ok, Params} = weberl_request:query_params(Request),
    Body = case lists:keyfind(<<"handler">>, 1, Params) of
               {_, Handler} when is_binary(Handler) -> Stats#{sessions_of => sessions_of(Handler)};
               _ -> Stats
           end,
    weberl_response:with_header(
      <<"content-type">>, <<"application/json">>,
      weberl_response:with_header(<<"cache-control">>, <<"no-store">>,
                                  weberl_response:text(200, json:encode(Body)))).

sessions_of(Handler) ->
    length([Id || {page, Id} <- pg:which_groups(weberl_live),
                  handled_by(Id, Handler)]).

handled_by(Id, Handler) ->
    try weberl_live:info(Id) of
        {ok, #{handler := Module}} when is_atom(Module), Module =/= undefined ->
            atom_to_binary(Module) =:= Handler;
        _ ->
            false
    catch
        _:_ -> false
    end.
