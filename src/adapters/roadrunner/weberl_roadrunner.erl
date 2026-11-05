%% @doc Roadrunner transport adapter (optional).
%%
%% This module compiles and loads without Roadrunner installed. It only calls
%% Roadrunner at runtime, and reports `{error, {adapter_unavailable, roadrunner}}'
%% when the dependency is missing. An application using it declares
%% `roadrunner' in its own dependencies.
%%
%% Static mounts from the listener's `static' field are served by
%% `roadrunner_static' (ETag, ranges, precompressed `.br'/`.gz' siblings, path
%% traversal protection; a missing file is Roadrunner's own 404). Every other
%% request goes to the shared catch-all handler `weberl_roadrunner_handler',
%% which dispatches through the Weberl route table (the table is the route
%% state). Route matching, normalization and 404s therefore stay in Weberl.
%%
%% == Options ==
%% `options' in the `listener' record may contain only:
%% <ul>
%%   <li>`max_content_length': non-negative integer, request body limit (bytes);</li>
%%   <li>`request_timeout': non-negative integer, milliseconds;</li>
%%   <li>`tls': `[ssl:tls_server_option()]' to serve HTTPS.</li>
%% </ul>
%% Anything else is rejected.
%%
%% == Limitations ==
%% Roadrunner buffers the whole request body (up to `max_content_length', 10 MB
%% by default) before calling the handler, so `weberl_request:read_body/1'
%% returns data that is already in memory. Only buffered responses are produced.
-module(weberl_roadrunner).
-behaviour(weberl_adapter).

-export([validate_options/1, validate_static/1, start_listener/3,
         stop_listener/1, port/1]).

-define(ALLOWED, [max_content_length, request_timeout, tls, protocols]).
-define(STATIC_ALLOWED, [cache_control, symlink_policy, cache_ttl_ms]).

-spec validate_options(map()) -> ok | {error, term()}.
validate_options(Opts) when is_map(Opts) ->
    case [K || K <- maps:keys(Opts), not lists:member(K, ?ALLOWED)] of
        [] -> check_values(maps:to_list(Opts));
        Unknown -> {error, {unknown_options, lists:sort(Unknown)}}
    end;
validate_options(Other) ->
    {error, {options_not_a_map, Other}}.

%% @doc Static mount options: `cache_control' (binary or string),
%% `symlink_policy' (`refuse_escapes' | `follow' | `refuse') and
%% `cache_ttl_ms' (non-negative integer or `infinity').
-spec validate_static([{string(), term(), map()}]) -> ok | {error, term()}.
validate_static([]) ->
    ok;
validate_static([{Prefix, _Source, Opts} | Rest]) ->
    case [K || K <- maps:keys(Opts), not lists:member(K, ?STATIC_ALLOWED)] of
        [] ->
            case static_values(maps:to_list(Opts)) of
                ok -> validate_static(Rest);
                {error, {K, V}} -> {error, {invalid_static_option, Prefix, K, V}}
            end;
        Unknown ->
            {error, {unknown_static_options, Prefix, lists:sort(Unknown)}}
    end.

-spec start_listener(atom(), term(), weberl_table:t()) ->
    {ok, weberl_adapter:ref()} | {error, term()}.
start_listener(Name, Listener, Table) when is_atom(Name) ->
    case ensure_roadrunner() of
        ok ->
            %% Names are derived from unique router names, so a listener that
            %% already has this name is a leftover of a router process that was
            %% killed without cleaning up. Replace it.
            _ = stop_listener(Name),
            Opts = listener_opts(Listener, Table),
            try roadrunner:start_listener(Name, Opts) of
                {ok, _Pid} -> {ok, Name};
                {error, Reason} -> {error, {listener_start_failed, Reason}}
            catch
                Class:Reason -> {error, {listener_start_failed, {Class, Reason}}}
            end;
        {error, _} = Error ->
            Error
    end.

-spec stop_listener(weberl_adapter:ref()) -> ok | {error, term()}.
stop_listener(Name) ->
    try roadrunner:stop_listener(Name) of
        ok -> ok;
        {error, not_found} -> ok
    catch
        exit:{noproc, _} -> ok;
        Class:Reason -> {error, {listener_stop_failed, {Class, Reason}}}
    end.

-spec port(weberl_adapter:ref()) -> inet:port_number().
port(Name) -> roadrunner_listener:port(Name).

%% Internal

listener_opts(Listener, Table) ->
    Base = #{port => weberl_config:listener_port(Listener),
             routes => routes(Listener, Table)},
    WithIp = case weberl_config:listener_ip(Listener) of
                 undefined -> Base;
                 Ip -> Base#{ip => Ip}
             end,
    maps:merge(WithIp, weberl_config:listener_options(Listener)).

