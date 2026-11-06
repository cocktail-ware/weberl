%% Test adapter for hand-built requests with a form: `form/1' and `multipart/1' answer from what the
%% request's `meta' holds (`pairs' and `parts'), and `cookies/1' parses the `cookie' header, so form,
%% limits and CSRF code can be tested without a listener. `calls/0' says which callbacks ran.
-module(weberl_test_form_adapter).
-behaviour(weberl_adapter).

-export([validate_options/1, start_listener/3, stop_listener/1, port/1,
         cookies/1, form/1, multipart/1, request/1, calls/0, reset_calls/0]).

validate_options(_) -> ok.
start_listener(Name, _Listener, _Table) -> {ok, Name}.
stop_listener(_) -> ok.
port(_) -> 0.

cookies(Request) -> weberl_test_cookie_adapter:cookies(Request).

form(Request) ->
    record(form),
    case maps:find(pairs, weberl_request:meta(Request)) of
        {ok, Pairs} -> {ok, Pairs};
        error -> {error, unsupported_content_type}
    end.

multipart(Request) ->
    record(multipart),
    case maps:find(parts, weberl_request:meta(Request)) of
        {ok, Parts} -> {ok, Parts};
        error -> {error, unsupported_content_type}
    end.

record(Callback) -> put(?MODULE, [Callback | calls()]).

%% The callbacks that ran in this process, oldest first.
calls() -> case get(?MODULE) of undefined -> []; L -> L end.

reset_calls() -> erase(?MODULE), ok.

%% A request: `method', `path', `query' (binary), `cookies' (`[{N, V}]'), `headers', and the body as
%% `pairs' (urlencoded) or `parts' (multipart: `[{Headers, Body}]'); the content type follows from them.
request(Opts) ->
    Cookies = maps:get(cookies, Opts, []),
    CookieHeader = [{<<"cookie">>, iolist_to_binary(lists:join("; ", [[N, "=", V] || {N, V} <- Cookies]))}
                    || Cookies =/= []],
    Type = case Opts of
               #{parts := _} -> [{<<"content-type">>, <<"multipart/form-data; boundary=B">>}];
               #{pairs := _} -> [{<<"content-type">>, <<"application/x-www-form-urlencoded">>}];
               _ -> []
           end,
    Meta = maps:merge(#{adapter => ?MODULE}, maps:with([pairs, parts], Opts)),
    weberl_request:new(#{method => maps:get(method, Opts, <<"POST">>),
                         path => maps:get(path, Opts, "/x"),
                         query => maps:get(query, Opts, <<>>),
                         headers => CookieHeader ++ Type ++ maps:get(headers, Opts, []),
                         meta => Meta}).
