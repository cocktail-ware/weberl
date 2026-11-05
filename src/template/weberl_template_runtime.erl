%% @doc Runtime support called from generated template modules.
%%
%% `assign/3' reads an assign (`@name' in a template): a missing one raises
%% `error({template_error, {missing_variable, View, Name}})'. `escaped/3' and
%% `raw/3' turn the value of an interpolation (`{{ Expr }}', `{{{ Expr }}}') into
%% text.
%%
%% Supported value types: UTF-8 binaries, character lists, integers, floats and
%% atoms (rendered as their name, so `true', `false' and `undefined' render as
%% such). Any other value raises
%% `error({template_error, {unsupported_value, View, Source, Value}})', `Source'
%% being the text of the expression (arbitrary terms are never rendered).
%%
%% `escaped/3' escapes `& < > " ''. `raw/3' does not and is unsafe for
%% untrusted input.
-module(weberl_template_runtime).

-export([assign/3, escaped/3, raw/3, url/4, escape/1]).

%% @doc An interpolation inside a URL attribute (`href', `src', ...): the value has to
%% be one made by `weberl_url', and its kind has to suit the attribute (HANDOFF
%% decision 8). `Policy' is `{web | local_only, start | inner}': the element's policy
%% and whether the interpolation begins the attribute value (a whole URL) or follows
%% literal text (a part of one). The result is HTML-escaped.
%%
%% Raises `{untagged_url, View, Line, Value}' for anything else and
%% `{unsafe_url, View, Line, Tagged}' for a kind the attribute does not take. The
%% template compiler finds most of these without rendering.
-spec url(term(), module(), pos_integer(), {web | local_only, start | inner}) -> binary().
url({weberl_url, Kind, Bin} = Value, View, Line, {Policy, Position}) when is_atom(Kind), is_binary(Bin) ->
    case url_kind_allowed(Kind, Policy, Position) of
        true -> escape(Bin);
        false -> erlang:error({template_error, {unsafe_url, View, Line, Value}})
    end;
url(Value, View, Line, _Policy) ->
    erlang:error({template_error, {untagged_url, View, Line, Value}}).

%% `unsafe_url' goes anywhere; a part (after literal text) is an encoded piece; a whole
%% value is a path, or on a `web' attribute also an absolute URL.
url_kind_allowed(unsafe, _, _) -> true;
url_kind_allowed(Kind, _, inner) -> Kind =:= component orelse Kind =:= query;
url_kind_allowed(Kind, web, start) -> lists:member(Kind, [path, url, router_path, router_url]);
url_kind_allowed(Kind, local_only, start) -> lists:member(Kind, [path, router_path]).

-spec assign(atom(), map(), module()) -> term().
assign(Name, Assigns, View) ->
    case maps:find(Name, Assigns) of
        {ok, Value} -> Value;
        error -> erlang:error({template_error, {missing_variable, View, Name}})
    end.

-spec escaped(term(), module(), binary()) -> binary().
escaped(Value, View, Source) -> escape(to_binary(Value, View, Source)).

-spec raw(term(), module(), binary()) -> binary().
raw(Value, View, Source) -> to_binary(Value, View, Source).

-spec escape(binary()) -> binary().
escape(Bin) ->
    case binary:match(Bin, [<<"&">>, <<"<">>, <<">">>, <<"\"">>, <<"'">>]) of
        nomatch -> Bin;
        _ -> << <<(esc(C))/binary>> || <<C>> <= Bin >>
    end.

esc($&) -> <<"&amp;">>;
esc($<) -> <<"&lt;">>;
esc($>) -> <<"&gt;">>;
esc($") -> <<"&quot;">>;
esc($') -> <<"&#39;">>;
esc(C) -> <<C>>.

to_binary(V, View, Source) when is_binary(V) ->
    case unicode:characters_to_binary(V, utf8, utf8) of
        B when is_binary(B) -> B;
        _ -> unsupported(V, View, Source)
    end;
to_binary(V, View, Source) when is_list(V) ->
    try unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> unsupported(V, View, Source)
    catch
        error:badarg -> unsupported(V, View, Source)
    end;
to_binary(V, _, _) when is_integer(V) -> integer_to_binary(V);
to_binary(V, _, _) when is_float(V) -> float_to_binary(V, [short]);
to_binary(V, _, _) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V, View, Source) -> unsupported(V, View, Source).

unsupported(V, View, Source) ->
    erlang:error({template_error, {unsupported_value, View, Source, V}}).
