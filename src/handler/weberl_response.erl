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
-module(weberl_response).

-export([new/3, html/2, text/2, binary/2,
         with_header/3, with_body/2, header/2,
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
    live = undefined :: undefined | normal | one_way | two_way
}.

-type t() :: #response{}.

%% @doc Build a response from raw parts. No default headers are added.
-spec new(100..599, [{iodata(), iodata()}], iodata()) -> t().
new(Status, Headers, Body) ->
    check_status(Status),
    check_body(Body),
    #response{status = Status,
              headers = lists:foldl(fun({N, V}, Acc) -> put_header(N, V, Acc) end,
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
-spec with_header(iodata(), iodata(), t()) -> t().
with_header(Name, Value, #response{headers = Hs} = R) ->
    R#response{headers = put_header(Name, Value, Hs)}.

%% @doc Replace the body, keeping status and headers.
-spec with_body(iodata(), t()) -> t().
with_body(Body, #response{} = R) ->
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

-spec header(iodata(), t()) -> {ok, binary()} | error.
header(Name, #response{headers = Hs}) ->
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
    N = lower(Name),
    [{N, to_bin(Value)} | lists:keydelete(N, 1, Hs)].

lower(Name) -> string:lowercase(to_bin(Name)).

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
