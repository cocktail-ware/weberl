%% @doc The single Roadrunner handler used for every Weberl route.
%%
%% The listener is started with `routes => {weberl_roadrunner_handler, Table}',
%% so the route table arrives as `roadrunner_req:state/1'. Intentionally no
%% `-behaviour(roadrunner_handler)': that would make this module depend on
%% Roadrunner at compile time.
-module(weberl_roadrunner_handler).

-export([handle/1]).

handle(Req) ->
    Table = roadrunner_req:state(Req),
    Response = weberl_dispatch:dispatch(weberl_roadrunner_convert:request(Req), Table),
    {weberl_roadrunner_convert:response(Response), Req}.
