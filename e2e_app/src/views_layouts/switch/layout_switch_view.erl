%% GET /switch[?layout=main|admin|none]  -- a two-way live page rendered with a layout the
%% handler picks per request (runtime layouts). Only the layouts a route allows can be named,
%% and the handler maps the query value onto them itself.
%%
%% The `who' region is in the admin layout only; the `name' region is in the view. The
%% request "rename" changes both assigns, so what the browser receives shows which pair the
%% session re-renders with.
-module(layout_switch_view).
-behaviour(weberl_handler).
-weberl_page(two_way).
-weberl_route(#{layout => main, layouts => [admin, none]}).

-export([handle/1, handle_request/3]).

handle(Request) ->
    ViewData = weberl_view_data:new(#{title => <<"Switch">>, who => <<"ann">>, name => <<"ann">>}),
    weberl_response:html(200, weberl_live:mount(?MODULE, Request, ViewData, #{layout => layout(Request)})).

%% Never pass the query value on: map it onto the allowed names.
layout(Request) ->
    {ok, Params} = weberl_request:query_params(Request),
    case lists:keyfind(<<"layout">>, 1, Params) of
        {_, <<"admin">>} -> admin;
        {_, <<"none">>} -> none;
        _ -> main
    end.

handle_request(<<"rename">>, Name, #{view := View}) when is_binary(Name) ->
    {reply, ok, weberl_view_data:with_assigns(#{who => Name, name => Name}, View)};
handle_request(_Name, _Data, _Page) ->
    ok.
