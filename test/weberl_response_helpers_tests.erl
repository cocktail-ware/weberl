%% Feedback from agentic (item 1): "Set-Cookie building (several cookies need
%% weberl_response:new/3 because with_header/3 replaces)", "303 redirects". Covers
%% add_header/3, set_cookie, delete_cookie, redirect and weberl_url:local/1, including
%% what reaches the wire through Roadrunner.
-module(weberl_response_helpers_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

base() -> weberl_response:html(200, <<"x">>).

%% ---------------------------------------------------------------------
%% add_header

add_header_keeps_repeats_test() ->
    R = weberl_response:add_header(weberl_response:add_header(base(), "X-A", "1"), "x-a", "2"),
    ?assertEqual([<<"1">>, <<"2">>], weberl_response:header_values(R, "X-A")),
    ?assertEqual({ok, <<"1">>}, weberl_response:header(R, "x-a")),
    %% with_header still replaces every header of that name
    R2 = weberl_response:with_header(R, "x-a", "3"),
    ?assertEqual([<<"3">>], weberl_response:header_values(R2, "x-a")).

new_keeps_repeated_headers_test() ->
    R = weberl_response:new(200, [{"Set-Cookie", "a=1"}, {"set-cookie", "b=2"}], <<>>),
    ?assertEqual([<<"a=1">>, <<"b=2">>], weberl_response:header_values(R, "set-cookie")).

headers_reject_injection_test_() ->
    [?_assertError(badarg, weberl_response:add_header(base(), "x-a", "1\r\nset-cookie: evil=1")),
     ?_assertError(badarg, weberl_response:with_header(base(), "x-a", "1\nx")),
     ?_assertError(badarg, weberl_response:add_header(base(), "x-a\r\ny", "1")),
     ?_assertError(badarg, weberl_response:add_header(base(), "x a", "1")),
     ?_assertError(badarg, weberl_response:add_header(base(), "", "1")),
     ?_assertError(badarg, weberl_response:new(200, [{"x", "a\r\nb"}], <<>>))].

%% ---------------------------------------------------------------------
%% set_cookie / delete_cookie

several_cookies_on_one_response_test() ->
    R = weberl_response:set_cookie(weberl_response:set_cookie(base(), "sid", "abc"),
                                   "csrf", "tok", #{http_only => false}),
    ?assertEqual([<<"sid=abc; Path=/; HttpOnly; SameSite=Lax">>,
                  <<"csrf=tok; Path=/; SameSite=Lax">>],
                 weberl_response:header_values(R, "set-cookie")).

cookie_options_test() ->
    Set = fun(Opts) ->
                  [C] = weberl_response:header_values(
                          weberl_response:set_cookie(base(), "n", "v", Opts), "set-cookie"),
                  C
          end,
    ?assertEqual(<<"n=v; Path=/app; Domain=example.com; Max-Age=60; Secure; HttpOnly; SameSite=Strict">>,
                 Set(#{path => "/app", domain => <<"example.com">>, max_age => 60, secure => true,
                       same_site => strict})),
    ?assertEqual(<<"n=v; Path=/; Secure; SameSite=None">>,
                 Set(#{secure => true, same_site => none, http_only => false})),
    ?assertEqual(<<"n=v; Path=/; HttpOnly; SameSite=Lax">>, Set(#{})).

cookie_name_and_value_are_validated_test_() ->
    Set = fun(N, V, O) -> weberl_response:set_cookie(base(), N, V, O) end,
    [?_assertError({invalid_cookie_name, <<>>}, Set("", "v", #{})),
     ?_assertError({invalid_cookie_name, <<"a b">>}, Set("a b", "v", #{})),
     ?_assertError({invalid_cookie_name, <<"a=b">>}, Set("a=b", "v", #{})),
     ?_assertError({invalid_cookie_value, <<"a;b">>}, Set("n", "a;b", #{})),
     ?_assertError({invalid_cookie_value, <<"a b">>}, Set("n", "a b", #{})),
     ?_assertError({invalid_cookie_value, <<"a\r\nSet-Cookie: x=1">>},
                   Set("n", "a\r\nSet-Cookie: x=1", #{})),
     ?_assertError({invalid_cookie_value, <<"\"q\"">>}, Set("n", "\"q\"", #{})),
     ?_assertError({invalid_cookie_attribute, path, <<"/a;Domain=evil">>},
                   Set("n", "v", #{path => "/a;Domain=evil"})),
     ?_assertError({invalid_cookie_attribute, domain, <<"x\r\ny">>},
                   Set("n", "v", #{domain => "x\r\ny"})),
     ?_assertError({invalid_cookie_option, {same_site, none, requires_secure}},
                   Set("n", "v", #{same_site => none})),
     ?_assertError({invalid_cookie_option, {max_age, -1}}, Set("n", "v", #{max_age => -1})),
     ?_assertError({invalid_cookie_option, {bogus, 1}}, Set("n", "v", #{bogus => 1}))].

delete_cookie_test() ->
    R = weberl_response:delete_cookie(base(), "sid", #{path => "/app"}),
    ?assertEqual([<<"sid=; Path=/app; Max-Age=0; HttpOnly; SameSite=Lax">>],
                 weberl_response:header_values(R, "set-cookie")),
    R2 = weberl_response:delete_cookie(base(), "sid"),
    ?assertEqual([<<"sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax">>],
                 weberl_response:header_values(R2, "set-cookie")).

%% ---------------------------------------------------------------------
%% redirect

redirect_defaults_to_303_test() ->
    R = weberl_response:redirect("/login"),
    ?assertEqual(303, weberl_response:status(R)),
    ?assertEqual({ok, <<"/login">>}, weberl_response:header(R, "location")),
    ?assertEqual(<<>>, iolist_to_binary(weberl_response:body(R))).

redirect_statuses_test_() ->
    [?_assertEqual(S, weberl_response:status(weberl_response:redirect(S, "/x")))
     || S <- [301, 302, 303, 307, 308]]
        ++ [?_assertError(badarg, weberl_response:redirect(200, "/x")),
            ?_assertError(badarg, weberl_response:redirect(304, "/x")),
            ?_assertError(badarg, weberl_response:redirect("/x\r\nset-cookie: a=1")),
            ?_assertError(badarg, weberl_response:redirect(<<>>))].

redirect_with_cookie_test() ->
    R = weberl_response:set_cookie(weberl_response:redirect("/home"), "sid", "s"),
    ?assertEqual(303, weberl_response:status(R)),
    ?assertEqual({ok, <<"/home">>}, weberl_response:header(R, "location")),
    ?assertEqual([<<"sid=s; Path=/; HttpOnly; SameSite=Lax">>],
                 weberl_response:header_values(R, "set-cookie")).

%% ---------------------------------------------------------------------
%% weberl_url:local/1 (what to check before redirecting to a client supplied target)

local_urls_test_() ->
    Local = ["/", "/home", "/a/b?c=d#e", <<"/items/5">>, "/%2Fx"],
    Other = ["//evil.com", "/\\evil.com", "http://evil.com", "https://x", "javascript:alert(1)",
             "next", "../x", "", "/\r\n/evil", "/\t/evil.com", "/ok\n", " /x", <<"//x">>, undefined, 5],
    [?_assert(weberl_url:local(U)) || U <- Local]
        ++ [?_assertNot(weberl_url:local(U)) || U <- Other].

%% ---------------------------------------------------------------------
%% On the wire: repeated set-cookie reaches the browser as separate headers

wire_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             Login = handler("login", """
                 handle(_) ->
                     R = weberl_response:redirect("/home"),
                     R1 = weberl_response:set_cookie(R, "sid", "abc", #{max_age => 3600}),
                     weberl_response:set_cookie(R1, "csrf", "tok", #{http_only => false}).
                 """),
             Name = weberl_test_handlers:unique("resp_helpers"),
             M = weberl_test_handlers:unique("resp_helpers_router"),
             load_router(M, [{"/login", Login}]),
             {ok, _} = weberl:start_link(Name, #router{modules = [M]},
                                         #listener{port = 0, ip = {127, 0, 0, 1}}),
             Name
     end,
     fun(Name) -> weberl:stop(Name) end,
     fun(Name) ->
             [{"a redirect with two cookies", fun() -> redirect_with_cookies_over_http(Name) end}]
     end}.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

redirect_with_cookies_over_http(Name) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ "/login",
    {ok, {{_, Status, _}, Headers, _}} =
        httpc:request(get, {Url, []}, [{autoredirect, false}], [{body_format, binary}]),
    ?assertEqual(303, Status),
    ?assertEqual("/home", proplists:get_value("location", Headers)),
    ?assertEqual(["sid=abc; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax",
                  "csrf=tok; Path=/; SameSite=Lax"],
                 proplists:get_all_values("set-cookie", Headers)).
