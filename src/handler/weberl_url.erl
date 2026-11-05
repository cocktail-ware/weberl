%% @doc URL checks and the URL helpers of templates.
%%
%% == Checks ==
%% An open redirect sends a user to an attacker's site through a link on yours,
%% typically a `next' parameter after login. {@link local/1} answers whether a
%% target is a path on this site, the only kind that is safe to take from the
%% client.
%%
%% == Helpers for templates ==
%% A URL attribute of a template (`href', `src', `action', ...) accepts only a
%% value made by one of these helpers (HANDOFF.md, decisions 8 and 9):
%% ```
%% <a href="{{ weberl_url:ensure_path(@next) }}">
%% <a href="/agents/{{ weberl_url:component(@id) }}">
%% <a href="/search?{{ weberl_url:query(#{q => @q}) }}">
%% <a href="{{ weberl_url:router_path("/agents") }}">
%% '''
%% Each returns a tagged value `{weberl_url, Kind, Binary}'. Only these functions make
%% one, so a string that came from a user is never accepted by accident; the
%% attribute then decides, at render time, which kinds it takes. `unsafe_url/1' skips
%% every check (it is still HTML-escaped when rendered).
%%
%% A helper raises `error:{template_error, Reason}' with `{not_a_path, Value}',
%% `{not_a_url, Value}', `{bad_url_value, Value}', `{bad_url_option, Option}',
%% `{unknown_route, Path}', `no_router', `{router_not_running, Name}',
%% `no_public_url' or `{bad_public_url, Value}'.
%%
%% == The router ==
%% `router_path/1,2' and `router_url/1,2' check the path against the route table of a
%% router. Which router: the `router' option, else the router of the current
%% request (set with {@link with_router/2}, which dispatch and live sessions do).
%% The table holds static paths only (dynamic paths: ROADMAP.md).
-module(weberl_url).

-export([local/1]).
-export([ensure_path/1, url/1, component/1, query/1, unsafe_url/1,
         router_path/1, router_path/2, router_url/1, router_url/2]).
-export([router_path_parts/2, router_url_parts/2, router_path_known/3, router_url_known/3]).
-export([is_tagged/1, kind/1, data/1]).
-export([with_router/2, ambient_router/0]).
-export_type([tagged/0, kind/0]).

-type kind() :: path | url | component | query | router_path | router_url | unsafe.
-type tagged() :: {weberl_url, kind(), binary()}.

-define(ROUTER_KEY, {weberl_url, router}).

%% ---------------------------------------------------------------------
%% Checks

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

%% ---------------------------------------------------------------------
%% Helpers

%% @doc A path on this site (see {@link local/1}); a full URL, a relative path or
%% anything else raises `{not_a_path, Value}'.
-spec ensure_path(term()) -> tagged().
ensure_path(Value) ->
    Bin = text(Value),
    case local(Bin) of
        true -> tag(path, Bin);
        false -> fail({not_a_path, Value})
    end.

%% @doc A path on this site or an absolute `http' / `https' URL, for links whose
%% target comes from data. Anything else (`javascript:', `//host', relative paths,
%% control characters, a backslash or a space in the URL) raises `{not_a_url, Value}'.
-spec url(term()) -> tagged().
url(Value) ->
    Bin = text(Value),
    case local(Bin) orelse web_url(Bin) of
        true -> tag(url, Bin);
        false -> fail({not_a_url, Value})
    end.

%% @doc One piece of a path or a query value, percent-encoded: everything but
%% `A-Z a-z 0-9 - . _ ~' (so a `/' becomes `%2F'). Integers and atoms are accepted.
%% Needs a literal prefix in the attribute (`href="/agents/{{ ... }}"').
-spec component(term()) -> tagged().
component(Value) -> tag(component, encode(text(Value))).

%% @doc A query string from a map or a list of `{Key, Value}', each key and value
%% encoded as in {@link component/1}: `k=v&k=v' (map keys in order). Needs a literal
%% prefix (`href="/search?{{ ... }}"').
-spec query(map() | [{term(), term()}]) -> tagged().
query(Pairs) -> tag(query, query_string(Pairs)).

%% @doc Whatever is given, unchecked. It is still HTML-escaped when rendered, so a
%% quote cannot leave the attribute; nothing checks the scheme, the destination or the
%% element. For links the application builds and vouches for.
-spec unsafe_url(term()) -> tagged().
unsafe_url(Value) -> tag(unsafe, text(Value)).

%% @doc {@link router_path/2} without options.
-spec router_path(term()) -> tagged().
router_path(Path) -> router_path(Path, #{}).

%% @doc A path on this site that is a route of the router (exact, static paths).
%% Options: `router' (the router's name; default the current request's), `query'
%% (a map or list as for {@link query/1}, appended after `?'), `no_warn' (read by the
%% template compiler, see HANDOFF.md decision 9). An unknown path raises
%% `{unknown_route, Path}'.
-spec router_path(term(), map()) -> tagged().
router_path(Path, Opts0) ->
    Opts = check_opts(Opts0),
    tag(router_path, with_query(route(Path, Opts), Opts)).

%% @doc {@link router_url/2} without options.
-spec router_url(term()) -> tagged().
router_url(Path) -> router_url(Path, #{}).

%% @doc Like {@link router_path/2}, as an absolute URL: the `public_url' of the
%% application environment (`https://example.com', no path) in front. Without it
%% `no_public_url' is raised; the `Host' header of a request is never used.
-spec router_url(term(), map()) -> tagged().
router_url(Path, Opts0) ->
    Opts = check_opts(Opts0),
    Route = route(Path, Opts),
    tag(router_url, with_query(<<(public_url())/binary, Route/binary>>, Opts)).

%% @doc What the template compiler makes of `router_path("/docs/{{ @page }}")': the
%% literal parts as they are and each placeholder as one percent-encoded segment, so a
%% value can never add a separator (`a/b' is `a%2Fb'). An empty value raises
%% `{empty_segment, Value}'. Otherwise as {@link router_path/2}.
-spec router_path_parts([{lit, binary()} | {seg, term()}], map()) -> tagged().
router_path_parts(Parts, Opts0) ->
    Opts = check_opts(Opts0),
    tag(router_path, with_query(route(join_parts(Parts), Opts), Opts)).

%% @doc Like {@link router_path_parts/2}, as {@link router_url/2}.
-spec router_url_parts([{lit, binary()} | {seg, term()}], map()) -> tagged().
router_url_parts(Parts, Opts0) ->
    Opts = check_opts(Opts0),
    Route = route(join_parts(Parts), Opts),
    tag(router_url, with_query(<<(public_url())/binary, Route/binary>>, Opts)).

%% @doc What the template compiler makes of `router_path(...)' when the template is compiled
%% with the route table: the parts as for {@link router_path_parts/2} and `Known', the
%% patterns (`weberl_route:pattern_parts/1') of the routes the call can match, which the
%% compiler worked out. The built path must match one of them, else `{unknown_route, Path}';
%% no router is needed when rendering, in whichever process that happens (a request, a
%% live session, a task of the application).
-spec router_path_known([{lit, binary()} | {seg, term()}], [[binary() | {param, atom()}]], map()) -> tagged().
router_path_known(Parts, Known, Opts0) ->
    Opts = check_opts(Opts0),
    tag(router_path, with_query(known_route(join_parts(Parts), Known), Opts)).

%% @doc Like {@link router_path_known/3}, as {@link router_url/2}.
-spec router_url_known([{lit, binary()} | {seg, term()}], [[binary() | {param, atom()}]], map()) -> tagged().
router_url_known(Parts, Known, Opts0) ->
    Opts = check_opts(Opts0),
    Route = known_route(join_parts(Parts), Known),
    tag(router_url, with_query(<<(public_url())/binary, Route/binary>>, Opts)).

%% `Known' is a list of route patterns (`weberl_route:pattern_parts/1'): the path has to match
%% one. The result is the path normalized (repeated and trailing slashes dropped).
known_route(Path, Known) ->
    case weberl_route:request_segments(unicode:characters_to_list(Path)) of
        {ok, Segments} ->
            lists:any(fun(Pattern) -> matches(Pattern, Segments) end, Known) orelse fail({unknown_route, Path}),
            joined(Segments);
        error ->
            fail({unknown_route, Path})
    end.

%% A parameter matches one segment (never empty); a static segment only itself.
matches([], []) -> true;
matches([{param, _} | Pattern], [_ | Segments]) -> matches(Pattern, Segments);
matches([Segment | Pattern], [Segment | Segments]) when is_binary(Segment) -> matches(Pattern, Segments);
matches(_, _) -> false.

joined([]) -> <<"/">>;
joined(Segments) -> iolist_to_binary([["/", S] || S <- Segments]).

join_parts(Parts) -> iolist_to_binary([part(P) || P <- Parts]).

part({lit, Bin}) when is_binary(Bin) -> Bin;
part({seg, Value}) ->
    case encode(text(Value)) of
        <<>> -> fail({empty_segment, Value});
        Encoded -> Encoded
    end.

%% ---------------------------------------------------------------------
%% Tagged values

-spec is_tagged(term()) -> boolean().
is_tagged({weberl_url, Kind, Data}) when is_atom(Kind), is_binary(Data) -> true;
is_tagged(_) -> false.

-spec kind(tagged()) -> kind().
kind({weberl_url, Kind, _}) -> Kind.

-spec data(tagged()) -> binary().
data({weberl_url, _, Data}) -> Data.

tag(Kind, Bin) -> {weberl_url, Kind, Bin}.

%% ---------------------------------------------------------------------
%% The router of the current request

%% @doc Run `Fun' with `Name' as the router of the current process (what
%% `router_path' and `router_url' check against), restoring the previous one after.
-spec with_router(atom(), fun(() -> Result)) -> Result.
with_router(Name, Fun) when is_atom(Name), is_function(Fun, 0) ->
    Old = erlang:put(?ROUTER_KEY, Name),
    try Fun()
    after
        case Old of
            undefined -> erlang:erase(?ROUTER_KEY);
            _ -> erlang:put(?ROUTER_KEY, Old)
        end
    end.

%% @doc The router of the current process, if one was set.
-spec ambient_router() -> atom() | undefined.
ambient_router() -> erlang:get(?ROUTER_KEY).

%% ---------------------------------------------------------------------
%% Internal

fail(Reason) -> erlang:error({template_error, Reason}).

%% Text of a value: binaries, strings, integers and atoms.
text(V) when is_binary(V) -> V;
text(V) when is_integer(V) -> integer_to_binary(V);
text(V) when is_atom(V) -> atom_to_binary(V, utf8);
text(V) when is_list(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> fail({bad_url_value, V})
    end;
text(V) -> fail({bad_url_value, V}).

%% Percent-encoding of the bytes of a UTF-8 text; unreserved characters stay.
encode(Bin) -> << <<(encode_byte(B))/binary>> || <<B>> <= Bin >>.

encode_byte(B) when B >= $a, B =< $z; B >= $A, B =< $Z; B >= $0, B =< $9;
                    B =:= $-; B =:= $.; B =:= $_; B =:= $~ -> <<B>>;
encode_byte(B) -> <<$%, (hex(B bsr 4)), (hex(B band 15))>>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.

query_string(Map) when is_map(Map) -> query_string(lists:sort(maps:to_list(Map)));
query_string(Pairs) when is_list(Pairs) ->
    Encoded = [pair(P) || P <- Pairs],
    iolist_to_binary(lists:join($&, Encoded));
query_string(Other) -> fail({bad_url_value, Other}).

pair({K, V}) -> [encode(text(K)), $=, encode(text(V))];
pair(Other) -> fail({bad_url_value, Other}).

%% An absolute http(s) URL: scheme, a non-empty host, no control characters, spaces
%% or backslashes (browsers read `\' as `/', which can hide a host).
web_url(Bin) ->
    case rest_after_scheme(Bin) of
        {ok, <<First, _/binary>> = Rest} when First =/= $/, First =/= $?, First =/= $#, First =/= $: ->
            lists:all(fun(C) -> C > 32 andalso C =/= 127 andalso C =/= $\\ end, binary_to_list(Rest));
        _ -> false
    end.

rest_after_scheme(<<S:7/binary, Rest/binary>> = Bin) ->
    case string:lowercase(S) of
        <<"http://">> -> {ok, Rest};
        _ -> rest_after_https(Bin)
    end;
rest_after_scheme(_) -> error.

rest_after_https(<<S:8/binary, Rest/binary>>) ->
    case string:lowercase(S) of
        <<"https://">> -> {ok, Rest};
        _ -> error
    end;
rest_after_https(_) -> error.

%% Options of router_path/router_url.
check_opts(Opts) when is_map(Opts) ->
    [fail({bad_url_option, K}) || K <- maps:keys(Opts), not lists:member(K, [router, query, no_warn])],
    case maps:get(no_warn, Opts, false) of
        B when is_boolean(B) -> ok;
        Other -> fail({bad_url_option, {no_warn, Other}})
    end,
    case maps:get(router, Opts, undefined) of
        R when is_atom(R) -> ok;
        Other2 -> fail({bad_url_option, {router, Other2}})
    end,
    Opts;
check_opts(Opts) -> fail({bad_url_option, Opts}).

with_query(Bin, #{query := Pairs}) ->
    case query_string(Pairs) of
        <<>> -> Bin;
        Q -> <<Bin/binary, $?, Q/binary>>
    end;
with_query(Bin, _) -> Bin.

%% The normalized path of the route, or `unknown_route'.
route(Path, Opts) ->
    Bin = text(Path),
    local(Bin) orelse fail({not_a_path, Path}),
    Table = table(Opts),
    case weberl_table:match(unicode:characters_to_list(Bin), Table) of
        {ok, _Route, _Params} ->
            {ok, Segments} = weberl_route:request_segments(unicode:characters_to_list(Bin)),
            joined(Segments);
        {error, not_found} ->
            fail({unknown_route, Bin})
    end.

table(Opts) ->
    Name = case maps:get(router, Opts, undefined) of
               undefined -> ambient_router();
               Given -> Given
           end,
    Name =/= undefined orelse fail(no_router),
    case weberl_router_server:table(Name) of
        {ok, Table} -> Table;
        {error, not_running} -> fail({router_not_running, Name})
    end.

public_url() ->
    case application:get_env(weberl, public_url) of
        {ok, V} ->
            Bin = text(V),
            Trimmed = string:trim(Bin, trailing, "/"),
            web_url(Trimmed) andalso not has_path(Trimmed) orelse fail({bad_public_url, V}),
            Trimmed;
        undefined -> fail(no_public_url)
    end.

%% `https://host' has no path after the host.
has_path(Url) ->
    [_Scheme, Rest] = binary:split(Url, <<"://">>),
    binary:match(Rest, [<<"/">>, <<"?">>, <<"#">>]) =/= nomatch.
