%% @doc Connects the router to the template engine: finds the `.weberl'
%% templates under the filesystem roots, associates them with the views that
%% were discovered, and compiles and loads them. Called when a router starts.
%%
%% Layouts are the `.weberl' files below the router's `layouts' directories,
%% named by their base name (`layouts/main.weberl' is `main'). A view selects
%% one in its route options, `-weberl_route(#{layout => main}).'; a view without a
%% layout is a standalone page. Layouts are composed when the router starts. That
%% layout is the view's default; `layouts => [admin, none]' (or `all') lists others the view may
%% be rendered with, chosen per render (`weberl_template:render/3'). Every allowed pair is
%% composed and compiled at start. Layout files are not associated with
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
    %% View => {Default, Listed}: what the view's route options say (`layout' and `layouts')
    Selected = maps:from_list([{weberl_route:handler(R), {default(R), weberl_route:layouts(R)}}
                               || R <- FsRoutes]),
    Misplaced = [{weberl_route:handler(R), layout_needs_a_filesystem_view}
                 || R <- Routes, weberl_route:origin(R) =/= filesystem,
                    weberl_route:layout(R) =/= none orelse weberl_route:layouts(R) =/= []],
    case Misplaced of
        [] -> prepare(Router, Views, Selected, Table);
        _ -> {error, {invalid_templates, Misplaced}}
    end.

prepare(Router, Views, Selected, Table) ->
    LayoutFiles = lists:sort(lists:append([weberl_template:discover(D)
                                           || D <- weberl_config:layouts(Router)])),
    ComponentDirs = weberl_config:components(Router),
    ComponentFiles = lists:append([weberl_template:discover(D) || D <- ComponentDirs]),
    Templates = [T || T <- lists:append([weberl_template:discover(weberl_config:root(F))
                                         || F <- weberl_config:filesystem(Router)]),
                      not lists:member(norm(T), [norm(L) || L <- LayoutFiles ++ ComponentFiles])],
    case weberl_template:associate(Templates, Views) of
        {ok, Pairs} ->
            maybe
                {ok, Layouts} ?= layouts(LayoutFiles),
                {ok, Components} ?= weberl_template_component:load(ComponentDirs, #{routes => Table}),
                compile_all(Pairs, Views, Layouts, Selected,
                            #{routes => Table, components => Components})
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

compile_all(Pairs, Views, Layouts, Selected, CompileOpts) ->
    Templated = [View || {View, _} <- Pairs],
    Orphans = [{View, layout_without_template} || {View, _} <- Views,
                   not lists:member(View, Templated), maps:get(View, Selected) =/= {none, []}],
    Results = [{View, compile(View, File, Layouts, maps:get(View, Selected), CompileOpts)}
               || {View, File} <- Pairs],
    case Orphans ++ [{View, Reason} || {View, {error, Reason}} <- Results] of
        [] ->
            lists:foreach(fun({_, {ok, Compiled}}) ->
                                  log_warnings(lists:usort(lists:append([weberl_template:warnings(C)
                                                                         || C <- Compiled]))),
                                  lists:foreach(fun weberl_template:load/1, Compiled)
                          end, Results);
        Errors ->
            {error, {invalid_templates, Errors}}
    end.

%% The default layout the route declares, `none' for a bare view.
default(Route) ->
    case weberl_route:layout(Route) of
        {ok, Name} -> Name;
        none -> none
    end.

%% Every allowed pair of the view: the default one (the view's own module) and one module per
%% other layout of the route's `layouts'. {ok, [Compiled]} or the first error.
compile(View, File, Layouts, {Default, Listed}, Opts) ->
    Others = case Listed of
                 all -> lists:sort(maps:keys(Layouts));
                 Names -> Names
             end,
    Allowed = [Default | [N || N <- lists:usort(Others), N =/= Default]],
    Results = [compile_pair(View, File, Layouts, Name, Name =:= Default,
                            Opts#{layouts => Allowed}) || Name <- Allowed],
    case [Error || {error, _} = Error <- Results] of
        [] -> {ok, [C || {ok, C} <- Results]};
        [Error | _] -> Error
    end.

compile_pair(View, File, Layouts, Name, IsDefault, Opts0) ->
    Opts = case IsDefault of
               true -> Opts0;
               false -> Opts0#{variant => Name}
           end,
    case Name of
        none ->
            weberl_template:compile_file(View, File, none, Opts);
        _ ->
            case Layouts of
                #{Name := Layout} -> weberl_template:compile_file(View, File, Layout, Opts);
                _ -> {error, {unknown_layout, Name}}
            end
    end.


%% What the template compiler warned about (a link with a placeholder, say), once per router start.
log_warnings(Warnings) ->
    lists:foreach(fun({warning, File, Line, Reason}) ->
                          logger:warning("~ts:~p: template warning: ~p", [File, Line, Reason])
                  end, Warnings).

norm(Path) -> filename:join(filename:split(Path)).
