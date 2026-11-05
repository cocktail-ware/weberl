%% @doc The signing key shared by everything Weberl authenticates with HMAC:
%% live page tokens ({@link weberl_live_guard}) and CSRF tokens ({@link weberl_csrf}).
%%
%% The key is `live_secret' (application env of `weberl', a binary of at least 16
%% bytes). Without it a random key is made on first use and lives as long as the
%% node: every restart invalidates what was signed before, and nodes of a cluster
%% reject each other's signatures. Set it in production.
%%
%% Each use passes its own `Label', so a MAC made for one purpose never verifies
%% for another (a CSRF token cannot be replayed as a page token).
-module(weberl_sign).

-export([init/0, secret/0, mac/2]).

-define(KEY, {weberl_sign, secret}).

%% @doc Make sure the key exists. Called at application start.
-spec init() -> ok.
init() ->
    _ = secret(),
    ok.

%% @doc HMAC-SHA256 of `Data' under the key, domain separated by `Label'.
-spec mac(iodata(), iodata()) -> binary().
mac(Label, Data) ->
    crypto:mac(hmac, sha256, secret(), [Label, 0, Data]).

-spec secret() -> binary().
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
