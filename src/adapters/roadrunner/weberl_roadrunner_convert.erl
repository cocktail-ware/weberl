%% @doc Conversion between Roadrunner request/response terms and Weberl's.
%%
%% Uses only the documented `roadrunner_req' accessors. The Roadrunner request
%% is a map, so nothing here needs Roadrunner headers or records.
-module(weberl_roadrunner_convert).

-export([request/1, response/1]).

%% @doc Roadrunner request map -> `weberl_request'. The body is not touched
%% until `weberl_request:read_body/1' is called.
-spec request(map()) -> weberl_request:t().
request(Req) ->
    weberl_request:new(
      #{method => roadrunner_req:method(Req),
        path => path(roadrunner_req:path(Req)),
        headers => roadrunner_req:headers(Req),
        query => roadrunner_req:qs(Req),
        peer => roadrunner_req:peer(Req),
        body_reader => fun() -> {ok, iolist_to_binary(roadrunner_req:body(Req))} end,
        meta => #{adapter => weberl_roadrunner,
                  raw => Req,
                  listener => roadrunner_req:listener_name(Req),
                  scheme => roadrunner_req:scheme(Req),
                  version => roadrunner_req:version(Req),
                  request_id => roadrunner_req:request_id(Req)}}).

%% @doc `weberl_response' -> Roadrunner `{Status, Headers, Body}'.
-spec response(weberl_response:t()) -> {100..599, [{binary(), binary()}], iodata()}.
response(Response) ->
    {weberl_response:status(Response),
     weberl_response:headers(Response),
     weberl_response:body(Response)}.

%% Route paths are strings; a path that is not valid UTF-8 falls back to its
%% bytes, so it simply will not match any route.
path(Bin) ->
    case unicode:characters_to_list(Bin) of
        L when is_list(L) -> L;
        _ -> binary_to_list(Bin)
    end.
