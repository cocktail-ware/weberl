%% @doc Transport-independent request dispatch.
%%
%% Resolves a request against a route table, invokes the handler and returns a
%% `weberl_response'. Never raises:
%% <ul>
%%   <li>unmatched route: 404 `Not Found' (text/plain);</li>
%%   <li>an unsafe method (`POST', `PUT', `PATCH', `DELETE') that fails the route's
%%       CSRF check (`weberl_csrf'): 403 `Forbidden', the handler is not called;</li>
%%   <li>`one_way' / `two_way' routes: the handler's topics are resolved
%%       (`weberl_live:topics/2'; invalid ones are a 500), a live session is
%%       opened (unless the route says `session => false', then the page id is
%%       just generated; it is `weberl_request:page/1' either way), and the
%%       beacon script, whose token carries the topics, is injected into a 2xx
%%       HTML response. Any other response closes the session again.</li>
%%   <li>handler raises, exits or throws, or returns anything other than a
%%       `weberl_response': 500 `Internal Server Error' (text/plain). The
%%       client sees no details; the cause is logged with the method, path,
%%       handler and stacktrace.</li>
%% </ul>
-module(weberl_dispatch).

-include_lib("kernel/include/logger.hrl").

-export([dispatch/2]).

-spec dispatch(weberl_request:t(), weberl_table:t()) -> weberl_response:t().
dispatch(Request0, Table) ->
    case weberl_table:match(weberl_request:path(Request0), Table) of
        {ok, Route, Raw} ->
            case decode_params(Raw) of
                {ok, Params} ->
                    Limits = maps:merge(weberl_table:limits(Table), weberl_route:limits(Route)),
                    Request = weberl_request:with_route(weberl_request:with_params(Request0, Params),
                                                        #{handler => weberl_route:handler(Route), limits => Limits,
                                                          data => weberl_route:data(Route)}),
                    weberl_url:with_router(Table, fun() -> routed(Route, Request) end);
                error ->
                    %% a `%' that is not an escape, or a value that is not UTF-8
                    ?LOG_WARNING(#{what => invalid_path_parameter,
                                   path => weberl_request:path(Request0),
                                   handler => weberl_route:handler(Route)}),
                    weberl_response:text(400, <<"Bad Request">>)
            end;
        {error, not_found} ->
            weberl_response:text(404, <<"Not Found">>)
    end.

routed(Route, Request) ->
    case weberl_csrf:check(weberl_route:csrf(Route), Request) of
        ok ->
            with_session(Request, fun() -> serve(weberl_route:live(Route), Route, Request) end);
        {error, {limit_exceeded, _}} ->
            %% the form that was read for the token is too big: already logged by weberl_limits
            weberl_response:text(413, <<"Payload Too Large">>);
        {error, Reason} ->
            ?LOG_WARNING(#{what => csrf_rejected, reason => Reason,
                           method => weberl_request:method(Request),
                           path => weberl_request:path(Request),
                           handler => weberl_route:handler(Route)}),
            weberl_response:text(403, <<"Forbidden">>)
    end.

%% Percent-decode each parameter value (once), all or nothing.
decode_params(Raw) ->
    maps:fold(fun(_Name, _Value, error) -> error;
                 (Name, Value, {ok, Acc}) ->
                      case weberl_route:decode_segment(Value) of
                          {ok, Decoded} -> {ok, Acc#{Name => Decoded}};
                          error -> error
                      end
              end, {ok, #{}}, Raw).

%% The request is available to the session functions of `weberl_response' while
%% the handler runs; afterwards the session the response carries becomes its cookie.
with_session(Request, Serve) ->
    ok = weberl_csrf:begin_request(),
    Response = weberl_session:run(Request, Serve),
    case weberl_session:finalize(Request, weberl_csrf:finalize(Response)) of
        {ok, Final} ->
            Final;
        {error, Reason} ->
            ?LOG_ERROR(#{what => session_not_written, reason => Reason,
                         method => weberl_request:method(Request),
                         path => weberl_request:path(Request)}),
            internal_error()
    end.

serve(normal, Route, Request) ->
    invoke(weberl_route:handler(Route), Request);
