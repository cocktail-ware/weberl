%% Uploads over real HTTP (Roadrunner), HANDOFF decision 13: a multipart form arrives as fields and
%% files, the body cap is the transport's per route (router level, route level, higher or lower than
%% the listener's), the form limits answer from the handler, and a form made by `weberl_form' carries
%% its CSRF token in the action's query string.
-module(weberl_upload_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, listener]).
-on_load(ensure_records/0).

-import(weberl_test_util, [load_router/2]).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

-define(BOUNDARY, "XyZ123boundary").

http_test_() ->
    {setup,
     fun() ->
             {ok, _} = application:ensure_all_started(inets),
             {ok, _} = application:ensure_all_started(roadrunner),
             start_app()
     end,
     fun(Name) -> weberl:stop(Name) end,
     fun(Name) ->
             [{"an upload arrives as fields and files", fun() -> upload(Name) end},
              {"a file input left empty is no file", fun() -> empty_file(Name) end},
              {"a name with a quote and a client path in the file name", fun() -> awkward_names(Name) end},
              {"a file over the route's limit is answered by the handler", fun() -> file_limit(Name) end},
              {"the router's body cap lowers the listener's", fun() -> router_cap(Name) end},
              {"a route can lower the body cap further", fun() -> route_lower_cap(Name) end},
              {"a route can raise the body cap above the listener's", fun() -> route_higher_cap(Name) end},
              {"the cap is checked from the declared length, before the body is sent", fun() -> early_refusal(Name) end},
              {"a body refused by the transport is logged when the Weberl event handler is on",
               fun() -> refusal_is_logged(Name) end},
              {"a form from weberl_form carries the token in its action", fun() -> secure_upload(Name) end},
              {"an upload without the token, or with a wrong one, is a 403", fun() -> forged_upload(Name) end},
              {"a urlencoded form posted to an upload route is refused for files", fun() -> urlencoded_to_upload(Name) end}]
     end}.

