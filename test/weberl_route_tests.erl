-module(weberl_route_tests).
-include_lib("eunit/include/eunit.hrl").

root_test() ->
    ?assertEqual({ok, "/"}, weberl_route:normalize_path("/")).

collapse_and_trailing_slash_test() ->
    ?assertEqual({ok, "/a/b"}, weberl_route:normalize_path("//a//b/")).

must_start_with_slash_test() ->
    ?assertEqual({error, must_start_with_slash}, weberl_route:normalize_path("a")),
    ?assertEqual({error, must_start_with_slash}, weberl_route:normalize_path("")).

dot_segments_test() ->
    ?assertMatch({error, {invalid_segment, ".."}}, weberl_route:normalize_path("/a/../b")),
    ?assertMatch({error, {invalid_segment, "."}}, weberl_route:normalize_path("/a/./b")).

dynamic_and_wildcard_unsupported_test() ->
    ?assertMatch({error, {unsupported_segment, ":id"}}, weberl_route:normalize_path("/a/:id")),
    ?assertMatch({error, {unsupported_segment, "*"}}, weberl_route:normalize_path("/a/*")).

invalid_chars_test() ->
    ?assertMatch({error, {invalid_segment, "a b"}}, weberl_route:normalize_path("/a b")),
    ?assertMatch({error, {invalid_segment, "a?b"}}, weberl_route:normalize_path("/a?b")).

not_a_string_test() ->
    ?assertEqual({error, not_a_string}, weberl_route:normalize_path(<<"/a">>)),
    ?assertEqual({error, not_a_string}, weberl_route:normalize_path(foo)).

accessors_test() ->
    R = weberl_route:new("/x", some_handler, declarative, some_router),
    ?assertEqual("/x", weberl_route:path(R)),
    ?assertEqual(some_handler, weberl_route:handler(R)),
    ?assertEqual(declarative, weberl_route:origin(R)),
    ?assertEqual(some_router, weberl_route:source(R)).
