%% GET /counter  -- a two-way live page with regions.
%%
%% The page has two regions (see counter_view.weberl). The button in the page
%% sends the request "add" (priv/static/counter.js), whose answer changes the
%% `count' assign: the session re-renders just that region and pushes it. A
%% small process updates the `time' assign every second the same way, from
%% outside the page.
%%
%% `private' view data (never rendered, never sent to the browser) remembers
%% when the page was opened; the request "age" answers from it.
-module(counter_view).
-behaviour(weberl_handler).
-weberl_page(two_way).

-export([handle/1, handle_request/3]).

handle(Request) ->
    PageId = weberl_request:page(Request),
    ViewData = weberl_view_data:new(#{count => 0, time => timestamp()},
                                    #{opened => erlang:system_time(second)}),
    spawn(fun() -> tick(PageId) end),
    %% Render the template and keep the view data in the page's session.
    weberl_response:html(200, weberl_live:mount(?MODULE, Request, ViewData)).

handle_request(<<"add">>, N, #{view := View}) when is_integer(N) ->
    #{count := Count} = weberl_view_data:assigns(View),
    New = Count + N,
    {reply, New, weberl_view_data:with_assigns(#{count => New}, View)};
handle_request(<<"age">>, _Data, #{view := View}) ->
    #{opened := Opened} = weberl_view_data:private(View),
    {reply, erlang:system_time(second) - Opened};
handle_request(_Name, _Data, _Page) ->
    ok.

%% Changes the `time' assign every second until the page is gone; the regions
%% that use it (only `clock') are re-rendered and pushed by the session.
tick(PageId) ->
    timer:sleep(1000),
    case weberl_live:assign(PageId, #{time => timestamp()}) of
        ok -> tick(PageId);
        {error, _} -> ok
    end.

timestamp() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second))).
