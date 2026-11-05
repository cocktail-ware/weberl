%% @doc Normalized route representation and URL path normalization.
%%
%% The `route' native record is the single internal representation shared by
%% filesystem and declarative routes.
-module(weberl_route).

-export([new/4, new/5, path/1, handler/1, origin/1, source/1, opts/1, live/1, session/1, csrf/1, layout/1,
         normalize_path/1, check_opts/1, check_live/1,
         normalize_pattern/1, pattern_parts/1, is_dynamic/1, shape/1, request_segments/1, decode_segment/1]).
-export_type([t/0, origin/0, path/0, live/0, opts/0]).
-export_record([route]).

-type path() :: string().
-type origin() :: filesystem | declarative.
%% How a page behaves in the browser: `normal' has no reactivity, `one_way'
%% is server push (SSE), `two_way' is a bidirectional channel (WebSocket).
-type live() :: normal | one_way | two_way.
%% `live': the page kind. `session': `false' makes a live page session-less
%% (no process per page; it only receives the topics of its handler, see
%% `weberl_live'); default `true'.
-type opts() :: #{live => live(), session => boolean(), csrf => true | origin | false,
                  layout => atom()}.

-record #route{
    path    :: path(),
    handler :: module(),
    origin  :: origin(),
    %% Source file (filesystem routes) or router module (declarative routes).
    source  :: file:filename() | module(),
    opts = #{} :: opts()
}.

-type t() :: #route{}.

