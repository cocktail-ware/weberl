%% @doc Connects the router to the template engine: finds the `.weberl'
%% templates under the filesystem roots, associates them with the views that
%% were discovered, and compiles and loads them. Called when a router starts.
%%
%% All templates are compiled before any is loaded, so a router either gets all
%% its templates or none are replaced. Errors:
%% `{unassociated_templates, Files}', `{duplicate_template_associations, _}',
%% `{invalid_templates, [{View, Reason}]}'.
-module(weberl_views).

-export([prepare/2]).

%% @doc `Router' is a validated `weberl_config' `router'; `Table' its table.
-spec prepare(term(), weberl_table:t()) -> ok | {error, term()}.
prepare(Router, Table) ->
    Views = [{weberl_route:handler(R), weberl_route:source(R)}
             || R <- weberl_table:routes(Table), weberl_route:origin(R) =:= filesystem],
    Templates = lists:append([weberl_template:discover(weberl_config:root(F))
                              || F <- weberl_config:filesystem(Router)]),
    case weberl_template:associate(Templates, Views) of
        {ok, Pairs} -> compile_all(Pairs);
        {error, _} = Error -> Error
    end.

compile_all(Pairs) ->
    Results = [{View, weberl_template:compile_file(View, File)} || {View, File} <- Pairs],
    case [{View, Reason} || {View, {error, Reason}} <- Results] of
        [] ->
            lists:foreach(fun({_, {ok, Compiled}}) -> weberl_template:load(Compiled) end, Results);
        Errors ->
            {error, {invalid_templates, Errors}}
    end.
