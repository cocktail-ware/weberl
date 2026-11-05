%% @doc Small URL checks for redirect targets.
%%
%% An open redirect sends a user to an attacker's site through a link on yours,
%% typically a `next' parameter after login. {@link local/1} answers whether a
%% target is a path on this site, the only kind that is safe to take from the
%% client.
-module(weberl_url).

-export([local/1]).

%% @doc `true' for a path on this site: it starts with a single `/' and not with
%% `//' or `/\' (browsers read both as a host), and has no control characters
%% (`\r', `\n', tabs, which browsers strip, and so can hide a second slash).
%% Relative paths (`next', `../x') and absolute URLs (`https://...',
%% `javascript:...') are `false'. Input that is not a string is `false'.
-spec local(iodata() | term()) -> boolean().
local(Target) when is_binary(Target); is_list(Target) ->
    try iolist_to_binary(Target) of
        <<"/", Rest/binary>> -> not second_is_host(Rest) andalso clean(Rest);
        _ -> false
    catch
        error:badarg -> false
    end;
local(_) -> false.

second_is_host(<<"/", _/binary>>) -> true;
second_is_host(<<"\\", _/binary>>) -> true;
second_is_host(_) -> false.

clean(Bin) ->
    lists:all(fun(C) -> C > 31 andalso C =/= 127 end, binary_to_list(Bin)).
