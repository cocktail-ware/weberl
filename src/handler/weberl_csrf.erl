%% @doc Cross-site request forgery protection, provided by the framework.
%%
%% Dispatch runs {@link check/2} before the handler of every route for the unsafe
%% methods (`POST', `PUT', `PATCH', `DELETE'); `GET', `HEAD' and `OPTIONS' are not
%% checked, so a handler must never change state on them. A route chooses its mode
%% with the route option `csrf':
%% <ul>
%%   <li>`true' (the default): the Origin check and the token check;</li>
%%   <li>`origin': the Origin check only (JSON APIs, webhooks, clients that cannot
%%       carry a token);</li>
%%   <li>`false': nothing. Say so on purpose.</li>
%% </ul>
%% A failed check answers `403' without calling the handler.
%%
%% == Origin check ==
%% A request with an `Origin' header must come from this site: the origin's
%% authority equals the `Host' header (and, on an HTTPS listener, the origin is
%% HTTPS too), or the whole origin is listed in the `csrf_origins' application
%% env of `weberl' (a list of binaries such as `<<"https://app.example">>', for a
%% proxy that rewrites `Host' or a partner site). `Origin: null' is refused. A
%% request without `Origin' passes this check (browsers omit it on some same-origin
%% requests, and clients that are not browsers have no ambient cookies to abuse);
%% the token is what covers it.
%%
%% == Token (signed double submit) ==
%% The browser holds a cookie (`weberl_csrf', or `__Host-weberl_csrf' when the
%% `secure_cookies' env is `true', which also makes it `Secure') with a random nonce
%% and its HMAC, and the page carries the same token in a hidden form field
%% (`_csrf', see {@link weberl_form}) or, for scripts, the `x-csrf-token' header.
%% The request is accepted when both are equal and the HMAC is ours. Another site
%% can make the browser send the cookie but cannot read it or the page, so it
%% cannot supply the matching field. The MAC means a cookie planted by something
%% else (a sibling subdomain) is rejected; `__Host-' also stops that in the
%% browser, so set `secure_cookies' in production.
%%
%% A page that shows a form gets its token with {@link protect/2}, which also sets
%% the cookie when the browser has none.
-module(weberl_csrf).

-export([check/2, verify/1, origin_ok/1, token/1, protect/2,
         cookie_name/0, field_name/0, header_name/0]).
-export_type([mode/0, reason/0]).

-type mode() :: true | origin | false.
-type reason() :: origin_mismatch | no_cookie | invalid_cookie | no_token | token_mismatch.

-define(LABEL, <<"weberl-csrf">>).
-define(NONCE_BYTES, 16).

-spec cookie_name() -> binary().
cookie_name() ->
    case secure() of
        true -> <<"__Host-weberl_csrf">>;
        false -> <<"weberl_csrf">>
    end.

-spec field_name() -> binary().
field_name() -> <<"_csrf">>.

-spec header_name() -> binary().
header_name() -> <<"x-csrf-token">>.

%% @doc What dispatch runs before the handler. `ok' for safe methods and for mode
%% `false'.
-spec check(mode(), weberl_request:t()) -> ok | {error, reason()}.
check(false, _Request) ->
    ok;
check(Mode, Request) ->
    case unsafe(weberl_request:method(Request)) of
        false ->
            ok;
        true ->
            case origin_ok(Request) of
                false -> {error, origin_mismatch};
                true when Mode =:= origin -> ok;
                true -> verify(Request)
            end
    end.

unsafe(<<"POST">>) -> true;
unsafe(<<"PUT">>) -> true;
unsafe(<<"PATCH">>) -> true;
unsafe(<<"DELETE">>) -> true;
unsafe(_) -> false.

%% @doc The Origin check alone (see the module documentation).
-spec origin_ok(weberl_request:t()) -> boolean().
origin_ok(Request) ->
    case weberl_request:header(Request, <<"origin">>) of
        error ->
            true;
        {ok, Origin} ->
            lists:member(Origin, allowed_origins())
                orelse same_site(Origin, Request)
    end.

same_site(Origin, Request) ->
    case {origin_parts(Origin), weberl_request:header(Request, <<"host">>)} of
        {{Scheme, Authority}, {ok, Host}} ->
            Authority =:= string:lowercase(Host) andalso scheme_ok(Scheme, Request);
        _ ->
            false
    end.

%% On an HTTPS listener an `http' origin on the same authority is a downgrade
%% attack (an active attacker can serve a page over HTTP and post it here).
scheme_ok(Scheme, Request) ->
    case maps:get(scheme, weberl_request:meta(Request), undefined) of
        https -> Scheme =:= <<"https">>;
        _ -> true
    end.

origin_parts(Origin) ->
    case binary:split(Origin, <<"://">>) of
        [Scheme, Authority] when Authority =/= <<>> ->
            {string:lowercase(Scheme), string:lowercase(Authority)};
        _ ->
            undefined
    end.

allowed_origins() ->
    [iolist_to_binary(O) || O <- application:get_env(weberl, csrf_origins, [])].

%% @doc Check the token of a request: the cookie must hold one of ours and the
%% request must send the same, in the `x-csrf-token' header or the `_csrf' field of
%% an urlencoded form.
-spec verify(weberl_request:t()) -> ok | {error, no_cookie | invalid_cookie | no_token | token_mismatch}.
verify(Request) ->
    case weberl_request:cookie(Request, cookie_name()) of
        error ->
            {error, no_cookie};
        {ok, Cookie} ->
            case valid(Cookie) of
                false ->
                    {error, invalid_cookie};
                true ->
                    case submitted(Request) of
                        error ->
                            {error, no_token};
                        {ok, Sent} ->
                            case equal(Sent, Cookie) of
                                true -> ok;
                                false -> {error, token_mismatch}
                            end
                    end
            end
    end.

submitted(Request) ->
    case weberl_request:header(Request, header_name()) of
        {ok, Token} ->
            {ok, Token};
        error ->
            case weberl_request:form(Request) of
                {ok, Fields} ->
                    case lists:keyfind(field_name(), 1, Fields) of
                        {_, Token} when is_binary(Token) -> {ok, Token};
                        _ -> error
                    end;
                {error, _} ->
                    error
            end
    end.

%% @doc The token for the page being rendered: the one in the request's cookie when
%% it is ours, otherwise a fresh one. Put it in the page and make sure the browser
%% has the cookie: use {@link protect/2}, which does both.
-spec token(weberl_request:t()) -> binary().
token(Request) ->
    case current(Request) of
        {ok, Token} -> Token;
        error -> fresh()
    end.

%% @doc `protect(Request, fun(Token) -> Response end)': builds the response with the
%% request's token and, when the browser does not have it yet, sets the cookie. The
%% response is marked `cache-control: private, no-store' unless the handler set a
%% `cache-control' itself, because it carries a per-browser token.
-spec protect(weberl_request:t(), fun((binary()) -> weberl_response:t())) -> weberl_response:t().
protect(Request, Build) when is_function(Build, 1) ->
    {Token, Known} = case current(Request) of
                         {ok, T} -> {T, true};
                         error -> {fresh(), false}
                     end,
    Response = Build(Token),
    WithCookie = case Known of
                     true -> Response;
                     false -> weberl_response:set_cookie(Response, cookie_name(), Token, cookie_options())
                 end,
    case weberl_response:header(WithCookie, <<"cache-control">>) of
        error -> weberl_response:with_header(WithCookie, <<"cache-control">>, <<"private, no-store">>);
        {ok, _} -> WithCookie
    end.

%% Session cookie: the token lives as long as the browser session.
cookie_options() ->
    #{secure => secure(), http_only => true, same_site => lax, path => <<"/">>}.

current(Request) ->
    case weberl_request:cookie(Request, cookie_name()) of
        {ok, Cookie} ->
            case valid(Cookie) of
                true -> {ok, Cookie};
                false -> error
            end;
        error ->
            error
    end.

fresh() ->
    Nonce = crypto:strong_rand_bytes(?NONCE_BYTES),
    <<(encode(Nonce))/binary, $., (encode(weberl_sign:mac(?LABEL, Nonce)))/binary>>.

valid(Token) ->
    case binary:split(Token, <<".">>) of
        [Encoded, Mac] ->
            case decode(Encoded) of
                {ok, Nonce} when byte_size(Nonce) =:= ?NONCE_BYTES ->
                    equal(Mac, encode(weberl_sign:mac(?LABEL, Nonce)));
                _ ->
                    false
            end;
        _ ->
            false
    end.

%% Constant time comparison.
equal(A, B) when byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
equal(_, _) ->
    false.

secure() -> weberl_cookie:secure().

encode(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

decode(Bin) ->
    try {ok, base64:decode(Bin, #{mode => urlsafe, padding => false})}
    catch error:_ -> error
    end.
