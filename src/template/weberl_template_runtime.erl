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

-export([assign/3, escaped/3, raw/3, escape/1]).

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
