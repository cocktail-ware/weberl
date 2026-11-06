%% Feedback from agentic (item 1): "CSRF (double-submit cookie)" was hand-written in the
%% application. The framework now checks the Origin and a signed double-submit token on
%% unsafe methods, and `weberl_form' puts the token in the form.
-module(weberl_csrf_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

%% ---------------------------------------------------------------------
%% Origin check (headers only, no adapter needed)

req(Method, Headers) ->
    req(Method, Headers, #{}).

req(Method, Headers, Meta) ->
    weberl_request:new(#{method => Method, path => "/x", headers => Headers, meta => Meta}).

origin_check_test_() ->
    Host = {<<"host">>, <<"app.test:8443">>},
    Ok = fun(Headers, Meta) -> weberl_csrf:origin_ok(req(<<"POST">>, Headers, Meta)) end,
    [{"no Origin passes", ?_assert(Ok([Host], #{}))},
     {"same origin passes", ?_assert(Ok([Host, {<<"origin">>, <<"https://app.test:8443">>}], #{}))},
     {"case does not matter", ?_assert(Ok([Host, {<<"origin">>, <<"HTTPS://APP.test:8443">>}], #{}))},
     {"another host", ?_assertNot(Ok([Host, {<<"origin">>, <<"https://evil.test">>}], #{}))},
     {"another port", ?_assertNot(Ok([Host, {<<"origin">>, <<"https://app.test:9999">>}], #{}))},
     {"a suffix is not the host",
      ?_assertNot(Ok([Host, {<<"origin">>, <<"https://app.test:8443.evil.test">>}], #{}))},
     {"null origin", ?_assertNot(Ok([Host, {<<"origin">>, <<"null">>}], #{}))},
     {"garbage origin", ?_assertNot(Ok([Host, {<<"origin">>, <<"app.test:8443">>}], #{}))},
     {"Origin without Host", ?_assertNot(Ok([{<<"origin">>, <<"https://app.test:8443">>}], #{}))},
     {"an http origin on an https listener is a downgrade",
      ?_assertNot(Ok([Host, {<<"origin">>, <<"http://app.test:8443">>}], #{scheme => https}))},
     {"an http origin on an http listener",
      ?_assert(Ok([Host, {<<"origin">>, <<"http://app.test:8443">>}], #{scheme => http}))}].

allowed_origins_test() ->
    Headers = [{<<"host">>, <<"internal:8080">>}, {<<"origin">>, <<"https://www.example.com">>}],
    ?assertNot(weberl_csrf:origin_ok(req(<<"POST">>, Headers))),
    application:set_env(weberl, csrf_origins, [<<"https://www.example.com">>]),
    try
        ?assert(weberl_csrf:origin_ok(req(<<"POST">>, Headers))),
        ?assertNot(weberl_csrf:origin_ok(
                     req(<<"POST">>, [{<<"host">>, <<"internal:8080">>},
                                      {<<"origin">>, <<"https://other.example.com">>}])))
    after
        application:unset_env(weberl, csrf_origins)
    end.

check_modes_test_() ->
    Evil = [{<<"host">>, <<"a.test">>}, {<<"origin">>, <<"https://evil.test">>}],
    Good = [{<<"host">>, <<"a.test">>}, {<<"origin">>, <<"https://a.test">>}],
    [{"mode false checks nothing", ?_assertEqual(ok, weberl_csrf:check(false, req(<<"POST">>, Evil)))},
     {"safe methods are not checked",
      [?_assertEqual(ok, weberl_csrf:check(true, req(M, Evil))) || M <- [<<"GET">>, <<"HEAD">>, <<"OPTIONS">>]]},
     {"unsafe methods are",
      [?_assertEqual({error, origin_mismatch}, weberl_csrf:check(origin, req(M, Evil)))
       || M <- [<<"POST">>, <<"PUT">>, <<"PATCH">>, <<"DELETE">>]]},
     {"mode origin needs no token", ?_assertEqual(ok, weberl_csrf:check(origin, req(<<"POST">>, Good)))},
     {"mode origin still refuses a foreign origin",
      ?_assertEqual({error, origin_mismatch}, weberl_csrf:check(true, req(<<"DELETE">>, Evil)))}].

route_option_test_() ->
    [?_assertEqual({ok, #{csrf => origin}}, weberl_route:check_opts(#{csrf => origin})),
     ?_assertEqual({ok, #{csrf => false}}, weberl_route:check_opts(#{csrf => false})),
     ?_assertEqual({error, {invalid_csrf, token}}, weberl_route:check_opts(#{csrf => token})),
     ?_assertEqual(true, weberl_route:csrf(weberl_route:new("/a", ?MODULE, declarative, "x", #{}))),
     ?_assertEqual(false, weberl_route:csrf(weberl_route:new("/a", ?MODULE, declarative, "x",
                                                             #{csrf => false})))].

%% ---------------------------------------------------------------------
%% protect/2 with a stub adapter (a request without cookies)

stub(Headers) ->
    req(<<"GET">>, Headers, #{adapter => weberl_test_no_static_adapter}).

protect_sets_the_cookie_test() ->
    R = weberl_csrf:protect(stub([]), fun(Token) -> weberl_response:html(200, Token) end),
    [Cookie] = weberl_response:header_values(R, "set-cookie"),
    {Name, Token} = cookie_pair(Cookie),
    ?assertEqual(<<"weberl_csrf">>, Name),
    ?assertEqual(Token, iolist_to_binary(weberl_response:body(R))),
    ?assertMatch({match, _}, re:run(Cookie, "; HttpOnly; SameSite=Lax$")),
    ?assertEqual(nomatch, re:run(Cookie, "Secure")),
    ?assertEqual({ok, <<"private, no-store">>}, weberl_response:header(R, "cache-control")).

protect_keeps_a_handler_cache_control_test() ->
    R = weberl_csrf:protect(stub([]),
                            fun(_) ->
                                    weberl_response:with_header(weberl_response:html(200, <<>>),
                                                                "cache-control", "private, max-age=5")
                            end),
    ?assertEqual({ok, <<"private, max-age=5">>}, weberl_response:header(R, "cache-control")).

secure_mode_test() ->
    application:set_env(weberl, secure_cookies, true),
    try
        R = weberl_csrf:protect(stub([]), fun(_) -> weberl_response:html(200, <<>>) end),
        [Cookie] = weberl_response:header_values(R, "set-cookie"),
        ?assertMatch(<<"__Host-weberl_csrf=", _/binary>>, Cookie),
        ?assertMatch({match, _}, re:run(Cookie, "; Path=/; Secure; HttpOnly")),
        ?assertEqual(<<"__Host-weberl_csrf">>, weberl_csrf:cookie_name())
    after
        application:unset_env(weberl, secure_cookies)
    end.

cookie_pair(SetCookie) ->
    [Pair | _] = binary:split(SetCookie, <<";">>),
    [Name, Value] = binary:split(Pair, <<"=">>),
    {Name, Value}.

%% ---------------------------------------------------------------------
%% weberl_form

form_test_() ->
    Input = <<"<input type=\"hidden\" name=\"_csrf\" value=\"TOK\">">>,
    Open = fun(Token, Action, Opts) -> iolist_to_binary(weberl_form:open(Token, Action, Opts)) end,
    [{"post form with the token by default",
      ?_assertEqual(<<"<form method=\"post\" action=\"/login\">", Input/binary>>,
                    Open(<<"TOK">>, "/login", #{}))},
     {"csrf => false leaves the token out (and needs none)",
      ?_assertEqual(<<"<form method=\"post\" action=\"/api\">">>,
                    Open(undefined, "/api", #{csrf => false}))},
     {"a get form never carries a token",
      ?_assertEqual(<<"<form method=\"get\" action=\"/search\">">>,
                    Open(<<"TOK">>, "/search", #{method => get}))},
     {"attributes are escaped and enctype goes after action",
      ?_assertEqual(<<"<form method=\"post\" action=\"/up\" enctype=\"text/plain\" "
                      "class=\"a&quot;b\">", Input/binary>>,
                    Open(<<"TOK">>, "/up", #{enctype => "text/plain",
                                             attrs => [{"class", "a\"b"}]}))},
     {"a multipart form carries its token in the action, not in a field",
      [?_assertEqual(<<"<form method=\"post\" action=\"/up?_csrf=TOK\" enctype=\"multipart/form-data\">">>,
                     Open(<<"TOK">>, "/up", #{enctype => multipart})),
       ?_assertEqual(<<"<form method=\"post\" action=\"/up?_csrf=TOK\" enctype=\"multipart/form-data\">">>,
                     Open(<<"TOK">>, "/up", #{enctype => "Multipart/Form-Data"})),
       %% an action with a query keeps it; the token is encoded
       ?_assertEqual(<<"<form method=\"post\" action=\"/up?kind=a&amp;_csrf=a.b%2Fc\" enctype=\"multipart/form-data\">">>,
                     Open(<<"a.b/c">>, "/up?kind=a", #{enctype => multipart})),
       %% csrf => false: no token anywhere
       ?_assertEqual(<<"<form method=\"post\" action=\"/up\" enctype=\"multipart/form-data\">">>,
                     Open(undefined, "/up", #{enctype => multipart, csrf => false}))]},
     {"the token is escaped",
      ?_assertEqual(<<"<input type=\"hidden\" name=\"_csrf\" value=\"a&quot;&gt;\">">>,
                    iolist_to_binary(weberl_form:csrf_input(<<"a\">">>)))},
     {"absolute http(s) actions are fine",
      ?_assertMatch(<<"<form method=\"post\" action=\"https://pay.example/x\">", _/binary>>,
                    Open(<<"TOK">>, "https://pay.example/x", #{}))},
     {"unsafe actions raise",
      [?_assertError(badarg, Open(<<"TOK">>, A, #{}))
       || A <- ["javascript:alert(1)", "//evil.test/x", "relative", "", "/x\r\ny", "https://"]]},
     {"bad options raise",
      [?_assertError(badarg, Open(<<"TOK">>, "/x", #{method => delete})),
       ?_assertError(badarg, Open(<<"TOK">>, "/x", #{attrs => [{"a b", "v"}]})),
       ?_assertError(badarg, Open(<<"TOK">>, "/x", #{attrs => [{"onclick=x y", "v"}]})),
       ?_assertError(badarg, Open(undefined, "/x", #{}))]}].

%% ---------------------------------------------------------------------
%% The whole flow over HTTP: what agentic wrote by hand, now from the framework

flow_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             start_app()
     end,
     fun(Name) -> weberl:stop(Name) end,
     fun(Name) ->
             [{"the page sets the cookie and carries the same token", fun() -> page(Name) end},
              {"a browser that has the cookie gets the same token", fun() -> page_again(Name) end},
              {"submit with cookie and field", fun() -> submit_ok(Name) end},
              {"submit with cookie and header (scripts)", fun() -> submit_header(Name) end},
              {"submit without the cookie", fun() -> submit_no_cookie(Name) end},
              {"submit without the field", fun() -> submit_no_field(Name) end},
              {"submit with another token", fun() -> submit_other_token(Name) end},
              {"a forged or planted cookie", fun() -> submit_forged(Name) end},
              {"a cross-site form post with the victim's cookie", fun() -> cross_site(Name) end},
              {"a same-site Origin is accepted", fun() -> same_site(Name) end},
              {"PUT and DELETE are checked too", fun() -> other_methods(Name) end},
              {"mode origin: no token, foreign origin refused", fun() -> origin_mode(Name) end},
              {"mode false: nothing is checked", fun() -> off_mode(Name) end},
              {"GET is never checked", fun() -> get_not_checked(Name) end}]
     end}.

start_app() ->
    Page = handler("page", """
        handle(R) ->
            weberl_csrf:protect(R, fun(Token) ->
                weberl_response:html(200, [weberl_form:open(Token, "/submit"), <<"</form>">>])
            end).
        """),
    Submit = handler("submit", """
        handle(R) -> weberl_response:text(200, <<"saved ", (weberl_request:method(R))/binary>>).
        """),
    Name = weberl_test_handlers:unique("csrf_flow"),
    M = weberl_test_handlers:unique("csrf_flow_router"),
    load_router(M, [{"/page", Page},
                    {"/submit", Submit},
                    {"/hook", Submit, #{csrf => origin}},
                    {"/open", Submit, #{csrf => false}}]),
    {ok, _} = weberl:start_link(Name, #router{modules = [M]},
                                #listener{port = 0, ip = {127, 0, 0, 1}}),
    Name.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

http(Method, Name, Path, Headers, Body) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    Req = case Method of
              get -> {Url, Headers};
              _ -> {Url, Headers, "application/x-www-form-urlencoded", Body}
          end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        quiet(fun() -> httpc:request(Method, Req, [], [{body_format, binary}]) end),
    {Status, RespHeaders, RespBody}.

quiet(Fun) ->
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, maps:get(level, Old)) end.

%% GET /page -> {Token, Headers, Body}
fetch_page(Name, Headers) ->
    {200, H, B} = http(get, Name, "/page", Headers, <<>>),
    {H, B}.

token_of_cookie(Headers) ->
    [Cookie] = proplists:get_all_values("set-cookie", Headers),
    {match, [Token]} = re:run(Cookie, "^weberl_csrf=([^;]+);", [{capture, all_but_first, binary}]),
    Token.

token_in_form(Body) ->
    {match, [Token]} = re:run(Body, "name=\"_csrf\" value=\"([^\"]+)\"", [{capture, all_but_first, binary}]),
    Token.

cookie_header(Token) -> {"cookie", "weberl_csrf=" ++ binary_to_list(Token)}.

body(Token) -> <<"_csrf=", Token/binary, "&title=hello">>.

page(Name) ->
    {H, B} = fetch_page(Name, []),
    Token = token_of_cookie(H),
    ?assertEqual(Token, token_in_form(B)),
    ?assertMatch(<<"<form method=\"post\" action=\"/submit\">", _/binary>>, B),
    ?assertEqual("private, no-store", proplists:get_value("cache-control", H)),
    ?assertMatch([_, _], binary:split(Token, <<".">>)).

page_again(Name) ->
    {H, _} = fetch_page(Name, []),
    Token = token_of_cookie(H),
    {H2, B2} = fetch_page(Name, [cookie_header(Token)]),
    ?assertEqual(Token, token_in_form(B2)),
    ?assertEqual([], proplists:get_all_values("set-cookie", H2)).

new_token(Name) ->
    {H, _} = fetch_page(Name, []),
    token_of_cookie(H).

submit_ok(Name) ->
    T = new_token(Name),
    ?assertMatch({200, _, <<"saved POST">>},
                 http(post, Name, "/submit", [cookie_header(T)], body(T))).

submit_header(Name) ->
    T = new_token(Name),
    ?assertMatch({200, _, <<"saved POST">>},
                 http(post, Name, "/submit",
                      [cookie_header(T), {"x-csrf-token", binary_to_list(T)}], <<"title=hello">>)).

submit_no_cookie(Name) ->
    T = new_token(Name),
    ?assertMatch({403, _, <<"Forbidden">>}, http(post, Name, "/submit", [], body(T))).

submit_no_field(Name) ->
    T = new_token(Name),
    ?assertMatch({403, _, <<"Forbidden">>},
                 http(post, Name, "/submit", [cookie_header(T)], <<"title=hello">>)),
    ?assertMatch({403, _, <<"Forbidden">>},
                 http(post, Name, "/submit", [cookie_header(T)], <<"_csrf=&title=hello">>)).

submit_other_token(Name) ->
    T1 = new_token(Name),
    T2 = new_token(Name),
    ?assertNotEqual(T1, T2),
    ?assertMatch({403, _, <<"Forbidden">>},
                 http(post, Name, "/submit", [cookie_header(T1)], body(T2))).

submit_forged(Name) ->
    T = new_token(Name),
    [Nonce, Mac] = binary:split(T, <<".">>),
    Forged = [<<"abc">>, <<"abc.def">>, <<Nonce/binary, ".AAAA">>,
              <<"AAAAAAAAAAAAAAAAAAAAAA.", Mac/binary>>,   %% another nonce with our MAC
              <<Nonce/binary, ".", Nonce/binary>>],
    [?assertMatch({403, _, <<"Forbidden">>},
                  http(post, Name, "/submit", [cookie_header(F)], body(F))) || F <- Forged].

cross_site(Name) ->
    T = new_token(Name),
    %% evil.test makes the victim's browser post a form: it sends the cookie and an
    %% Origin of the attacker, but the attacker cannot know the token, so even a
    %% guess with the right cookie fails; and with the token it fails on the Origin.
    ?assertMatch({403, _, _}, http(post, Name, "/submit",
                                   [cookie_header(T), {"origin", "https://evil.test"}],
                                   <<"title=hello">>)),
    ?assertMatch({403, _, _}, http(post, Name, "/submit",
                                   [cookie_header(T), {"origin", "https://evil.test"}], body(T))),
    ?assertMatch({403, _, _}, http(post, Name, "/submit",
                                   [cookie_header(T), {"origin", "null"}], body(T))).

same_site(Name) ->
    T = new_token(Name),
    Origin = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)),
    ?assertMatch({200, _, <<"saved POST">>},
                 http(post, Name, "/submit", [cookie_header(T), {"origin", Origin}], body(T))).

other_methods(Name) ->
    T = new_token(Name),
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ "/submit",
    quiet(fun() ->
        {ok, {{_, S1, _}, _, _}} = httpc:request(put, {Url, [], "text/plain", <<"x">>}, [], []),
        {ok, {{_, S2, _}, _, _}} = httpc:request(delete, {Url, []}, [], []),
        {ok, {{_, S3, _}, _, _}} = httpc:request(put, {Url, [cookie_header(T), {"x-csrf-token", binary_to_list(T)}],
                                                       "text/plain", <<"x">>}, [], []),
        ?assertEqual([403, 403, 200], [S1, S2, S3])
    end).

origin_mode(Name) ->
    ?assertMatch({200, _, <<"saved POST">>}, http(post, Name, "/hook", [], <<"a=1">>)),
    ?assertMatch({403, _, _}, http(post, Name, "/hook", [{"origin", "https://evil.test"}], <<"a=1">>)).

off_mode(Name) ->
    ?assertMatch({200, _, <<"saved POST">>},
                 http(post, Name, "/open", [{"origin", "https://evil.test"}], <<"a=1">>)).

get_not_checked(Name) ->
    ?assertMatch({200, _, <<"saved GET">>},
                 http(get, Name, "/submit", [{"origin", "https://evil.test"}], <<>>)).
