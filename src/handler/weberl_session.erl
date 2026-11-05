%% @doc The session: a map kept in one encrypted, authenticated cookie.
%%
%% Weberl does not own logins. It gives the application a safe place to keep what
%% it needs between requests (a user id, a "remember me" marker, a cart...); what
%% goes in, and how it is used, is the application's. Users work with
%% {@link weberl_request:session/1} and the session functions of
%% {@link weberl_response}; this module is the machinery behind them.
%%
%% == The cookie ==
%% `weberl_session' (`__Host-weberl_session' with `secure_cookies'), `HttpOnly',
%% `SameSite=Lax', `Path=/'. The value is `base64url(IV ++ Tag ++ Ciphertext)',
%% ChaCha20-Poly1305 under a key derived from `live_secret' for this purpose
%% only. The client can neither read nor change it. The plaintext is
%% `{1, Expires, Map}' as an Erlang term (`term_to_binary', compressed), read back
%% with `binary_to_term(..., [safe])' once it has authenticated: any term that
%% survives that works, but funs, pids and references do not belong in a session.
%%
%% == Size ==
%% Browsers keep about 4 KB per cookie. `session_warn_bytes' (default 3000) logs a
%% warning when a session grows past it; `session_max_bytes' (default 3800, never
%% more than 4096) is a hard limit: a response that would exceed it is a logged
%% 500, because silently losing a login is worse than failing loudly. Both count
%% the cookie name and value.
%%
%% == Lifetime ==
%% `session_ttl' (seconds, default two days). The expiry is absolute: it is stored
%% inside the encrypted payload (and as the cookie's `Max-Age'), set when the
%% session is created and kept when it is changed, so a session does not live
%% longer by being used. `weberl_response:set_session/2', `reset_session/1' and
%% `session_ttl/2' start a new lifetime (a "remember me" is
%% `session_ttl(Response, 30 * 86400)'). `infinity' has no server-side expiry; the
%% cookie's `Max-Age' is then 400 days, the longest a browser keeps a cookie.
%%
%% == Limits to know ==
%% There is no server-side record, so a session cannot be revoked: a stolen cookie
%% works until it expires. An application that needs revocation keeps an id or a
%% version in the session and checks it against its own storage. Without a
%% configured `live_secret' the key is generated at node start, so a restart ends
%% every session (a warning is logged the first time a session is written).
%%
%% == Loading ==
%% A response starts a session change from the request's session. By default
%% dispatch makes the request available to the handler's process, so
%% `weberl_response:put_session/3' and friends load it by themselves. That
%% convenience is behind the internal setting `session_autoload' (default `true');
%% without it, call `weberl_response:load_session(Response, Request)' first.
-module(weberl_session).

-include_lib("kernel/include/logger.hrl").

-export([cookie_name/0, read/1, encode/2, decode/1, default_ttl/0,
         run/2, ambient/0, finalize/2]).

-define(AMBIENT, {?MODULE, request}).
-define(LABEL, <<"weberl-session">>).
-define(IV_BYTES, 12).
-define(TAG_BYTES, 16).
-define(FOREVER, 400 * 86400).
-define(BROWSER_LIMIT, 4096).

-spec cookie_name() -> binary().
cookie_name() ->
    case weberl_cookie:secure() of
        true -> <<"__Host-weberl_session">>;
        false -> <<"weberl_session">>
    end.

-spec default_ttl() -> pos_integer().
default_ttl() ->
    case application:get_env(weberl, session_ttl, 2 * 86400) of
        N when is_integer(N), N > 0 -> N;
        _ -> 2 * 86400
    end.

%% @doc The session in the request's cookie and when it expires, or `none' when
%% the cookie is missing, not ours, tampered with or expired.
-spec read(weberl_request:t()) -> {map(), integer() | infinity} | none.
read(Request) ->
    case weberl_request:cookie(Request, cookie_name()) of
        {ok, Value} ->
            case decode(Value) of
                {ok, Map, Expires} -> {Map, Expires};
                error -> none
            end;
        error ->
            none
    end.

