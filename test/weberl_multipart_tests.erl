%% Multipart forms (HANDOFF decision 13): `Content-Disposition' parsing, `multipart/1', `form/1' and
%% `files/1' on a multipart body, the layered limits and their logging, `safe_filename/1', the CSRF
%% token of a multipart form (query string, body never parsed) and what dispatch makes of it. The
%% complaint behind them: an upload form could not be read at all (`form/1' refused multipart).
-module(weberl_multipart_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router]).
-on_load(ensure_records/0).

ensure_records() ->
    {module, weberl_config} = code:ensure_loaded(weberl_config),
    ok.

-define(MIB, 1048576).

%% ---------------------------------------------------------------------
%% Helpers

text(Name, Value) ->
    {[{<<"content-disposition">>, <<"form-data; name=\"", Name/binary, "\"">>}], Value}.

file(Name, Filename, Type, Body) ->
    {[{<<"content-disposition">>, <<"form-data; name=\"", Name/binary, "\"; filename=\"", Filename/binary, "\"">>},
      {<<"content-type">>, Type}], Body}.

req(Parts) -> weberl_test_form_adapter:request(#{parts => Parts}).

with_limits(Request, Limits) -> weberl_request:with_route(Request, #{handler => some_handler, limits => Limits}).

%% Run Fun with logging captured: {Result, [Report]} of the warnings.
captured(Fun) ->
    Id = list_to_atom("weberl_mp_h_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Sink = list_to_atom("weberl_mp_sink_" ++ integer_to_list(erlang:unique_integer([positive]))),
    register(Sink, self()),
    ok = logger:add_handler(Id, weberl_test_log_handler, #{config => #{sink => Sink}, level => warning}),
    Old = logger:get_primary_config(),
    #{level := DefaultLevel} = element(2, logger:get_handler_config(default)),
    ok = logger:set_primary_config(level, warning),
    ok = logger:set_handler_config(default, level, none),
    try
        Result = Fun(),
        {Result, drain()}
    after
        logger:remove_handler(Id),
        logger:set_handler_config(default, level, DefaultLevel),
        logger:set_primary_config(level, maps:get(level, Old)),
        unregister(Sink)
    end.

drain() ->
    receive {log, #{msg := {report, Report}}} -> [Report | drain()]
    after 0 -> []
    end.

with_env(Key, Value, Fun) ->
    Old = application:get_env(weberl, Key),
    application:set_env(weberl, Key, Value),
    try Fun()
    after
        case Old of
            {ok, O} -> application:set_env(weberl, Key, O);
            undefined -> application:unset_env(weberl, Key)
        end
    end.

%% ---------------------------------------------------------------------
%% Content-Disposition

disposition_test() ->
    ?assertEqual({ok, #{name => <<"a">>}}, weberl_multipart:disposition(<<"form-data; name=\"a\"">>)),
    ?assertEqual({ok, #{name => <<"f">>, filename => <<"x.png">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"f\"; filename=\"x.png\"">>)),
    %% case of the type and the keys, white space, an unquoted token
    ?assertEqual({ok, #{name => <<"f">>, filename => <<"x.png">>}},
                 weberl_multipart:disposition(<<"FORM-DATA ;  NAME = f ;Filename=\"x.png\"">>)),
    %% a `;' or an escaped quote inside a quoted value
    ?assertEqual({ok, #{name => <<"a;b">>, filename => <<"c\"d.txt">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"a;b\"; filename=\"c\\\"d.txt\"">>)),
    %% curl writes \" and \\; a browser leaves a backslash alone, so any other one stays
    ?assertEqual({ok, #{name => <<"a">>, filename => <<"x\\y.txt">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"a\"; filename=\"x\\\\y.txt\"">>)),
    ?assertEqual({ok, #{name => <<"a">>, filename => <<"C:\\dir\\x.txt">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"a\"; filename=\"C:\\dir\\x.txt\"">>)),
    %% the first of a repeated parameter wins; other parameters are ignored
    ?assertEqual({ok, #{name => <<"one">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"one\"; name=\"two\"; foo=bar">>)),
    ?assertEqual({ok, #{name => <<"a">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"a\"; filename*=UTF-8''x.png">>)),
    ?assertEqual({ok, #{name => <<"a">>, filename => <<>>}},
                 weberl_multipart:disposition(<<"form-data; name=\"a\"; filename=\"\"">>)).

disposition_browser_escapes_test() ->
    %% browsers write `"' as %22 and line breaks as %0D %0A; nothing else is decoded
    ?assertEqual({ok, #{name => <<"a\"b">>, filename => <<"x\r\ny %41 100%.txt">>}},
                 weberl_multipart:disposition(<<"form-data; name=\"a%22b\"; filename=\"x%0D%0Ay %41 100%.txt\"">>)),
    ?assertEqual({ok, #{name => <<"a\r\n">>}}, weberl_multipart:disposition(<<"form-data; name=\"a%0d%0a\"">>)).

disposition_errors_test() ->
    [?assertEqual(error, weberl_multipart:disposition(V))
     || V <- [<<"form-data">>, <<"form-data; filename=\"x\"">>, <<"attachment; name=\"a\"">>,
              <<"inline">>, <<>>, <<"form-data; name=\"unterminated">>, <<"form-data; name=\"\xff\"">>,
              <<"form-data; name=\"a\"; filename=\"\xc3\"">>]].

%% ---------------------------------------------------------------------
%% Parts, fields and files

multipart_gives_every_part_in_order_test() ->
    {ok, Parts} = weberl_request:multipart(req([text(<<"title">>, <<"Hi">>),
                                                file(<<"doc">>, <<"a.txt">>, <<"text/plain">>, <<"hello">>),
                                                text(<<"tag">>, <<"x">>)])),
    ?assertMatch([#{name := <<"title">>, filename := undefined, content_type := <<"text/plain">>, body := <<"Hi">>},
                  #{name := <<"doc">>, filename := <<"a.txt">>, content_type := <<"text/plain">>, body := <<"hello">>},
                  #{name := <<"tag">>, filename := undefined, body := <<"x">>}], Parts),
    [#{headers := Headers} | _] = Parts,
    ?assertMatch({_, <<"form-data; name=\"title\"">>}, lists:keyfind(<<"content-disposition">>, 1, Headers)).

content_type_defaults_test() ->
    {ok, [Field, File]} = weberl_request:multipart(
        req([text(<<"a">>, <<"1">>),
             {[{<<"content-disposition">>, <<"form-data; name=\"f\"; filename=\"x.bin\"">>}], <<1, 2, 3>>}])),
    ?assertEqual(<<"text/plain">>, maps:get(content_type, Field)),
    ?assertEqual(<<"application/octet-stream">>, maps:get(content_type, File)).

form_gives_the_text_fields_of_a_multipart_body_test() ->
    weberl_test_form_adapter:reset_calls(),
    Request = req([text(<<"_csrf">>, <<"tok">>), text(<<"title">>, <<"Hi">>),
                   file(<<"doc">>, <<"a.txt">>, <<"text/plain">>, <<"hello">>), text(<<"tag">>, <<"x">>),
                   text(<<"tag">>, <<"y">>)]),
    ?assertEqual({ok, [{<<"_csrf">>, <<"tok">>}, {<<"title">>, <<"Hi">>}, {<<"tag">>, <<"x">>}, {<<"tag">>, <<"y">>}]},
                 weberl_request:form(Request)),
    %% it went through multipart/1, not the urlencoded callback
    ?assertEqual([multipart], weberl_test_form_adapter:calls()).

files_gives_the_parts_with_a_file_name_test() ->
    {ok, Files} = weberl_request:files(req([text(<<"title">>, <<"Hi">>),
                                            file(<<"doc">>, <<"a.txt">>, <<"text/plain">>, <<"hello">>),
                                            file(<<"img">>, <<"b.png">>, <<"image/png">>, <<137, 80, 78, 71>>)])),
    ?assertEqual([#{name => <<"doc">>, filename => <<"a.txt">>, content_type => <<"text/plain">>,
                    body => <<"hello">>, size => 5},
                  #{name => <<"img">>, filename => <<"b.png">>, content_type => <<"image/png">>,
                    body => <<137, 80, 78, 71>>, size => 4}], Files).

an_empty_file_input_is_no_file_test() ->
    %% a browser sends a file input left empty as a part with filename="" and no content
    Request = req([text(<<"title">>, <<"Hi">>), file(<<"doc">>, <<>>, <<"application/octet-stream">>, <<>>)]),
    ?assertEqual({ok, []}, weberl_request:files(Request)),
    ?assertEqual({ok, [{<<"title">>, <<"Hi">>}]}, weberl_request:form(Request)),
    {ok, Parts} = weberl_request:multipart(Request),
    ?assertMatch([_, #{name := <<"doc">>, filename := <<>>}], Parts),
    %% an empty file with a name is a file
    ?assertMatch({ok, [#{filename := <<"empty.txt">>, size := 0}]},
                 weberl_request:files(req([file(<<"doc">>, <<"empty.txt">>, <<"text/plain">>, <<>>)]))).

file_bodies_are_raw_bytes_test() ->
    Bytes = list_to_binary(lists:seq(0, 255)),
    {ok, [File]} = weberl_request:files(req([file(<<"f">>, <<"all.bin">>, <<"application/octet-stream">>, Bytes)])),
    ?assertEqual(Bytes, maps:get(body, File)).

malformed_parts_are_errors_test() ->
    %% no content-disposition, no name, a text field that is not UTF-8
    ?assertEqual({error, malformed_multipart}, weberl_request:multipart(req([{[], <<"x">>}]))),
    ?assertEqual({error, malformed_multipart},
                 weberl_request:multipart(req([{[{<<"content-disposition">>, <<"form-data">>}], <<"x">>}]))),
    ?assertEqual({error, malformed_multipart},
                 weberl_request:multipart(req([text(<<"a">>, <<"\xff\xfe">>)]))),
    ?assertEqual({error, malformed_multipart}, weberl_request:form(req([text(<<"a">>, <<"\xc3">>)]))),
    %% but a file may hold any bytes
    ?assertMatch({ok, [_]}, weberl_request:files(req([file(<<"f">>, <<"x">>, <<"a/b">>, <<"\xff\xfe">>)]))).

a_request_that_is_not_multipart_is_refused_test() ->
    Urlencoded = weberl_test_form_adapter:request(#{pairs => [{<<"a">>, <<"1">>}]}),
    ?assertEqual({error, unsupported_content_type}, weberl_request:multipart(Urlencoded)),
    %% a form with a file input and no enctype: the files are absent, not silently empty
    ?assertEqual({error, unsupported_content_type}, weberl_request:files(Urlencoded)),
    ?assertEqual({ok, [{<<"a">>, <<"1">>}]}, weberl_request:form(Urlencoded)),
    None = weberl_test_form_adapter:request(#{}),
    ?assertEqual({error, unsupported_content_type}, weberl_request:multipart(None)).

the_multipart_content_type_is_read_by_its_type_test() ->
    Req = fun(Type) ->
        weberl_request:new(#{method => <<"POST">>, path => "/x",
                             headers => [{<<"content-type">>, Type}],
                             meta => #{adapter => weberl_test_form_adapter, parts => [text(<<"a">>, <<"1">>)]}})
    end,
    [?assert(weberl_request:is_multipart(Req(T)))
     || T <- [<<"multipart/form-data; boundary=x">>, <<"Multipart/Form-Data;boundary=x">>, <<" multipart/form-data ">>]],
    [?assertNot(weberl_request:is_multipart(Req(T)))
     || T <- [<<"application/x-www-form-urlencoded">>, <<"multipart/mixed; boundary=x">>, <<"text/plain">>]].

%% ---------------------------------------------------------------------
%% safe_filename

safe_filename_test() ->
    [?assertEqual(Expected, weberl_request:safe_filename(Name))
     || {Name, Expected} <- [{<<"photo.png">>, <<"photo.png">>},
                             {<<"C:\\Users\\me\\photo.png">>, <<"photo.png">>},
                             {<<"/etc/passwd">>, <<"passwd">>},
                             {<<"../../etc/passwd">>, <<"passwd">>},
                             {<<"a/b/../c.txt">>, <<"c.txt">>},
                             {<<"..">>, <<"file">>},
                             {<<".">>, <<"file">>},
                             {<<".htaccess">>, <<"htaccess">>},
                             {<<"  spaced name.txt  ">>, <<"spaced name.txt">>},
                             {<<"report.pdf.">>, <<"report.pdf">>},
                             {<<"a\r\nb\0c.txt">>, <<"abc.txt">>},
                             {<<>>, <<"file">>},
                             {<<"/">>, <<"file">>},
                             {<<"dir/">>, <<"file">>},
                             {<<"é.png"/utf8>>, <<"é.png"/utf8>>}]].

%% ---------------------------------------------------------------------
%% Limits

exceeded(Result, Limit) -> ?assertEqual({error, {limit_exceeded, Limit}}, Result).

each_limit_is_checked_test() ->
    weberl_live_test_util:quiet(fun each_limit_is_checked/0).

each_limit_is_checked() ->
    Many = [text(<<"f">>, <<"v">>) || _ <- lists:seq(1, 4)],
    exceeded(weberl_request:multipart(req(Many), #{max_fields => 3}), max_fields),
    ?assertMatch({ok, [_, _, _, _]}, weberl_request:multipart(req(Many), #{max_fields => 4})),
    exceeded(weberl_request:multipart(req([text(<<"f">>, <<"abcd">>)]), #{max_field_bytes => 3}), max_field_bytes),
    ?assertMatch({ok, _}, weberl_request:multipart(req([text(<<"f">>, <<"abc">>)]), #{max_field_bytes => 3})),
    Files = [file(<<"f">>, <<"a.txt">>, <<"t/p">>, <<"x">>) || _ <- lists:seq(1, 3)],
    exceeded(weberl_request:multipart(req(Files), #{max_files => 2}), max_files),
    ?assertMatch({ok, _}, weberl_request:multipart(req(Files), #{max_files => 3})),
    exceeded(weberl_request:multipart(req([file(<<"f">>, <<"a.txt">>, <<"t/p">>, <<"1234">>)]), #{max_file_bytes => 3}),
             max_file_bytes),
    ?assertMatch({ok, _}, weberl_request:multipart(req([file(<<"f">>, <<"a.txt">>, <<"t/p">>, <<"123">>)]),
                                                   #{max_file_bytes => 3})),
    exceeded(weberl_request:multipart(req([file(<<"f">>, <<"abcd.txt">>, <<"t/p">>, <<"x">>)]), #{max_filename_bytes => 7}),
             max_filename_bytes),
    ?assertMatch({ok, _}, weberl_request:multipart(req([file(<<"f">>, <<"abcd.txt">>, <<"t/p">>, <<"x">>)]),
                                                   #{max_filename_bytes => 8})).

limits_apply_through_form_and_files_test() ->
    weberl_live_test_util:quiet(fun limits_apply_through_form_and_files/0).

limits_apply_through_form_and_files() ->
    Request = req([text(<<"a">>, <<"1">>), text(<<"b">>, <<"2">>), file(<<"f">>, <<"x">>, <<"t/p">>, <<"123">>)]),
    exceeded(weberl_request:form(Request, #{max_fields => 1}), max_fields),
    exceeded(weberl_request:files(Request, #{max_file_bytes => 2}), max_file_bytes),
    ?assertMatch({ok, [_]}, weberl_request:files(Request, #{max_file_bytes => 3})).

an_empty_file_input_counts_for_no_limit_test() ->
    Request = req([file(<<"f">>, <<>>, <<"a/b">>, <<>>), file(<<"g">>, <<"x.txt">>, <<"a/b">>, <<"1">>)]),
    ?assertMatch({ok, _}, weberl_request:multipart(Request, #{max_files => 1})).

the_defaults_are_sane_test() ->
    ?assertEqual(#{max_fields => 100, max_field_bytes => ?MIB, max_files => 10, max_file_bytes => 5 * ?MIB,
                   max_filename_bytes => 255}, weberl_limits:defaults()),
    %% a file of the default maximum is fine, one byte more is not
    Edge = fun(Size) -> req([file(<<"f">>, <<"big.bin">>, <<"a/b">>, binary:copy(<<0>>, Size))]) end,
    ?assertMatch({ok, [_]}, weberl_request:files(Edge(5 * ?MIB))),
    {Result, _} = captured(fun() -> weberl_request:files(Edge(5 * ?MIB + 1)) end),
    exceeded(Result, max_file_bytes),
    %% 100 fields, not 101
    Fields = fun(N) -> req([text(<<"f">>, <<"v">>) || _ <- lists:seq(1, N)]) end,
    ?assertMatch({ok, _}, weberl_request:form(Fields(100))),
    {Result2, _} = captured(fun() -> weberl_request:form(Fields(101)) end),
    exceeded(Result2, max_fields),
    %% 10 files, not 11
    FileParts = fun(N) -> req([file(<<"f">>, <<"x">>, <<"a/b">>, <<"1">>) || _ <- lists:seq(1, N)]) end,
    ?assertMatch({ok, _}, weberl_request:files(FileParts(10))),
    {Result3, _} = captured(fun() -> weberl_request:files(FileParts(11)) end),
    exceeded(Result3, max_files).

an_exceeded_limit_is_logged_without_the_content_test() ->
    Request = weberl_request:with_route(
                weberl_test_form_adapter:request(#{path => "/upload",
                                                   parts => [file(<<"f">>, <<"secret.txt">>, <<"t/p">>, <<"top secret">>)]}),
                #{handler => upload_handler, limits => #{}}),
    {Result, Reports} = captured(fun() -> weberl_request:files(Request, #{max_file_bytes => 5}) end),
    exceeded(Result, max_file_bytes),
    ?assertMatch([#{what := form_limit_exceeded, limit := max_file_bytes, allowed := 5, seen := 10,
                    path := "/upload", handler := upload_handler}], Reports),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(io_lib:format("~p", [Reports])), <<"top secret">>)),
    %% nothing is logged when nothing is exceeded
    ?assertEqual([], element(2, captured(fun() -> weberl_request:files(Request, #{max_file_bytes => 10}) end))).

urlencoded_forms_have_the_field_limits_too_test() ->
    weberl_live_test_util:quiet(fun urlencoded_forms_have_the_field_limits_too/0).

urlencoded_forms_have_the_field_limits_too() ->
    Pairs = [{<<"a">>, <<"1">>}, {<<"b">>, <<"22">>}, {<<"flag">>, true}],
    Request = weberl_test_form_adapter:request(#{pairs => Pairs}),
    ?assertEqual({ok, Pairs}, weberl_request:form(Request)),
    exceeded(weberl_request:form(Request, #{max_fields => 2}), max_fields),
    ?assertEqual({ok, Pairs}, weberl_request:form(Request, #{max_fields => 3})),
    exceeded(weberl_request:form(Request, #{max_field_bytes => 1}), max_field_bytes),
    ?assertEqual({ok, Pairs}, weberl_request:form(Request, #{max_field_bytes => 2})).

%% ---------------------------------------------------------------------
%% Layers: default < application env < router < route < call, each key on its own

layers_test() ->
    Request = req([]),
    ?assertEqual(weberl_limits:defaults(), weberl_limits:effective(Request, #{})),
    with_env(form_limits, #{max_files => 3, max_fields => 7}, fun() ->
        ?assertMatch(#{max_files := 3, max_fields := 7, max_file_bytes := _}, weberl_limits:effective(Request, #{})),
        %% the route (which dispatch has merged over the router) wins over the env, and only for its keys
        Routed = with_limits(Request, #{max_files => 2}),
        E = weberl_limits:effective(Routed, #{}),
        ?assertEqual({2, 7, 5 * ?MIB}, {maps:get(max_files, E), maps:get(max_fields, E), maps:get(max_file_bytes, E)}),
        %% the call wins over the route
        C = weberl_limits:effective(Routed, #{max_files => 1, max_file_bytes => 9}),
        ?assertEqual({1, 7, 9}, {maps:get(max_files, C), maps:get(max_fields, C), maps:get(max_file_bytes, C)})
    end),
    %% max_body_bytes has no default: unset, it is the transport's
    ?assertNot(maps:is_key(max_body_bytes, weberl_limits:effective(Request, #{}))),
    ?assertEqual(5000, maps:get(max_body_bytes, weberl_limits:effective(with_limits(Request, #{max_body_bytes => 5000}), #{}))).

each_layer_changes_the_behaviour_test() ->
    Files = [file(<<"f">>, <<"x">>, <<"a/b">>, <<"1">>) || _ <- lists:seq(1, 3)],
    Request = req(Files),
    ?assertMatch({ok, _}, weberl_request:files(Request)),
    with_env(form_limits, #{max_files => 2}, fun() ->
        exceeded(element(1, captured(fun() -> weberl_request:files(Request) end)), max_files),
        %% the route raises it again
        ?assertMatch({ok, _}, weberl_request:files(with_limits(Request, #{max_files => 3}))),
        %% and the call lowers it
        exceeded(element(1, captured(fun() -> weberl_request:files(with_limits(Request, #{max_files => 3}), #{max_files => 1}) end)),
                 max_files)
    end).

limits_are_validated_test() ->
    ?assertEqual({ok, #{max_files => 1}}, weberl_limits:check(#{max_files => 1})),
    ?assertEqual({error, {unknown_limit, max_nothing}}, weberl_limits:check(#{max_nothing => 1})),
    ?assertEqual({error, {invalid_limit, max_files, -1}}, weberl_limits:check(#{max_files => -1})),
    ?assertEqual({error, {invalid_limit, max_files, <<"3">>}}, weberl_limits:check(#{max_files => <<"3">>})),
    ?assertEqual({error, {invalid_limit, max_files, 1.5}}, weberl_limits:check(#{max_files => 1.5})),
    ?assertEqual({error, {invalid_limits, [max_files]}}, weberl_limits:check([max_files])),
    ?assertEqual({ok, #{max_body_bytes => 10}}, weberl_limits:check(#{max_body_bytes => 10})),
    %% the body limit is read before the handler runs: not a per call limit
    ?assertEqual({error, {limit_not_allowed_here, max_body_bytes}}, weberl_limits:check_call(#{max_body_bytes => 10})),
    ?assertError({badarg, {limit_not_allowed_here, max_body_bytes}},
                 weberl_request:multipart(req([]), #{max_body_bytes => 10})),
    ?assertError({badarg, {unknown_limit, nope}}, weberl_request:files(req([]), #{nope => 1})).

route_and_router_configuration_is_validated_test() ->
    ?assertEqual({ok, #{limits => #{max_files => 2}}}, weberl_route:check_opts(#{limits => #{max_files => 2}})),
    ?assertEqual({error, {invalid_limits, {unknown_limit, nope}}}, weberl_route:check_opts(#{limits => #{nope => 1}})),
    ?assertEqual({error, {invalid_limits, {invalid_limit, max_files, x}}}, weberl_route:check_opts(#{limits => #{max_files => x}})),
    ?assertEqual({error, {invalid_limits, {invalid_limits, nope}}}, weberl_route:check_opts(#{limits => nope})),
    Route = weberl_route:new("/up", h, declarative, router, #{limits => #{max_file_bytes => 9}}),
    ?assertEqual(#{max_file_bytes => 9}, weberl_route:limits(Route)),
    ?assertEqual(#{}, weberl_route:limits(weberl_route:new("/up", h, declarative, router))),
    {ok, Table} = weberl_table:assemble([], [Route]),
    ?assertEqual(#{}, weberl_table:limits(Table)),
    ?assertEqual(#{max_files => 4}, weberl_table:limits(weberl_table:with_limits(Table, #{max_files => 4}))),
    %% the router record
    ?assertMatch({error, {invalid_config, {limits, {unknown_limit, nope}}}},
                 weberl:build(#router{limits = #{nope => 1}})),
    {ok, T} = weberl:build(#router{limits = #{max_files => 4}}),
    ?assertEqual(#{max_files => 4}, weberl_table:limits(T)).

the_attribute_of_a_view_can_set_limits_test() ->
    weberl_test_util:with_tmp(fun(D) ->
        weberl_test_util:write_tree(D, [{"up/up_view.erl",
            "-module(up_view). -weberl_route(#{limits => #{max_file_bytes => 52428800, max_body_bytes => 104857600}}).\n"
            "-export([handle/1]). handle(_) -> ok.\n"}]),
        {ok, [R]} = weberl_fs:discover(D, "/"),
        ?assertEqual(#{max_file_bytes => 52428800, max_body_bytes => 104857600}, weberl_route:limits(R))
    end).

env_limits_are_audited_when_a_router_starts_test() ->
    {ok, Table} = weberl_table:assemble([], [weberl_route:new("/up", h, declarative, router)]),
    with_env(form_limits, #{bogus => 1}, fun() ->
        ?assertEqual({error, {invalid_config, {form_limits, {unknown_limit, bogus}}}}, weberl_limits:audit(Table))
    end),
    ?assertEqual(ok, weberl_limits:audit(Table)),
    %% a file limit above the body limit is logged: such a file could never arrive
    Inconsistent = weberl_route:new("/up", h, declarative, router, #{limits => #{max_body_bytes => 1000, max_file_bytes => 2000}}),
    {ok, T2} = weberl_table:assemble([], [Inconsistent]),
    {Audit, Reports} = captured(fun() -> weberl_limits:audit(T2) end),
    ?assertEqual(ok, Audit),
    ?assertMatch([#{what := form_limits_inconsistent, path := "/up", max_body_bytes := 1000, max_file_bytes := 2000}], Reports),
    %% a body limit under the (default 5 MiB) file limit is inconsistent too
    Small = weberl_route:new("/small", h, declarative, router, #{limits => #{max_body_bytes => 1000}}),
    {ok, T3} = weberl_table:assemble([], [Small]),
    ?assertMatch([#{what := form_limits_inconsistent, path := "/small"}], element(2, captured(fun() -> weberl_limits:audit(T3) end))),
    %% the router's limits sit under the route's: a router that sets both is consistent
    {ok, Plain} = weberl_table:assemble([], [weberl_route:new("/r", h, declarative, router)]),
    Router = weberl_table:with_limits(Plain, #{max_body_bytes => 5000, max_file_bytes => 4000}),
    ?assertEqual([], element(2, captured(fun() -> weberl_limits:audit(Router) end))),
    %% ... and one that sets only the body limit under the default file limit is not
    Lower = weberl_table:with_limits(Plain, #{max_body_bytes => 5000}),
    ?assertMatch([#{what := form_limits_inconsistent, path := "/r"}],
                 element(2, captured(fun() -> weberl_limits:audit(Lower) end))),
    %% a route can set its own file limit under the router's body limit
    OwnFile = weberl_route:new("/f", h, declarative, router, #{limits => #{max_file_bytes => 100}}),
    {ok, T5} = weberl_table:assemble([], [OwnFile]),
    ?assertEqual([], element(2, captured(fun() -> weberl_limits:audit(weberl_table:with_limits(T5, #{max_body_bytes => 5000})) end))),
    %% consistent: nothing
    Fine = weberl_route:new("/fine", h, declarative, router, #{limits => #{max_body_bytes => 100 * ?MIB, max_file_bytes => 50 * ?MIB}}),
    {ok, T4} = weberl_table:assemble([], [Fine]),
    ?assertEqual([], element(2, captured(fun() -> weberl_limits:audit(T4) end))).

form_error_maps_the_errors_to_responses_test() ->
    Status = fun(Reason) -> weberl_response:status(weberl_response:form_error(Reason)) end,
    ?assertEqual(413, Status({limit_exceeded, max_file_bytes})),
    ?assertEqual(415, Status(unsupported_content_type)),
    ?assertEqual(415, Status(no_content_type)),
    ?assertEqual(400, Status(malformed_multipart)),
    ?assertEqual(400, Status(closed)),
    ?assertEqual(<<"Payload Too Large">>, weberl_response:body(weberl_response:form_error({limit_exceeded, max_files}))).

%% ---------------------------------------------------------------------
%% CSRF: the token of a multipart form is in the query string; the body is not parsed for it

token_and_cookie() ->
    Token = weberl_csrf:token(weberl_test_cookie_adapter:request([])),
    {Token, [{binary_to_list(weberl_csrf:cookie_name()), binary_to_list(Token)}]}.

multipart_post(Opts) ->
    {Token, Cookies} = case Opts of
                           #{token := T} -> {T, [{binary_to_list(weberl_csrf:cookie_name()), binary_to_list(T)}]};
                           _ -> token_and_cookie()
                       end,
    Query = maps:get(query, Opts, <<"_csrf=", Token/binary>>),
    weberl_test_form_adapter:request(maps:merge(#{cookies => Cookies, query => Query, path => "/up",
                                                  parts => [file(<<"f">>, <<"a.txt">>, <<"t/p">>, <<"x">>)]},
                                                maps:without([query, token], Opts))).

the_token_in_the_query_of_a_multipart_form_is_accepted_test() ->
    weberl_test_form_adapter:reset_calls(),
    ?assertEqual(ok, weberl_csrf:verify(multipart_post(#{}))),
    %% decided without reading the body at all
    ?assertEqual([], weberl_test_form_adapter:calls()).

a_wrong_or_missing_query_token_is_refused_without_parsing_the_body_test() ->
    weberl_test_form_adapter:reset_calls(),
    ?assertEqual({error, token_mismatch}, weberl_csrf:verify(multipart_post(#{query => <<"_csrf=nope">>}))),
    ?assertEqual({error, no_token}, weberl_csrf:verify(multipart_post(#{query => <<>>}))),
    ?assertEqual({error, no_token}, weberl_csrf:verify(multipart_post(#{query => <<"other=1">>}))),
    ?assertEqual([], weberl_test_form_adapter:calls()).

a_token_in_the_multipart_body_is_not_looked_for_test() ->
    {Token, Cookies} = token_and_cookie(),
    weberl_test_form_adapter:reset_calls(),
    Request = weberl_test_form_adapter:request(#{cookies => Cookies,
                                                 parts => [text(<<"_csrf">>, Token), file(<<"f">>, <<"a">>, <<"t/p">>, <<"x">>)]}),
    ?assertEqual({error, no_token}, weberl_csrf:verify(Request)),
    ?assertEqual([], weberl_test_form_adapter:calls()).

the_header_comes_first_then_the_query_then_an_urlencoded_body_test() ->
    {Token, Cookies} = token_and_cookie(),
    Bad = <<"_csrf=bad">>,
    %% the header wins over a bad query
    ?assertEqual(ok, weberl_csrf:verify(multipart_post(#{token => Token, query => Bad,
                                                         headers => [{<<"x-csrf-token">>, Token}]}))),
    %% a bad header is not rescued by a good query
    ?assertEqual({error, token_mismatch},
                 weberl_csrf:verify(multipart_post(#{token => Token, query => <<"_csrf=", Token/binary>>,
                                                     headers => [{<<"x-csrf-token">>, <<"bad">>}]}))),
    %% an urlencoded body still carries it as a field
    ?assertEqual(ok, weberl_csrf:verify(weberl_test_form_adapter:request(#{cookies => Cookies,
                                                                             pairs => [{<<"_csrf">>, Token}]}))),
    %% the query of an urlencoded form is looked at first
    ?assertEqual(ok, weberl_csrf:verify(weberl_test_form_adapter:request(#{cookies => Cookies,
                                                                             query => <<"_csrf=", Token/binary>>,
                                                                             pairs => []}))),
    %% an invalid query string is not an error of its own
    ?assertEqual(ok, weberl_csrf:verify(weberl_test_form_adapter:request(#{cookies => Cookies, query => <<"%zz">>,
                                                                             pairs => [{<<"_csrf">>, Token}]}))).

an_urlencoded_form_over_a_limit_is_a_limit_error_not_a_missing_token_test() ->
    {Token, Cookies} = token_and_cookie(),
    Request = with_limits(weberl_test_form_adapter:request(#{cookies => Cookies, pairs => [{<<"_csrf">>, Token}]}),
                          #{max_field_bytes => 3}),
    ?assertEqual({error, {limit_exceeded, max_field_bytes}},
                 element(1, captured(fun() -> weberl_csrf:verify(Request) end))).

protect_keeps_the_token_url_out_of_referers_test() ->
    Build = fun(Request) -> weberl_csrf:protect(Request, fun(T) -> weberl_response:html(200, T) end) end,
    R = Build(weberl_test_cookie_adapter:request([])),
    ?assertEqual({ok, <<"same-origin">>}, weberl_response:header(R, <<"referrer-policy">>)),
    ?assertEqual({ok, <<"private, no-store">>}, weberl_response:header(R, <<"cache-control">>)),
    %% a policy the handler set is kept
    Own = weberl_csrf:protect(weberl_test_cookie_adapter:request([]),
                              fun(T) -> weberl_response:with_header(weberl_response:html(200, T), <<"referrer-policy">>, <<"no-referrer">>) end),
    ?assertEqual({ok, <<"no-referrer">>}, weberl_response:header(Own, <<"referrer-policy">>)).

%% ---------------------------------------------------------------------
%% Dispatch

load(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

table(Routes, RouterLimits) ->
    {ok, T} = weberl_table:assemble([], Routes),
    weberl_table:with_limits(T, RouterLimits).

upload_route(Handler, Limits) ->
    {ok, Opts} = weberl_route:check_opts(#{limits => Limits}),
    weberl_route:new("/up", Handler, declarative, router, Opts).

body(Response) -> iolist_to_binary(weberl_response:body(Response)).

dispatch_gives_the_handler_the_limits_of_its_route_over_its_router_test() ->
    H = load("lim", "handle(R) -> weberl_response:text(200, io_lib:format(\"~w\", [lists:sort(maps:to_list(weberl_request:limits(R)))]))."),
    T = table([upload_route(H, #{max_files => 2, max_file_bytes => 9})], #{max_files => 5, max_fields => 7}),
    R = weberl_dispatch:dispatch(weberl_test_form_adapter:request(#{method => <<"GET">>, path => "/up"}), T),
    ?assertEqual(<<"[{max_fields,7},{max_file_bytes,9},{max_files,2}]">>, body(R)),
    %% and the handler's own route info
    H2 = load("lim2", "handle(R) -> weberl_response:text(200, atom_to_binary(maps:get(handler, weberl_request:route(R))))."),
    T2 = table([upload_route(H2, #{})], #{}),
    ?assertEqual(atom_to_binary(H2),
                 body(weberl_dispatch:dispatch(weberl_test_form_adapter:request(#{method => <<"GET">>, path => "/up"}), T2))).

dispatch_runs_an_upload_with_the_query_token_test() ->
    H = load("up", "handle(R) -> {ok, Files} = weberl_request:files(R), "
                   "weberl_response:text(200, [integer_to_binary(length(Files)), $:, [maps:get(filename, F) || F <- Files]])."),
    T = table([upload_route(H, #{})], #{}),
    weberl_test_form_adapter:reset_calls(),
    R = weberl_dispatch:dispatch(multipart_post(#{}), T),
    ?assertEqual({200, <<"1:a.txt">>}, {weberl_response:status(R), body(R)}),
    %% a forged upload (no token) is a 403 and its body is never parsed
    weberl_test_form_adapter:reset_calls(),
    {Token, Cookies} = token_and_cookie(),
    _ = Token,
    Forged = weberl_test_form_adapter:request(#{cookies => Cookies, path => "/up",
                                                parts => [file(<<"f">>, <<"a">>, <<"t/p">>, <<"x">>)]}),
    {Forbidden, _} = captured(fun() -> weberl_dispatch:dispatch(Forged, T) end),
    ?assertEqual(403, weberl_response:status(Forbidden)),
    ?assertEqual([], weberl_test_form_adapter:calls()).

dispatch_answers_413_when_the_form_read_for_the_token_is_too_big_test() ->
    H = load("big", "handle(_) -> weberl_response:text(200, <<\"reached\">>)."),
    T = table([upload_route(H, #{max_field_bytes => 3})], #{}),
    {Token, Cookies} = token_and_cookie(),
    Request = weberl_test_form_adapter:request(#{cookies => Cookies, path => "/up", pairs => [{<<"_csrf">>, Token}]}),
    {R, Reports} = captured(fun() -> weberl_dispatch:dispatch(Request, T) end),
    ?assertEqual({413, <<"Payload Too Large">>}, {weberl_response:status(R), body(R)}),
    ?assertMatch([#{what := form_limit_exceeded, limit := max_field_bytes}], Reports).

a_handler_maps_a_limit_error_with_form_error_test() ->
    H = load("fe", "handle(R) -> case weberl_request:files(R) of {ok, _} -> weberl_response:text(200, <<\"ok\">>); "
                   "{error, E} -> weberl_response:form_error(E) end."),
    T = table([upload_route(H, #{max_file_bytes => 0})], #{}),
    {R, _} = captured(fun() -> weberl_dispatch:dispatch(multipart_post(#{}), T) end),
    ?assertEqual(413, weberl_response:status(R)).
