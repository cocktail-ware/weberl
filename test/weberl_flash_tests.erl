%% Feedback from agentic (item 6): "Flash is a fixed-code query parameter (?flash=registered)
%% mapped to known messages in Erlang". Flash now rides the session: put it on a redirect,
%% take it on the page that shows it, and let it pass through pages that do not.
-module(weberl_flash_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

%% ---------------------------------------------------------------------
%% A tiny browser for hand-built requests: each page runs as dispatch would
%% (the request is ambient, the session cookie is written afterwards) and the
%% cookie it sets is sent with the next request.

-define(NAME, <<"weberl_session">>).

%% Cookie jar: undefined (no cookie) | Value. Returns {Result, NewJar, SetCookie?}
page(Jar, Handler) ->
    Cookies = case Jar of undefined -> []; _ -> [{?NAME, Jar}] end,
    Request = weberl_test_cookie_adapter:request(Cookies),
    Response0 = weberl_session:run(Request, fun() -> Handler(Request) end),
    {Result, Response} = case Response0 of
                             {R, Resp} -> {R, Resp};
                             Resp -> {none, Resp}
                         end,
    {ok, Final} = weberl_session:finalize(Request, Response),
    {Result, jar(Jar, Final), set_cookies(Final)}.

set_cookies(Response) -> weberl_response:header_values(Response, "set-cookie").

jar(Old, Response) ->
    case set_cookies(Response) of
        [] -> Old;
        [C] ->
            [Pair | Attrs] = binary:split(C, <<"; ">>, [global]),
            case lists:member(<<"Max-Age=0">>, Attrs) of
                true -> undefined;
                false -> element(2, list_to_tuple(binary:split(Pair, <<"=">>)))
            end
    end.

base() -> weberl_response:html(200, <<"x">>).
redirect() -> weberl_response:redirect("/next").

with_env(Key, Value, Fun) ->
    Old = application:get_env(weberl, Key),
    application:set_env(weberl, Key, Value),
    try Fun()
    after
        case Old of
            undefined -> application:unset_env(weberl, Key);
            {ok, V} -> application:set_env(weberl, Key, V)
        end
    end.

%% ---------------------------------------------------------------------
%% The basic round trip

put_on_a_redirect_and_take_on_the_next_page_test() ->
    %% POST handler: say it and redirect
    {_, Jar1, [_]} = page(undefined, fun(_) ->
                                             weberl_flash:put(redirect(), error, <<"Wrong password">>)
                                     end),
    %% the page that shows it
    {{Flash, _}, Jar2, [_]} = page(Jar1, fun(Req) ->
                                                 {Flash, Resp} = weberl_flash:take(Req, base()),
                                                 {{Flash, ok}, Resp}
                                         end),
    ?assertEqual(#{error => <<"Wrong password">>}, Flash),
    %% gone afterwards (the cookie was deleted: nothing else was in the session)
    ?assertEqual(undefined, Jar2),
    {Again, _, []} = page(Jar2, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{}, Again).

get_does_not_clear_test() ->
    {_, Jar, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), info, <<"Saved">>) end),
    {First, Jar2, []} = page(Jar, fun(Req) -> {weberl_flash:get(Req), base()} end),
    {Second, _, []} = page(Jar2, fun(Req) -> {weberl_flash:get(Req, info), base()} end),
    ?assertEqual(#{info => <<"Saved">>}, First),
    ?assertEqual({ok, <<"Saved">>}, Second).

several_messages_test() ->
    {_, Jar, _} = page(undefined, fun(_) ->
                                          R1 = weberl_flash:put(redirect(), info, <<"a">>),
                                          R2 = weberl_flash:put(R1, warning, <<"b">>),
                                          weberl_flash:put(R2, info, <<"c">>)     %% same key: replaced
                                  end),
    {Flash, _, _} = page(Jar, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{info => <<"c">>, warning => <<"b">>}, Flash).

take_with_nothing_to_take_writes_nothing_test() ->
    {{Flash, _}, Jar, []} = page(undefined, fun(Req) ->
                                                    {F, Resp} = weberl_flash:take(Req, base()),
                                                    {{F, ok}, Resp}
                                            end),
    ?assertEqual(#{}, Flash),
    ?assertEqual(undefined, Jar).

%% ---------------------------------------------------------------------
%% Pass-through: the complaint behind the flash design

a_redirect_that_does_not_read_it_passes_it_on_test() ->
    {_, Jar1, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), ok, <<"Registered">>) end),
    %% B: a redirect that never touches flash sends no cookie at all
    {_, Jar2, SetByB} = page(Jar1, fun(_) -> redirect() end),
    ?assertEqual([], SetByB),
    ?assertEqual(Jar1, Jar2),
    %% C shows it
    {{Flash, _}, Jar3, _} = page(Jar2, fun(Req) ->
                                               {F, Resp} = weberl_flash:take(Req, base()),
                                               {{F, ok}, Resp}
                                       end),
    ?assertEqual(#{ok => <<"Registered">>}, Flash),
    ?assertEqual(undefined, Jar3).

a_page_that_only_gets_leaves_it_for_the_next_test() ->
    {_, Jar1, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), ok, <<"m">>) end),
    {_, Jar2, []} = page(Jar1, fun(Req) -> {weberl_flash:get(Req), base()} end),
    {Flash, _, []} = page(Jar2, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{ok => <<"m">>}, Flash).

