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

-export([assemble/2, lookup/2, handler/2, routes/1, shadowed/1]).
-export_type([t/0]).
-export_record([table]).

-record #table{
    routes   = [] :: [weberl_route:t()],
    index    = #{} :: #{weberl_route:path() => weberl_route:t()},
    shadowed = [] :: [weberl_route:t()]
}.

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

check_duplicate_paths(Origin, Routes) ->
    Groups = group_by(fun weberl_route:path/1, Routes),
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
    FsPaths = maps:from_list([{weberl_route:path(R), true} || R <- FsRoutes]),
    {Kept, Shadowed} =
        lists:partition(
          fun(R) -> not maps:is_key(weberl_route:path(R), FsPaths) end, DeclRoutes),
    All = lists:sort(fun(A, B) -> weberl_route:path(A) =< weberl_route:path(B) end,
                     FsRoutes ++ Kept),
    ShadowedSorted = lists:sort(fun(A, B) -> sort_key(A) =< sort_key(B) end, Shadowed),
    #table{routes = All,
           index = maps:from_list([{weberl_route:path(R), R} || R <- All]),
           shadowed = ShadowedSorted}.

sort_key(R) ->
    {weberl_route:path(R), weberl_route:source(R), weberl_route:handler(R)}.
