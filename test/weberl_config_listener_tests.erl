-module(weberl_config_listener_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [listener]).
-on_load(ensure_records/0).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

defaults_test() ->
    L = #listener{port = 8888},
    ?assertEqual({ok, L}, weberl_config:validate_listener(L)),
    ?assertEqual(weberl_roadrunner, weberl_config:listener_adapter(L)),
    ?assertEqual(undefined, weberl_config:listener_ip(L)),
    ?assertEqual(8888, weberl_config:listener_port(L)),
    ?assertEqual(#{}, weberl_config:listener_options(L)).

full_test() ->
    L = #listener{port = 0, ip = {127, 0, 0, 1},
                  options = #{max_content_length => 1024, request_timeout => 500}},
    ?assertEqual({ok, L}, weberl_config:validate_listener(L)).

ipv6_ip_test() ->
    L = #listener{port = 80, ip = {0, 0, 0, 0, 0, 0, 0, 1}},
    ?assertEqual({ok, L}, weberl_config:validate_listener(L)).

not_a_listener_test() ->
    ?assertEqual({error, {invalid_config, {not_a_listener, foo}}},
                 weberl_config:validate_listener(foo)).

invalid_port_test_() ->
    [?_assertEqual({error, {invalid_config, {listener, {invalid_port, P}}}},
                   weberl_config:validate_listener(#listener{port = P}))
     || P <- [-1, 65536, "80", http, undefined]].

invalid_ip_test_() ->
    [?_assertEqual({error, {invalid_config, {listener, {invalid_ip, I}}}},
                   weberl_config:validate_listener(#listener{port = 1, ip = I}))
     || I <- [{1, 2, 3}, {256, 0, 0, 1}, "127.0.0.1"]].

adapter_not_found_test() ->
    ?assertEqual({error, {invalid_config, {listener, {adapter_not_found, no_such_adapter_mod}}}},
                 weberl_config:validate_listener(
                   #listener{adapter = no_such_adapter_mod, port = 1})).

invalid_adapter_test_() ->
    [?_assertEqual({error, {invalid_config, {listener, {invalid_adapter, A}}}},
                   weberl_config:validate_listener(#listener{adapter = A, port = 1}))
     || A <- ["roadrunner", 5, lists]].

options_not_a_map_test() ->
    ?assertEqual({error, {invalid_config, {listener, {options_not_a_map, [a]}}}},
                 weberl_config:validate_listener(#listener{port = 1, options = [a]})).

unknown_adapter_option_test() ->
    ?assertEqual({error, {invalid_config, {listener, {options, {unknown_options, [b, z]}}}}},
                 weberl_config:validate_listener(
                   #listener{port = 1, options = #{z => 1, b => 2, request_timeout => 1}})).

invalid_adapter_option_value_test_() ->
    [?_assertEqual({error, {invalid_config, {listener, {options, {invalid_option, K, V}}}}},
                   weberl_config:validate_listener(#listener{port = 1, options = #{K => V}}))
     || {K, V} <- [{max_content_length, -1}, {max_content_length, big},
                   {request_timeout, "5"}, {tls, not_a_list},
                   {protocols, http1}, {protocols, []}]].