keep_after_take_passes_it_on_test() ->
    {_, Jar1, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), ok, <<"m">>) end),
    %% a handler that reads it (take) and then decides to redirect with it kept
    {{Seen, _}, Jar2, [_]} =
        page(Jar1, fun(Req) ->
                           {F, Resp} = weberl_flash:take(Req, redirect()),
                           {{F, ok}, weberl_flash:keep(Req, Resp)}
                       end),
    ?assertEqual(#{ok => <<"m">>}, Seen),
    {Flash, _, _} = page(Jar2, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{ok => <<"m">>}, Flash).

keep_is_a_no_op_when_there_is_nothing_to_add_test() ->
    {_, Jar1, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), ok, <<"m">>) end),
    {_, Jar2, Set} = page(Jar1, fun(Req) -> {none, weberl_flash:keep(Req, base())} end),
    ?assertEqual([], Set),
    ?assertEqual(Jar1, Jar2),
    {_, undefined, []} = page(undefined, fun(Req) -> {none, weberl_flash:keep(Req, base())} end).

%% What this response puts survives take, in either order

put_then_take_keeps_the_new_flash_test() ->
    {_, Jar1, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), old, <<"o">>) end),
    {{Seen, _}, Jar2, _} =
        page(Jar1, fun(Req) ->
                           R1 = weberl_flash:put(redirect(), new, <<"n">>),
                           {F, R2} = weberl_flash:take(Req, R1),
                           {{F, ok}, R2}
                       end),
    ?assertEqual(#{old => <<"o">>}, Seen),
    {Next, _, _} = page(Jar2, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{new => <<"n">>}, Next).

take_then_put_keeps_the_new_flash_test() ->
    {_, Jar1, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), old, <<"o">>) end),
    {_, Jar2, _} =
        page(Jar1, fun(Req) ->
                           {_, R1} = weberl_flash:take(Req, redirect()),
                           {none, weberl_flash:put(R1, new, <<"n">>)}
                       end),
    {Next, _, _} = page(Jar2, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{new => <<"n">>}, Next).

%% ---------------------------------------------------------------------
%% Expiry and the session around it

