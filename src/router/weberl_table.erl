%% @doc Route table assembly, conflict handling and exact lookup.
%%
%% Precedence and ordering (deterministic):
%%
%% <ol>
%%   <li>All filesystem roots share one priority; all declarative router
%%       modules share another, lower one.</li>
%%   <li>Duplicate modules among filesystem views are an error.</li>
%%   <li>Duplicate normalized paths within a priority level are an error.</li>
%%   <li>A declarative route whose path is also a filesystem route is dropped
%%       from the table and listed in `shadowed/1'.</li>
%%   <li>`routes/1' is sorted by path (string order).</li>
%% </ol>
-module(weberl_table).

-export([assemble/2, lookup/2, match/2, handler/2, routes/1, shadowed/1]).
-export_type([t/0, params/0]).
-export_record([table]).

%% Static routes are found in `index' (exact path); routes with parameters in `trie', a tree of
%% segments (HANDOFF.md, decisions 11 and 12). A node has the static children by name, at
%% most one parameter child, and the route that ends there with its parameter names.
-record #table{
    routes   = [] :: [weberl_route:t()],
    index    = #{} :: #{weberl_route:path() => weberl_route:t()},
    trie     = undefined :: trie_node() | undefined,
    shadowed = [] :: [weberl_route:t()]
}.

-type trie_node() :: #{static := #{binary() => trie_node()},
                  param := none | trie_node(),
                  route := none | {weberl_route:t(), [atom()]}}.
%% The values of a route's parameters, as they are in the path (not percent-decoded).
-type params() :: #{atom() => binary()}.

-type t() :: #table{}.

%% @doc Combine filesystem and declarative routes into a validated table.
-spec assemble([weberl_route:t()], [weberl_route:t()]) -> {ok, t()} | {error, term()}.
assemble(FsRoutes, DeclRoutes) ->
    Checks = [fun() -> check_duplicate_modules(FsRoutes) end,
              fun() -> check_duplicate_paths(filesystem, FsRoutes) end,
              fun() -> check_duplicate_paths(declarative, DeclRoutes) end],
    case run_checks(Checks) of
        ok -> {ok, merge(FsRoutes, DeclRoutes)};
        {error, _} = Error -> Error
    end.

