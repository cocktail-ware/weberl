%% @doc Beacon injection: adds the client `<script>' tag to an HTML response.
%%
%% The tag goes right before the last `</body>' (matched case-insensitively),
%% or at the end of the document when there is none. It carries the page id
%% and kind as data attributes; `priv/client.js' reads them.
-module(weberl_live_beacon).

-include_lib("kernel/include/logger.hrl").

-export([inject/2, tag/2, tag/3, injectable/1, cache_control/2]).

%% @doc Keep a live page out of shared caches. The page embeds a token and an
%% id that belong to one render, so a shared cache serving it to others would
%% hand out someone else's credentials. Without a `cache-control' header the
%% response gets `private, no-store'; a header the handler set is respected,
%% but one that allows shared caching (`public', `s-maxage', or `max-age'
%% without `private') is logged as a warning, since it is almost certainly a
%% mistake. `Context' (path and handler) is only for that log entry. Build the
%% cacheable part of a page statically and mount the live parts with JS instead.
-spec cache_control(weberl_response:t(), map()) -> weberl_response:t().
cache_control(Response, Context) ->
    case weberl_response:header(Response, <<"cache-control">>) of
        error ->
            weberl_response:with_header(Response, <<"cache-control">>, <<"private, no-store">>);
        {ok, Value} ->
            case shared_caching(Value) of
                true ->
                    ?LOG_WARNING(Context#{what => live_page_allows_shared_caching,
                                          cache_control => Value});
                false ->
                    ok
            end,
            Response
    end.

shared_caching(Value) ->
    Directives = [directive(D) || D <- binary:split(Value, <<",">>, [global])],
    Has = fun(Name) -> lists:member(Name, Directives) end,
    (Has(<<"public">>) orelse Has(<<"s-maxage">>) orelse Has(<<"max-age">>))
        andalso not Has(<<"private">>) andalso not Has(<<"no-store">>).

%% `Max-Age=60' -> `max-age'
directive(D) ->
    [Name | _] = binary:split(string:trim(D), <<"=">>),
    string:lowercase(string:trim(Name)).

%% @doc Is this a response that should carry the beacon: a 2xx HTML page.
-spec injectable(weberl_response:t()) -> boolean().
injectable(Response) ->
    Status = weberl_response:status(Response),
    Status >= 200 andalso Status < 300 andalso
        case weberl_response:header(Response, <<"content-type">>) of
            {ok, Type} -> is_html(Type);
            error -> false
        end.

%% @doc Inject the beacon tag for `PageId' / `Kind' (and the claims, see
%% {@link tag/3}) into the response body.
-spec inject(weberl_response:t(),
             {weberl_live:page_id(), one_way | two_way}
           | {weberl_live:page_id(), one_way | two_way, map()}) ->
    weberl_response:t().
inject(Response, {PageId, Kind}) ->
    inject(Response, {PageId, Kind, #{}});
inject(Response, {PageId, Kind, Claims}) ->
    Body = iolist_to_binary(weberl_response:body(Response)),
    weberl_response:with_body(Response, insert(Body, tag(PageId, Kind, Claims))).

%% @doc The script tags: the transport engine (`priv/engine.js', no DOM, so a
%% worker can run it too) and the beacon (`priv/client.js', which reads the data
%% attributes below); deferred scripts run in order. The page id and the token
%% are URL-safe base64, so they need no escaping in an attribute. `data-weberl-fallback' is `poll' when
%% long-poll may replace a failing stream/socket for this kind of page (see
%% {@link weberl_live:poll_enabled/1}), `none' otherwise.
-spec tag(weberl_live:page_id(), one_way | two_way) -> binary().
tag(PageId, Kind) ->
    tag(PageId, Kind, #{}).

%% @doc Like {@link tag/2} with the claims signed into the token (`session',
%% `handler', `topics'; see `weberl_live_guard'). The topics are also listed in
%% `data-weberl-topics' (a JSON array, only when there are any) so the browser
%% can route topic events to the page; the token is what the server trusts.
-spec tag(weberl_live:page_id(), one_way | two_way, map()) -> binary().
tag(PageId, Kind, Claims) ->
    Fallback = case weberl_live:poll_enabled(Kind) of true -> "poll"; false -> "none" end,
    Token = weberl_live_guard:issue(PageId, weberl_live:channels(Kind), Claims#{kind => Kind}),
    iolist_to_binary(["<script src=\"", weberl_live:engine_path(), "\" defer></script>",
                      "<script src=\"", weberl_live:client_path(),
                      "\" data-weberl-page=\"", PageId,
                      "\" data-weberl-token=\"", Token,
                      "\" data-weberl-kind=\"", atom_to_binary(Kind),
                      "\" data-weberl-fallback=\"", Fallback, "\"",
                      topics_attribute(maps:get(topics, Claims, [])),
                      csrf_attribute(),
                      " defer></script>"]).

%% The token of the page, when its forms used one (`{: form :}'): the browser puts it into the forms
%% of a region that the server re-renders without a request. It is on the page in the forms anyway.
csrf_attribute() ->
    case weberl_csrf:used_token() of
        {ok, Token} -> [" data-weberl-csrf=\"", escape(Token), "\""];
        none -> ""
    end.

topics_attribute([]) -> "";
topics_attribute(Topics) ->
    [" data-weberl-topics=\"", escape(iolist_to_binary(json:encode(Topics))), "\""].

escape(Bin) ->
    << <<(case C of
              $& -> <<"&amp;">>;
              $" -> <<"&quot;">>;
              $< -> <<"&lt;">>;
              $> -> <<"&gt;">>;
              _ -> <<C>>
          end)/binary>> || <<C>> <= Bin >>.

insert(Body, Tag) ->
    case last_body_close(Body) of
        {ok, Pos} ->
            <<Before:Pos/binary, After/binary>> = Body,
            <<Before/binary, Tag/binary, After/binary>>;
        error ->
            <<Body/binary, Tag/binary>>
    end.

last_body_close(Body) ->
    case binary:matches(ascii_lower(Body), <<"</body">>) of
        [] -> error;
        Matches -> {Pos, _} = lists:last(Matches), {ok, Pos}
    end.

ascii_lower(Bin) ->
    << <<(lower(C))>> || <<C>> <= Bin >>.

lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

is_html(Type) ->
    Lower = ascii_lower(Type),
    binary:match(Lower, <<"text/html">>) =/= nomatch orelse
        binary:match(Lower, <<"application/xhtml+xml">>) =/= nomatch.
