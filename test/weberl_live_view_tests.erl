%% The view data of a page with a session (weberl_view_data): mount, assign,
%% modify, and what a request handler can do with it.
-module(weberl_live_view_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util, [quiet/1]).

view_data_test() ->
    V = weberl_view_data:new(#{a => 1}),
    ?assertEqual(#{a => 1}, weberl_view_data:assigns(V)),
    ?assertEqual(#{}, weberl_view_data:private(V)),
    V2 = weberl_view_data:new(#{a => 1}, #{u => 7}),
    ?assertEqual(#{u => 7}, weberl_view_data:private(V2)),
    ?assertEqual(#{a => 1, b => 2}, weberl_view_data:assigns(weberl_view_data:with_assigns(#{b => 2}, V))),
    ?assertEqual(#{a => 9}, weberl_view_data:assigns(weberl_view_data:with_assigns(#{a => 9}, V))),
    ?assertEqual(#{u => 7, v => 8}, weberl_view_data:private(weberl_view_data:with_private(#{v => 8}, V2))),
    ?assertEqual(#{}, weberl_view_data:assigns(weberl_view_data:set_assigns(#{}, V))),
    ?assertEqual(#{}, weberl_view_data:private(weberl_view_data:set_private(#{}, V2))),
    ?assert(weberl_view_data:is_view_data(V)),
    ?assertNot(weberl_view_data:is_view_data(#{a => 1})),
    ?assertError(function_clause, weberl_view_data:new(not_a_map)).

changed_assigns_test() ->
    New = fun(M) -> weberl_view_data:new(M) end,
    ?assertEqual([], weberl_view_data:changed_assigns(New(#{a => 1}), New(#{a => 1}))),
    ?assertEqual([a, c, d], weberl_view_data:changed_assigns(New(#{a => 1, b => 2, c => 3}),
                                                              New(#{a => 2, b => 2, d => 4}))),
    %% private data is not an assign
    ?assertEqual([], weberl_view_data:changed_assigns(weberl_view_data:new(#{a => 1}, #{p => 1}),
                                                       weberl_view_data:new(#{a => 1}, #{p => 2}))).

%% ---------------------------------------------------------------------

view_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(weberl), ok end,
     fun(_) -> ok end,
     [{"mount renders the template and the session keeps the record", fun mount/0},
      {"mount without a session just renders", fun mount_without_session/0},
      {"assign re-renders only the regions that use a changed variable", fun assign/0},
      {"assign errors", fun assign_errors/0},
      {"assign while detached is delivered on attach", fun assign_detached/0},
      {"modify changes the view data and re-renders", fun modify/0},
      {"modify errors", fun modify_errors/0},
      {"handle_request sees the view and can return a new one", fun request_view/0},
      {"handle_request returning something else than view data fails", fun request_bad_view/0},
      {"a handler mounts the page it is rendering through dispatch", fun through_dispatch/0},
      {"a page that never mounted has no view; a record from a callback without a session is dropped",
       fun request_without_view/0}]}.

source(Module) ->
    "-module(" ++ atom_to_list(Module) ++ "). -export([handle/1, handle_request/3]). "
    "handle(_) -> weberl_response:html(200, <<\"x\">>). "
    "handle_request(<<\"add\">>, N, #{view := V}) -> "
    "    #{count := C} = weberl_view_data:assigns(V), "
    "    {reply, C + N, weberl_view_data:with_assigns(#{count => C + N}, V)}; "
    "handle_request(<<\"user\">>, _, #{view := V}) -> "
    "    {reply, maps:get(user, weberl_view_data:private(V))}; "
    "handle_request(<<\"bad\">>, _, _) -> {ok, not_a_view}; "
    "handle_request(<<\"keep\">>, _, #{view := V}) -> "
    "    {ok, weberl_view_data:with_private(#{seen => true}, V)}; "
    "handle_request(<<\"has_view\">>, _, Ctx) -> {reply, maps:is_key(view, Ctx)}; "
    "handle_request(<<\"drop\">>, _, _) -> {reply, ok, weberl_view_data:new(#{count => 1})}.".

%% A view whose template has the regions `count' (variable `count') and `name'
%% (variable `title').
view() ->
    View = weberl_test_handlers:unique("vw"),
    weberl_test_handlers:load(View, source(View)),
    {ok, C} = weberl_template:compile_source(
                View, <<"<h1>{{ title }}</h1>"
                        "{: region count :}<b>{{ count }}</b>{: /region count :}"
                        "{: region name :}<i>{{ title }}</i>{: /region name :}">>,
                "t.weberl"),
    ok = weberl_template:load(C),
    View.

view_data() ->
    weberl_view_data:new(#{title => <<"T">>, count => 1}, #{user => <<"ann">>}).

%% A mounted, attached page: {View, PageId, Request}.
page() ->
    View = view(),
    {ok, Id} = weberl_live:open(view_owner, one_way, #{handler => View}),
    ok = weberl_live:attach(Id, self()),
    Request = weberl_request:with_page(Id, weberl_request:new(#{method => <<"GET">>, path => "/p"})),
    {View, Id, Request}.

html(IoData) -> iolist_to_binary(IoData).

%% The next region event as {Region, Html}.
region(Id) ->
    receive
        {weberl_live, Id, {event, <<"weberl:region">>, Data}} ->
            #{~"region" := R, ~"html" := H} = json:decode(Data),
            {binary_to_atom(R), H}
    after 300 -> timeout
    end.

mount() ->
    {View, Id, Request} = page(),
    Html = weberl_live:mount(View, Request, view_data()),
    ?assertEqual(<<"<h1>T</h1><weberl-region name=\"count\"><b>1</b></weberl-region>"
                   "<weberl-region name=\"name\"><i>T</i></weberl-region>">>, html(Html)),
    ?assertEqual({ok, view_data()}, weberl_live:view(Id)),
    %% mounting again replaces it
    _ = weberl_live:mount(View, Request, weberl_view_data:new(#{title => <<"U">>, count => 2})),
    ?assertMatch({ok, _}, weberl_live:view(Id)),
    ?assertEqual(#{title => <<"U">>, count => 2},
                 weberl_view_data:assigns(element(2, weberl_live:view(Id)))),
    ?assertError(badarg, weberl_live:mount(View, Request, #{title => <<"x">>})).

mount_without_session() ->
    View = view(),
    Plain = weberl_request:new(#{method => <<"GET">>, path => "/p"}),
    ?assertMatch(<<"<h1>T</h1>", _/binary>>, html(weberl_live:mount(View, Plain, view_data()))),
    %% a page id nobody holds (a session-less page)
    Page = weberl_request:with_page(weberl_live:new_page_id(), Plain),
    ?assertMatch(<<"<h1>T</h1>", _/binary>>, html(weberl_live:mount(View, Page, view_data()))),
    ?assertEqual({error, not_found}, weberl_live:view(<<"nosuchpage">>)).

assign() ->
    {View, Id, Request} = page(),
    _ = weberl_live:mount(View, Request, view_data()),
    %% `count' is used by one region only
    ?assertEqual(ok, weberl_live:assign(Id, #{count => 5})),
    ?assertEqual({count, <<"<b>5</b>">>}, region(Id)),
    ?assertEqual(timeout, region(Id)),
    %% `title' is used by `name' (and the page, which is not a region)
    ?assertEqual(ok, weberl_live:assign(Id, #{title => <<"a<b">>})),
    ?assertEqual({name, <<"<i>a&lt;b</i>">>}, region(Id)),
    %% the same value again changes nothing
    ?assertEqual(ok, weberl_live:assign(Id, #{title => <<"a<b">>, count => 5})),
    ?assertEqual(timeout, region(Id)),
    %% both at once: in template order
    ?assertEqual(ok, weberl_live:assign(Id, #{title => <<"x">>, count => 6})),
    ?assertEqual({count, <<"<b>6</b>">>}, region(Id)),
    ?assertEqual({name, <<"<i>x</i>">>}, region(Id)),
    %% a variable no region uses: kept, nothing pushed
    ?assertEqual(ok, weberl_live:assign(Id, #{other => 1})),
    ?assertEqual(timeout, region(Id)),
    ?assertMatch(#{other := 1}, weberl_view_data:assigns(element(2, weberl_live:view(Id)))).

assign_errors() ->
    {View, Id, _} = page(),
    ?assertEqual({error, no_view}, weberl_live:assign(Id, #{a => 1})),
    ?assertEqual({error, no_view}, weberl_live:modify(Id, fun(V) -> V end)),
    ?assertEqual({error, no_view}, weberl_live:view(Id)),
    ?assertEqual({error, not_found}, weberl_live:assign(<<"nosuchpage">>, #{a => 1})),
    %% a region that cannot render (a variable it needs was removed) is logged, the rest go on
    {_, Id2, Request2} = page(),
    _ = weberl_live:mount(View, Request2, view_data()),
    %% (`count' is removed: its region cannot render, `title' did not change)
    quiet(fun() ->
        ok = weberl_live:modify(Id2, fun(V) -> weberl_view_data:set_assigns(#{title => <<"T">>}, V) end),
        ?assertEqual(timeout, region(Id2))
    end),
    ?assertEqual(#{title => <<"T">>}, weberl_view_data:assigns(element(2, weberl_live:view(Id2)))).

assign_detached() ->
    View = view(),
    {ok, Id} = weberl_live:open(view_owner, one_way, #{handler => View}),
    Request = weberl_request:with_page(Id, weberl_request:new(#{method => <<"GET">>, path => "/p"})),
    _ = weberl_live:mount(View, Request, view_data()),
    ?assertEqual(ok, weberl_live:assign(Id, #{count => 9})),
    ok = weberl_live:attach(Id, self()),
    ?assertEqual({count, <<"<b>9</b>">>}, region(Id)).

modify() ->
    {View, Id, Request} = page(),
    _ = weberl_live:mount(View, Request, view_data()),
    ?assertEqual(ok, weberl_live:modify(Id, fun(V) ->
        weberl_view_data:with_private(#{role => admin}, weberl_view_data:with_assigns(#{count => 2}, V))
    end)),
    ?assertEqual({count, <<"<b>2</b>">>}, region(Id)),
    {ok, Now} = weberl_live:view(Id),
    ?assertEqual(#{user => <<"ann">>, role => admin}, weberl_view_data:private(Now)),
    %% a change of private data only pushes nothing
    ok = weberl_live:modify(Id, fun(V) -> weberl_view_data:with_private(#{role => user}, V) end),
    ?assertEqual(timeout, region(Id)).

modify_errors() ->
    {View, Id, Request} = page(),
    _ = weberl_live:mount(View, Request, view_data()),
    quiet(fun() ->
        ?assertEqual({error, failed}, weberl_live:modify(Id, fun(_) -> not_a_view end)),
        ?assertEqual({error, failed}, weberl_live:modify(Id, fun(_) -> error(boom) end))
    end),
    %% the session and its view survive
    ?assertEqual({ok, view_data()}, weberl_live:view(Id)).

request_view() ->
    {View, Id, Request} = page(),
    _ = weberl_live:mount(View, Request, view_data()),
    %% the handler reads the private data (the user the HTTP request knew)
    ?assertEqual({ok, {reply, <<"ann">>}}, weberl_live:request(Id, <<"user">>, null)),
    %% and returns a new view: the session keeps it and updates the region
    ?assertEqual({ok, {reply, 4}}, weberl_live:request(Id, <<"add">>, 3)),
    ?assertEqual({count, <<"<b>4</b>">>}, region(Id)),
    ?assertEqual({ok, {reply, 6}}, weberl_live:request(Id, <<"add">>, 2)),
    ?assertEqual({count, <<"<b>6</b>">>}, region(Id)),
    %% `{ok, View}' without a reply, private data only: no region changes
    ?assertEqual({ok, noreply}, weberl_live:request(Id, <<"keep">>, null)),
    ?assertEqual(timeout, region(Id)),
    ?assertMatch(#{seen := true, user := <<"ann">>},
                 weberl_view_data:private(element(2, weberl_live:view(Id)))).

request_bad_view() ->
    {View, Id, Request} = page(),
    _ = weberl_live:mount(View, Request, view_data()),
    quiet(fun() ->
        ?assertEqual({error, failed}, weberl_live:request(Id, <<"bad">>, null))
    end),
    ?assertEqual({ok, view_data()}, weberl_live:view(Id)).

through_dispatch() ->
    View = weberl_test_handlers:unique("vd"),
    weberl_test_handlers:load(
      View, "-module(" ++ atom_to_list(View) ++ "). -export([handle/1, handle_request/3]). "
            "handle(R) -> V = weberl_view_data:new(#{n => 1}, #{who => <<\"ann\">>}), "
            "weberl_response:html(200, weberl_live:mount(" ++ atom_to_list(View) ++ ", R, V)). "
            "handle_request(<<\"inc\">>, _, #{view := V}) -> "
            "    #{n := N} = weberl_view_data:assigns(V), "
            "    {reply, maps:get(who, weberl_view_data:private(V)), weberl_view_data:with_assigns(#{n => N + 1}, V)}."),
    {ok, C} = weberl_template:compile_source(
                View, <<"<body>{: region n :}<b>{{ n }}</b>{: /region n :}</body>">>, "t.weberl"),
    ok = weberl_template:load(C),
    {ok, Table} = weberl_table:assemble(
                    [], [weberl_route:new("/p", View, declarative, router, #{live => one_way})]),
    Request = weberl_request:new(#{method => <<"GET">>, path => "/p",
                                   meta => #{listener => view_dispatch_listener}}),
    Page = iolist_to_binary(weberl_response:body(weberl_dispatch:dispatch(Request, Table))),
    ?assertMatch({_, _}, binary:match(Page, <<"<weberl-region name=\"n\"><b>1</b></weberl-region>">>)),
    {match, [Id]} = re:run(Page, "data-weberl-page=\"([^\"]+)\"", [{capture, all_but_first, binary}]),
    ok = weberl_live:attach(Id, self()),
    ?assertEqual({ok, {reply, <<"ann">>}}, weberl_live:request(Id, <<"inc">>, null)),
    ?assertEqual({n, <<"<b>2</b>">>}, region(Id)).

request_without_view() ->
    %% a page that never mounted has no `view' in its context ...
    View = view(),
    {ok, Id} = weberl_live:open(view_owner, one_way, #{handler => View}),
    ?assertEqual({ok, {reply, false}}, weberl_live:request(Id, <<"has_view">>, null)),
    %% ... and the callbacks module drops a record it cannot keep
    Context = #{page => <<"p">>, kind => one_way, topics => []},
    ?assertEqual({ok, {reply, ok}}, weberl_live_callbacks:request(View, <<"drop">>, null, Context)),
    %% returning one makes it the page's view when the session had none
    ?assertEqual({ok, {reply, ok}}, weberl_live:request(Id, <<"drop">>, null)),
    ?assertEqual(#{count => 1}, weberl_view_data:assigns(element(2, weberl_live:view(Id)))).