start_app() ->
    Files = handler("files", """
        handle(R) ->
            case {weberl_request:form(R), weberl_request:files(R)} of
                {{ok, Fields}, {ok, Files}} ->
                    FieldText = [[N, $=, V, $;] || {N, V} <- Fields],
                    FileText = [[maps:get(name, F), $:, maps:get(filename, F), $:, integer_to_binary(maps:get(size, F)),
                                 $:, maps:get(content_type, F), $:, weberl_request:safe_filename(maps:get(filename, F)), $;]
                                || F <- Files],
                    weberl_response:text(200, [<<"fields=">>, FieldText, <<"|files=">>, FileText]);
                {{error, {limit_exceeded, L}}, _} -> weberl_response:text(413, [<<"limit:">>, atom_to_binary(L)]);
                {_, {error, {limit_exceeded, L}}} -> weberl_response:text(413, [<<"limit:">>, atom_to_binary(L)]);
                {_, {error, E}} -> weberl_response:form_error(E)
            end.
        """),
    Page = handler("page", """
        handle(R) ->
            weberl_csrf:protect(R, fun(Token) ->
                weberl_response:html(200, [weberl_form:open(Token, "/secure", #{enctype => multipart}),
                                           <<"<input type=\"file\" name=\"doc\"></form>">>])
            end).
        """),
    Name = weberl_test_handlers:unique("upload"),
    M = weberl_test_handlers:unique("upload_router"),
    NoCsrf = #{csrf => false},
    load_router(M, [{"/files", Files, NoCsrf},
                    {"/small", Files, NoCsrf#{limits => #{max_body_bytes => 1000, max_file_bytes => 500}}},
                    {"/big", Files, NoCsrf#{limits => #{max_body_bytes => 100000, max_file_bytes => 90000}}},
                    {"/tiny", Files, NoCsrf#{limits => #{max_file_bytes => 10}}},
                    {"/page", Page},
                    {"/secure", Files}]),
    %% the listener allows 20000 bytes, the router 5000 (its routes may say otherwise)
    {ok, _} = weberl:start_link(Name, #router{modules = [M], limits = #{max_body_bytes => 5000, max_file_bytes => 4000}},
                                #listener{port = 0, ip = {127, 0, 0, 1},
                                          options = #{max_content_length => 20000}}),
    Name.

handler(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

%% ---------------------------------------------------------------------
%% Requests

part(Name, Value) ->
    ["--", ?BOUNDARY, "\r\nContent-Disposition: form-data; name=\"", Name, "\"\r\n\r\n", Value, "\r\n"].

file_part(Name, Filename, Type, Content) ->
    ["--", ?BOUNDARY, "\r\nContent-Disposition: form-data; name=\"", Name, "\"; filename=\"", Filename,
     "\"\r\nContent-Type: ", Type, "\r\n\r\n", Content, "\r\n"].

body(Parts) -> iolist_to_binary([Parts, "--", ?BOUNDARY, "--\r\n"]).

multipart_type() -> "multipart/form-data; boundary=" ++ ?BOUNDARY.

url(Name, Path) -> "http://127.0.0.1:" ++ integer_to_list(weberl:port(Name)) ++ Path.

post(Name, Path, Parts) -> post(Name, Path, [], multipart_type(), body(Parts)).

post(Name, Path, Headers, Type, Body) ->
    quiet(fun() ->
        {ok, {{_, Status, _}, RespHeaders, RespBody}} =
            httpc:request(post, {url(Name, Path), Headers, Type, Body}, [], [{body_format, binary}]),
        {Status, RespHeaders, RespBody}
    end).

get(Name, Path) ->
    {ok, {{_, Status, _}, Headers, Body}} =
        httpc:request(get, {url(Name, Path), []}, [], [{body_format, binary}]),
    {Status, Headers, Body}.

quiet(Fun) ->
    Old = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try Fun() after logger:set_primary_config(level, maps:get(level, Old)) end.

%% ---------------------------------------------------------------------
%% Tests

upload(Name) ->
    Png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255>>,
    {200, _, Body} = post(Name, "/files", [part("title", "Hello"), file_part("avatar", "me.png", "image/png", Png),
                                           part("tag", "a"), part("tag", "b")]),
    ?assertEqual(<<"fields=title=Hello;tag=a;tag=b;|files=avatar:me.png:10:image/png:me.png;">>, Body).

empty_file(Name) ->
    {200, _, Body} = post(Name, "/files", [part("title", "x"),
                                           file_part("avatar", "", "application/octet-stream", "")]),
    ?assertEqual(<<"fields=title=x;|files=">>, Body).

awkward_names(Name) ->
    {200, _, Body} = post(Name, "/files", [file_part("a%22b", "..%5C..%5Cx\\evil%22.exe", "text/plain", "x")]),
    %% %22 is a quote; the client's `\' stays and safe_filename keeps only the last part
    ?assertEqual(<<"fields=|files=a\"b:..%5C..%5Cx\\evil\".exe:1:text/plain:evil\".exe;">>, Body).

file_limit(Name) ->
    %% /tiny: max_file_bytes 10; the body is far below every body cap
    {200, _, Ok} = post(Name, "/tiny", [file_part("f", "a.txt", "text/plain", "0123456789")]),
    ?assertMatch(<<"fields=|files=f:a.txt:10:", _/binary>>, Ok),
    {413, _, Limit} = post(Name, "/tiny", [file_part("f", "a.txt", "text/plain", "0123456789A")]),
    ?assertEqual(<<"limit:max_file_bytes">>, Limit).

%% the router says 5000 bytes (and a 4000 byte file), the listener 20000
router_cap(Name) ->
    {200, _, _} = post(Name, "/files", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 3000))]),
    {413, _, _} = post(Name, "/files", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 6000))]),
    %% within the body cap, over the file limit
    {413, _, Limit} = post(Name, "/files", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 4500))]),
    ?assertEqual(<<"limit:max_file_bytes">>, Limit).

route_lower_cap(Name) ->
    {200, _, _} = post(Name, "/small", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 400))]),
    %% 1500 bytes: under the router's 5000, over this route's 1000: refused by the transport
    {413, _, Refused} = post(Name, "/small", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 1500))]),
    ?assertNotEqual(<<"limit:max_file_bytes">>, Refused),
    %% 600 bytes: within the body cap, over this route's file limit of 500: the handler answers
    {413, _, Limit} = post(Name, "/small", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 600))]),
    ?assertEqual(<<"limit:max_file_bytes">>, Limit).

route_higher_cap(Name) ->
    %% 30000 bytes is over the listener's 20000 and the router's 5000, under this route's 100000
    {200, _, Body} = post(Name, "/big", [file_part("f", "big.bin", "a/b", binary:copy(<<"x">>, 30000))]),
    ?assertMatch(<<"fields=|files=f:big.bin:30000:", _/binary>>, Body),
    {413, _, _} = post(Name, "/big", [file_part("f", "big.bin", "a/b", binary:copy(<<"x">>, 120000))]),
    %% the same file is refused where the route does not raise the cap
    {413, _, _} = post(Name, "/files", [file_part("f", "big.bin", "a/b", binary:copy(<<"x">>, 30000))]).

%% Roadrunner refuses a body whose declared length is over the cap before reading it: a client that
%% announces a huge body and sends nothing gets the answer at once.
early_refusal(Name) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, weberl:port(Name), [binary, {active, false}]),
    Request = ["POST /small HTTP/1.1\r\nHost: x\r\nContent-Type: ", multipart_type(),
               "\r\nContent-Length: 5000000\r\n\r\n"],
    ok = gen_tcp:send(Socket, Request),
    {ok, Reply} = gen_tcp:recv(Socket, 0, 2000),
    gen_tcp:close(Socket),
    ?assertMatch(<<"HTTP/1.1 413", _/binary>>, Reply).

