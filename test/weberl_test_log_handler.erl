%% Test logger handler: forwards events to a registered process.
-module(weberl_test_log_handler).
-export([log/2]).

log(Event, #{config := #{sink := Name}}) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> Pid ! {log, Event}, ok
    end.
