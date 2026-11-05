%% @doc Shared parts of the live endpoints under `/_weberl' (stream, WebSocket,
%% long-poll, requests): method check, credentials and response shapes.
%%
%% The credential is the page token (`weberl_live_guard', which also says
%% which channels the page may use), sent in the
%% `x-weberl-token' header or, where a browser API cannot set headers
%% (`EventSource', `WebSocket'), the `t' query parameter. It is checked before
%% the session is looked up, so an unknown page and a forged token are
%% indistinguishable (403); browser requests must also pass the origin check.
-module(weberl_roadrunner_live).

-include_lib("kernel/include/logger.hrl").

-export([authorize/3, connect/2, json/2, text/2, token/1]).

-type response() :: {pos_integer(), [{binary(), binary()}], binary()}.
-type outcome() :: {ok, weberl_live:page_id(), weberl_live_guard:claims()} | {error, response()}.

%% @doc Check method, token (for `Channel'), origin and that the page exists
%% (its session does; a session-less page is just its token). `Methods' are the
%% allowed methods. On success returns the page id and the token's claims
%% (`weberl_live_guard:claims()').
-spec authorize(map(), [binary()], weberl_live_guard:channel()) -> outcome().
authorize(Req, Methods, Channel) ->
    case method(Req, Methods) of
        ok ->
            case roadrunner_req:bindings(Req) of
                #{~"id" := Id} -> check(Req, Id, Channel);
                _ -> {error, text(404, ~"Not Found")}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Check method and origin of an endpoint that is not about one page (the
%% multiplexed WebSocket): its pages present their own tokens when they
%% subscribe.
-spec connect(map(), [binary()]) -> ok | {error, response()}.
connect(Req, Methods) ->
    case method(Req, Methods) of
        ok ->
            case weberl_live_guard:origin_ok(headers(Req)) of
                true -> check_version(Req, ws, undefined);
                false -> {error, text(403, ~"Forbidden")}
            end;
        {error, _} = Error ->
            Error
    end.

%% A connection declares the version of the scripts it runs (`v'); one that
%% declares another (or none) is logged, not refused: a stale script may be an
%% honest cached page or someone using an outdated one on purpose. Only the
%% requests that start a connection carry it (the stream, the socket, a poll
%% asking for snapshots), so a request without `v' is not a mismatch.
check_version(Req, Channel, Page) ->
    Query = roadrunner_req:parse_qs(Req),
    case carries_version(Channel, Query) of
        false ->
            ok;
        true ->
            Expected = integer_to_binary(weberl_live:client_version()),
            case lists:keyfind(~"v", 1, Query) of
                {_, Expected} ->
                    ok;
                Other ->
                    Declared = case Other of
                                   {_, V} when is_binary(V) -> binary:part(V, 0, min(32, byte_size(V)));
                                   _ -> undefined
                               end,
                    ?LOG_WARNING(#{what => live_client_version_mismatch, channel => Channel,
                                   page => Page, declared => Declared,
                                   expected => weberl_live:client_version()}),
                    ok
            end
    end.

carries_version(poll, Query) -> lists:keymember(~"snapshot", 1, Query);
carries_version(request, _Query) -> false;
carries_version(_Channel, _Query) -> true.

method(Req, Methods) ->
    case lists:member(roadrunner_req:method(Req), Methods) of
        true ->
            ok;
        false ->
            Allow = iolist_to_binary(lists:join(~", ", Methods)),
            {error, text(405, ~"Method Not Allowed", [{~"allow", Allow}])}
    end.

check(Req, Id, Channel) ->
    case weberl_live_guard:claims(Id, Channel, token(Req)) of
        {ok, Claims} ->
            case weberl_live_guard:origin_ok(headers(Req)) of
                true -> check_version(Req, Channel, Id), exists(Id, Claims);
                false -> {error, text(403, ~"Forbidden")}
            end;
        error ->
            {error, text(403, ~"Forbidden")}
    end.

exists(Id, #{session := true} = Claims) ->
    case weberl_live:info(Id) of
        {ok, _Info} -> {ok, Id, Claims};
        {error, not_found} -> {error, text(404, ~"Not Found")}
    end;
exists(Id, Claims) ->
    {ok, Id, Claims}.

%% @doc The token a request carries, `undefined' if none.
-spec token(map()) -> binary() | undefined.
token(Req) ->
    case lists:keyfind(~"x-weberl-token", 1, headers(Req)) of
        {_, Token} ->
            Token;
        false ->
            case lists:keyfind(~"t", 1, roadrunner_req:parse_qs(Req)) of
                {_, Token} when is_binary(Token) -> Token;
                _ -> undefined
            end
    end.

json(Status, Term) ->
    {Status, [{~"content-type", ~"application/json"}, {~"cache-control", ~"no-store"}],
     json:encode(Term)}.

text(Status, Body) ->
    text(Status, Body, []).

text(Status, Body, Extra) ->
    {Status, [{~"content-type", ~"text/plain"}, {~"cache-control", ~"no-store"} | Extra],
     iolist_to_binary(Body)}.

headers(Req) ->
    [{string:lowercase(N), V} || {N, V} <- roadrunner_req:headers(Req)].
