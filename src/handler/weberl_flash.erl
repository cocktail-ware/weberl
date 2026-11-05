%% @doc Flash: short messages for the next page ("Saved", "Wrong password"), the
%% post/redirect/get companion.
%%
%% A flash is a map `#{Key => Value}' (any terms) kept in the {@link weberl_session}
%% under a reserved key, with its own time of writing: it expires after `flash_ttl'
%% seconds (default 300, an application env of `weberl') however long the session
%% lives. It therefore rides the session's encrypted cookie; using flash creates a
%% session cookie if there is none.
%%
%% ```
%% %% after a POST: say it, then redirect
%% weberl_flash:put(weberl_response:redirect("/login"), error, <<"Wrong password">>)
%%
%% %% the page that shows it: read it and clear it
%% {Flash, Response} = weberl_flash:take(Request, weberl_response:html(200, Html))
%% '''
%%
%% == Reading, clearing, passing through ==
%% Reading does not clear. {@link get/1} returns what the request carried and leaves
%% the cookie alone; {@link take/2} reads it and makes the response remove it. A
%% handler that never calls `take' leaves the flash where it is, so it survives:
%% a redirect that does not touch flash passes it on to the next page (in a chain
%% A, B, C the flash shows at C when only C takes it). After a `take' that should
%% not have cleared, {@link keep/2} puts the request's flash back into the response.
%%
%% Only what the request delivered is removed: a flash this response `put' itself
%% (for the next page) survives `take', in either order. A `put' is added to an
%% unread flash rather than replacing it, so show flash (`take') on the pages that
%% display it.
-module(weberl_flash).

-compile({no_auto_import, [get/1]}).

-export([put/3, get/1, get/2, take/2, keep/2]).

-define(KEY, '$weberl_flash').

%% @doc Add `Key => Value' to the flash this response sends (an unread flash from
%% the request is kept, the same key is replaced).
-spec put(weberl_response:t(), term(), term()) -> weberl_response:t().
put(Response, Key, Value) ->
    store(Response, (current(Response))#{Key => Value}).

%% @doc The flash the request carried: a map, `#{}' when there is none or it has
%% expired. Does not clear it.
-spec get(weberl_request:t()) -> map().
get(Request) ->
    live(weberl_request:session_get(Request, ?KEY)).

%% @doc `{ok, Value} | error' for `Key' in {@link get/1}.
-spec get(weberl_request:t(), term()) -> {ok, term()} | error.
get(Request, Key) ->
    maps:find(Key, get(Request)).

%% @doc `{Flash, Response}': the request's flash, and the response with it removed
%% (nothing is written when there is no flash).
-spec take(weberl_request:t(), weberl_response:t()) -> {map(), weberl_response:t()}.
take(Request, Response) ->
    Delivered = get(Request),
    case map_size(Delivered) of
        0 ->
            {Delivered, Response};
        _ ->
            Remaining = maps:filter(fun(K, V) -> maps:find(K, Delivered) =/= {ok, V} end,
                                    current(Response)),
            {Delivered, store(Response, Remaining)}
    end.

%% @doc Put the request's flash into the response: for a handler that called
%% {@link take/2} (or `reset_session') and now wants the messages to reach the next
%% page after all. What the response already holds wins over the request's for
%% the same key. The messages get a fresh `flash_ttl'.
-spec keep(weberl_request:t(), weberl_response:t()) -> weberl_response:t().
keep(Request, Response) ->
    Delivered = get(Request),
    Held = current(Response),
    case maps:merge(Delivered, Held) of
        Held -> Response;
        Merged -> store(Response, Merged)
    end.

%% ---------------------------------------------------------------------

%% The flash the response will send (its session's, which starts as the request's).
current(Response) ->
    live(weberl_response:session_get(Response, ?KEY)).

store(Response, Flash) when map_size(Flash) =:= 0 ->
    case weberl_response:session_get(Response, ?KEY) of
        error -> Response;
        {ok, _} -> weberl_response:delete_session(Response, ?KEY)
    end;
store(Response, Flash) ->
    weberl_response:put_session(Response, ?KEY, {os:system_time(second), Flash}).

live({ok, {WrittenAt, Flash}}) when is_integer(WrittenAt), is_map(Flash) ->
    case WrittenAt + ttl() > os:system_time(second) of
        true -> Flash;
        false -> #{}
    end;
live(_) ->
    #{}.

ttl() ->
    case application:get_env(weberl, flash_ttl, 300) of
        N when is_integer(N), N > 0 -> N;
        _ -> 300
    end.
