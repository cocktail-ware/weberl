%% Links on a live page (HANDOFF decisions 8 and 9): a region with links re-renders when its
%% assigns change, in the session process or in the process of whoever calls `update/3'.
%% The page is compiled with the route table, so rendering needs no router; an id that is
%% not a route fails that render (logged, nothing pushed) and the page goes on.
-module(weberl_live_urls_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util, [quiet/1]).

urls_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(weberl), ok end,
     fun(_) -> ok end,
     [{"links in a region follow the assigns, encoded and checked against the routes", fun links_follow_assigns/0},
      {"an id that is not a route fails the render, the page goes on", fun unknown_route_is_logged/0},
      {"update/3 from another process renders with the table compiled in", fun update_from_another_process/0}]}.

table() ->
    Routes = [weberl_route:new(P, weberl_test_handlers, declarative, weberl_test_handlers)
              || P <- ["/", "/agents", "/docs/intro", "/docs/api"]],
    {ok, Table} = weberl_table:assemble([], Routes),
    Table.

source(Module) ->
    "-module(" ++ atom_to_list(Module) ++ "). -export([handle/1]). "
    "handle(_) -> weberl_response:html(200, <<\"x\">>).".

template() ->
    <<"{: region links :}<ul>"
      "{: for Id <- @ids :}"
      "<li><a href=\"/agents/{{ weberl_url:component(Id) }}\">a</a>"
      "<a href=\"{{ weberl_url:router_path(\"/docs/{{ Id }}\", #{no_warn => true}) }}\">d</a></li>"
      "{: empty :}<li>none</li>{: /for :}"
      "</ul>{: /region links :}">>.

view() ->
    View = weberl_test_handlers:unique("urlv"),
    weberl_test_handlers:load(View, source(View)),
    {ok, C} = weberl_template:compile_source(View, template(), "t.weberl", none, #{routes => table()}),
    ok = weberl_template:load(C),
    View.

page() ->
    View = view(),
    {ok, Id} = weberl_live:open(urls_owner, one_way, #{handler => View}),
    ok = weberl_live:attach(Id, self()),
    Request = weberl_request:with_page(weberl_request:new(#{method => <<"GET">>, path => "/p"}), Id),
    Html = iolist_to_binary(weberl_live:mount(View, Request, weberl_view_data:new(#{ids => []}))),
    {Id, Html}.

region(Id) ->
    receive
        {weberl_live, Id, {event, <<"weberl:region">>, Data}} ->
            #{~"region" := R, ~"html" := H} = json:decode(Data),
            {binary_to_atom(R), H}
    after 300 -> timeout
    end.

links_follow_assigns() ->
    {Id, First} = page(),
    ?assertEqual(<<"<weberl-region name=\"links\"><ul><li>none</li></ul></weberl-region>">>, First),
    ok = weberl_live:assign(Id, #{ids => [<<"api">>, <<"intro">>]}),
    ?assertEqual({links, <<"<ul>"
                           "<li><a href=\"/agents/api\">a</a><a href=\"/docs/api\">d</a></li>"
                           "<li><a href=\"/agents/intro\">a</a><a href=\"/docs/intro\">d</a></li>"
                           "</ul>">>}, region(Id)).

unknown_route_is_logged() ->
    {Id, _} = page(),
    quiet(fun() ->
        ok = weberl_live:assign(Id, #{ids => [<<"nope">>]}),
        ?assertEqual(timeout, region(Id)),
        %% a value with a slash cannot pass as two segments of a route
        ok = weberl_live:assign(Id, #{ids => [<<"api/x">>]}),
        ?assertEqual(timeout, region(Id))
    end),
    ok = weberl_live:assign(Id, #{ids => [<<"api">>]}),
    ?assertEqual({links, <<"<ul><li><a href=\"/agents/api\">a</a><a href=\"/docs/api\">d</a></li></ul>">>},
                 region(Id)).

update_from_another_process() ->
    {Id, _} = page(),
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Self ! {updated, weberl_live:update(Id, links, #{ids => [<<"intro">>]})}
    end),
    receive {updated, Result} -> ?assertEqual(ok, Result) end,
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    ?assertEqual({links, <<"<ul><li><a href=\"/agents/intro\">a</a><a href=\"/docs/intro\">d</a></li></ul>">>},
                 region(Id)).
