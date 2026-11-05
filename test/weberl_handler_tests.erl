-module(weberl_handler_tests).
-include_lib("eunit/include/eunit.hrl").

load(Src) ->
    Mod = weberl_test_handlers:unique("wh"),
    weberl_test_handlers:load(Mod, "-module(" ++ atom_to_list(Mod) ++ "). " ++ Src),
    Mod.

check_ok_test() ->
    M = load("-export([handle/1]). handle(_) -> weberl_response:text(200, <<>>)."),
    ?assertEqual(ok, weberl_handler:check(M)),
    ?assertEqual({ok, #{}}, weberl_handler:metadata(M)).

check_missing_handle_test() ->
    M = load("-export([other/0]). other() -> ok."),
    ?assertEqual({error, {invalid_handler, M, missing_callback_handle_1}},
                 weberl_handler:check(M)).

check_wrong_arity_test() ->
    M = load("-export([handle/0]). handle() -> ok."),
    ?assertEqual({error, {invalid_handler, M, missing_callback_handle_1}},
                 weberl_handler:check(M)).

check_not_loadable_test() ->
    ?assertMatch({error, {invalid_handler, no_such_weberl_handler, {not_loadable, _}}},
                 weberl_handler:check(no_such_weberl_handler)).

metadata_callback_test() ->
    M = load("-export([handle/1, weberl_metadata/0]). handle(_) -> ok. "
             "weberl_metadata() -> #{layout => main}."),
    ?assertEqual({ok, #{layout => main}}, weberl_handler:metadata(M)),
    ?assertEqual(ok, weberl_handler:check(M)).

metadata_not_a_map_test() ->
    M = load("-export([handle/1, weberl_metadata/0]). handle(_) -> ok. "
             "weberl_metadata() -> [not_a_map]."),
    ?assertEqual({error, {invalid_handler, M, {invalid_metadata, [not_a_map]}}},
                 weberl_handler:check(M)).

metadata_crash_test() ->
    M = load("-export([handle/1, weberl_metadata/0]). handle(_) -> ok. "
             "weberl_metadata() -> erlang:error(boom)."),
    ?assertEqual({error, {invalid_handler, M, {metadata_failed, error, boom}}},
                 weberl_handler:check(M)).
