%% The URL helpers of templates (HANDOFF decisions 8 and 9): tagged values, encoding, the
%% checks, and the router-verified paths. The complaint behind them: a link with an id
%% or a `next' parameter in it needs a URL escape, not an HTML one.
-module(weberl_url_helpers_tests).
-include_lib("eunit/include/eunit.hrl").

error_of(Fun) ->
    try Fun() of V -> {no_error, V}
    catch error:{template_error, Reason} -> Reason end.

data(Tagged) -> weberl_url:data(Tagged).

%% ---------------------------------------------------------------------
%% component and query: an id or a `next' in a link

a_component_is_percent_encoded_test() ->
    ?assertEqual({weberl_url, component, <<"a%20b%2Fc">>}, weberl_url:component(<<"a b/c">>)),
    ?assertEqual(<<"..%2Fsecret">>, data(weberl_url:component(<<"../secret">>))),
    ?assertEqual(<<"%C3%A9">>, data(weberl_url:component(<<"é"/utf8>>))),
    ?assertEqual(<<"%C3%A9">>, data(weberl_url:component([233]))),
    ?assertEqual(<<"AZaz09-._~">>, data(weberl_url:component(<<"AZaz09-._~">>))),
    ?assertEqual(<<"%3Cscript%3E%22%27%26">>, data(weberl_url:component(<<"<script>\"'&">>))).

a_component_accepts_ids_and_atoms_test() ->
    ?assertEqual(<<"42">>, data(weberl_url:component(42))),
    ?assertEqual(<<"agent_7">>, data(weberl_url:component(agent_7))),
    ?assertEqual(<<"a%20b">>, data(weberl_url:component("a b"))).

