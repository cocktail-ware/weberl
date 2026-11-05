-module(weberl_config_static_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [listener]).
-on_load(ensure_records/0).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

validate(Static) ->
    weberl_config:validate_listener(#listener{port = 0, static = Static}).

err(Reason) -> {error, {invalid_config, {listener, Reason}}}.

default_is_empty_test() ->
    {ok, L} = weberl_config:validate_listener(#listener{port = 0}),
    ?assertEqual([], weberl_config:listener_static(L)).

normalizes_to_three_tuples_test() ->
    {ok, L} = validate([{"/static/", "assets"},
                        {"//img//", {priv, weberl, "img"}, #{cache_ttl_ms => 10}}]),
    ?assertEqual([{"/static", "assets", #{}},
                  {"/img", {priv, weberl, "img"}, #{cache_ttl_ms => 10}}],
                 weberl_config:listener_static(L)).

root_prefix_rejected_test() ->
    ?assertEqual(err({static, 1, {invalid_prefix, "/", root_not_allowed}}),
                 validate([{"/", "assets"}])).

reserved_prefix_rejected_test_() ->
    [?_assertEqual(err({static, 1, {invalid_prefix, P, reserved}}),
                   validate([{P, "assets"}]))
     || P <- ["/_weberl", "/_weberl/js"]].

invalid_prefix_rejected_test() ->
    ?assertMatch({error, {invalid_config, {listener, {static, 1, {invalid_prefix, "x", _}}}}},
                 validate([{"x", "assets"}])),
    ?assertMatch({error, {invalid_config, {listener, {static, 1, {invalid_prefix, "/a/*", _}}}}},
                 validate([{"/a/*", "assets"}])).

invalid_source_rejected_test_() ->
    [?_assertEqual(err({static, 1, {invalid_source, S}}), validate([{"/s", S}]))
     || S <- ["", <<"bin">>, 5, {priv, "app", "x"}]].

malformed_mount_rejected_test() ->
    ?assertEqual(err({static, 2, {not_a_static_mount, foo}}),
                 validate([{"/a", "d"}, foo])).

not_a_list_test() ->
    ?assertEqual(err({static, {not_a_list, foo}}), validate(foo)).

duplicate_prefix_rejected_test() ->
    ?assertEqual(err({static, {overlapping_prefixes, "/s", "/s"}}),
                 validate([{"/s", "a"}, {"/s/", "b"}])).

nested_prefix_rejected_test() ->
    ?assertEqual(err({static, {overlapping_prefixes, "/a", "/a/b"}}),
                 validate([{"/a/b", "x"}, {"/a", "y"}])).

sibling_prefixes_allowed_test() ->
    ?assertMatch({ok, _}, validate([{"/a", "x"}, {"/ab", "y"}])).

adapter_options_checked_test_() ->
    [?_assertEqual(err({static, {unknown_static_options, "/s", [bogus]}}),
                   validate([{"/s", "d", #{bogus => 1}}])),
     ?_assertEqual(err({static, {invalid_static_option, "/s", symlink_policy, nope}}),
                   validate([{"/s", "d", #{symlink_policy => nope}}])),
     ?_assertEqual(err({static, {invalid_static_option, "/s", cache_ttl_ms, -1}}),
                   validate([{"/s", "d", #{cache_ttl_ms => -1}}])),
     ?_assertMatch({ok, _},
                   validate([{"/s", "d", #{cache_control => <<"max-age=60">>,
                                           symlink_policy => follow,
                                           cache_ttl_ms => infinity}}]))].

adapter_without_static_support_test() ->
    L = #listener{adapter = weberl_test_no_static_adapter, port = 0,
                  static = [{"/s", "d"}]},
    ?assertEqual(err({static, {static_unsupported, weberl_test_no_static_adapter}}),
                 weberl_config:validate_listener(L)).

adapter_without_static_ok_when_unused_test() ->
    L = #listener{adapter = weberl_test_no_static_adapter, port = 0},
    ?assertMatch({ok, _}, weberl_config:validate_listener(L)).