flash_expires_on_its_own_test() ->
    {_, Jar, _} = page(undefined, fun(_) -> weberl_flash:put(redirect(), ok, <<"m">>) end),
    ?assertMatch({#{ok := _}, _, _}, page(Jar, fun(Req) -> {weberl_flash:get(Req), base()} end)),
    %% older than flash_ttl although the session itself is still valid
    Stale = weberl_session:encode(#{'$weberl_flash' => {os:system_time(second) - 301, #{ok => <<"m">>}}},
                                  os:system_time(second) + 1000),
    ?assertMatch({#{}, _, _}, page(Stale, fun(Req) -> {weberl_flash:get(Req), base()} end)),
    {Flash, _, _} = page(Stale, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{}, Flash),
    with_env(flash_ttl, 1000, fun() ->
        {Flash2, _, _} = page(Stale, fun(Req) -> {weberl_flash:get(Req), base()} end),
        ?assertEqual(#{ok => <<"m">>}, Flash2)
    end).

an_expired_flash_is_replaced_not_merged_test() ->
    Stale = weberl_session:encode(#{'$weberl_flash' => {os:system_time(second) - 301, #{old => <<"x">>}}},
                                  os:system_time(second) + 1000),
    {_, Jar, _} = page(Stale, fun(_) -> weberl_flash:put(redirect(), new, <<"n">>) end),
    {Flash, _, _} = page(Jar, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{new => <<"n">>}, Flash).

the_rest_of_the_session_is_untouched_test() ->
    Login = fun(_) ->
                    weberl_response:put_session(weberl_response:reset_session(base()), user_id, 42)
            end,
    {_, Jar0, _} = page(undefined, Login),
    {_, Jar1, _} = page(Jar0, fun(_) -> weberl_flash:put(redirect(), info, <<"Saved">>) end),
    {{Flash, User}, Jar2, [_]} =
        page(Jar1, fun(Req) ->
                           {F, Resp} = weberl_flash:take(Req, base()),
                           {{F, weberl_request:session_get(Req, user_id)}, Resp}
                       end),
    ?assertEqual(#{info => <<"Saved">>}, Flash),
    ?assertEqual({ok, 42}, User),
    %% the cookie is still there (the session has user_id) and no longer holds the flash
    ?assertNotEqual(undefined, Jar2),
    {{Session, _}, _, _} = page(Jar2, fun(Req) -> {{weberl_request:session(Req), ok}, base()} end),
    ?assertEqual(#{user_id => 42}, Session),
    %% the session's expiry was not extended by the flash writes
    {ok, _, Expires0} = weberl_session:decode(Jar0),
    {ok, _, Expires2} = weberl_session:decode(Jar2),
    ?assertEqual(Expires0, Expires2).

values_can_be_any_term_test() ->
    {_, Jar, _} = page(undefined, fun(_) ->
                                          weberl_flash:put(redirect(), {field, email}, {error, [too_short, <<"x">>]})
                                  end),
    {Flash, _, _} = page(Jar, fun(Req) -> {weberl_flash:get(Req), base()} end),
    ?assertEqual(#{{field, email} => {error, [too_short, <<"x">>]}}, Flash).

%% ---------------------------------------------------------------------
%% Over HTTP: register -> redirect -> (a redirect that ignores it) -> home

flow_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             start_app()
     end,
     fun(Name) -> weberl:stop(Name) end,
     fun(Name) ->
             [{"flash survives a pass-through redirect and is shown once", fun() -> http_flow(Name) end},
              {"a page that does not touch flash sets no cookie", fun() -> http_untouched(Name) end}]
     end}.

start_app() ->
    Register = handler("register", """
        handle(_) ->
            weberl_flash:put(weberl_response:redirect("/welcome"), ok, <<"Registered">>).
        """),
    Welcome = handler("welcome", """
        handle(_) -> weberl_response:redirect("/home").
        """),
    Home = handler("home", """
        handle(R) ->
            {Flash, Resp} = weberl_flash:take(R, weberl_response:text(200, <<>>)),
            weberl_response:with_body(Resp, io_lib:format("~0p", [Flash])).
        """),
    Name = weberl_test_handlers:unique("flash_flow"),
    M = weberl_test_handlers:unique("flash_flow_router"),
    load_router(M, [{"/register", Register}, {"/welcome", Welcome}, {"/home", Home}]),
    {ok, _} = weberl:start_link(Name, #router{modules = [M]},
                                #listener{port = 0, ip = {127, 0, 0, 1}}),
    Name.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

get(Name, Path, Cookie) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path,
    Headers = [{"cookie", Cookie} || Cookie =/= none],
    {ok, {{_, Status, _}, H, B}} =
        httpc:request(get, {Url, Headers}, [{autoredirect, false}], [{body_format, binary}]),
    {Status, H, B}.

cookie_of(Headers) ->
    [C] = proplists:get_all_values("set-cookie", Headers),
    [Pair | _] = string:split(C, ";"),
    Pair.

http_flow(Name) ->
    {303, H1, _} = get(Name, "/register", none),
    ?assertEqual("/welcome", proplists:get_value("location", H1)),
    Cookie = cookie_of(H1),
    %% /welcome redirects again without reading the flash: no new cookie
    {303, H2, _} = get(Name, "/welcome", Cookie),
    ?assertEqual("/home", proplists:get_value("location", H2)),
    ?assertEqual([], proplists:get_all_values("set-cookie", H2)),
    %% /home shows it and deletes it
    {200, H3, Body} = get(Name, "/home", Cookie),
    ?assertEqual(<<"#{ok => <<\"Registered\">>}">>, Body),
    [Deleted] = proplists:get_all_values("set-cookie", H3),
    ?assertMatch({match, _}, re:run(Deleted, "^weberl_session=; Path=/; Max-Age=0")),
    %% a browser that has the new state (no cookie) sees nothing
    {200, _, Body2} = get(Name, "/home", none),
    ?assertEqual(<<"#{}">>, Body2).

http_untouched(Name) ->
    {200, H, <<"#{}">>} = get(Name, "/home", none),
    ?assertEqual([], proplists:get_all_values("set-cookie", H)).