%% Static mounts first, then Weberl's own endpoints under `/_weberl' (the
%% beacon script and the live stream, WebSocket, long-poll and request
%% endpoints), then the catch-all that dispatches
%% through the Weberl table (a trailing `*' also matches the root path).
routes(Listener, Table) ->
    Static = [static_route(M) || M <- weberl_config:listener_static(Listener)],
    Static ++ internal_routes() ++ [{~"/*path", weberl_roadrunner_handler, Table}].

internal_routes() ->
    [{~"/_weberl/client.js", roadrunner_static,
      #{file => {priv, weberl, ~"client.js"}, cache_control => ~"no-cache"}},
     {~"/_weberl/engine.js", roadrunner_static,
      #{file => {priv, weberl, ~"engine.js"}, cache_control => ~"no-cache"}},
     {~"/_weberl/hub.js", roadrunner_static,
      #{file => {priv, weberl, ~"hub.js"}, cache_control => ~"no-cache"}},
     {~"/_weberl/sse/:id", weberl_roadrunner_sse, #{}},
     {~"/_weberl/ws", weberl_roadrunner_ws, #{}},
     {~"/_weberl/poll/:id", weberl_roadrunner_poll, #{}},
     {~"/_weberl/request/:id", weberl_roadrunner_request, #{}}].

static_route({Prefix, Source, Opts}) ->
    Path = unicode:characters_to_binary(Prefix ++ "/*path"),
    {Path, roadrunner_static, static_opts(Source, Opts)}.

static_opts({priv, App, Sub}, Opts) ->
    (cache_control(Opts))#{dir => {priv, App, unicode:characters_to_binary(Sub)}};
static_opts(Dir, Opts) ->
    (cache_control(Opts))#{dir => unicode:characters_to_binary(Dir)}.

cache_control(#{cache_control := CC} = Opts) when is_list(CC) ->
    Opts#{cache_control := unicode:characters_to_binary(CC)};
cache_control(Opts) ->
    Opts.

ensure_roadrunner() ->
    case application:ensure_all_started(roadrunner) of
        {ok, _} ->
            ok;
        {error, {roadrunner, {"no such file or directory", _}}} ->
            {error, {adapter_unavailable, roadrunner}};
        {error, Reason} ->
            {error, {adapter_start_failed, roadrunner, Reason}}
    end.

check_values([]) -> ok;
check_values([{K, V} | Rest]) ->
    case check_value(K, V) of
        true -> check_values(Rest);
        false -> {error, {invalid_option, K, V}}
    end.

static_values([]) -> ok;
static_values([{K, V} | Rest]) ->
    case static_value(K, V) of
        true -> static_values(Rest);
        false -> {error, {K, V}}
    end.

static_value(cache_control, V) -> is_binary(V) orelse is_list(V);
static_value(symlink_policy, V) -> lists:member(V, [refuse_escapes, follow, refuse]);
static_value(cache_ttl_ms, infinity) -> true;
static_value(cache_ttl_ms, V) -> is_integer(V) andalso V >= 0.

check_value(max_content_length, V) -> is_integer(V) andalso V >= 0;
check_value(request_timeout, V) -> is_integer(V) andalso V >= 0;
check_value(tls, V) -> is_list(V);
%% Roadrunner's own list: `http1', `http2', `http3' or `{http2, Opts}'.
check_value(protocols, V) -> is_list(V) andalso V =/= [].
