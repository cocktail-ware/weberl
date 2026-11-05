%% Updating a region of a live page: weberl_live:update/3 and update_topic/4.
-module(weberl_live_regions_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util,
        [with_router/2, new_page/2, open_stream/3, read_until/3, has/2, await_state/2, quiet/1]).

regions_test_() ->
    {setup,
     fun weberl_live_test_util:start_apps/0,
     fun(_) -> ok end,
     [{"update renders the region and pushes it to the page", fun update/0},
      {"update errors push nothing", fun update_errors/0},
      {"update_topic renders once and publishes to the topic", fun update_topic/0},
      {"update_topic errors", fun update_topic_errors/0},
      {"the event arrives over the stream", fun over_sse/0}]}.

%% A view with a template that has a `cart' region.
view() ->
    View = weberl_test_handlers:unique("rgn"),
    weberl_test_handlers:load(
      View, "-module(" ++ atom_to_list(View) ++ "). -export([handle/1]). "
            "handle(_) -> weberl_response:html(200, <<\"<html><body>x</body></html>\">>)."),
    {ok, C} = weberl_template:compile_source(
                View, <<"<h1>{{ @title }}</h1>{: region cart :}<ul>{{ @items }}</ul>{: /region cart :}">>,
                "t.weberl"),
    ok = weberl_template:load(C),
    View.

open_page(View) ->
    {ok, Id} = weberl_live:open(regions_owner, one_way, #{handler => View}),
    ok = weberl_live:attach(Id, self()),
    Id.

event(Id) ->
    receive {weberl_live, Id, {event, Name, Data}} -> {Name, json:decode(Data)}
    after 500 -> timeout
    end.

update() ->
    View = view(),
    Id = open_page(View),
    ?assertEqual(ok, weberl_live:update(Id, cart, #{items => <<"a < b">>})),
    ?assertEqual({<<"weberl:region">>, #{~"region" => ~"cart", ~"html" => ~"<ul>a &lt; b</ul>"}},
                 event(Id)).

update_errors() ->
    View = view(),
    Id = open_page(View),
    quiet(fun() ->
        ?assertEqual({error, {unknown_region, View, nope}}, weberl_live:update(Id, nope, #{})),
        ?assertEqual({error, {missing_variable, View, items}}, weberl_live:update(Id, cart, #{})),
        ?assertEqual({error, not_found}, weberl_live:update(<<"nosuchpage">>, cart, #{items => 1})),
        %% a page whose handler has no template
        {ok, Plain} = weberl_live:open(regions_owner, one_way, #{handler => lists}),
        ?assertEqual({error, {no_template, lists}}, weberl_live:update(Plain, cart, #{})),
        %% a page opened without a handler
        {ok, Bare} = weberl_live:open(regions_owner, one_way),
        ?assertEqual({error, no_handler}, weberl_live:update(Bare, cart, #{}))
    end),
    ?assertEqual(timeout, event(Id)).

update_topic() ->
    View = view(),
    Topic = <<"region-topic-1">>,
    ok = pg:join(weberl_live, {topic, Topic}, self()),
    try
        ?assertEqual(ok, weberl_live:update_topic(Topic, View, cart, #{items => 3})),
        receive
            {weberl_live_topic, Topic, <<"weberl:region">>, Payload, Frame} ->
                ?assertEqual(#{~"region" => ~"cart", ~"html" => ~"<ul>3</ul>"}, json:decode(Payload)),
                ?assertMatch(#{~"topic" := Topic, ~"event" := ~"weberl:region"}, json:decode(Frame))
        after 500 -> ?assert(false)
        end
    after
        pg:leave(weberl_live, {topic, Topic}, self())
    end.

update_topic_errors() ->
    View = view(),
    Topic = <<"region-topic-2">>,
    ok = pg:join(weberl_live, {topic, Topic}, self()),
    try
        quiet(fun() ->
            ?assertEqual({error, {unknown_region, View, nope}},
                         weberl_live:update_topic(Topic, View, nope, #{})),
            ?assertEqual({error, {no_template, lists}},
                         weberl_live:update_topic(Topic, lists, cart, #{}))
        end),
        receive {weberl_live_topic, _, _, _, _} -> ?assert(false) after 100 -> ok end
    after
        pg:leave(weberl_live, {topic, Topic}, self())
    end.

over_sse() ->
    View = view(),
    with_router([{"/live", View, #{live => one_way}}], fun(Name) ->
        {Id, Token} = new_page(Name, "/live"),
        {Sock, _Head, Rest} = open_stream(Name, Id, Token),
        await_state(Id, attached),
        ok = weberl_live:update(Id, cart, #{items => <<"x">>}),
        {ok, Data} = read_until(Sock, Rest, <<"region">>),
        ?assert(has(Data, <<"weberl:region">>)),
        {ok, More} = read_until(Sock, Data, <<"</ul>">>),
        ?assert(has(More, <<"<ul>x</ul>">>)),
        gen_tcp:close(Sock)
    end).
