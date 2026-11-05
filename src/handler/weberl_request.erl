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
%%   <li>`params': route parameters. Always `#{}' for static routes.</li>
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
         params/1, peer/1, meta/1, read_body/1, cookies/1, cookie/2, form/1, session/1, session_get/2,
         page/1, with_page/2]).
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
    page = undefined :: undefined | binary()
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

%% @doc The body of an `application/x-www-form-urlencoded' request as
%% `[{Name, Value | true}]' (binaries; `+' and percent escapes decoded; a field
%% without `=' is `true'; names may repeat, in order). Any other content type is
%% `{error, unsupported_content_type}' (`multipart/form-data' too, for now) and a
%% missing one `{error, no_content_type}'. The adapter reads the body, so its
%% size limit applies (`max_content_length' for Roadrunner). Raises
%% `{no_adapter, form}' for a request that was not built by an adapter.
-spec form(t()) -> {ok, [{binary(), binary() | true}]} | {error, term()}.
form(#request{} = R) ->
    (adapter(R, form)):form(R).

%% @doc The live page id when the route is `one_way' / `two_way', else
%% `undefined'. Pass it to whatever pushes updates with `weberl_live:push/3'.
-spec page(t()) -> undefined | binary().
page(#request{page = P}) -> P.

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
