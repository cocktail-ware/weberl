%% @doc `Set-Cookie' serialization (RFC 6265), independent of any transport.
%%
%% Used by {@link weberl_response:set_cookie/4}. Every caller supplied binary is
%% checked against the RFC grammar first, and a violation raises instead of
%% reaching the wire, where a `;' or a line break in a value echoed from user
%% input would smuggle attributes or split the header:
%% <ul>
%%   <li>`{invalid_cookie_name, Name}': empty, or a byte outside an HTTP token;</li>
%%   <li>`{invalid_cookie_value, Value}': a byte outside `cookie-octet' (controls,
%%       space, `"', `,', `;', `\'). Values are written as given: encode
%%       anything else yourself (base64url, percent-encoding);</li>
%%   <li>`{invalid_cookie_attribute, Key, Value}': a `path' or `domain' with a
%%       control character or `;';</li>
%%   <li>`{invalid_cookie_option, Option}': an unknown option, a wrong type, or
%%       `same_site => none' without `secure => true' (browsers drop it).</li>
%% </ul>
%%
%% Options and defaults (the shortest call is the safe one):
%% <ul>
%%   <li>`path' (`<<"/">>'), `domain' (none, so the cookie is host only);</li>
%%   <li>`max_age' (seconds; none, so a session cookie; `0' deletes);</li>
%%   <li>`http_only' (`true'), `secure' (`false': the framework cannot know whether
%%       the site is served over HTTPS; set it in production);</li>
%%   <li>`same_site' (`lax'; `strict' | `lax' | `none').</li>
%% </ul>
-module(weberl_cookie).

-export([serialize/3]).
-export_type([options/0]).

-type options() :: #{path => iodata(), domain => iodata(), max_age => non_neg_integer(),
                     http_only => boolean(), secure => boolean(),
                     same_site => strict | lax | none}.

%% @doc The value of a `set-cookie' header.
-spec serialize(iodata(), iodata(), options()) -> binary().
serialize(Name0, Value0, Opts) when is_map(Opts) ->
    ok = check_options(Opts),
    Name = iolist_to_binary(Name0),
    Value = iolist_to_binary(Value0),
    ok = valid_name(Name),
    ok = valid_value(Value),
    Path = attribute(path, maps:get(path, Opts, <<"/">>)),
    Domain = case Opts of
                 #{domain := D} -> ["; Domain=", attribute(domain, D)];
                 _ -> []
             end,
    MaxAge = case Opts of
                 #{max_age := N} -> ["; Max-Age=", integer_to_binary(N)];
                 _ -> []
             end,
    Secure = flag(secure, false, Opts, "; Secure"),
    HttpOnly = flag(http_only, true, Opts, "; HttpOnly"),
    SameSite = case maps:get(same_site, Opts, lax) of
                   strict -> "; SameSite=Strict";
                   lax -> "; SameSite=Lax";
                   none -> "; SameSite=None"
               end,
    iolist_to_binary([Name, $=, Value, "; Path=", Path, Domain, MaxAge, Secure,
                      HttpOnly, SameSite]).

%% Internal

flag(Key, Default, Opts, Text) ->
    case maps:get(Key, Opts, Default) of
        true -> Text;
        false -> []
    end.

check_options(Opts) ->
    lists:foreach(fun check_option/1, maps:to_list(Opts)),
    case Opts of
        #{same_site := none} ->
            case maps:get(secure, Opts, false) of
                true -> ok;
                false -> erlang:error({invalid_cookie_option, {same_site, none, requires_secure}})
            end;
        _ -> ok
    end.

check_option({path, V}) when is_binary(V); is_list(V) -> ok;
check_option({domain, V}) when is_binary(V); is_list(V) -> ok;
check_option({max_age, N}) when is_integer(N), N >= 0 -> ok;
check_option({http_only, B}) when is_boolean(B) -> ok;
check_option({secure, B}) when is_boolean(B) -> ok;
check_option({same_site, V}) when V =:= strict; V =:= lax; V =:= none -> ok;
check_option(Other) -> erlang:error({invalid_cookie_option, Other}).

%% RFC 9110 `token'.
valid_name(<<>>) -> erlang:error({invalid_cookie_name, <<>>});
valid_name(Name) ->
    case lists:all(fun token_char/1, binary_to_list(Name)) of
        true -> ok;
        false -> erlang:error({invalid_cookie_name, Name})
    end.

token_char(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 -> true;
token_char(C) -> lists:member(C, "!#$%&'*+-.^_`|~").

%% RFC 6265 `cookie-octet': printable ASCII except space, DQUOTE, comma,
%% semicolon and backslash. An empty value is allowed.
valid_value(Value) ->
    case lists:all(fun value_char/1, binary_to_list(Value)) of
        true -> ok;
        false -> erlang:error({invalid_cookie_value, Value})
    end.

value_char(C) ->
    C > 32 andalso C < 127 andalso C =/= $" andalso C =/= $, andalso C =/= $;
        andalso C =/= $\\.

%% Header injection safety only, not the full grammar of each attribute.
attribute(Key, Value0) ->
    Value = iolist_to_binary(Value0),
    case Value =/= <<>> andalso lists:all(fun(C) -> C > 31 andalso C =/= 127 andalso C =/= $; end,
                                          binary_to_list(Value)) of
        true -> Value;
        false -> erlang:error({invalid_cookie_attribute, Key, Value})
    end.