%% @doc The cookie value for a session map.
-spec encode(map(), integer() | infinity) -> binary().
encode(Map, Expires) ->
    Plain = term_to_binary({1, Expires, Map}, [compressed]),
    IV = crypto:strong_rand_bytes(?IV_BYTES),
    {Cipher, Tag} = crypto:crypto_one_time_aead(chacha20_poly1305, key(), IV, Plain, ?LABEL,
                                                ?TAG_BYTES, true),
    base64:encode(<<IV/binary, Tag/binary, Cipher/binary>>, #{mode => urlsafe, padding => false}).

%% @doc Decrypt a cookie value. `error' for anything that is not an unexpired
%% session made by this key.
-spec decode(binary()) -> {ok, map(), integer() | infinity} | error.
decode(Value) ->
    try base64:decode(Value, #{mode => urlsafe, padding => false}) of
        <<IV:?IV_BYTES/binary, Tag:?TAG_BYTES/binary, Cipher/binary>> ->
            case crypto:crypto_one_time_aead(chacha20_poly1305, key(), IV, Cipher, ?LABEL, Tag, false) of
                Plain when is_binary(Plain) -> open(Plain);
                _ -> error
            end;
        _ ->
            error
    catch
        error:_ -> error
    end.

open(Plain) ->
    try binary_to_term(Plain, [safe]) of
        {1, Expires, Map} when is_map(Map) ->
            case expired(Expires) of
                true -> error;
                false -> {ok, Map, Expires}
            end;
        _ ->
            error
    catch
        error:_ -> error
    end.

expired(infinity) -> false;
expired(Expires) when is_integer(Expires) -> Expires =< os:system_time(second);
expired(_) -> true.

key() -> weberl_sign:key(?LABEL).

%% ---------------------------------------------------------------------
%% Ambient request (the automatic loading)

%% @doc Run `Fun' with `Request' available to the session functions of
%% `weberl_response' in this process (see "Loading" above). Dispatch wraps every
%% handler call with it.
-spec run(weberl_request:t(), fun(() -> Result)) -> Result.
run(Request, Fun) ->
    case autoload() of
        false ->
            Fun();
        true ->
            Previous = erlang:put(?AMBIENT, Request),
            try Fun()
            after
                case Previous of
                    undefined -> erlang:erase(?AMBIENT);
                    _ -> erlang:put(?AMBIENT, Previous)
                end
            end
    end.

%% @doc The request of the running handler, when automatic loading is on.
-spec ambient() -> {ok, weberl_request:t()} | none.
ambient() ->
    case autoload() andalso erlang:get(?AMBIENT) of
        false -> none;
        undefined -> none;
        Request -> {ok, Request}
    end.

%% Not a public setting yet: later it will be switchable per route and globally.
autoload() ->
    application:get_env(weberl, session_autoload, true) =/= false.

%% ---------------------------------------------------------------------
%% Writing the cookie

%% @doc Add the `set-cookie' for the response's session, when the handler changed
%% it. An empty session deletes the cookie.
-spec finalize(weberl_request:t(), weberl_response:t()) ->
    {ok, weberl_response:t()} | {error, term()}.
finalize(Request, Response) ->
    case weberl_response:session_state(Response) of
        undefined ->
            {ok, Response};
        {Map, _Mode} when map_size(Map) =:= 0 ->
            {ok, weberl_response:delete_cookie(Response, cookie_name(), cookie_options(#{}))};
        {Map, Mode} ->
            Now = os:system_time(second),
            Expires = expires(Mode, weberl_response:session_ttl(Response), Request, Now),
            Value = encode(Map, Expires),
            Name = cookie_name(),
            Size = byte_size(Name) + 1 + byte_size(Value),
            case check_size(Size) of
                ok ->
                    warn_generated_key(),
                    {ok, weberl_response:set_cookie(Response, Name, Value,
                                                    cookie_options(#{max_age => max_age(Expires, Now)}))};
                {error, _} = Error ->
                    Error
            end
    end.

expires(_Mode, infinity, _Request, _Now) -> infinity;
expires(_Mode, Ttl, _Request, Now) when is_integer(Ttl) -> Now + Ttl;
expires(fresh, undefined, _Request, Now) -> Now + default_ttl();
expires(continue, undefined, Request, Now) ->
    case read(Request) of
        {_, Expires} -> Expires;
        none -> Now + default_ttl()
    end.

max_age(infinity, _Now) -> ?FOREVER;
max_age(Expires, Now) -> max(Expires - Now, 0).

cookie_options(Extra) ->
    Extra#{secure => weberl_cookie:secure(), http_only => true, same_site => lax, path => <<"/">>}.

check_size(Size) ->
    Max = min(limit(session_max_bytes, 3800), ?BROWSER_LIMIT),
    Warn = limit(session_warn_bytes, 3000),
    if
        Size > Max ->
            {error, {session_too_large, Size, Max}};
        Size > Warn ->
            ?LOG_WARNING(#{what => session_large, bytes => Size, warn_at => Warn, max => Max}),
            ok;
        true ->
            ok
    end.

limit(Key, Default) ->
    case application:get_env(weberl, Key, Default) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    end.

%% Once per node start: sessions written under a generated key end at a restart.
warn_generated_key() ->
    Key = {?MODULE, warned_generated_key},
    case weberl_sign:configured() orelse persistent_term:get(Key, false) of
        true ->
            ok;
        false ->
            persistent_term:put(Key, true),
            ?LOG_WARNING(#{what => session_key_generated,
                           hint => "set live_secret, or a restart ends every session"})
    end.
