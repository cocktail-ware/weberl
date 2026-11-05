%% Feedback from agentic (item 1): "cookie parsing, urlencoded form parsing" had to be
%% hand-written in the application. `weberl_request:cookies/1', `cookie/2' and
%% `form/1' do it through the adapter, tested here over real HTTP (Roadrunner) and
%% through a request built by hand.
-module(weberl_request_helpers_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

%% ---------------------------------------------------------------------
%% Over HTTP: a login-like form POST with a session cookie

http_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             start_app()
     end,
     fun({Name, _}) -> weberl:stop(Name) end,
     fun({Name, _}) ->
             [{"cookies are parsed in wire order", fun() -> cookies_over_http(Name) end},
              {"a cookie value keeps its '=' and is not decoded", fun() -> cookie_value_raw(Name) end},
              {"no cookie header is an empty list", fun() -> no_cookies(Name) end},
              {"urlencoded form: + and %XX decoded, repeats and flags kept",
               fun() -> form_over_http(Name) end},
              {"a form and cookies in the same request", fun() -> login_post(Name) end},
              {"other content types are refused", fun() -> form_wrong_type(Name) end},
              {"multipart is not supported yet", fun() -> form_multipart(Name) end},
              {"a body over the limit is an error, not a crash", fun() -> form_too_big(Name) end}]
     end}.

start_app() ->
    Cookies = handler("cookies", """
        handle(R) ->
            Out = io_lib:format("~0p|~0p|~0p", [weberl_request:cookies(R),
                                             weberl_request:cookie(R, <<"sid">>),
                                             weberl_request:cookie(R, "nope")]),
            weberl_response:text(200, Out).
        """),
    Form = handler("form", """
        handle(R) ->
            weberl_response:text(200, io_lib:format("~0p", [weberl_request:form(R)])).
        """),
    Login = handler("login", """
        handle(R) ->
            {ok, Form} = weberl_request:form(R),
            {ok, Sid} = weberl_request:cookie(R, <<"sid">>),
            User = proplists:get_value(<<"user">>, Form),
            weberl_response:text(200, [<<"user=">>, User, <<" sid=">>, Sid]).
        """),
    Name = weberl_test_handlers:unique("helpers"),
    M = weberl_test_handlers:unique("helpers_router"),
    load_router(M, [{"/cookies", Cookies}, {"/form", Form}, {"/login", Login}]),
    {ok, _} = weberl:start_link(Name, #router{modules = [M]},
                                #listener{port = 0, ip = {127, 0, 0, 1},
                                          options = #{max_content_length => 200}}),
    {Name, M}.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

post(Name, Path, Headers, ContentType, Body) ->
    request(Name, Path, {url(Name, Path), Headers, ContentType, Body}, post).

get(Name, Path, Headers) ->
    request(Name, Path, {url(Name, Path), Headers}, get).

url(Name, Path) -> "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path.

request(_Name, _Path, Req, Method) ->
    {ok, {{_, Status, _}, _, Body}} = httpc:request(Method, Req, [], [{body_format, binary}]),
    {Status, Body}.

cookies_over_http(Name) ->
    {200, Out} = get(Name, "/cookies", [{"cookie", "theme=dark; sid=abc123; lang=pt"}]),
    ?assertEqual(<<"[{<<\"theme\">>,<<\"dark\">>},{<<\"sid\">>,<<\"abc123\">>},"
                   "{<<\"lang\">>,<<\"pt\">>}]|{ok,<<\"abc123\">>}|error">>, Out).

cookie_value_raw(Name) ->
    {200, Out} = get(Name, "/cookies", [{"cookie", "sid=a=b%20c"}]),
    ?assertEqual(<<"[{<<\"sid\">>,<<\"a=b%20c\">>}]|{ok,<<\"a=b%20c\">>}|error">>, Out).

no_cookies(Name) ->
    {200, Out} = get(Name, "/cookies", []),
    ?assertEqual(<<"[]|error|error">>, Out).

form_over_http(Name) ->
    {200, Out} = post(Name, "/form", [], "application/x-www-form-urlencoded",
                      <<"email=a%40b.com&name=Ana+Maria&tag=x&tag=y&flag">>),
    ?assertEqual(<<"{ok,[{<<\"email\">>,<<\"a@b.com\">>},{<<\"name\">>,<<\"Ana Maria\">>},"
                   "{<<\"tag\">>,<<\"x\">>},{<<\"tag\">>,<<\"y\">>},{<<\"flag\">>,true}]}">>, Out).

login_post(Name) ->
    {200, Out} = post(Name, "/login", [{"cookie", "sid=S1"}],
                      "application/x-www-form-urlencoded", <<"user=ana&password=pw">>),
    ?assertEqual(<<"user=ana sid=S1">>, Out).

form_wrong_type(Name) ->
    {200, Out} = post(Name, "/form", [], "application/json", <<"{\"a\":1}">>),
    ?assertEqual(<<"{error,unsupported_content_type}">>, Out).

form_multipart(Name) ->
    Body = <<"--B\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n">>,
    {200, Out} = post(Name, "/form", [], "multipart/form-data; boundary=B", Body),
    ?assertEqual(<<"{error,unsupported_content_type}">>, Out).

form_too_big(Name) ->
    Big = binary:copy(<<"a=1&">>, 100),
    {Status, _} = quiet(fun() ->
                                post(Name, "/form", [], "application/x-www-form-urlencoded", Big)
                        end),
    %% Roadrunner refuses the body (413) before the handler runs.
    ?assertEqual(413, Status).

quiet(Fun) ->
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, maps:get(level, Old)) end.

%% ---------------------------------------------------------------------
%% Requests that no adapter built

hand_built_request_has_no_adapter_test() ->
    R = weberl_request:new(#{method => <<"GET">>, path => "/",
                             headers => [{<<"cookie">>, <<"a=1">>}]}),
    ?assertError({no_adapter, cookies}, weberl_request:cookies(R)),
    ?assertError({no_adapter, cookies}, weberl_request:cookie(R, <<"a">>)),
    ?assertError({no_adapter, form}, weberl_request:form(R)).

%% A request built with any adapter module goes through that module's callbacks.
stub_adapter_is_used_test() ->
    R = weberl_request:new(#{method => <<"GET">>, path => "/",
                             meta => #{adapter => weberl_test_no_static_adapter}}),
    ?assertEqual([], weberl_request:cookies(R)),
    ?assertEqual(error, weberl_request:cookie(R, <<"a">>)),
    ?assertEqual({error, no_content_type}, weberl_request:form(R)).
