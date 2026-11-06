%% Minimal adapter without the optional validate_static/1 callback.
-module(weberl_test_no_static_adapter).
-behaviour(weberl_adapter).

-export([validate_options/1, start_listener/3, stop_listener/1, port/1,
         cookies/1, form/1, multipart/1]).

validate_options(_) -> ok.
cookies(_) -> [].
form(_) -> {error, no_content_type}.
multipart(_) -> {error, no_content_type}.
start_listener(Name, _Listener, _Table) -> {ok, Name}.
stop_listener(_) -> ok.
port(_) -> 0.
