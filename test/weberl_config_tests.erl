-module(weberl_config_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router]).

defaults_test() ->
    {ok, C} = weberl_config:validate(#router{}),
    ?assertEqual([], weberl_config:filesystem(C)),
    ?assertEqual([], weberl_config:modules(C)).

filesystem_prefix_default_test() ->
    {ok, C} = weberl_config:validate(
                #router{filesystem = [#filesystem_router{root = "src/views"}]}),
    [Fs] = weberl_config:filesystem(C),
    ?assertEqual("src/views", weberl_config:root(Fs)),
    ?assertEqual("/", weberl_config:prefix(Fs)).

prefix_is_normalized_test() ->
    {ok, C} = weberl_config:validate(
                #router{filesystem = [#filesystem_router{root = "a", prefix = "//admin/"}]}),
    [Fs] = weberl_config:filesystem(C),
    ?assertEqual("/admin", weberl_config:prefix(Fs)).

valid_full_config_test() ->
    Config = #router{
                filesystem = [#filesystem_router{root = "src/views", prefix = "/"},
                              #filesystem_router{root = "src/admin/views", prefix = "/admin"}],
                modules = [my_app_router]},
    ?assertMatch({ok, _}, weberl_config:validate(Config)).

not_a_router_test() ->
    ?assertMatch({error, {invalid_config, {not_a_router, _}}},
                 weberl_config:validate(#{filesystem => []})).

filesystem_not_a_list_test() ->
    ?assertMatch({error, {invalid_config, {filesystem_not_a_list, _}}},
                 weberl_config:validate(#router{filesystem = x})).

filesystem_element_not_record_test() ->
    ?assertMatch({error, {invalid_config, {filesystem, 1, {not_a_filesystem_router, _}}}},
                 weberl_config:validate(#router{filesystem = [{"src/views", "/"}]})).

invalid_root_test() ->
    ?assertMatch({error, {invalid_config, {filesystem, 1, {invalid_root, _}}}},
                 weberl_config:validate(
                   #router{filesystem = [#filesystem_router{root = ""}]})),
    ?assertMatch({error, {invalid_config, {filesystem, 1, {invalid_root, _}}}},
                 weberl_config:validate(
                   #router{filesystem = [#filesystem_router{root = <<"bin">>}]})).

invalid_prefix_test() ->
    Bad = fun(P) ->
                  weberl_config:validate(
                    #router{filesystem = [#filesystem_router{root = "ok"},
                                          #filesystem_router{root = "ok", prefix = P}]})
          end,
    ?assertMatch({error, {invalid_config, {filesystem, 2, {invalid_prefix, "admin", _}}}},
                 Bad("admin")),
    ?assertMatch({error, {invalid_config, {filesystem, 2, {invalid_prefix, "/a/..", _}}}},
                 Bad("/a/..")),
    ?assertMatch({error, {invalid_config, {filesystem, 2, {invalid_prefix, "/a/*", _}}}},
                 Bad("/a/*")),
    ?assertMatch({error, {invalid_config, {filesystem, 2, {invalid_prefix, admin, _}}}},
                 Bad(admin)).

modules_not_a_list_test() ->
    ?assertMatch({error, {invalid_config, {modules_not_a_list, _}}},
                 weberl_config:validate(#router{modules = my_app_router})).

invalid_router_module_test() ->
    ?assertMatch({error, {invalid_config, {invalid_router_module, "x"}}},
                 weberl_config:validate(#router{modules = ["x"]})).

duplicate_router_module_test() ->
    ?assertMatch({error, {invalid_config, {duplicate_router_module, a}}},
                 weberl_config:validate(#router{modules = [a, b, a]})).
