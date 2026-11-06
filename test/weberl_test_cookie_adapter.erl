%% Test adapter for hand-built requests: parses the `cookie' header itself, so
%% session and CSRF code can be tested without a listener.
-module(weberl_test_cookie_adapter).
-behaviour(weberl_adapter).

-export([validate_options/1, start_listener/3, stop_listener/1, port/1,
         cookies/1, form/1, multipart/1, request/1, request/2]).

validate_options(_) -> ok.
start_listener(Name, _Listener, _Table) -> {ok, Name}.
stop_listener(_) -> ok.
port(_) -> 0.

cookies(Request) ->
    case weberl_request:header(Request, <<"cookie">>) of
        {ok, Header} ->
            [{string:trim(N), string:trim(V)}
             || Pair <- binary:split(Header, <<";">>, [global]),
                [N, V] <- [binary:split(Pair, <<"=">>)]];
        error ->
            []
    end.

form(_) -> {error, no_content_type}.

multipart(_) -> {error, no_content_type}.

%% A GET request carrying these cookies.
request(Cookies) -> request(<<"GET">>, Cookies).

request(Method, Cookies) ->
    Header = iolist_to_binary(lists:join("; ", [[N, "=", V] || {N, V} <- Cookies])),
    weberl_request:new(#{method => Method, path => "/x",
                         headers => [{<<"cookie">>, Header} || Cookies =/= []],
                         meta => #{adapter => ?MODULE}}).
