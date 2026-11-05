%% @doc Public configuration (native records) and validation.
%%
%% Consumers import the records:
%% ```
%% -import_record(weberl_config, [router, filesystem_router, listener]).
%% '''
-module(weberl_config).

-export([validate/1, filesystem/1, modules/1, layouts/1, root/1, prefix/1,
         validate_listener/1, listener_adapter/1, listener_ip/1,
         listener_port/1, listener_options/1, listener_static/1]).

-record #filesystem_router{
    root :: string(),
    prefix = "/" :: string()
}.

-record #router{
    filesystem = [] :: [filesystem_router],
    modules = [] :: [module()],
    layouts = [] :: [string()]
}.

%% Transport listener. `adapter' is a module implementing `weberl_adapter';
%% `ip' is the interface to bind (`undefined' = all); `port' 0 asks the OS for
%% a free port; `options' are adapter-specific (validated by the adapter).
%%
%% `static' lists static asset mounts served by the adapter before the route
%% table is consulted: `{UrlPrefix, Source}' or `{UrlPrefix, Source, Opts}'.
%% `Source' is a directory path or `{priv, App, SubPath}'. `Opts' is a map of
%% adapter-specific static options (validated by the adapter). Validation
%% normalizes every entry to the three-element form.
-record #listener{
    adapter = weberl_roadrunner :: module(),
    ip = undefined :: undefined | inet:ip_address(),
    port :: inet:port_number(),
    options = #{} :: map(),
    static = [] :: list()
}.

-export_record([router, filesystem_router, listener]).