a_component_rejects_what_has_no_text_test() ->
    ?assertEqual({bad_url_value, #{}}, error_of(fun() -> weberl_url:component(#{}) end)),
    ?assertEqual({bad_url_value, {a}}, error_of(fun() -> weberl_url:component({a}) end)),
    ?assertEqual({bad_url_value, 1.5}, error_of(fun() -> weberl_url:component(1.5) end)).

a_query_encodes_keys_and_values_test() ->
    ?assertEqual({weberl_url, query, <<"next=%2Fa%3Fb%3D1%26c%3D2">>},
                 weberl_url:query(#{next => <<"/a?b=1&c=2">>})),
    ?assertEqual(<<"a=1&b=x%20y">>, data(weberl_url:query(#{b => <<"x y">>, a => 1}))),
    ?assertEqual(<<"k=1&k=2">>, data(weberl_url:query([{k, 1}, {k, 2}]))),
    ?assertEqual(<<>>, data(weberl_url:query(#{}))),
    ?assertEqual(<<"q=%26%3Dx">>, data(weberl_url:query([{<<"q">>, <<"&=x">>}]))).

a_query_rejects_what_is_not_pairs_test() ->
    ?assertEqual({bad_url_value, x}, error_of(fun() -> weberl_url:query([x]) end)),
    ?assertEqual({bad_url_value, x}, error_of(fun() -> weberl_url:query(x) end)).

%% ---------------------------------------------------------------------
%% ensure_path: only a path on this site

ensure_path_accepts_a_local_path_test() ->
    ?assertEqual({weberl_url, path, <<"/agents/1?tab=2#x">>}, weberl_url:ensure_path(<<"/agents/1?tab=2#x">>)),
    ?assertEqual(<<"/">>, data(weberl_url:ensure_path("/"))).

ensure_path_raises_on_anything_else_test() ->
    [?assertEqual({not_a_path, V}, error_of(fun() -> weberl_url:ensure_path(V) end))
     || V <- [<<"https://example.com/x">>, <<"//evil.com">>, <<"/\\evil.com">>, <<"javascript:alert(1)">>,
              <<"relative/path">>, <<"../x">>, <<>>, <<"/a\nb">>, <<"/a\tb">>]].

%% ---------------------------------------------------------------------
%% url: a path or an http(s) URL

url_accepts_paths_and_web_urls_test() ->
    [?assertEqual({weberl_url, url, V}, weberl_url:url(V))
     || V <- [<<"/local">>, <<"http://example.com">>, <<"https://example.com/a?b=c#d">>,
              <<"HTTPS://EXAMPLE.COM/">>, <<"https://user@example.com:8080/x">>]].

url_raises_on_the_rest_test() ->
    [?assertEqual({not_a_url, V}, error_of(fun() -> weberl_url:url(V) end))
     || V <- [<<"javascript:alert(1)">>, <<"JaVaScRiPt:alert(1)">>, <<"data:text/html,x">>, <<"//evil.com">>,
              <<"mailto:a@b.c">>, <<"relative">>, <<"https://">>, <<"https:///evil.com">>,
              <<"https://exa mple.com">>, <<"https://evil.com\\@good.com">>, <<"http://a\nb">>,
              <<"ftp://example.com">>, <<"https:evil.com">>, <<>>]].

%% ---------------------------------------------------------------------
%% unsafe_url: no checks

unsafe_url_keeps_anything_test() ->
    ?assertEqual({weberl_url, unsafe, <<"javascript:alert(1)">>}, weberl_url:unsafe_url(<<"javascript:alert(1)">>)),
    ?assertEqual(<<"mailto:a@b.c">>, data(weberl_url:unsafe_url("mailto:a@b.c"))).

%% ---------------------------------------------------------------------
%% Tagged values

only_the_helpers_make_tagged_values_test() ->
    ?assert(weberl_url:is_tagged(weberl_url:component(<<"x">>))),
    ?assert(weberl_url:is_tagged(weberl_url:unsafe_url(<<"x">>))),
    ?assertEqual(component, weberl_url:kind(weberl_url:component(<<"x">>))),
    [?assertNot(weberl_url:is_tagged(V))
     || V <- [<<"/x">>, "/x", {weberl_url, path}, {weberl_url, path, "list"}, {weberl_url, <<"k">>, <<"x">>}, #{}]].

%% ---------------------------------------------------------------------
%% router_path / router_url

setup_router() ->
    Routes = [weberl_route:new(P, weberl_test_handlers, declarative, weberl_test_handlers)
              || P <- ["/", "/agents", "/agents/new", "/about"]],
    {ok, Table} = weberl_table:assemble([], Routes),
    Name = list_to_atom("url_router_" ++ integer_to_list(erlang:unique_integer([positive]))),
    persistent_term:put({weberl_router, Name}, Table),
    Name.

with_router(Fun) ->
    Name = setup_router(),
    try weberl_url:with_router(Name, Fun)
    after persistent_term:erase({weberl_router, Name})
    end.

router_path_accepts_a_route_test() ->
    with_router(fun() ->
        ?assertEqual({weberl_url, router_path, <<"/agents">>}, weberl_url:router_path("/agents")),
        ?assertEqual(<<"/agents/new">>, data(weberl_url:router_path(<<"/agents/new">>))),
        ?assertEqual(<<"/">>, data(weberl_url:router_path(<<"/">>))),
        %% a trailing slash names the same route; the route's own path is returned
        ?assertEqual(<<"/agents">>, data(weberl_url:router_path(<<"/agents/">>)))
    end).

router_path_raises_on_a_path_that_is_not_a_route_test() ->
    with_router(fun() ->
        ?assertEqual({unknown_route, <<"/agnts">>}, error_of(fun() -> weberl_url:router_path("/agnts") end)),
        ?assertEqual({unknown_route, <<"/agents/7">>}, error_of(fun() -> weberl_url:router_path("/agents/7") end)),
        ?assertEqual({unknown_route, <<"/agents/%2F">>}, error_of(fun() -> weberl_url:router_path("/agents/%2F") end))
    end).

router_path_is_still_a_path_test() ->
    with_router(fun() ->
        [?assertEqual({not_a_path, V}, error_of(fun() -> weberl_url:router_path(V) end))
         || V <- [<<"https://example.com/agents">>, <<"//agents">>, <<"agents">>]]
    end).

router_path_appends_an_encoded_query_test() ->
    with_router(fun() ->
        ?assertEqual(<<"/agents?q=a%20b&tab=2">>,
                     data(weberl_url:router_path("/agents", #{query => #{q => <<"a b">>, tab => 2}}))),
        ?assertEqual(<<"/agents">>, data(weberl_url:router_path("/agents", #{query => #{}}))),
        %% the query cannot change the path that was checked
        ?assertEqual(<<"/agents?next=%2Fabout">>,
                     data(weberl_url:router_path("/agents", #{query => [{next, <<"/about">>}]})))
    end).

router_path_options_are_checked_test() ->
    with_router(fun() ->
        ?assertEqual({bad_url_option, nope}, error_of(fun() -> weberl_url:router_path("/agents", #{nope => 1}) end)),
        ?assertEqual({bad_url_option, {no_warn, 1}}, error_of(fun() -> weberl_url:router_path("/agents", #{no_warn => 1}) end)),
        ?assertEqual({bad_url_option, {router, "x"}}, error_of(fun() -> weberl_url:router_path("/agents", #{router => "x"}) end)),
        ?assertEqual({bad_url_option, []}, error_of(fun() -> weberl_url:router_path("/agents", []) end)),
        %% no_warn is for the compiler: accepted, no effect here
        ?assertEqual(<<"/agents">>, data(weberl_url:router_path("/agents", #{no_warn => true})))
    end).

router_path_needs_a_router_test() ->
    ?assertEqual(no_router, error_of(fun() -> weberl_url:router_path("/agents") end)),
    ?assertEqual({router_not_running, nobody}, error_of(fun() -> weberl_url:router_path("/agents", #{router => nobody}) end)).

the_router_option_replaces_the_ambient_router_test() ->
    Name = setup_router(),
    try
        ?assertEqual(<<"/agents">>, data(weberl_url:router_path("/agents", #{router => Name}))),
        weberl_url:with_router(nobody, fun() ->
            ?assertEqual(<<"/about">>, data(weberl_url:router_path("/about", #{router => Name}))),
            ?assertEqual({router_not_running, nobody}, error_of(fun() -> weberl_url:router_path("/about") end))
        end)
    after persistent_term:erase({weberl_router, Name})
    end.

with_router_restores_the_previous_router_test() ->
    ?assertEqual(undefined, weberl_url:ambient_router()),
    weberl_url:with_router(a, fun() ->
        weberl_url:with_router(b, fun() -> ?assertEqual(b, weberl_url:ambient_router()) end),
        ?assertEqual(a, weberl_url:ambient_router())
    end),
    ?assertEqual(undefined, weberl_url:ambient_router()),
    ?assertError(boom, weberl_url:with_router(a, fun() -> error(boom) end)),
    ?assertEqual(undefined, weberl_url:ambient_router()).

router_url_uses_the_public_url_test() ->
    with_public_url("https://example.com/", fun() ->
        with_router(fun() ->
            ?assertEqual({weberl_url, router_url, <<"https://example.com/agents">>}, weberl_url:router_url("/agents")),
            ?assertEqual(<<"https://example.com/agents?q=x%20y">>,
                         data(weberl_url:router_url("/agents", #{query => #{q => <<"x y">>}}))),
            ?assertEqual(<<"https://example.com/">>, data(weberl_url:router_url("/"))),
            ?assertEqual({unknown_route, <<"/nope">>}, error_of(fun() -> weberl_url:router_url("/nope") end))
        end)
    end),
    with_public_url(<<"http://localhost:8080">>, fun() ->
        with_router(fun() ->
            ?assertEqual(<<"http://localhost:8080/about">>, data(weberl_url:router_url("/about")))
        end)
    end).

router_url_needs_a_good_public_url_test() ->
    with_router(fun() ->
        with_public_url(undefined, fun() ->
            ?assertEqual(no_public_url, error_of(fun() -> weberl_url:router_url("/agents") end))
        end),
        [with_public_url(V, fun() ->
            ?assertEqual({bad_public_url, V}, error_of(fun() -> weberl_url:router_url("/agents") end))
         end) || V <- ["example.com", "javascript:x", "https://example.com/base", "//example.com", "https://"]]
    end).

with_public_url(Value, Fun) ->
    Old = application:get_env(weberl, public_url),
    case Value of
        undefined -> application:unset_env(weberl, public_url);
        _ -> application:set_env(weberl, public_url, Value)
    end,
    try Fun()
    after
        case Old of
            {ok, O} -> application:set_env(weberl, public_url, O);
            undefined -> application:unset_env(weberl, public_url)
        end
    end.
