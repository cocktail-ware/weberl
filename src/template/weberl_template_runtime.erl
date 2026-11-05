%% @doc Runtime support called from generated template modules.
%%
%% Supported value types: UTF-8 binaries, character lists, integers, floats and
%% booleans. A missing variable or any other value raises
%% `error({template_error, Reason})' with Reason
%% `{missing_variable, View, Name}' or `{unsupported_value, View, Name, Value}'
%% (arbitrary terms are never rendered).
%%
%% `escaped/3' escapes `& < > " ''. `raw/3' does not and is unsafe for
%% untrusted input.
-module(weberl_template_runtime).

-export([escaped/3, raw/3, escape/1]).

-spec escaped(atom(), map(), module()) -> binary().
escaped(Name, Assigns, View) -> escape(value(Name, Assigns, View)).

-spec raw(atom(), map(), module()) -> binary().
raw(Name, Assigns, View) -> value(Name, Assigns, View).

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

value(Name, Assigns, View) ->
    case maps:find(Name, Assigns) of
        {ok, V} -> to_binary(V, Name, View);
        error -> erlang:error({template_error, {missing_variable, View, Name}})
    end.

to_binary(V, Name, View) when is_binary(V) ->
    case unicode:characters_to_binary(V, utf8, utf8) of
        B when is_binary(B) -> B;
        _ -> unsupported(V, Name, View)
    end;
to_binary(V, Name, View) when is_list(V) ->
    try unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> unsupported(V, Name, View)
    catch
        error:badarg -> unsupported(V, Name, View)
    end;
to_binary(V, _, _) when is_integer(V) -> integer_to_binary(V);
to_binary(V, _, _) when is_float(V) -> float_to_binary(V, [short]);
to_binary(true, _, _) -> <<"true">>;
to_binary(false, _, _) -> <<"false">>;
to_binary(V, Name, View) -> unsupported(V, Name, View).

unsupported(V, Name, View) ->
    erlang:error({template_error, {unsupported_value, View, Name, V}}).