%% @doc Validate a `router' configuration. On success the returned record has
%% normalized filesystem prefixes.
-spec validate(term()) -> {ok, #router{}} | {error, term()}.
validate(#router{filesystem = Fs, modules = Ms, layouts = Ls}) ->
    case validate_filesystem(Fs, 1, []) of
        {ok, Fs1} ->
            case validate_modules(Ms, []) of
                ok -> validate_layouts(Ls, Fs1, Ms);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end;
validate(Other) ->
    {error, {invalid_config, {not_a_router, Other}}}.

%% @doc Validate a `listener' configuration, including the adapter's own
%% options (`Adapter:validate_options/1').
-spec validate_listener(term()) -> {ok, #listener{}} | {error, term()}.
validate_listener(#listener{adapter = Adapter, ip = Ip, port = Port,
                            options = Opts, static = Static} = L) ->
    Checks = [fun() -> check_adapter(Adapter) end,
              fun() -> check_ip(Ip) end,
              fun() -> check_port(Port) end,
              fun() -> check_options_map(Opts) end,
              fun() -> check_adapter_options(Adapter, Opts) end],
    case run_checks(Checks) of
        ok ->
            case normalize_static(Static) of
                {ok, Static1} ->
                    case check_adapter_static(Adapter, Static1) of
                        ok -> {ok, L#listener{static = Static1}};
                        {error, Reason} ->
                            {error, {invalid_config, {listener, Reason}}}
                    end;
                {error, Reason} ->
                    {error, {invalid_config, {listener, Reason}}}
            end;
        {error, Reason} ->
            {error, {invalid_config, {listener, Reason}}}
    end;
validate_listener(Other) ->
    {error, {invalid_config, {not_a_listener, Other}}}.

-spec listener_adapter(#listener{}) -> module().
listener_adapter(#listener{adapter = A}) -> A.

-spec listener_ip(#listener{}) -> undefined | inet:ip_address().
listener_ip(#listener{ip = I}) -> I.

-spec listener_port(#listener{}) -> inet:port_number().
listener_port(#listener{port = P}) -> P.

-spec listener_options(#listener{}) -> map().
listener_options(#listener{options = O}) -> O.

%% @doc Normalized static mounts: `[{Prefix, Source, Opts}]'.
-spec listener_static(#listener{}) -> [{string(), term(), map()}].
listener_static(#listener{static = S}) -> S.

-spec filesystem(#router{}) -> [#filesystem_router{}].
filesystem(#router{filesystem = F}) -> F.

-spec modules(#router{}) -> [module()].
modules(#router{modules = M}) -> M.

%% @doc Directories whose `.weberl' files are layouts (see `weberl_template_layout').
-spec layouts(#router{}) -> [string()].
layouts(#router{layouts = L}) -> L.

-spec root(#filesystem_router{}) -> file:filename().
root(#filesystem_router{root = R}) -> R.

-spec prefix(#filesystem_router{}) -> string().
prefix(#filesystem_router{prefix = P}) -> P.

run_checks([]) -> ok;
run_checks([Check | Rest]) ->
    case Check() of
        ok -> run_checks(Rest);
        {error, _} = Error -> Error
    end.

check_adapter(Adapter) when is_atom(Adapter), Adapter =/= undefined ->
    case code:ensure_loaded(Adapter) of
        {module, Adapter} ->
            case erlang:function_exported(Adapter, validate_options, 1)
                andalso erlang:function_exported(Adapter, start_listener, 3)
                andalso erlang:function_exported(Adapter, stop_listener, 1) of
                true -> ok;
                false -> {error, {invalid_adapter, Adapter}}
            end;
        {error, _} ->
            {error, {adapter_not_found, Adapter}}
    end;
check_adapter(Other) ->
    {error, {invalid_adapter, Other}}.

check_ip(undefined) -> ok;
check_ip(Ip) ->
    case inet:is_ip_address(Ip) of
        true -> ok;
        false -> {error, {invalid_ip, Ip}}
    end.

check_port(Port) when is_integer(Port), Port >= 0, Port =< 65535 -> ok;
check_port(Port) -> {error, {invalid_port, Port}}.

check_options_map(Opts) when is_map(Opts) -> ok;
check_options_map(Opts) -> {error, {options_not_a_map, Opts}}.

check_adapter_options(Adapter, Opts) ->
    case Adapter:validate_options(Opts) of
        ok -> ok;
        {error, Reason} -> {error, {options, Reason}}
    end.

check_adapter_static(_Adapter, []) ->
    ok;
check_adapter_static(Adapter, Static) ->
    case erlang:function_exported(Adapter, validate_static, 1) of
        true ->
            case Adapter:validate_static(Static) of
                ok -> ok;
                {error, Reason} -> {error, {static, Reason}}
            end;
        false ->
            {error, {static, {static_unsupported, Adapter}}}
    end.

%% Static mounts: normalize prefixes, check sources, reject the reserved
%% `/_weberl' namespace, the root prefix, duplicates and nested prefixes.
normalize_static(Static) when is_list(Static) ->
    normalize_static(Static, 1, []);
normalize_static(Other) ->
    {error, {static, {not_a_list, Other}}}.

normalize_static([], _I, Acc) ->
    Mounts = lists:reverse(Acc),
    case overlapping(Mounts) of
        none -> {ok, Mounts};
        {A, B} -> {error, {static, {overlapping_prefixes, A, B}}}
    end;
normalize_static([Entry | Rest], I, Acc) ->
    case normalize_mount(Entry) of
        {ok, Mount} -> normalize_static(Rest, I + 1, [Mount | Acc]);
        {error, Reason} -> {error, {static, I, Reason}}
    end.

normalize_mount({Prefix, Source}) ->
    normalize_mount({Prefix, Source, #{}});
normalize_mount({Prefix, Source, Opts}) when is_map(Opts) ->
    case weberl_route:normalize_path(Prefix) of
        {ok, "/"} ->
            {error, {invalid_prefix, Prefix, root_not_allowed}};
        {ok, P} ->
            case reserved(P) of
                true -> {error, {invalid_prefix, Prefix, reserved}};
                false ->
                    case check_source(Source) of
                        ok -> {ok, {P, Source, Opts}};
                        {error, _} = Error -> Error
                    end
            end;
        {error, Reason} ->
            {error, {invalid_prefix, Prefix, Reason}}
    end;
normalize_mount(Other) ->
    {error, {not_a_static_mount, Other}}.

reserved("/_weberl") -> true;
reserved("/_weberl/" ++ _) -> true;
reserved(_) -> false.

check_source({priv, App, Sub}) when is_atom(App), App =/= undefined ->
    check_source_path(Sub, {priv, App, Sub});
check_source(Path) ->
    check_source_path(Path, Path).

check_source_path(Path, Source) when is_list(Path), Path =/= [] ->
    case io_lib:printable_unicode_list(Path) of
        true -> ok;
        false -> {error, {invalid_source, Source}}
    end;
check_source_path(_Path, Source) ->
    {error, {invalid_source, Source}}.

overlapping(Mounts) ->
    Prefixes = [P || {P, _, _} <- Mounts],
    Pairs = [{A, B} || A <- Prefixes, B <- Prefixes, A =/= B, under(B, A)],
    case lists:sort(Pairs) of
        [] -> dup_or_none(Prefixes);
        [Pair | _] -> Pair
    end.

dup_or_none(Prefixes) ->
    case Prefixes -- lists:usort(Prefixes) of
        [] -> none;
        [D | _] -> {D, D}
    end.

%% `B' is `A' or lies below it.
under(B, A) -> lists:prefix(A ++ "/", B).

validate_filesystem([], _I, Acc) ->
    {ok, lists:reverse(Acc)};
validate_filesystem([#filesystem_router{root = Root, prefix = Prefix} | Rest], I, Acc) ->
    case validate_root(Root) of
        ok ->
            case weberl_route:normalize_path(Prefix) of
                {ok, P} ->
                    Item = #filesystem_router{root = Root, prefix = P},
                    validate_filesystem(Rest, I + 1, [Item | Acc]);
                {error, Reason} ->
                    {error, {invalid_config,
                             {filesystem, I, {invalid_prefix, Prefix, Reason}}}}
            end;
        {error, Reason} ->
            {error, {invalid_config, {filesystem, I, Reason}}}
    end;
validate_filesystem([Other | _], I, _Acc) ->
    {error, {invalid_config, {filesystem, I, {not_a_filesystem_router, Other}}}};
validate_filesystem(Other, _I, _Acc) ->
    {error, {invalid_config, {filesystem_not_a_list, Other}}}.

validate_layouts(Ls, Fs, Ms) when is_list(Ls) ->
    case [L || L <- Ls, validate_root(L) =/= ok] of
        [] -> {ok, #router{filesystem = Fs, modules = Ms, layouts = Ls}};
        [Bad | _] -> {error, {invalid_config, {layouts, {invalid_directory, Bad}}}}
    end;
validate_layouts(Other, _Fs, _Ms) ->
    {error, {invalid_config, {layouts_not_a_list, Other}}}.

validate_root(Root) when is_list(Root), Root =/= [] ->
    case io_lib:printable_unicode_list(Root) of
        true -> ok;
        false -> {error, {invalid_root, Root}}
    end;
validate_root(Root) ->
    {error, {invalid_root, Root}}.

validate_modules([], _Seen) ->
    ok;
validate_modules([M | Rest], Seen) when is_atom(M) ->
    case lists:member(M, Seen) of
        true -> {error, {invalid_config, {duplicate_router_module, M}}};
        false -> validate_modules(Rest, [M | Seen])
    end;
validate_modules([M | _], _Seen) ->
    {error, {invalid_config, {invalid_router_module, M}}};
validate_modules(Other, _Seen) ->
    {error, {invalid_config, {modules_not_a_list, Other}}}.
