%% Dispatch of one_way / two_way routes: session, page id, beacon injection.
-module(weberl_dispatch_live_tests).
-include_lib("eunit/include/eunit.hrl").

dispatch_live_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(weberl), ok end,
     fun(_) -> ok end,
     [{"live html page gets session, page id and beacon", fun html_page/0},
      {"two_way pages too", fun two_way_page/0},
      {"normal routes are untouched", fun normal_route/0},
      {"non-html responses close the session", fun non_html/0},
      {"error responses close the session", fun failing_handler/0},
      {"page id reaches the handler and pushes arrive", fun page_id_push/0},
      {"live support missing: page served without it", fun live_unavailable/0},
      {"a handler can narrow the page kind", fun downgrade/0},
      {"a downgrade to normal serves a plain page and ends the session", fun downgrade_to_normal/0},
      {"widening the kind is a 500", fun widening/0},
      {"the marker means nothing on a normal route", fun marker_on_normal_route/0},
      {"live pages are kept out of shared caches", fun cache_control_default/0},
      {"a cache-control the handler set is kept; shared caching is warned about",
       fun cache_control_handler/0}]}.

load(Name, Body) ->
    Mod = weberl_test_handlers:unique(Name),
    weberl_test_handlers:load(
      Mod, "-module(" ++ atom_to_list(Mod) ++ "). -export([handle/1]). " ++ Body),
    Mod.

