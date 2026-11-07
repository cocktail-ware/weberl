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

-export([assign/3, escaped/3, raw/3, url/4, escape/1, json_script/3, json_attr/3, form_open/6]).


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
url(Value, View, Line, Policy) ->
    escape(url_text(Value, View, Line, Policy)).

%% The checked text of a URL value (not yet HTML-escaped).
url_text({weberl_url, Kind, Bin} = Value, View, Line, {Policy, Position}) when is_atom(Kind), is_binary(Bin) ->
    case url_kind_allowed(Kind, Policy, Position) of
        true -> Bin;
        false -> erlang:error({template_error, {unsafe_url, View, Line, Value}})
    end;
url_text(Value, View, Line, _Policy) ->
    erlang:error({template_error, {untagged_url, View, Line, Value}}).

%% @doc `{: form Action [, Opts] :}': the opening `<form>' tag and its CSRF field (see
%% {@link weberl_form:open/3}, `Opts' is its options map). The token is the running handler's (the
%% request is ambient while it renders; the cookie and the headers are set after the handler). With
%% no request the token is left empty if the form stands in a region (`InRegion'), which the
%% browser fills (`weberl_form:csrf_input/2'), and raises `csrf_token_unavailable' otherwise.
-spec form_open(term(), term(), module(), pos_integer(), boolean(), {web | local_only, start | inner}) ->
    iodata().
form_open(ActionValue, Opts, View, Line, InRegion, Policy) ->
    Action = url_text(ActionValue, View, Line, Policy),
    is_map(Opts) andalso maps:without([method, enctype, attrs, csrf], Opts) =:= #{}
        orelse erlang:error({template_error, {bad_form_options, View, Line, Opts}}),
    Protected = maps:get(method, Opts, post) =/= get andalso maps:get(csrf, Opts, true) =/= false,
    Multipart = maps:get(enctype, Opts, undefined) =:= multipart,
    Token = case Protected of
                false ->
                    undefined;
                true ->
                    case weberl_csrf:render_token() of
                        {ok, T} ->
                            T;
                        none when InRegion andalso not Multipart ->
                            <<>>;
                        none ->
                            erlang:error({template_error, {csrf_token_unavailable, View, Line}})
                    end
            end,
    try weberl_form:open(Token, Action, Opts#{fill => true})
    catch error:badarg -> erlang:error({template_error, {bad_form_options, View, Line, Opts}})
    end.

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

%% @doc `{: json Expr :}' in a data script (`<script type="application/json">'): the value as JSON
%% (`json:encode/1': maps, lists, binaries, numbers, `true', `false', `null', other atoms as strings),
%% with `<', `>', `&' and the line separators U+2028/9 written as `\\uXXXX', so the text cannot close
%% the script, open a comment or end a line. The page reads it with `JSON.parse(el.textContent)'.
%% A value JSON cannot hold raises `{template_error, {unsupported_value, View, Source, Value}}'.
-spec json_script(term(), module(), binary()) -> binary().
json_script(Value, View, Source) ->
    iolist_to_binary(script_safe(json_text(Value, View, Source))).

script_safe(<<>>) -> [];
script_safe(<<$<, R/binary>>) -> ["\\u003c" | script_safe(R)];
script_safe(<<$>, R/binary>>) -> ["\\u003e" | script_safe(R)];
script_safe(<<$&, R/binary>>) -> ["\\u0026" | script_safe(R)];
script_safe(<<16#2028/utf8, R/binary>>) -> ["\\u2028" | script_safe(R)];
script_safe(<<16#2029/utf8, R/binary>>) -> ["\\u2029" | script_safe(R)];
script_safe(<<C, R/binary>>) -> [C | script_safe(R)].

%% @doc `{: json Expr :}' in a quoted attribute value: the JSON, HTML-escaped
%% (`data-state="{: json @state :}"', read with `JSON.parse(el.dataset.state)').
-spec json_attr(term(), module(), binary()) -> binary().
json_attr(Value, View, Source) ->
    escape(json_text(Value, View, Source)).

json_text(Value, View, Source) ->
    try iolist_to_binary(json:encode(Value))
    catch error:_ -> erlang:error({template_error, {unsupported_value, View, Source, Value}})
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
