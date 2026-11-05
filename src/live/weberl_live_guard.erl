%% @doc Credentials and cross-origin checks for the live endpoints.
%%
%% Every live endpoint (stream, WebSocket, long-poll, requests) requires the
%% page token issued when the page was rendered: the beacon tag carries it
%% (`data-weberl-token'). The token is
%% `base64url(Salt ++ Channels ++ Claims ++ HMAC-SHA256(Secret, "weberl-page" ++ PageId ++ Salt ++ Channels ++ Claims))',
%% with a random 8-byte salt per page and `Channels' a one-byte set of the
%% channels the page may use (`sse', `ws', `poll', `request'). It proves the
%% holder was given the page by this server (or by a node sharing its secret);
%% the page id alone, which appears in URLs and logs, is not enough. It is
%% bound to one page id, so it cannot be moved to another page, and the channel
%% set is covered by the MAC, so it cannot be widened: each endpoint verifies
%% its own channel, e.g. a `two_way' page's token never opens the SSE stream and
%% a page whose long-poll fallback is off carries no `poll'.
%%
%% `Claims' say what the server needs to know about the page without a session
%% to ask (session-less pages have none): its kind, whether it has a session,
%% its handler module and the topics it may subscribe to (see {@link claims/0}).
%% They are covered by the MAC too, so a page cannot grant itself topics.
%% Layout: `Flags:8' (bit 0 session, bit 1 two_way), `HandlerSize:16' and the
%% handler name, `TopicCount:8' and per topic `Size:16' and the topic.
%%
%% The secret is `live_secret' (application env of `weberl', a binary of at
%% least 16 bytes) when set, otherwise random bytes generated once per node
%% start. Nodes of a cluster that must accept each other's tokens need to
%% share a configured secret.
%%
%% {@link origin_ok/1} is a second, browser-only layer: when a request carries
%% an `Origin' header, its authority must equal the `Host' header. Requests
%% without `Origin' (not sent by browsers for same-origin GETs, or sent by
%% non-browser clients) pass this check; the token is what authenticates them.
-module(weberl_live_guard).

-export([init/0, issue/2, issue/3, verify/3, claims/3, origin_ok/1]).
-export_type([channel/0, claims/0]).

-type channel() :: sse | ws | poll | request.
%% What a token vouches for besides the page id and channels.
-type claims() :: #{kind := one_way | two_way,
                    session := boolean(),
                    handler := module() | undefined,
                    topics := [binary()]}.

-define(SALT_BYTES, 8).
-define(MAC_BYTES, 32).
-define(KEY, {weberl_live_guard, secret}).
-define(LABEL, <<"weberl-page">>).

%% @doc Make sure the secret exists. Called at application start; the other
%% functions also create it on first use.
-spec init() -> ok.
init() ->
    _ = secret(),
    ok.

%% @doc The token for a page, valid for the given channels only.
-spec issue(weberl_live:page_id(), [channel()]) -> binary().
issue(PageId, Channels) ->
    issue(PageId, Channels, #{}).

%% @doc The token for a page, with claims (missing keys default to a
%% `one_way' page with a session, no handler and no topics). The topics must
%% have been checked with `weberl_live:check_topics/1'.
-spec issue(weberl_live:page_id(), [channel()], map()) -> binary().
issue(PageId, Channels, Claims) when is_binary(PageId), is_list(Channels), is_map(Claims) ->
    Salt = crypto:strong_rand_bytes(?SALT_BYTES),
    Mask = mask(Channels),
    Encoded = encode_claims(maps:merge(#{kind => one_way, session => true,
                                         handler => undefined, topics => []}, Claims)),
    encode(<<Salt/binary, Mask, Encoded/binary, (mac(PageId, Salt, Mask, Encoded))/binary>>).

%% @doc Is `Token' a token issued for `PageId' that allows `Channel'.
%% Constant-time MAC comparison.
-spec verify(weberl_live:page_id(), channel(), term()) -> boolean().
verify(PageId, Channel, Token) ->
    case claims(PageId, Channel, Token) of
        {ok, _} -> true;
        error -> false
    end.

%% @doc Like {@link verify/3}, and returns what the token vouches for.
-spec claims(weberl_live:page_id(), channel(), term()) -> {ok, claims()} | error.
claims(PageId, Channel, Token) when is_binary(PageId), is_binary(Token) ->
    case decode(Token) of
        {ok, <<Salt:?SALT_BYTES/binary, Mask, Rest/binary>>} when byte_size(Rest) >= ?MAC_BYTES ->
            Size = byte_size(Rest) - ?MAC_BYTES,
            <<Encoded:Size/binary, Mac:?MAC_BYTES/binary>> = Rest,
            case crypto:hash_equals(mac(PageId, Salt, Mask, Encoded), Mac)
                 andalso Mask band bit(Channel) =/= 0 of
                true -> decode_claims(Encoded);
                false -> error
            end;
        _ ->
            error
    end;
claims(_PageId, _Channel, _Token) ->
    error.

%% @doc Origin check for request headers (`[{LowercaseName, Value}]').
-spec origin_ok([{binary(), binary()}]) -> boolean().
origin_ok(Headers) ->
    case lists:keyfind(<<"origin">>, 1, Headers) of
        false ->
            true;
        {_, Origin} ->
            case lists:keyfind(<<"host">>, 1, Headers) of
                {_, Host} -> authority(Origin) =:= lower(Host);
                false -> false
            end
    end.