%% Roadrunner reports the refusal as an event, which its default handler drops: with the handler of
%% `weberl_roadrunner_events' (one per node, set here as an application would in its sys.config) it
%% is a warning in the log.
refusal_is_logged(Name) ->
    Id = weberl_upload_events_h,
    ok = logger:add_handler(Id, weberl_test_log_handler, #{config => #{sink => weberl_upload_sink}, level => warning}),
    register(weberl_upload_sink, self()),
    Old = logger:get_primary_config(),
    ok = logger:set_primary_config(level, warning),
    #{level := DefaultLevel} = element(2, logger:get_handler_config(default)),
    ok = logger:set_handler_config(default, level, none),
    ok = roadrunner_event:put_handler(weberl_roadrunner_events),
    try
        {413, _, _} = post_unquiet(Name, "/small", [file_part("f", "a.bin", "a/b", binary:copy(<<"x">>, 1500))]),
        receive
            {log, #{msg := {report, #{what := request_body_too_large, listener := Listener, peer := Peer}}}} ->
                ?assert(is_atom(Listener)),
                ?assertMatch(<<"127.0.0.1:", _/binary>>, Peer)
        after 1000 ->
            ?assert(false)
        end
    after
        ok = roadrunner_event:put_handler(roadrunner_event_noop),
        logger:remove_handler(Id),
        logger:set_handler_config(default, level, DefaultLevel),
        logger:set_primary_config(level, maps:get(level, Old)),
        unregister(weberl_upload_sink)
    end.

post_unquiet(Name, Path, Parts) ->
    {ok, {{_, Status, _}, Headers, Body}} =
        httpc:request(post, {url(Name, Path), [], multipart_type(), body(Parts)}, [], [{body_format, binary}]),
    {Status, Headers, Body}.

%% /page renders a multipart form with the token in the action and sets the cookie
secure_upload(Name) ->
    {200, Headers, Html} = get(Name, "/page"),
    ?assertEqual("same-origin", proplists:get_value("referrer-policy", Headers)),
    {Action, Cookie} = action_and_cookie(Headers, Html),
    ?assertMatch("/secure?_csrf=" ++ _, Action),
    ?assertNotEqual(nomatch, binary:match(Html, <<"enctype=\"multipart/form-data\"">>)),
    %% no hidden field: the token is in the URL
    ?assertEqual(nomatch, binary:match(Html, <<"type=\"hidden\"">>)),
    {200, _, Body} = post(Name, Action, [{"cookie", Cookie}], multipart_type(),
                          body([part("title", "t"), file_part("doc", "d.txt", "text/plain", "hello")])),
    ?assertEqual(<<"fields=title=t;|files=doc:d.txt:5:text/plain:d.txt;">>, Body).

forged_upload(Name) ->
    {200, Headers, Html} = get(Name, "/page"),
    {Action, Cookie} = action_and_cookie(Headers, Html),
    Parts = body([file_part("doc", "d.txt", "text/plain", "hello")]),
    %% a browser of another site sends the cookie but cannot know the token
    {403, _, _} = post(Name, "/secure", [{"cookie", Cookie}], multipart_type(), Parts),
    {403, _, _} = post(Name, "/secure?_csrf=forged", [{"cookie", Cookie}], multipart_type(), Parts),
    %% a token in the body is not looked for in a multipart body
    {403, _, _} = post(Name, "/secure", [{"cookie", Cookie}], multipart_type(),
                       body([part("_csrf", token_of(Action)), file_part("doc", "d.txt", "text/plain", "hello")])),
    %% the token without the cookie
    {403, _, _} = post(Name, Action, [], multipart_type(), Parts),
    {200, _, _} = post(Name, Action, [{"cookie", Cookie}], multipart_type(), Parts).

urlencoded_to_upload(Name) ->
    %% a form with a file input and no enctype sends the file's name only: files are an error
    %% (415), not silently none
    {415, _, Body} = post(Name, "/files", [], "application/x-www-form-urlencoded", <<"title=Hi&doc=a.txt">>),
    ?assertEqual(<<"Unsupported Media Type">>, Body).

%% The form's action (HTML-unescaped) and the CSRF cookie the page set
action_and_cookie(Headers, Html) ->
    {match, [Action0]} = re:run(Html, <<"action=\"([^\"]+)\"">>, [{capture, [1], list}]),
    Action = string:replace(Action0, "&amp;", "&", all),
    [Cookie | _] = [lists:takewhile(fun(C) -> C =/= $; end, V)
                    || {"set-cookie", V} <- Headers, lists:prefix("weberl_csrf=", V)],
    {lists:flatten(Action), Cookie}.

token_of(Action) ->
    [_, Token] = string:split(Action, "_csrf="),
    list_to_binary(Token).
