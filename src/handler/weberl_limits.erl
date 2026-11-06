%% @doc Limits on what a form submission may contain (HANDOFF.md, decision 13).
%%
%% A form is limited by six independent keys, each a non-negative integer:
%% <ul>
%%   <li>`max_fields': text fields (urlencoded pairs, or multipart parts without a filename);</li>
%%   <li>`max_field_bytes': the size of one text value;</li>
%%   <li>`max_files': file parts;</li>
%%   <li>`max_file_bytes': the size of one file;</li>
%%   <li>`max_filename_bytes': the length of a client's file name;</li>
%%   <li>`max_body_bytes': the whole request body, files and framing included. Enforced by
%%       the transport before the body is read (Roadrunner's `max_content_length', per
%%       route), so it is set in configuration, not per call; unset it is the listener's
%%       `max_content_length' (10 MiB for Roadrunner).</li>
%% </ul>
%% They are layered, the most specific winning, and each key on its own:
%% ```
%% per call    weberl_request:multipart(Request, #{max_file_bytes => 50 * 1024 * 1024})
%% route       -weberl_route(#{limits => #{max_body_bytes => ..., max_file_bytes => ...}}).
%% router      the `limits' of the router configuration
%% global      application env `weberl', `form_limits' (a map)
%% default     {@link defaults/0}
%% '''
%% Raising the limits for one upload route means setting `max_body_bytes' and
%% `max_file_bytes' on that route together.
%%
%% A limit that is exceeded is logged as a warning (`form_limit_exceeded': the limit,
%% what is allowed, what was seen, the path and the handler; never the content) and
%% the parse returns `{error, {limit_exceeded, Limit}}'.
-module(weberl_limits).

-include_lib("kernel/include/logger.hrl").

-export([defaults/0, check/1, check_call/1, check_env/0, audit/1, effective/2, exceeded/4, keys/0]).
-export_type([limits/0, limit/0]).

-type limit() :: max_fields | max_field_bytes | max_files | max_file_bytes
               | max_filename_bytes | max_body_bytes.
-type limits() :: #{limit() => non_neg_integer()}.

-define(MIB, 1048576).

-spec keys() -> [limit()].
keys() -> [max_fields, max_field_bytes, max_files, max_file_bytes, max_filename_bytes, max_body_bytes].

%% @doc The built-in limits. `max_body_bytes' is not among them: unset, the transport's
%% own limit applies.
-spec defaults() -> limits().
defaults() ->
    #{max_fields => 100,
      max_field_bytes => ?MIB,
      max_files => 10,
      max_file_bytes => 5 * ?MIB,
      max_filename_bytes => 255}.

%% @doc Validate limits given in configuration (a route, a router, the application env).
-spec check(term()) -> {ok, limits()} | {error, term()}.
check(Limits) when is_map(Limits) ->
    case [K || K := _ <- Limits, not lists:member(K, keys())] of
        [Unknown | _] ->
            {error, {unknown_limit, Unknown}};
        [] ->
            case [{K, V} || K := V <- Limits, not (is_integer(V) andalso V >= 0)] of
                [{K, V} | _] -> {error, {invalid_limit, K, V}};
                [] -> {ok, Limits}
            end
    end;
check(Other) ->
    {error, {invalid_limits, Other}}.

%% @doc Validate the limits of one call: as {@link check/1}, but `max_body_bytes' is read by
%% the transport before the handler runs, so it cannot be given per call.
-spec check_call(term()) -> {ok, limits()} | {error, term()}.
check_call(#{max_body_bytes := _}) ->
    {error, {limit_not_allowed_here, max_body_bytes}};
check_call(Limits) ->
    check(Limits).

%% @doc Validate the `form_limits' of the application env (checked when a router starts).
-spec check_env() -> {ok, limits()} | {error, term()}.
check_env() ->
    check(application:get_env(weberl, form_limits, #{})).

%% @doc Checked when a router starts: the application env's `form_limits' has to be valid (else
%% `{error, {invalid_config, {form_limits, Reason}}}'), and a route whose `max_body_bytes' is
%% below its `max_file_bytes' is logged (`form_limits_inconsistent'): a file of that size could
%% never arrive.
-spec audit(weberl_table:t()) -> ok | {error, term()}.
audit(Table) ->
    case check_env() of
        {error, Reason} ->
            {error, {invalid_config, {form_limits, Reason}}};
        {ok, Env} ->
            Base = lists:foldl(fun(Layer, Acc) -> maps:merge(Acc, Layer) end, defaults(),
                               [Env, weberl_table:limits(Table)]),
            lists:foreach(fun(Route) -> audit_route(Route, Base) end, weberl_table:routes(Table))
    end.

audit_route(Route, Base) ->
    Limits = maps:merge(Base, weberl_route:limits(Route)),
    case Limits of
        #{max_body_bytes := Body, max_file_bytes := File} when File > Body ->
            ?LOG_WARNING(#{what => form_limits_inconsistent, path => weberl_route:path(Route),
                           handler => weberl_route:handler(Route), max_body_bytes => Body,
                           max_file_bytes => File});
        _ ->
            ok
    end.

%% @doc The limits in force for a request: the defaults, the application env, the
%% limits dispatch resolved for the route (route over router), then the call's own.
-spec effective(weberl_request:t(), limits()) -> limits().
effective(Request, Call) ->
    lists:foldl(fun(Layer, Acc) -> maps:merge(Acc, Layer) end, defaults(),
                [env(), weberl_request:limits(Request), Call]).

env() ->
    case check_env() of
        {ok, Limits} -> Limits;
        {error, _} -> #{}
    end.

%% @doc Log an exceeded limit and give the error to return.
-spec exceeded(limit(), non_neg_integer(), non_neg_integer(), weberl_request:t()) ->
    {error, {limit_exceeded, limit()}}.
exceeded(Limit, Allowed, Seen, Request) ->
    ?LOG_WARNING(#{what => form_limit_exceeded, limit => Limit, allowed => Allowed, seen => Seen,
                   path => weberl_request:path(Request),
                   handler => maps:get(handler, weberl_request:route(Request), undefined)}),
    {error, {limit_exceeded, Limit}}.
