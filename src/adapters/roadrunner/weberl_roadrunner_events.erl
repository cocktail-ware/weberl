%% @doc An opt-in Roadrunner event handler that logs a request refused for its body size.
%%
%% The body cap (`max_body_bytes' of {@link weberl_limits}, Roadrunner's `max_content_length') is
%% enforced by Roadrunner before the body is read and before Weberl sees the request, and Roadrunner
%% reports it only as an event, which its default handler drops. Enable this handler to have it in
%% the log, with the listener and the client's address (the path is not known at that point):
%% ```
%% %% sys.config
%% [{roadrunner, [{event_handler, weberl_roadrunner_events}]}].
%% '''
%% There is one handler per node, read when the `roadrunner' application starts. An application with
%% a handler of its own can call {@link handle_event/2} from it. Only the body-size rejection is
%% logged: the other rejections (malformed requests) are left alone, as a flood of them is how a log is
%% filled.
-module(weberl_roadrunner_events).

-include_lib("kernel/include/logger.hrl").

-export([handle_event/2]).

-spec handle_event(atom(), term()) -> ok.
handle_event(request_rejected, {Listener, Peer, content_length_too_large}) ->
    ?LOG_WARNING(#{what => request_body_too_large, listener => Listener, peer => peer(Peer)}),
    ok;
handle_event(_Event, _Args) ->
    ok.

peer({Ip, Port}) ->
    try iolist_to_binary([inet:ntoa(Ip), $:, integer_to_binary(Port)])
    catch _:_ -> Ip
    end;
peer(Other) ->
    Other.