-spec new(path(), module(), origin(), file:filename() | module()) -> t().
new(Path, Handler, Origin, Source) ->
    new(Path, Handler, Origin, Source, #{}).

%% @doc `Opts' must already be validated with {@link check_opts/1}.
-spec new(path(), module(), origin(), file:filename() | module(), opts()) -> t().
new(Path, Handler, Origin, Source, Opts)
  when is_atom(Handler), (Origin =:= filesystem orelse Origin =:= declarative),
       is_map(Opts) ->
    #route{path = Path, handler = Handler, origin = Origin, source = Source,
           opts = Opts}.

-spec path(t()) -> path().
path(#route{path = P}) -> P.

-spec handler(t()) -> module().
handler(#route{handler = H}) -> H.

-spec origin(t()) -> origin().
origin(#route{origin = O}) -> O.

-spec source(t()) -> file:filename() | module().
source(#route{source = S}) -> S.

-spec opts(t()) -> opts().
opts(#route{opts = O}) -> O.

%% @doc The route's page kind; `normal' unless declared otherwise.
-spec live(t()) -> live().
live(#route{opts = O}) -> maps:get(live, O, normal).

%% @doc Does the route's live page have a session; `true' unless the route
%% says `session => false'.
-spec session(t()) -> boolean().
session(#route{opts = O}) -> maps:get(session, O, true).

%% @doc The layout the route declares (`layout => Name' in its options, i.e.
%% `-weberl_route(#{layout => main}).' in a view), `none' when it declares none. Only
%% filesystem views have templates, so only they may declare one; see
%% {@link weberl_views}. The layout a view was compiled with, whichever way it was
%% selected, is `weberl_template:layout/1'.
-spec layout(t()) -> {ok, atom()} | none.
layout(#route{opts = O}) ->
    case maps:find(layout, O) of
        {ok, Name} -> {ok, Name};
        error -> none
    end.

%% @doc The CSRF mode of the route, `true' unless declared otherwise (see
%% {@link weberl_csrf}).
-spec csrf(t()) -> weberl_csrf:mode().
csrf(#route{opts = O}) -> maps:get(csrf, O, true).

%% @doc Validate a route options map. The keys are `live', `session', `csrf' and
%% `layout' (an atom); a session-less page has to be live.
-spec check_opts(term()) -> {ok, opts()} | {error, term()}.
check_opts(Opts) when is_map(Opts) ->
    case [K || K <- maps:keys(Opts), K =/= live, K =/= session, K =/= csrf, K =/= layout] of
        [] ->
            Checks = [check_kind(Opts), check_session(Opts), check_csrf(Opts), check_layout(Opts)],
            case [E || {error, _} = E <- Checks] of
                [] -> {ok, Opts};
                [Error | _] -> Error
            end;
        Unknown ->
            {error, {unknown_options, lists:sort(Unknown)}}
    end;
check_opts(Other) ->
    {error, {options_not_a_map, Other}}.

check_kind(Opts) ->
    case maps:find(live, Opts) of
        error -> ok;
        {ok, Kind} -> check_live(Kind)
    end.

check_layout(Opts) ->
    case maps:find(layout, Opts) of
        error -> ok;
        {ok, Name} when is_atom(Name) -> ok;
        {ok, Other} -> {error, {invalid_layout, Other}}
    end.

check_csrf(Opts) ->
    case maps:find(csrf, Opts) of
        error -> ok;
        {ok, Mode} when Mode =:= true; Mode =:= origin; Mode =:= false -> ok;
        {ok, Other} -> {error, {invalid_csrf, Other}}
    end.

check_session(Opts) ->
    case maps:find(session, Opts) of
        error -> ok;
        {ok, Session} when not is_boolean(Session) -> {error, {invalid_session, Session}};
        {ok, false} ->
            case maps:get(live, Opts, normal) of
                normal -> {error, session_option_needs_a_live_page};
                _ -> ok
            end;
        {ok, true} -> ok
    end.

-spec check_live(term()) -> ok | {error, term()}.
check_live(Kind) when Kind =:= normal; Kind =:= one_way; Kind =:= two_way -> ok;
check_live(Other) -> {error, {invalid_live, Other}}.

%% @doc Normalize a static URL path.
%%
%% Must be a string starting with `/'. Repeated slashes are collapsed and a
%% trailing slash is removed (the root stays `/'). Segments `.' and `..',
%% segments containing whitespace, control characters, `?', `#' or `\',
%% and segments containing `:' or `*' (reserved for dynamic/wildcard routes)
%% are rejected.
-spec normalize_path(term()) -> {ok, path()} | {error, term()}.
normalize_path(Path) when is_list(Path) ->
    case io_lib:printable_unicode_list(Path) of
        true -> normalize_string(Path);
        false -> {error, not_a_string}
    end;
normalize_path(_) ->
    {error, not_a_string}.

normalize_string([$/ | _] = Path) ->
    Segments = [S || S <- string:split(Path, "/", all), S =/= ""],
    case check_segments(Segments) of
        ok -> {ok, join_segments(Segments)};
        {error, _} = Error -> Error
    end;
normalize_string(_) ->
    {error, must_start_with_slash}.

check_segments([]) -> ok;
check_segments([S | Rest]) ->
    case check_segment(S) of
        ok -> check_segments(Rest);
        {error, _} = Error -> Error
    end.

check_segment(".") -> {error, {invalid_segment, "."}};
check_segment("..") -> {error, {invalid_segment, ".."}};
check_segment(S) ->
    case lists:search(fun bad_char/1, S) of
        false -> ok;
        {value, C} when C =:= $:; C =:= $* -> {error, {unsupported_segment, S}};
        {value, _} -> {error, {invalid_segment, S}}
    end.

bad_char(C) ->
    C =< 32 orelse C =:= 127 orelse C =:= $? orelse C =:= $# orelse
        C =:= $\\ orelse C =:= $: orelse C =:= $*.

join_segments([]) -> "/";
join_segments(Segments) -> lists:append(["/" ++ S || S <- Segments]).

%% ---------------------------------------------------------------------
%% Patterns: static paths whose segments may be `:name' parameters

%% @doc Normalize a route pattern: like {@link normalize_path/1}, but a segment may
%% be a parameter `:name' (`name' is `[a-z][a-z0-9_]*', once per pattern), which
%% matches exactly one non-empty segment (HANDOFF.md, decision 11).
-spec normalize_pattern(term()) -> {ok, path()} | {error, term()}.
normalize_pattern(Path) when is_list(Path) ->
    case io_lib:printable_unicode_list(Path) of
        true -> pattern_string(Path);
        false -> {error, not_a_string}
    end;
normalize_pattern(_) ->
    {error, not_a_string}.

pattern_string([$/ | _] = Path) ->
    Segments = [S || S <- string:split(Path, "/", all), S =/= ""],
    case check_pattern(Segments, []) of
        ok -> {ok, join_segments(Segments)};
        {error, _} = Error -> Error
    end;
pattern_string(_) ->
    {error, must_start_with_slash}.

check_pattern([], _Seen) -> ok;
check_pattern([[$: | Name] = Segment | Rest], Seen) ->
    case valid_parameter(Name) of
        false ->
            {error, {invalid_parameter, Segment}};
        true ->
            case lists:member(Name, Seen) of
                true -> {error, {duplicate_parameter, Name}};
                false -> check_pattern(Rest, [Name | Seen])
            end
    end;
check_pattern([Segment | Rest], Seen) ->
    case check_segment(Segment) of
        ok -> check_pattern(Rest, Seen);
        {error, _} = Error -> Error
    end.

valid_parameter([C | Rest]) when C >= $a, C =< $z ->
    lists:all(fun(X) -> (X >= $a andalso X =< $z) orelse (X >= $0 andalso X =< $9) orelse X =:= $_ end, Rest);
valid_parameter(_) ->
    false.

%% @doc The segments of a normalized pattern: a binary for a static segment,
%% `{param, Name}' for a parameter.
-spec pattern_parts(path()) -> [binary() | {param, atom()}].
pattern_parts(Path) ->
    [part(S) || S <- string:split(Path, "/", all), S =/= ""].

part([$: | Name]) -> {param, list_to_atom(Name)};
part(Segment) -> unicode:characters_to_binary(Segment).

%% @doc Does the pattern have a parameter?
-spec is_dynamic(path()) -> boolean().
is_dynamic(Path) ->
    lists:any(fun({param, _}) -> true; (_) -> false end, pattern_parts(Path)).

%% @doc The shape of a pattern: its parameters without names (`/agents/:id' is
%% `/agents/:'). Two patterns with the same shape cannot both be routes.
-spec shape(path()) -> path().
shape(Path) ->
    join_segments([case P of {param, _} -> ":"; _ -> unicode:characters_to_list(P) end
                   || P <- pattern_parts(Path)]).

%% @doc The segments of a request path, as binaries, repeated and trailing slashes
%% dropped. Unlike {@link normalize_path/1} a segment may contain `:' and `*' (a
%% parameter value can); `.' and `..', white space, control characters, `?', `#' and
%% `\' are refused. The segments are not percent-decoded.
-spec request_segments(term()) -> {ok, [binary()]} | error.
request_segments([$/ | _] = Path) ->
    case io_lib:printable_unicode_list(Path) of
        true ->
            Segments = [S || S <- string:split(Path, "/", all), S =/= ""],
            case lists:all(fun request_segment_ok/1, Segments) of
                true -> {ok, [unicode:characters_to_binary(S) || S <- Segments]};
                false -> error
            end;
        false ->
            error
    end;
request_segments(_) ->
    error.

request_segment_ok(".") -> false;
request_segment_ok("..") -> false;
request_segment_ok(S) ->
    not lists:any(fun(C) -> C =< 32 orelse C =:= 127 orelse C =:= $? orelse C =:= $# orelse C =:= $\\ end, S).

%% @doc Percent-decode one path segment. `%' is valid only as `%HH'; a bad escape, or a
%% result that is not valid UTF-8, is `error' (the request is a `400').
-spec decode_segment(binary()) -> {ok, binary()} | error.
decode_segment(Segment) when is_binary(Segment) ->
    case decode(Segment, []) of
        {ok, Decoded} ->
            case unicode:characters_to_binary(Decoded, utf8, utf8) of
                Decoded -> {ok, Decoded};
                _ -> error
            end;
        error ->
            error
    end.

decode(<<>>, Acc) ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
decode(<<$%, H, L, Rest/binary>>, Acc) ->
    case {hex(H), hex(L)} of
        {{ok, High}, {ok, Low}} -> decode(Rest, [<<(High * 16 + Low)>> | Acc]);
        _ -> error
    end;
decode(<<$%, _/binary>>, _Acc) ->
    error;
decode(<<C, Rest/binary>>, Acc) ->
    decode(Rest, [<<C>> | Acc]).

hex(C) when C >= $0, C =< $9 -> {ok, C - $0};
hex(C) when C >= $a, C =< $f -> {ok, C - $a + 10};
hex(C) when C >= $A, C =< $F -> {ok, C - $A + 10};
hex(_) -> error.
