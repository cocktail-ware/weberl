%% @doc Weberl-native HTTP request (native record) and accessors.
%%
%% Transport adapters build requests with {@link new/1}. Fields:
%% <ul>
%%   <li>`method': upper-case binary, e.g. `<<"GET">>'.</li>
%%   <li>`path': string, same representation as route paths. It is the raw
%%       request path: not percent-decoded and not normalized.</li>
%%   <li>`headers': `[{LowercaseName, Value}]' binaries, in arrival order.</li>
%%   <li>`query': raw query string (binary, without `?'). Parse on demand with
%%       {@link query_params/1}.</li>
%%   <li>`params': route parameters, `#{id => <<"7">>}' for a route `/agents/:id' (values
%%       percent-decoded; `#{}' for a static route).</li>
%%   <li>`peer': `{Address, Port}' or `undefined'.</li>
%%   <li>`meta': free-form map for transport metadata.</li>
%% </ul>
%%
%% Convention: every function takes the request first (`method(Request)',
%% `header(Request, Name)'), so accessors compose with pipelines and helpers.
%%
%% The body is never read when a request is built. {@link read_body/1} calls the
%% reader the adapter supplied (`body_reader'); whether a second call works is
%% transport dependent.
-module(weberl_request).

-export([new/1,
         method/1, path/1, headers/1, header/2, query/1, query_params/1,
         params/1, peer/1, meta/1, read_body/1, cookies/1, cookie/2, form/1, form/2, multipart/1, multipart/2,
         files/1, files/2, is_multipart/1, safe_filename/1, session/1, session_get/2,
         page/1, with_page/2, with_params/2, route/1, limits/1, route_data/1, with_route/2]).
-export_type([t/0]).
-export_record([request]).

-record #request{
    method :: binary(),
    path :: string(),
    headers = [] :: [{binary(), binary()}],
    query = <<>> :: binary(),
    params = #{} :: map(),
    body_reader :: undefined | fun(() -> {ok, binary()} | {error, term()}),
    peer = undefined :: undefined | {inet:ip_address(), inet:port_number()},
    meta = #{} :: map(),
    %% Live page id, set by dispatch for `one_way' / `two_way' routes.
    page = undefined :: undefined | binary(),
    %% What dispatch knows of the route that matched: `handler' and the `limits' in force
    %% for it (route over router), see `weberl_limits'. Empty for a hand-made request.
    route = #{} :: #{handler => module(), limits => weberl_limits:limits(), data => term()}
}.

-type t() :: #request{}.

%% @doc Build a request from a map. Required keys: `method', `path'.
%% Optional: `headers', `query', `params', `peer', `meta', and either `body'
%% (a binary) or `body_reader' (a `fun/0').
-spec new(map()) -> t().
new(#{method := Method, path := Path} = Opts)
  when is_binary(Method), is_list(Path) ->
    #request{
       method = string:uppercase(Method),
       path = Path,
       headers = [{string:lowercase(N), V} || {N, V} <- maps:get(headers, Opts, [])],
       query = maps:get(query, Opts, <<>>),
       params = maps:get(params, Opts, #{}),
       body_reader = reader(Opts),
       peer = maps:get(peer, Opts, undefined),
       meta = maps:get(meta, Opts, #{})
      }.

-spec method(t()) -> binary().
method(#request{method = M}) -> M.

-spec path(t()) -> string().
path(#request{path = P}) -> P.

-spec headers(t()) -> [{binary(), binary()}].
headers(#request{headers = H}) -> H.

%% @doc Case-insensitive lookup of the first header with that name.
-spec header(t(), iodata()) -> {ok, binary()} | error.
header(#request{headers = H}, Name) ->
    case lists:keyfind(string:lowercase(iolist_to_binary(Name)), 1, H) of
        {_, V} -> {ok, V};
        false -> error
    end.

-spec query(t()) -> binary().
query(#request{query = Q}) -> Q.

%% @doc Parse the query string into `[{Name, Value | true}]' (binaries).
-spec query_params(t()) -> {ok, [{binary(), binary() | true}]} | {error, invalid_query}.
query_params(#request{query = <<>>}) ->
    {ok, []};
query_params(#request{query = Q}) ->
    case uri_string:dissect_query(Q) of
        {error, _, _} ->
            {error, invalid_query};
        Pairs ->
            {ok, [{bin(K), bin(V)} || {K, V} <- Pairs]}
    end.

-spec params(t()) -> map().
params(#request{params = P}) -> P.

-spec peer(t()) -> undefined | {inet:ip_address(), inet:port_number()}.
peer(#request{peer = P}) -> P.

-spec meta(t()) -> map().
meta(#request{meta = M}) -> M.

%% @doc The request's cookies as `[{Name, Value}]' in wire order, parsed by the
%% adapter (`weberl_adapter' callback `cookies/1'); `[]' when there are none.
%% Values are not decoded: what the client sent is what you get. Raises
%% `{no_adapter, cookies}' for a request that was not built by an adapter.
-spec cookies(t()) -> [{binary(), binary()}].
cookies(#request{} = R) ->
    (adapter(R, cookies)):cookies(R).

%% @doc The first cookie named `Name' (case-sensitive), `{ok, Value} | error'.
-spec cookie(t(), iodata()) -> {ok, binary()} | error.
cookie(#request{} = R, Name) ->
    case lists:keyfind(iolist_to_binary(Name), 1, cookies(R)) of
        {_, V} -> {ok, V};
        false -> error
    end.

%% @doc The session in the request's cookie (see {@link weberl_session}): the map
%% the application stored, `#{}' when there is none, or when the cookie is not
%% ours, was tampered with or has expired. It is what the browser sent; changes
%% made on the response in this request are not in it (read them back from the
%% response with `weberl_response:session_get/2').
-spec session(t()) -> map().
session(#request{} = R) ->
    case weberl_session:read(R) of
        {Map, _Expires} -> Map;
        none -> #{}
    end.

%% @doc `{ok, Value} | error' for `Key' in {@link session/1}.
-spec session_get(t(), term()) -> {ok, term()} | error.
session_get(#request{} = R, Key) ->
    maps:find(Key, session(R)).

%% @doc The text fields of a form body as `[{Name, Value | true}]' (binaries, names may
%% repeat, in order). For `application/x-www-form-urlencoded' `+' and percent escapes are
%% decoded and a field without `=' is `true'; for `multipart/form-data' these are the parts
%% without a file name (the files are {@link files/1}). Another content type is `{error,
%% unsupported_content_type}' and a missing one `{error, no_content_type}'. The
%% {@link weberl_limits} apply (`{error, {limit_exceeded, Limit}}', logged); the adapter
%% reads the body, so the transport's size limit applies first. Raises `{no_adapter, form}'
%% for a request that was not built by an adapter.
-spec form(t()) -> {ok, [{binary(), binary() | true}]} | {error, term()}.
form(#request{} = R) ->
    form(R, #{}).

%% @doc Like {@link form/1} with limits for this call (see {@link weberl_limits}).
-spec form(t(), weberl_limits:limits()) -> {ok, [{binary(), binary() | true}]} | {error, term()}.
form(#request{} = R, Call) ->
    Limits = call_limits(R, Call),
    case multipart_type(R) of
        true ->
            case parts(R, Limits) of
                {ok, Parts} -> {ok, weberl_multipart:fields(Parts)};
                {error, _} = Error -> Error
            end;
        false ->
            case (adapter(R, form)):form(R) of
                {ok, Pairs} -> urlencoded_within(Pairs, Limits, R);
                {error, _} = Error -> Error
            end
    end.

%% The fields of an urlencoded body against the limits.
urlencoded_within(Pairs, Limits, R) ->
    #{max_fields := MaxFields, max_field_bytes := MaxBytes} = Limits,
    Biggest = lists:max([0 | [value_size(V) || {_, V} <- Pairs]]),
    if
        length(Pairs) > MaxFields -> weberl_limits:exceeded(max_fields, MaxFields, length(Pairs), R);
        Biggest > MaxBytes -> weberl_limits:exceeded(max_field_bytes, MaxBytes, Biggest, R);
        true -> {ok, Pairs}
    end.

value_size(true) -> 0;
value_size(V) -> byte_size(V).

%% @doc The parts of a `multipart/form-data' body, in order, each `#{name, filename,
%% content_type, headers, body}' (`filename' is `undefined' for a text field and `<<>>' for a
%% file input left empty). See `weberl_multipart' for what is and is not checked: names, file
%% names and content types are the client's. Errors: `{error, unsupported_content_type}' (not a
%% multipart request), `malformed_multipart', `{error, {limit_exceeded, Limit}}' and the
%% transport's.
-spec multipart(t()) -> {ok, [weberl_multipart:part()]} | {error, term()}.
multipart(#request{} = R) ->
    multipart(R, #{}).

%% @doc Like {@link multipart/1} with limits for this call (see {@link weberl_limits}).
-spec multipart(t(), weberl_limits:limits()) -> {ok, [weberl_multipart:part()]} | {error, term()}.
multipart(#request{} = R, Call) ->
    parts(R, call_limits(R, Call)).

%% @doc The files of a `multipart/form-data' body: `[#{name, filename, content_type, body,
%% size}]' for the parts that have a file name, leaving out a file input that was left empty.
%% A request that is not multipart is `{error, unsupported_content_type}': a form with a file
%% input needs `enctype="multipart/form-data"', see `weberl_form:open/3'.
-spec files(t()) -> {ok, [map()]} | {error, term()}.
files(#request{} = R) ->
    files(R, #{}).

%% @doc Like {@link files/1} with limits for this call (see {@link weberl_limits}).
-spec files(t(), weberl_limits:limits()) -> {ok, [map()]} | {error, term()}.
files(#request{} = R, Call) ->
    case parts(R, call_limits(R, Call)) of
        {ok, Parts} -> {ok, weberl_multipart:files(Parts)};
        {error, _} = Error -> Error
    end.

%% @doc A file name that is safe to store, made from a client's (see `weberl_multipart').
-spec safe_filename(binary()) -> binary().
safe_filename(Name) -> weberl_multipart:safe_filename(Name).

parts(R, Limits) ->
    case multipart_type(R) of
        true ->
            case (adapter(R, multipart)):multipart(R) of
                {ok, Raw} -> weberl_multipart:parts(Raw, Limits, R);
                {error, _} = Error -> Error
            end;
        false ->
            {error, unsupported_content_type}
    end.

%% Limits for a call: the defaults, env, route and the call's own (`max_body_bytes' is not a
%% per call limit).
call_limits(R, Call) ->
    case weberl_limits:check_call(Call) of
        {ok, Checked} -> weberl_limits:effective(R, Checked);
        {error, Reason} -> erlang:error({badarg, Reason})
    end.

%% @doc Is the body `multipart/form-data' (by the `Content-Type' header)?
-spec is_multipart(t()) -> boolean().
is_multipart(#request{} = R) -> multipart_type(R).

multipart_type(R) ->
    case header(R, <<"content-type">>) of
        {ok, Type} ->
            [Main | _] = binary:split(Type, <<";">>),
            string:lowercase(string:trim(Main)) =:= <<"multipart/form-data">>;
        error ->
            false
    end.

%% @doc What dispatch knows of the matched route: `#{handler, limits, data}' (`#{}' for a request
%% that did not come through dispatch).
-spec route(t()) -> map().
route(#request{route = Route}) -> Route.

%% @doc The form limits dispatch resolved for the route (route over router), `#{}' when none.
-spec limits(t()) -> weberl_limits:limits().
limits(#request{route = Route}) -> maps:get(limits, Route, #{}).

%% @doc The data the matched route carries (`data => Term' in its options: `{Path, Handler,
%% #{data => #{action => update}}}' or `-weberl_route(#{data => ...}).'), `#{}' when it has none.
%% It is set in the code, not by the client, so one handler module can serve several routes and
%% tell them apart without a path parameter anyone could change.
-spec route_data(t()) -> term().
route_data(#request{route = Route}) -> maps:get(data, Route, #{}).

%% @doc The request with the route information dispatch sets (`handler', `limits', `data').
-spec with_route(t(), map()) -> t().
with_route(#request{} = R, Route) when is_map(Route) -> R#request{route = Route}.

%% @doc The live page id when the route is `one_way' / `two_way', else
%% `undefined'. Pass it to whatever pushes updates with `weberl_live:push/3'.
-spec page(t()) -> undefined | binary().
page(#request{page = P}) -> P.

%% @doc The request with its route parameters (`#{id => <<"7">>}'); dispatch sets them
%% from the route that matched.
-spec with_params(t(), #{atom() => binary()}) -> t().
with_params(#request{} = R, Params) when is_map(Params) -> R#request{params = Params}.

-spec with_page(t(), binary()) -> t().
with_page(#request{} = R, PageId) when is_binary(PageId) -> R#request{page = PageId}.

%% @doc Read the request body through the adapter-supplied reader. A request
%% with no reader has an empty body.
-spec read_body(t()) -> {ok, binary()} | {error, term()}.
read_body(#request{body_reader = undefined}) -> {ok, <<>>};
read_body(#request{body_reader = Reader}) -> Reader().

%% Internal

adapter(#request{meta = #{adapter := Adapter}}, _Function) -> Adapter;
adapter(#request{}, Function) -> erlang:error({no_adapter, Function}).

reader(#{body_reader := F}) when is_function(F, 0) -> F;
reader(#{body := B}) when is_binary(B) -> fun() -> {ok, B} end;
reader(_) -> undefined.

bin(true) -> true;
bin(B) when is_binary(B) -> B;
bin(L) -> unicode:characters_to_binary(L).
