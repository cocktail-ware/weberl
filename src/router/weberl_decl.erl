%% @doc Declarative route collection.
%%
%% A router module exports `routes/0' returning a list of `{Path, HandlerModule}'
%% or `{Path, HandlerModule, Opts}' entries, where `Opts' is a map
%% (`#{live => normal | one_way | two_way}'). Several paths may reference the
%% same handler.
-module(weberl_decl).

-export([collect/1, collect_module/1]).

%% @doc Collect routes from several router modules, in the given order.
-spec collect([module()]) -> {ok, [weberl_route:t()]} | {error, term()}.
collect(Modules) ->
    collect(Modules, []).

collect([], Acc) ->
    {ok, lists:append(lists:reverse(Acc))};
collect([M | Rest], Acc) ->
    case collect_module(M) of
        {ok, Routes} -> collect(Rest, [Routes | Acc]);
        {error, _} = Error -> Error
    end.

%% @doc Collect and normalize the routes of one router module.
-spec collect_module(module()) -> {ok, [weberl_route:t()]} | {error, term()}.
collect_module(M) when is_atom(M) ->
    case code:ensure_loaded(M) of
        {module, M} ->
            case erlang:function_exported(M, routes, 0) of
                true -> run(M);
                false -> {error, {missing_routes_function, M}}
            end;
        {error, Reason} ->
            {error, {router_module_not_loadable, M, Reason}}
    end.

run(M) ->
    try M:routes() of
        Entries when is_list(Entries) -> normalize_entries(M, Entries, []);
        Other -> {error, {invalid_routes_return, M, Other}}
    catch
        Class:Reason -> {error, {routes_failed, M, {Class, Reason}}}
    end.

normalize_entries(_M, [], Acc) ->
    {ok, lists:reverse(Acc)};
normalize_entries(M, [{Path, Handler} = Entry | Rest], Acc) ->
    route(M, Entry, Path, Handler, #{}, Rest, Acc);
normalize_entries(M, [{Path, Handler, Opts} = Entry | Rest], Acc) ->
    route(M, Entry, Path, Handler, Opts, Rest, Acc);
normalize_entries(M, [Entry | _], _Acc) ->
    {error, {invalid_route, M, Entry, malformed_entry}};
normalize_entries(M, Other, _Acc) ->
    {error, {invalid_routes_return, M, Other}}.

route(M, Entry, _Path, Handler, _Opts, _Rest, _Acc) when not is_atom(Handler) ->
    {error, {invalid_route, M, Entry, {invalid_handler, Handler}}};
route(M, Entry, Path, Handler, Opts, Rest, Acc) ->
    case weberl_route:normalize_pattern(Path) of
        {ok, P} ->
            case weberl_route:check_opts(Opts) of
                {ok, Opts1} ->
                    Route = weberl_route:new(P, Handler, declarative, M, Opts1),
                    normalize_entries(M, Rest, [Route | Acc]);
                {error, Reason} ->
                    {error, {invalid_route, M, Entry, {invalid_options, Reason}}}
            end;
        {error, Reason} ->
            {error, {invalid_route, M, Entry, {invalid_path, Reason}}}
    end.