serve(Kind, Route, Request) ->
    Handler = weberl_route:handler(Route),
    case weberl_live:topics(Route, Request) of
        {ok, Topics} ->
            live(Kind, Route, Topics, Request);
        {error, Reason} ->
            ?LOG_ERROR(#{what => live_topics_failed, handler => Handler,
                         path => weberl_request:path(Request), reason => Reason}),
            internal_error()
    end.

%% The page's id comes from a session (a process per page) or, for a
%% session-less page, is just generated: its token carries what the connection
%% needs to know.
live(Kind, Route, Topics, Request) ->
    Handler = weberl_route:handler(Route),
    Session = weberl_route:session(Route),
    case open(Session, Kind, Handler, Topics, Request) of
        {ok, PageId} ->
            Response = invoke(Handler, weberl_request:with_page(Request, PageId)),
            case final_kind(Kind, Response, Request) of
                {ok, Final} ->
                    finish(Final, Kind, Response, {PageId, Session, Handler, Topics}, Request);
                error ->
                    Session andalso weberl_live:close(PageId),
                    internal_error()
            end;
        {error, Reason} ->
            %% Live support is unavailable: serve the page without it.
            ?LOG_ERROR(#{what => live_open_failed, reason => Reason,
                         path => weberl_request:path(Request)}),
            invoke(Handler, Request)
    end.

%% The kind the page is served as: the route's, or what the handler narrowed it
%% to (`weberl_response:live/2'). Widening it is a bug of the handler.
final_kind(Kind, Response, Request) ->
    case weberl_response:live(Response) of
        undefined ->
            {ok, Kind};
        Wanted ->
            case rank(Wanted) =< rank(Kind) of
                true ->
                    {ok, Wanted};
                false ->
                    ?LOG_ERROR(#{what => live_kind_widened, route_kind => Kind,
                                 requested => Wanted, path => weberl_request:path(Request)}),
                    error
            end
    end.

rank(normal) -> 0;
rank(one_way) -> 1;
rank(two_way) -> 2.

%% Serve the response as `Final'. `normal' (or a response that cannot carry the
%% beacon) ends the session; a live page gets the beacon and is kept out of
%% shared caches.
finish(Final, Kind, Response, {PageId, Session, Handler, Topics}, Request) ->
    case Final =/= normal andalso weberl_live_beacon:injectable(Response) of
        true ->
            Session andalso Final =/= Kind andalso weberl_live:downgrade(PageId, Final),
            Claims = #{session => Session, handler => Handler, topics => Topics},
            Injected = weberl_live_beacon:inject(Response, {PageId, Final, Claims}),
            weberl_live_beacon:cache_control(
              Injected, #{path => weberl_request:path(Request), handler => Handler});
        false ->
            Session andalso weberl_live:close(PageId),
            case Final of
                %% A downgrade is decided per request (who is asking), so the
                %% plain page varies like the live one and must not be shared.
                normal ->
                    weberl_live_beacon:cache_control(
                      Response, #{path => weberl_request:path(Request), handler => Handler});
                _ ->
                    Response
            end
    end.

open(true, Kind, Handler, Topics, Request) ->
    Owner = maps:get(listener, weberl_request:meta(Request), undefined),
    weberl_live:open(Owner, Kind, #{handler => Handler, topics => Topics});
open(false, _Kind, _Handler, _Topics, _Request) ->
    {ok, weberl_live:new_page_id()}.

invoke(Handler, Request) ->
    try Handler:handle(Request) of
        Result ->
            case weberl_response:normalize(Result) of
                {ok, Response} ->
                    Response;
                {error, Reason} ->
                    log_failure(Handler, Request, error, Reason, []),
                    internal_error()
            end
    catch
        Class:Reason:Stack ->
            log_failure(Handler, Request, Class, Reason, Stack),
            internal_error()
    end.

internal_error() ->
    weberl_response:text(500, <<"Internal Server Error">>).

log_failure(Handler, Request, Class, Reason, Stack) ->
    ?LOG_ERROR(#{what => handler_failure,
                 handler => Handler,
                 method => weberl_request:method(Request),
                 path => weberl_request:path(Request),
                 class => Class,
                 reason => Reason,
                 stacktrace => Stack}).