%% @doc The route a request path belongs to, with its parameters (raw, not decoded). A
%% static route wins over one with parameters, and otherwise the first segment where
%% routes differ decides: a static segment before a parameter (`/agents/new' before
%% `/agents/:id'; `/a/b/:y' before `/a/:x/c'). `{error, not_found}' for no route and for a
%% path that is not valid.
-spec match(term(), t()) -> {ok, weberl_route:t(), params()} | {error, not_found}.
match(Path, #table{index = Index, trie = Trie}) ->
    case weberl_route:request_segments(Path) of
        {ok, Segments} ->
            case maps:find(joined(Segments), Index) of
                {ok, Route} ->
                    {ok, Route, #{}};
                error ->
                    walk(Segments, Trie, [])
            end;
        error ->
            {error, not_found}
    end.

joined([]) -> "/";
joined(Segments) -> unicode:characters_to_list(iolist_to_binary([["/", S] || S <- Segments])).

walk(_Segments, undefined, _Values) ->
    {error, not_found};
walk([], #{route := none}, _Values) ->
    {error, not_found};
walk([], #{route := {Route, Names}}, Values) ->
    {ok, Route, maps:from_list(lists:zip(Names, lists:reverse(Values)))};
walk([Segment | Rest], #{static := Static, param := Param}, Values) ->
    case maps:find(Segment, Static) of
        {ok, Child} ->
            case walk(Rest, Child, Values) of
                {ok, _, _} = Found -> Found;
                {error, not_found} -> walk_param(Segment, Rest, Param, Values)
            end;
        error ->
            walk_param(Segment, Rest, Param, Values)
    end.

walk_param(_Segment, _Rest, none, _Values) -> {error, not_found};
walk_param(Segment, Rest, Child, Values) -> walk(Rest, Child, [Segment | Values]).

%% @doc Exact static-path lookup. The path is normalized first; invalid or
%% unknown paths yield `{error, not_found}'.
-spec lookup(term(), t()) -> {ok, weberl_route:t()} | {error, not_found}.
lookup(Path, #table{index = Index}) ->
    case weberl_route:normalize_path(Path) of
        {ok, P} ->
            case maps:find(P, Index) of
                {ok, Route} -> {ok, Route};
                error -> {error, not_found}
            end;
        {error, _} ->
            {error, not_found}
    end.

%% @doc Like {@link lookup/2} but returns only the handler module.
-spec handler(term(), t()) -> {ok, module()} | {error, not_found}.
handler(Path, Table) ->
    case lookup(Path, Table) of
        {ok, Route} -> {ok, weberl_route:handler(Route)};
        {error, _} = Error -> Error
    end.

-spec routes(t()) -> [weberl_route:t()].
routes(#table{routes = R}) -> R.

%% @doc Declarative routes dropped because a filesystem route has the same path.
-spec shadowed(t()) -> [weberl_route:t()].
shadowed(#table{shadowed = S}) -> S.

%% Internal

run_checks([]) -> ok;
run_checks([Check | Rest]) ->
    case Check() of
        ok -> run_checks(Rest);
        {error, _} = Error -> Error
    end.

check_duplicate_modules(Routes) ->
    Groups = group_by(fun weberl_route:handler/1, Routes),
    Dups = [{Mod, lists:sort([{weberl_route:path(R), weberl_route:source(R)} || R <- L])}
            || {Mod, L} <- lists:sort(maps:to_list(Groups)), length(L) > 1],
    case Dups of
        [] -> ok;
        _ -> {error, {duplicate_modules, Dups}}
    end.

%% Two routes of the same shape (`/a/:x', `/a/:y') are duplicates: a path could belong to both.
check_duplicate_paths(Origin, Routes) ->
    Groups = group_by(fun(R) -> weberl_route:shape(weberl_route:path(R)) end, Routes),
    Dups = [{Path, lists:sort([{weberl_route:handler(R), weberl_route:source(R)} || R <- L])}
            || {Path, L} <- lists:sort(maps:to_list(Groups)), length(L) > 1],
    case Dups of
        [] -> ok;
        _ -> {error, {duplicate_routes, Origin, Dups}}
    end.

group_by(KeyFun, Items) ->
    lists:foldr(
      fun(Item, Acc) ->
              maps:update_with(KeyFun(Item), fun(L) -> [Item | L] end, [Item], Acc)
      end, #{}, Items).

merge(FsRoutes, DeclRoutes) ->
    FsShapes = maps:from_list([{shape(R), true} || R <- FsRoutes]),
    {Kept, Shadowed} =
        lists:partition(
          fun(R) -> not maps:is_key(shape(R), FsShapes) end, DeclRoutes),
    All = lists:sort(fun(A, B) -> weberl_route:path(A) =< weberl_route:path(B) end,
                     FsRoutes ++ Kept),
    ShadowedSorted = lists:sort(fun(A, B) -> sort_key(A) =< sort_key(B) end, Shadowed),
    #table{routes = All,
           index = maps:from_list([{weberl_route:path(R), R}
                                   || R <- All, not weberl_route:is_dynamic(weberl_route:path(R))]),
           trie = trie([R || R <- All, weberl_route:is_dynamic(weberl_route:path(R))]),
           shadowed = ShadowedSorted}.

shape(R) -> weberl_route:shape(weberl_route:path(R)).

sort_key(R) ->
    {weberl_route:path(R), weberl_route:source(R), weberl_route:handler(R)}.

%% The segment tree of the routes with parameters (`undefined' for none).
trie([]) ->
    undefined;
trie(Routes) ->
    lists:foldl(fun(Route, Trie) ->
                        Parts = weberl_route:pattern_parts(weberl_route:path(Route)),
                        Names = [Name || {param, Name} <- Parts],
                        insert(Parts, {Route, Names}, Trie)
                end, new_node(), Routes).

new_node() -> #{static => #{}, param => none, route => none}.

insert([], Leaf, Node) ->
    Node#{route := Leaf};
insert([{param, _} | Rest], Leaf, #{param := Param} = Node) ->
    Child = case Param of none -> new_node(); _ -> Param end,
    Node#{param := insert(Rest, Leaf, Child)};
insert([Segment | Rest], Leaf, #{static := Static} = Node) ->
    Child = maps:get(Segment, Static, new_node()),
    Node#{static := Static#{Segment => insert(Rest, Leaf, Child)}}.
