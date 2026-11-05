%% GET /clock (with a layout)  -- a one-way live page: the server pushes the time every second.
-module(layout_clock_view).
-behaviour(weberl_handler).
-weberl_page(one_way).
-weberl_route(#{layout => main}).

-export([handle/1]).

handle(Request) ->
    %% The page id identifies this page's live session. Hand it to whatever
    %% will push updates; here a small process that ticks until the page is gone.
    PageId = weberl_request:page(Request),
    spawn(fun() -> tick(PageId) end),
    weberl_response:html(200, weberl_template:render(?MODULE, #{title => <<"Clock">>, time => timestamp()})).

tick(PageId) ->
    timer:sleep(1000),
    case weberl_live:push(PageId, <<"tick">>, timestamp()) of
        ok -> tick(PageId);
        {error, not_found} -> ok
    end.

timestamp() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second))).
