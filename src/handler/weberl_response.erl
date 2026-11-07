%% @doc Weberl-native HTTP response (native record) and constructors.
%%
%% A response is a status code, a header list and a body. Header names are
%% stored as lowercase binaries, values as binaries. The body is `iodata()'.
%%
%% Constructors set a default `content-type':
%% <ul>
%%   <li>{@link html/2}: `text/html; charset=utf-8'</li>
%%   <li>{@link text/2}: `text/plain; charset=utf-8'</li>
%%   <li>{@link binary/2}: `application/octet-stream'</li>
%% </ul>
%% Invalid arguments raise `error:badarg'.
%%
%% Convention: functions that work on a response take it first
%% (`header(Response, Name)', `with_header(Response, Name, Value)'), the same
%% as `weberl_request'.
-module(weberl_response).

-export([new/3, html/2, text/2, binary/2,
         with_header/3, add_header/3, with_body/2, header/2, header_values/2,
         set_cookie/3, set_cookie/4, delete_cookie/2, delete_cookie/3,
         redirect/1, redirect/2, form_error/1,
         load_session/2, put_session/3, delete_session/2, set_session/2, reset_session/1,
         session_ttl/2, session/1, session_get/2, session_state/1, session_ttl/1,
         live/2, live/1,
         status/1, headers/1, body/1,
         normalize/1]).
-export_type([t/0, headers/0]).
-export_record([response]).

-type headers() :: [{binary(), binary()}].

-record #response{
    status :: non_neg_integer(),
    headers = [] :: headers(),
    body = <<>> :: iodata(),
    %% Page kind the handler narrowed the page to, see live/2.
    live = undefined :: undefined | normal | one_way | two_way,
    %% The session this response sets, see the "Session" functions below. `fresh'
    %% starts a new lifetime, `continue' keeps the request session's expiry.
    session = undefined :: undefined | {map(), fresh | continue},
    session_ttl = undefined :: undefined | pos_integer() | infinity
}.

-type t() :: #response{}.

%% @doc Build a response from raw parts. No default headers are added.
-spec new(100..599, [{iodata(), iodata()}], iodata()) -> t().
new(Status, Headers, Body) ->
    check_status(Status),
    check_body(Body),
    #response{status = Status,
              headers = lists:foldl(fun({N, V}, Acc) -> append_header(N, V, Acc) end,
                                    [], Headers),
              body = Body}.

-spec html(100..599, iodata()) -> t().
html(Status, Body) -> typed(Status, "text/html; charset=utf-8", Body).

-spec text(100..599, iodata()) -> t().
text(Status, Body) -> typed(Status, "text/plain; charset=utf-8", Body).

-spec binary(100..599, iodata()) -> t().
binary(Status, Body) -> typed(Status, "application/octet-stream", Body).

%% @doc Set a header, replacing any existing header of the same name
%% (case-insensitive).
-spec with_header(t(), iodata(), iodata()) -> t().
with_header(#response{headers = Hs} = R, Name, Value) ->
    R#response{headers = put_header(Name, Value, Hs)}.

%% @doc Add a header after the existing ones without replacing a header of the
%% same name: for headers that may repeat, such as `set-cookie' (several cookies
%% are several headers). Names and values with control characters raise `badarg'.
-spec add_header(t(), iodata(), iodata()) -> t().
add_header(#response{headers = Hs} = R, Name, Value) ->
    R#response{headers = append_header(Name, Value, Hs)}.

%% @doc Add a cookie to the response (a `set-cookie' header; earlier ones are kept).
%% Same as `set_cookie(Response, Name, Value, #{})': path `/', `HttpOnly',
%% `SameSite=Lax'. See {@link weberl_cookie} for the options and the errors raised
%% for names and values that cannot be sent safely.
-spec set_cookie(t(), iodata(), iodata()) -> t().
set_cookie(Response, Name, Value) ->
    set_cookie(Response, Name, Value, #{}).

-spec set_cookie(t(), iodata(), iodata(), weberl_cookie:options()) -> t().
set_cookie(Response, Name, Value, Opts) ->
    add_header(Response, <<"set-cookie">>, weberl_cookie:serialize(Name, Value, Opts)).

%% @doc Ask the browser to drop a cookie (an empty value with `Max-Age=0'). `Opts'
%% must carry the `path' and `domain' the cookie was set with.
-spec delete_cookie(t(), iodata()) -> t().
delete_cookie(Response, Name) ->
    delete_cookie(Response, Name, #{}).

-spec delete_cookie(t(), iodata(), weberl_cookie:options()) -> t().
delete_cookie(Response, Name, Opts) ->
    set_cookie(Response, Name, <<>>, Opts#{max_age => 0}).

%% @doc The response for an error of `weberl_request:form/1,2', `multipart/1,2' or `files/1,2':
%% `{limit_exceeded, _}' is `413 Payload Too Large', `unsupported_content_type' and
%% `no_content_type' are `415 Unsupported Media Type', anything else (`malformed_multipart',
%% a body the transport could not read) is `400 Bad Request'. A plain text body; build your
%% own response when the form should be shown again.
-spec form_error(term()) -> t().
form_error({limit_exceeded, _}) -> text(413, <<"Payload Too Large">>);
form_error(unsupported_content_type) -> text(415, <<"Unsupported Media Type">>);
form_error(no_content_type) -> text(415, <<"Unsupported Media Type">>);
form_error(_Other) -> text(400, <<"Bad Request">>).

%% @doc A redirect with status `303 See Other', the right answer after a form POST
%% (the browser follows with a GET). See {@link redirect/2}.
-spec redirect(iodata()) -> t().
redirect(Location) -> redirect(303, Location).

%% @doc A redirect with a `location' header and an empty body. `Status' is one of
%% 301, 302, 303, 307, 308. The location must not contain control characters
%% (`badarg'). Weberl does not restrict where it points: when the target comes from
%% the client (`?next=...'), check it first with {@link weberl_url:local/1}.
-spec redirect(301 | 302 | 303 | 307 | 308, iodata()) -> t().
redirect(Status, Location) when Status =:= 301; Status =:= 302; Status =:= 303;
                                Status =:= 307; Status =:= 308 ->
    L = header_value(Location),
    L =/= <<>> orelse erlang:error(badarg),
    #response{status = Status, headers = [{<<"location">>, L}], body = <<>>};
redirect(_Status, _Location) ->
    erlang:error(badarg).

%% ---------------------------------------------------------------------
%% Session (see {@link weberl_session})
%%
%% A response that changes the session carries the whole new map, so reading it
%% back is exact: after `put_session(R, K, V)', `session_get(R, K)' is `{ok, V}'
%% and every other key is still there. The first change starts from the request's
%% session, which dispatch makes available to the handler (or which you load
%% yourself with {@link load_session/2}). Dispatch writes the cookie after the
%% handler returns; a response that never touches the session sends no session
%% cookie.

%% @doc Start from the session in `Request''s cookie. Only needed when automatic
%% loading is off; a response that already holds a session is returned as it is.
-spec load_session(t(), weberl_request:t()) -> t().
load_session(#response{session = undefined} = R, Request) ->
    R#response{session = {weberl_request:session(Request), continue}};
load_session(#response{} = R, _Request) ->
    R.

%% @doc Set `Key' in the session.
-spec put_session(t(), term(), term()) -> t().
put_session(#response{} = R, Key, Value) ->
    {Map, Mode} = session_base(R, put_session),
    R#response{session = {Map#{Key => Value}, Mode}}.

%% @doc Remove `Key' from the session.
-spec delete_session(t(), term()) -> t().
delete_session(#response{} = R, Key) ->
    {Map, Mode} = session_base(R, delete_session),
    R#response{session = {maps:remove(Key, Map), Mode}}.

%% @doc Replace the whole session with `Map' and start a new lifetime (log in).
-spec set_session(t(), map()) -> t().
set_session(#response{} = R, Map) when is_map(Map) ->
    R#response{session = {Map, fresh}}.

%% @doc Empty the session: its cookie is deleted (log out; also the first step of a
%% login, so nothing of an earlier session carries over).
%%
%% The one exception is the flash this response itself put ("Account created"):
%% it is for the next page and survives, so `put' and `reset_session' work in either
%% order. The flash the request delivered is dropped with the rest of the old session
%% (`weberl_flash:keep/2' puts it back).
-spec reset_session(t()) -> t().
reset_session(#response{} = R) ->
    Own = weberl_flash:own(R),
    R1 = set_session(R, #{}),
    case map_size(Own) of
        0 -> R1;
        _ -> maps:fold(fun(K, V, Acc) -> weberl_flash:put(Acc, K, V) end, R1, Own)
    end.

%% @doc How long this session lives from now, in seconds, or `infinity' (no
%% server-side expiry; the cookie lasts 400 days, a browser's maximum). Starts a
%% new lifetime ("remember me"). Without it a new session lives `session_ttl'
%% seconds (default two days) and a changed one keeps its expiry.
-spec session_ttl(t(), pos_integer() | infinity) -> t().
session_ttl(#response{} = R, Ttl) when Ttl =:= infinity; is_integer(Ttl), Ttl > 0 ->
    {Map, Mode} = session_base(R, session_ttl),
    R#response{session = {Map, Mode}, session_ttl = Ttl};
session_ttl(#response{}, _Ttl) ->
    erlang:error(badarg).

%% @doc The session this response will set, `undefined' when it does not touch it.
-spec session(t()) -> undefined | map().
session(#response{session = undefined}) -> undefined;
session(#response{session = {Map, _}}) -> Map.

%% @doc `{ok, Value} | error' for `Key' in the response's session (loading the
%% request's if the response has none yet, like the writing functions).
-spec session_get(t(), term()) -> {ok, term()} | error.
session_get(#response{} = R, Key) ->
    {Map, _Mode} = session_base(R, session_get),
    maps:find(Key, Map).

%% @private For {@link weberl_session:finalize/2}.
-spec session_state(t()) -> undefined | {map(), fresh | continue}.
session_state(#response{session = S}) -> S.

%% @private
-spec session_ttl(t()) -> undefined | pos_integer() | infinity.
session_ttl(#response{session_ttl = T}) -> T.

session_base(#response{session = {_, _} = S}, _Op) ->
    S;
session_base(#response{session = undefined}, Op) ->
    case weberl_session:ambient() of
        {ok, Request} -> {weberl_request:session(Request), continue};
        none -> erlang:error({session_not_loaded, Op})
    end.

%% @doc Every value of the headers called `Name', in order (`[]' when none).
-spec header_values(t(), iodata()) -> [binary()].
header_values(#response{headers = Hs}, Name) ->
    N = lower(Name),
    [V || {K, V} <- Hs, K =:= N].

%% @doc Replace the body, keeping status and headers.
-spec with_body(t(), iodata()) -> t().
with_body(#response{} = R, Body) ->
    check_body(Body),
    R#response{body = Body}.

%% @doc Mark the response as served for a page of kind `Kind' (a downgrade):
%% a route declared `two_way' can answer a request as `one_way' or `normal',
%% and a `one_way' route as `normal', so one handler serves several situations
%% (for example the live version for a logged-in user and a plain page
%% otherwise). Dispatch reads the marker after `handle/1' returns: a `normal'
%% page is served without the beacon and its session is closed; a narrower live
%% kind gets the beacon for that kind. Asking for a wider kind than the route's
%% is a handler bug (a logged 500). It has no effect on routes that are not live.
-spec live(t(), normal | one_way | two_way) -> t().
live(#response{} = R, Kind) when Kind =:= normal; Kind =:= one_way; Kind =:= two_way ->
    R#response{live = Kind};
live(#response{}, _Kind) ->
    erlang:error(badarg).

%% @doc The kind the handler narrowed the page to with {@link live/2},
%% `undefined' when it did not.
-spec live(t()) -> undefined | normal | one_way | two_way.
live(#response{live = Kind}) -> Kind.

-spec header(t(), iodata()) -> {ok, binary()} | error.
header(#response{headers = Hs}, Name) ->
    case lists:keyfind(lower(Name), 1, Hs) of
        {_, V} -> {ok, V};
        false -> error
    end.

-spec status(t()) -> non_neg_integer().
status(#response{status = S}) -> S.

-spec headers(t()) -> headers().
headers(#response{headers = H}) -> H.

-spec body(t()) -> iodata().
body(#response{body = B}) -> B.

%% @doc Check a value returned by a handler.
-spec normalize(term()) -> {ok, t()} | {error, {invalid_handler_return, term()}}.
normalize(#response{} = R) -> {ok, R};
normalize(Other) -> {error, {invalid_handler_return, Other}}.

%% Internal

typed(Status, ContentType, Body) ->
    check_status(Status),
    check_body(Body),
    #response{status = Status,
              headers = [{<<"content-type">>, list_to_binary(ContentType)}],
              body = Body}.

put_header(Name, Value, Hs) ->
    N = header_name(Name),
    [{N, header_value(Value)} | [H || {K, _} = H <- Hs, K =/= N]].

%% Appends after the existing headers, keeping the order.
append_header(Name, Value, Hs) ->
    Hs ++ [{header_name(Name), header_value(Value)}].

lower(Name) -> string:lowercase(to_bin(Name)).

%% Header injection: a control character (CR, LF, NUL...) in a name or value, or a
%% `:' or space in a name, would split or corrupt the header block.
header_name(Name) ->
    N = lower(Name),
    case N =/= <<>> andalso lists:all(fun(C) -> C > 32 andalso C < 127 andalso C =/= $: end,
                                      binary_to_list(N)) of
        true -> N;
        false -> erlang:error(badarg)
    end.

header_value(Value) ->
    V = to_bin(Value),
    case lists:all(fun(C) -> (C >= 32 andalso C =/= 127) orelse C =:= $\t end,
                   binary_to_list(V)) of
        true -> V;
        false -> erlang:error(badarg)
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> B;
        _ -> erlang:error(badarg)
    end;
to_bin(_) -> erlang:error(badarg).

check_status(S) when is_integer(S), S >= 100, S =< 599 -> ok;
check_status(_) -> erlang:error(badarg).

check_body(B) when is_binary(B) -> ok;
check_body(B) when is_list(B) ->
    try iolist_size(B) of
        _ -> ok
    catch
        error:badarg -> erlang:error(badarg)
    end;
check_body(_) -> erlang:error(badarg).
