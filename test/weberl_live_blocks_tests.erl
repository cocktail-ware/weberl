%% Blocks on a live page: the pattern to make a conditional live is to put it inside a
%% region (README "Conditionals, case and loops"). A change of an assign re-renders the
%% regions whose blocks read it, and pushes them to the page; an `if' outside any region is
%% rendered once and is not touched.
-module(weberl_live_blocks_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_live_test_util, [quiet/1]).

blocks_test_() ->
    {setup,
     fun() -> {ok, _} = application:ensure_all_started(weberl), ok end,
     fun(_) -> ok end,
     [{"a conditional inside a region is re-rendered when its assign changes", fun conditional_in_region/0},
      {"a loop inside a region re-renders with its list", fun loop_in_region/0},
      {"a case inside a region binds and matches on each render", fun case_in_region/0},
      {"an if outside any region is not updated", fun conditional_outside_region/0},
      {"a region in a branch is pushed whether or not it is shown", fun region_in_a_branch/0},
      {"an expression that raises while re-rendering is logged and the page goes on", fun raising_region/0}]}.

source(Module) ->
    "-module(" ++ atom_to_list(Module) ++ "). -export([handle/1]). "
    "handle(_) -> weberl_response:html(200, <<\"x\">>).".

%% The page:
%%   an `if' outside any region (the header),
%%   region `nav':    an if/else on `user' and a for over `agents',
%%   region `flash':  a case on `flash',
%%   region `extra':  inside an if branch (the branch itself is not in a region).
template() ->
    <<"{: if @user =/= undefined :}<header>hi</header>{: else :}<header>anon</header>{: /if :}"
      "{: region nav :}"
      "{: if @user =/= undefined :}<b>{{ @user }}</b>{: else :}<i>guest</i>{: /if :}"
      "<ul>{: for A <- @agents :}<li>{{ A }}</li>{: empty :}<li>none</li>{: /for :}</ul>"
      "{: /region nav :}"
      "{: region flash :}"
      "{: case @flash :}{: of undefined :}{: of {error, Msg} :}<p class=\"e\">{{ Msg }}</p>"
      "{: of {info, Msg} :}<p>{{ Msg }}</p>{: /case :}"
      "{: /region flash :}"
      "{: if @show_extra :}{: region extra :}<em>{{ @extra }}</em>{: /region extra :}{: /if :}">>.

view() ->
    View = weberl_test_handlers:unique("blk"),
    weberl_test_handlers:load(View, source(View)),
    {ok, C} = weberl_template:compile_source(View, template(), "t.weberl"),
    ok = weberl_template:load(C),
    View.

data() ->
    weberl_view_data:new(#{user => undefined, agents => [], flash => undefined,
                           show_extra => false, extra => <<"e">>}).

%% A mounted, attached page: {Id, FirstHtml}.
page() ->
    View = view(),
    {ok, Id} = weberl_live:open(blocks_owner, one_way, #{handler => View}),
    ok = weberl_live:attach(Id, self()),
    Request = weberl_request:with_page(weberl_request:new(#{method => <<"GET">>, path => "/p"}), Id),
    {Id, iolist_to_binary(weberl_live:mount(View, Request, data()))}.

region(Id) ->
    receive
        {weberl_live, Id, {event, <<"weberl:region">>, Data}} ->
            #{~"region" := R, ~"html" := H} = json:decode(Data),
            {binary_to_atom(R), H}
    after 300 -> timeout
    end.

first_render_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(weberl), ok end, fun(_) -> ok end,
     fun() ->
             {_Id, Html} = page(),
             ?assertEqual(<<"<header>anon</header>"
                            "<weberl-region name=\"nav\"><i>guest</i><ul><li>none</li></ul></weberl-region>"
                            "<weberl-region name=\"flash\"></weberl-region>">>, Html)
     end}.

conditional_in_region() ->
    {Id, _} = page(),
    %% `user' is read by the `if' inside `nav' (and by the header, which is not a region)
    ok = weberl_live:assign(Id, #{user => <<"ana">>}),
    ?assertEqual({nav, <<"<b>ana</b><ul><li>none</li></ul>">>}, region(Id)),
    ?assertEqual(timeout, region(Id)),
    ok = weberl_live:assign(Id, #{user => undefined}),
    ?assertEqual({nav, <<"<i>guest</i><ul><li>none</li></ul>">>}, region(Id)).

loop_in_region() ->
    {Id, _} = page(),
    ok = weberl_live:assign(Id, #{agents => [<<"a">>, <<"b<c">>]}),
    ?assertEqual({nav, <<"<i>guest</i><ul><li>a</li><li>b&lt;c</li></ul>">>}, region(Id)),
    ok = weberl_live:assign(Id, #{agents => []}),
    ?assertEqual({nav, <<"<i>guest</i><ul><li>none</li></ul>">>}, region(Id)),
    %% nothing else read `agents'
    ?assertEqual(timeout, region(Id)).

case_in_region() ->
    {Id, _} = page(),
    ok = weberl_live:assign(Id, #{flash => {error, <<"Bad">>}}),
    ?assertEqual({flash, <<"<p class=\"e\">Bad</p>">>}, region(Id)),
    ok = weberl_live:assign(Id, #{flash => {info, <<"Saved">>}}),
    ?assertEqual({flash, <<"<p>Saved</p>">>}, region(Id)),
    ok = weberl_live:assign(Id, #{flash => undefined}),
    ?assertEqual({flash, <<>>}, region(Id)).

conditional_outside_region() ->
    {Id, _} = page(),
    %% only `nav' is pushed; the `<header>' stays what the first render made it
    ok = weberl_live:assign(Id, #{user => <<"ana">>}),
    ?assertEqual({nav, <<"<b>ana</b><ul><li>none</li></ul>">>}, region(Id)),
    ?assertEqual(timeout, region(Id)).

%% `extra' is inside an `if' branch: its content depends on `extra' only. A change of
%% `extra' pushes it even while the branch is hidden (the browser finds no element and
%% ignores the patch); showing it needs a new render of the page.
region_in_a_branch() ->
    {Id, Html} = page(),
    ?assertEqual(nomatch, binary:match(Html, <<"extra">>)),
    ok = weberl_live:assign(Id, #{extra => <<"new">>}),
    ?assertEqual({extra, <<"<em>new</em>">>}, region(Id)),
    ok = weberl_live:assign(Id, #{show_extra => true}),
    %% `show_extra' is read by the `if' around the region, which belongs to no region
    ?assertEqual(timeout, region(Id)).

%% `for' over something that is not a list raises while re-rendering the region: the
%% session logs it and keeps going, the other regions are unaffected.
raising_region() ->
    {Id, _} = page(),
    quiet(fun() ->
        ok = weberl_live:assign(Id, #{agents => not_a_list}),
        ?assertEqual(timeout, region(Id))
    end),
    ok = weberl_live:assign(Id, #{flash => {info, <<"still alive">>}}),
    ?assertEqual({flash, <<"<p>still alive</p>">>}, region(Id)).
