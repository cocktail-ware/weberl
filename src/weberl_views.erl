%% @doc Connects the router to the template engine: finds the `.weberl'
%% templates under the filesystem roots, associates them with the views that
%% were discovered, and compiles and loads them. Called when a router starts.
%%
%% Layouts are the `.weberl' files below the router's `layouts' directories,
%% named by their base name (`layouts/main.weberl' is `main'). A view selects
%% one in its route options, `-weberl_route(#{layout => main}).'; a view without a
%% layout is a standalone page. Layouts are composed when the router starts, so
%% the choice is per view, not per request. Layout files are not associated with
%% views, so they may also live below a filesystem root.
%%
%% All templates are compiled before any is loaded, so a router either gets all
%% its templates or none are replaced. Errors:
%% `{unassociated_templates, Files}', `{duplicate_template_associations, _}',
%% `{duplicate_layouts, [{Name, Files}]}', `{invalid_layouts, [{Name, Reason}]}',
%% `{invalid_templates, [{View, Reason}]}' (Reason may be `{unknown_layout, Name}',
%% `layout_without_template' or, for a declarative route that names a layout,
%% `layout_needs_a_filesystem_view':
%% only filesystem views have templates).
-module(weberl_views).

-export([prepare/2]).

%% @doc `Router' is a validated `weberl_config' `router'; `Table' its table.
-spec prepare(term(), weberl_table:t()) -> ok | {error, term()}.
prepare(Router, Table) ->
    Routes = weberl_table:routes(Table),
    FsRoutes = [R || R <- Routes, weberl_route:origin(R) =:= filesystem],
    Views = [{weberl_route:handler(R), weberl_route:source(R)} || R <- FsRoutes],
    %% View => {ok, Layout} | none: what the view's route options say
    Selected = maps:from_list([{weberl_route:handler(R), weberl_route:layout(R)} || R <- FsRoutes]),
    Misplaced = [{weberl_route:handler(R), layout_needs_a_filesystem_view}
                 || R <- Routes, weberl_route:origin(R) =/= filesystem,
                    weberl_route:layout(R) =/= none],
    case Misplaced of
        [] -> prepare(Router, Views, Selected, Table);
        _ -> {error, {invalid_templates, Misplaced}}
    end.

prepare(Router, Views, Selected, Table) ->
    LayoutFiles = lists:sort(lists:append([weberl_template:discover(D)
                                           || D <- weberl_config:layouts(Router)])),
    Templates = [T || T <- lists:append([weberl_template:discover(weberl_config:root(F))
                                         || F <- weberl_config:filesystem(Router)]),
                      not lists:member(norm(T), [norm(L) || L <- LayoutFiles])],
    case weberl_template:associate(Templates, Views) of
        {ok, Pairs} ->
            case layouts(LayoutFiles) of
                {ok, Layouts} -> compile_all(Pairs, Views, Layouts, Selected, Table);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

layouts(Files) ->
    Named = [{list_to_atom(filename:basename(F, ".weberl")), F} || F <- Files],
    Groups = lists:foldl(fun({N, F}, Acc) -> maps:update_with(N, fun(L) -> [F | L] end, [F], Acc) end,
                         #{}, Named),
    case [{N, lists:sort(Fs)} || {N, [_, _ | _] = Fs} <- lists:sort(maps:to_list(Groups))] of
        [] ->
            Results = [{N, weberl_template:parse_layout(F)} || {N, F} <- Named],
            case [{N, Reason} || {N, {error, Reason}} <- Results] of
                [] -> {ok, maps:from_list([{N, L} || {N, {ok, L}} <- Results])};
                Errors -> {error, {invalid_layouts, Errors}}
            end;
        Dups ->
            {error, {duplicate_layouts, Dups}}
    end.

compile_all(Pairs, Views, Layouts, Selected, Table) ->
    Templated = [View || {View, _} <- Pairs],
    Orphans = [{View, layout_without_template} || {View, _} <- Views,
                   not lists:member(View, Templated), maps:get(View, Selected) =/= none],
    Results = [{View, compile(View, File, Layouts, maps:get(View, Selected), #{routes => Table})}
               || {View, File} <- Pairs],
    case Orphans ++ [{View, Reason} || {View, {error, Reason}} <- Results] of
        [] ->
            lists:foreach(fun({_, {ok, Compiled}}) ->
                                  log_warnings(weberl_template:warnings(Compiled)),
                                  weberl_template:load(Compiled)
                          end, Results);
        Errors ->
            {error, {invalid_templates, Errors}}
    end.

compile(View, File, _Layouts, none, Opts) ->
    weberl_template:compile_file(View, File, none, Opts);
compile(View, File, Layouts, {ok, Name}, Opts) ->
    case Layouts of
        #{Name := Layout} -> weberl_template:compile_file(View, File, Layout, Opts);
        _ -> {error, {unknown_layout, Name}}
    end.


%% What the template compiler warned about (a link with a placeholder, say), once per router start.
log_warnings(Warnings) ->
    lists:foreach(fun({warning, File, Line, Reason}) ->
                          logger:warning("~ts:~p: template warning: ~p", [File, Line, Reason])
                  end, Warnings).

norm(Path) -> filename:join(filename:split(Path)).
