%% @doc Client requests over HTTP (`POST /_weberl/request/:id').
%%
%% The way a `one_way' page (or a `two_way' page without a working socket)
%% sends a request to its handler's `handle_request/3'. The body is the JSON
%% request of `weberl_live_wire'; the answer is its JSON answer with an HTTP
%% status (`400' malformed, `404' unknown page, `501' handler without
%% `handle_request/3', `500' it crashed).
-module(weberl_roadrunner_request).

-export([handle/1]).

handle(Req) ->
    case weberl_roadrunner_live:authorize(Req, [~"POST"], request) of
        {ok, Id, Claims} -> post(Req, Id, Claims);
        {error, Response} -> {Response, Req}
    end.

post(Req, Id, Claims) ->
    case roadrunner_req:read_body(Req) of
        {ok, Body, Req2} ->
            case weberl_live_wire:decode_request(iolist_to_binary(Body)) of
                {ok, Request} ->
                    {Status, Json} = weberl_live_wire:run_request(Id, Claims, Request),
                    {weberl_roadrunner_live:json(Status, Json), Req2};
                {error, bad_request} ->
                    {weberl_roadrunner_live:json(400, #{error => ~"bad_request"}), Req2}
            end;
        {error, _} ->
            {weberl_roadrunner_live:json(400, #{error => ~"bad_request"}), Req}
    end.
