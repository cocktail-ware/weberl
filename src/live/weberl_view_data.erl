%% @doc What the session of a live page keeps for it (native record).
%%
%% A page's handler builds one when it mounts the page (`weberl_live:mount/3')
%% and the session holds it for the life of the page. It stays on the server and
%% is never sent to the browser as such. Today it has two parts, and more can be
%% added without breaking callers:
%% <ul>
%%   <li>`assigns': the template variables. The regions of the page are
%%       rendered from them, and a region is re-rendered when a variable it
%%       uses changes.</li>
%%   <li>`private': the handler's own data (who the user is, what the page
%%       was opened for, ...), never rendered.</li>
%% </ul>
%% The record also remembers the layout the page was mounted with (`with_layout/2').
%% It is the Phoenix idea of keeping what a regular HTTP request knew (cookie,
%% authenticated user) for the life of the page, after which the browser talks
%% only through the live connection. `handle_request/3' of a page with a session
%% receives the current record (`#{view := ViewData}' in the page context) and
%% may return a changed one.
%%
%% ```
%% ViewData = weberl_view_data:new(#{items => Items}, #{user_id => UserId}),
%% weberl_live:mount(?MODULE, Request, ViewData).
%% '''
-module(weberl_view_data).

-export([new/1, new/2, assigns/1, private/1,
         with_assigns/2, with_private/2, set_assigns/2, set_private/2,
         layout/1, with_layout/2, render_opts/1,
         is_view_data/1, changed_assigns/2]).
-export_type([t/0]).
-export_record([view_data]).

-record #view_data{
    assigns = #{} :: map(),
    private = #{} :: map(),
    %% the layout the page is rendered with; undefined: the view's default
    layout = undefined :: undefined | atom()
}.

-type t() :: #view_data{}.

%% @doc A record with these template variables and no private data.
-spec new(map()) -> t().
new(Assigns) when is_map(Assigns) ->
    #view_data{assigns = Assigns}.

-spec new(map(), map()) -> t().
new(Assigns, Private) when is_map(Assigns), is_map(Private) ->
    #view_data{assigns = Assigns, private = Private}.

-spec assigns(t()) -> map().
assigns(#view_data{assigns = A}) -> A.

-spec private(t()) -> map().
private(#view_data{private = P}) -> P.

%% @doc Merge `Changes' into the assigns (keys already there are replaced).
-spec with_assigns(map(), t()) -> t().
with_assigns(Changes, #view_data{assigns = A} = V) when is_map(Changes) ->
    V#view_data{assigns = maps:merge(A, Changes)}.

%% @doc Merge `Changes' into the private data.
-spec with_private(map(), t()) -> t().
with_private(Changes, #view_data{private = P} = V) when is_map(Changes) ->
    V#view_data{private = maps:merge(P, Changes)}.

%% @doc Replace all the assigns (to remove a key, for instance).
-spec set_assigns(map(), t()) -> t().
set_assigns(Assigns, #view_data{} = V) when is_map(Assigns) ->
    V#view_data{assigns = Assigns}.

%% @doc Replace all the private data.
-spec set_private(map(), t()) -> t().
set_private(Private, #view_data{} = V) when is_map(Private) ->
    V#view_data{private = Private}.

%% @doc The layout the page is rendered with (see `weberl_template:render/3'); `undefined' is
%% the view's default layout. The session renders and re-renders the page's regions with it.
-spec layout(t()) -> undefined | atom().
layout(#view_data{layout = L}) -> L.

%% @doc Render the page with `Layout' (one the route allows, `none' for the bare view).
-spec with_layout(atom(), t()) -> t().
with_layout(Layout, #view_data{} = V) when is_atom(Layout) ->
    V#view_data{layout = Layout}.

%% @doc The options for `weberl_template:render/3' and friends that this record stands for.
-spec render_opts(t()) -> weberl_template:render_opts().
render_opts(#view_data{layout = undefined}) -> #{};
render_opts(#view_data{layout = L}) -> #{layout => L}.

-spec is_view_data(term()) -> boolean().
is_view_data(#view_data{}) -> true;
is_view_data(_) -> false.

%% @doc The assign keys whose value differs between two records (added,
%% removed or changed), sorted.
-spec changed_assigns(t(), t()) -> [atom()].
changed_assigns(#view_data{assigns = Old}, #view_data{assigns = New}) ->
    Keys = lists:usort(maps:keys(Old) ++ maps:keys(New)),
    [K || K <- Keys, maps:find(K, Old) =/= maps:find(K, New)].