%% ---------------------------------------------------------------------

mac(PageId, Salt, Mask, Claims) ->
    crypto:mac(hmac, sha256, secret(), [?LABEL, PageId, Salt, Mask, Claims]).

encode_claims(#{kind := Kind, session := Session, handler := Handler, topics := Topics}) ->
    Flags = (case Session of true -> 1; false -> 0 end)
        bor (case Kind of two_way -> 2; one_way -> 0 end),
    Name = case Handler of undefined -> <<>>; _ -> atom_to_binary(Handler) end,
    <<Flags, (byte_size(Name)):16, Name/binary, (length(Topics)),
      (<< <<(byte_size(T)):16, T/binary>> || T <- Topics >>)/binary>>.

%% The bytes are authentic (the MAC matched), but parse strictly anyway.
decode_claims(<<Flags, NameSize:16, Name:NameSize/binary, Count, Topics/binary>>) ->
    case decode_topics(Count, Topics, []) of
        {ok, List} ->
            case handler(Name) of
                {ok, Handler} ->
                    {ok, #{kind => case Flags band 2 of 0 -> one_way; _ -> two_way end,
                           session => Flags band 1 =:= 1,
                           handler => Handler,
                           topics => List}};
                error ->
                    error
            end;
        error ->
            error
    end;
decode_claims(_) ->
    error.

decode_topics(0, <<>>, Acc) -> {ok, lists:reverse(Acc)};
decode_topics(N, <<Size:16, Topic:Size/binary, Rest/binary>>, Acc) when N > 0 ->
    decode_topics(N - 1, Rest, [Topic | Acc]);
decode_topics(_, _, _) -> error.

handler(<<>>) -> {ok, undefined};
handler(Name) ->
    try {ok, binary_to_existing_atom(Name)}
    catch error:badarg -> error
    end.

mask(Channels) -> lists:foldl(fun(C, Acc) -> Acc bor bit(C) end, 0, Channels).

bit(sse) -> 1;
bit(ws) -> 2;
bit(poll) -> 4;
bit(request) -> 8.

secret() ->
    case application:get_env(weberl, live_secret) of
        {ok, Secret} when is_binary(Secret), byte_size(Secret) >= 16 ->
            Secret;
        _ ->
            case persistent_term:get(?KEY, undefined) of
                undefined ->
                    Secret = crypto:strong_rand_bytes(32),
                    ok = persistent_term:put(?KEY, Secret),
                    Secret;
                Secret ->
                    Secret
            end
    end.

encode(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

decode(Token) ->
    try {ok, base64:decode(Token, #{mode => urlsafe, padding => false})}
    catch error:_ -> error
    end.

%% `scheme://authority' -> `authority' (lower case); anything else (including
%% the opaque origin `null') never equals a host.
authority(Origin) ->
    case binary:split(Origin, <<"://">>) of
        [_Scheme, Authority] -> lower(Authority);
        _ -> undefined
    end.

lower(Bin) -> string:lowercase(Bin).