req(Path) ->
    weberl_request:new(#{method => <<"GET">>, path => Path,
                         meta => #{listener => dispatch_live_listener}}).

table(Routes) ->
    {ok, T} = weberl_table:assemble(
                [], [weberl_route:new(P, M, declarative, router, #{live => K})
                     || {P, M, K} <- Routes]),
    T.

body(R) -> iolist_to_binary(weberl_response:body(R)).

page_id_of(Body) ->
    {match, [Id]} = re:run(Body, "data-weberl-page=\"([^\"]+)\"",
                           [{capture, all_but_first, binary}]),
    Id.

html_page() ->
    H = load("lh", "handle(_) -> weberl_response:html(200, <<\"<body>hi</body>\">>)."),
    R = weberl_dispatch:dispatch(req("/p"), table([{"/p", H, one_way}])),
    B = body(R),
    Id = page_id_of(B),
    ?assertMatch({_, _}, binary:match(B, <<"data-weberl-kind=\"one_way\"">>)),
    ?assertMatch({_, _}, binary:match(B, <<"/_weberl/client.js">>)),
    ?assertMatch({ok, #{kind := one_way, owner := dispatch_live_listener}},
                 weberl_live:info(Id)).

two_way_page() ->
    H = load("lw", "handle(_) -> weberl_response:html(200, <<\"<body></body>\">>)."),
    B = body(weberl_dispatch:dispatch(req("/p"), table([{"/p", H, two_way}]))),
    ?assertMatch({_, _}, binary:match(B, <<"data-weberl-kind=\"two_way\"">>)),
    ?assertMatch({ok, #{kind := two_way}}, weberl_live:info(page_id_of(B))).

normal_route() ->
    H = load("ln", "handle(R) -> weberl_response:html(200, "
                   "[<<\"<body>\">>, io_lib:format(\"~p\", [weberl_request:page(R)]), "
                   "<<\"</body>\">>])."),
    B = body(weberl_dispatch:dispatch(req("/p"), table([{"/p", H, normal}]))),
    ?assertEqual(<<"<body>undefined</body>">>, B).

non_html() ->
    H = load("lt", "handle(R) -> weberl_response:text(200, weberl_request:page(R))."),
    R = weberl_dispatch:dispatch(req("/p"), table([{"/p", H, one_way}])),
    Id = body(R),
    ?assertEqual(nomatch, binary:match(Id, <<"<script">>)),
    await_gone(Id).

failing_handler() ->
    H = load("lf", "handle(R) -> put(id, weberl_request:page(R)), "
                   "weberl_live:push(weberl_request:page(R), <<\"a\">>, <<\"b\">>), "
                   "error(boom)."),
    %% The id is only visible inside the handler; find the new session by owner.
    Owner = list_to_atom("fail_owner_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Request = weberl_request:new(#{method => <<"GET">>, path => "/p",
                                   meta => #{listener => Owner}}),
    Logger = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    try
        R = weberl_dispatch:dispatch(Request, table([{"/p", H, one_way}])),
        ?assertEqual(500, weberl_response:status(R))
    after
        logger:set_primary_config(level, maps:get(level, Logger))
    end,
    timer:sleep(100),
    ?assertEqual([], pg:get_local_members(weberl_live, {owner, Owner})).

page_id_push() ->
    H = load("lp","handle(R) -> persistent_term:put(live_test_id, weberl_request:page(R)), "
                   "weberl_response:html(200, <<\"<body></body>\">>)."),
    B = body(weberl_dispatch:dispatch(req("/p"), table([{"/p", H, one_way}]))),
    Id = persistent_term:get(live_test_id),
    ?assertEqual(Id, page_id_of(B)),
    ok = weberl_live:attach(Id, self()),
    ok = weberl_live:push(Id, <<"tick">>, <<"1">>),
    receive {weberl_live, Id, {event, <<"tick">>, <<"1">>}} -> ok
    after 500 -> ?assert(false)
    end,
    persistent_term:erase(live_test_id).

live_unavailable() ->
    H = load("lu", "handle(_) -> weberl_response:html(200, <<\"<body>x</body>\">>)."),
    ok = application:stop(weberl),
    try
        Logger = logger:get_primary_config(),
        logger:set_primary_config(level, none),
        R = try weberl_dispatch:dispatch(req("/p"), table([{"/p", H, one_way}]))
            after logger:set_primary_config(level, maps:get(level, Logger)) end,
        ?assertEqual(200, weberl_response:status(R)),
        ?assertEqual(<<"<body>x</body>">>, body(R))
    after
        {ok, _} = application:ensure_all_started(weberl)
    end.

%% ---------------------------------------------------------------------
%% Downgrade and cache-control

%% A handler that answers with the page marked as `Kind'.
marked(Prefix, Kind) ->
    load(Prefix, "handle(_) -> weberl_response:live("
                 "weberl_response:html(200, <<\"<body>x</body>\">>), " ++ atom_to_list(Kind) ++ ").").

%% Dispatch `Path' as a route of kind `RouteKind' for a fresh owner.
serve(Handler, RouteKind) ->
    Owner = list_to_atom("dl_owner_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Request = weberl_request:new(#{method => <<"GET">>, path => "/p",
                                   meta => #{listener => Owner}}),
    {Owner, weberl_dispatch:dispatch(Request, table([{"/p", Handler, RouteKind}]))}.

sessions(Owner) -> pg:get_local_members(weberl_live, {owner, Owner}).

claims_of(Body, Channel) ->
    {match, [Token]} = re:run(Body, "data-weberl-token=\"([^\"]+)\"", [{capture, all_but_first, binary}]),
    weberl_live_guard:claims(page_id_of(Body), Channel, Token).

downgrade() ->
    {_, R} = serve(marked("dg1", one_way), two_way),
    B = body(R),
    ?assertMatch({_, _}, binary:match(B, <<"data-weberl-kind=\"one_way\"">>)),
    ?assertMatch({ok, #{kind := one_way}}, claims_of(B, sse)),
    %% the session knows too (the cast is asynchronous)
    Id = page_id_of(B),
    await_kind(Id, one_way),
    %% the same kind as the route is no change
    {_, R2} = serve(marked("dg2", two_way), two_way),
    ?assertMatch({_, _}, binary:match(body(R2), <<"data-weberl-kind=\"two_way\"">>)).

await_kind(Id, Kind) -> await_kind(Id, Kind, 40).
await_kind(Id, Kind, 0) -> ?assertMatch({ok, #{kind := Kind}}, weberl_live:info(Id));
await_kind(Id, Kind, N) ->
    case weberl_live:info(Id) of
        {ok, #{kind := Kind}} -> ok;
        _ -> timer:sleep(25), await_kind(Id, Kind, N - 1)
    end.

downgrade_to_normal() ->
    [begin
         {Owner, R} = serve(marked("dn", normal), RouteKind),
         ?assertEqual(200, weberl_response:status(R)),
         ?assertEqual(<<"<body>x</body>">>, body(R)),
         %% no beacon, kept out of shared caches, and the session is gone
         ?assertEqual({ok, <<"private, no-store">>}, weberl_response:header(<<"cache-control">>, R)),
         await_no_sessions(Owner)
     end || RouteKind <- [one_way, two_way]].

await_no_sessions(Owner) -> await_no_sessions(Owner, 40).
await_no_sessions(Owner, 0) -> ?assertEqual([], sessions(Owner));
await_no_sessions(Owner, N) ->
    case sessions(Owner) of
        [] -> ok;
        _ -> timer:sleep(25), await_no_sessions(Owner, N - 1)
    end.

widening() ->
    weberl_live_test_util:quiet(fun() ->
        {Owner, R} = serve(marked("dw", two_way), one_way),
        ?assertEqual(500, weberl_response:status(R)),
        await_no_sessions(Owner)
    end).

marker_on_normal_route() ->
    {_, R} = serve(marked("dm", two_way), normal),
    ?assertEqual(<<"<body>x</body>">>, body(R)).

cache_control_default() ->
    {_, R} = serve(load("cd", "handle(_) -> weberl_response:html(200, <<\"<body>x</body>\">>)."),
                   one_way),
    ?assertEqual({ok, <<"private, no-store">>}, weberl_response:header(<<"cache-control">>, R)).

cache_control_handler() ->
    Handler = fun(Value) ->
                      load("cc", "handle(_) -> weberl_response:with_header(<<\"cache-control\">>, <<\""
                                 ++ Value ++ "\">>, weberl_response:html(200, <<\"<body>x</body>\">>)).")
              end,
    Warned = fun(Value) ->
                     Self = self(),
                     Id = list_to_atom("cc_h_" ++ integer_to_list(erlang:unique_integer([positive]))),
                     ok = logger:add_handler(Id, weberl_test_log_handler,
                                             #{config => #{sink => Id}, level => warning}),
                     register(Id, Self),
                     Old = logger:get_primary_config(),
                     ok = logger:set_primary_config(level, warning),
                     try
                         {_, R} = serve(Handler(Value), one_way),
                         %% what the handler set stays as it is
                         ?assertEqual({ok, list_to_binary(Value)},
                                      weberl_response:header(<<"cache-control">>, R)),
                         receive
                             {log, #{msg := {report, #{what := live_page_allows_shared_caching}}}} -> true
                         after 200 -> false
                         end
                     after
                         logger:remove_handler(Id),
                         unregister(Id),
                         logger:set_primary_config(level, maps:get(level, Old))
                     end
             end,
    [?assert(Warned(V)) || V <- ["public, max-age=60", "max-age=60", "s-maxage=10",
                                 "PUBLIC", "Max-Age=5"]],
    [?assertNot(Warned(V)) || V <- ["private, max-age=60", "no-store", "no-cache",
                                    "private", "max-age=60, no-store"]].

await_gone(Id) -> await_gone(Id, 40).
await_gone(Id, 0) -> ?assertEqual({error, not_found}, weberl_live:whereis(Id));
await_gone(Id, N) ->
    case weberl_live:whereis(Id) of
        {error, not_found} -> ok;
        {ok, _} -> timer:sleep(25), await_gone(Id, N - 1)
    end.
