%% @doc Expression front end of the template blocks (`if', `case', `for' and
%% `{{ Expr }}'): turns the Erlang text inside a tag into abstract forms and tells
%% what it uses.
%%
%% This module and the other `weberl_blocks_*' modules know nothing of HTML, regions
%% or Weberl: they call only OTP. What belongs to the consumer is passed in as
%% hooks, see {@link render/2}. The language is described in `TEMPLATE_BLOCKS.md'.
%%
%% == Assigns and locals ==
%% In the text, `@name' (lower case) is an assign: a value the consumer supplies by
%% name. Everything else is plain Erlang: capitalized names are local variables,
%% bound by the patterns and generators of the enclosing blocks. The two cannot
%% clash. `@name' is only recognised outside strings, quoted atoms, character
%% literals (`$@') and comments, and not inside an atom (`user@host' is an atom).
%%
%% == Results ==
%% Each parse returns a map with the forms and the facts the caller needs:
%% <ul>
%%   <li>`assigns': the assign names used, sorted: the dependencies of the block;</li>
%%   <li>`free': local variables used but not bound by the text itself (they have to
%%       be bound by an enclosing block: the caller checks that);</li>
%%   <li>`bound': local variables the text binds (patterns and generators).</li>
%% </ul>
%% The forms still carry the assigns as marker variables: {@link render/2} puts the
%% consumer's own code in their place and renames the locals, after which the forms
%% can go into a module or be run with `erl_eval'.
%%
%% == Errors ==
%% `{invalid_expression, Text, {Line, Message}}' (scan or parse failure, with the
%% line in the template), `{not_a_single_expression, Text}',
%% `{assign_in_pattern, Name}', `{rebound_variable, Name}' (a generator binds a
%% name an earlier qualifier already bound) and `{reserved_variable, Name}'.
-module(weberl_blocks_expr).

-export([expression/2, clause/2, qualifiers/2, render/2, tag_end/2]).
-export_type([hooks/0, parsed/0, error/0, tag_error/0]).

%% Why a tag text could not be delimited; `Lines' is the number of line breaks before
%% the offending character, counted from the start of the text.
-type tag_error() :: unterminated
                   | {unterminated_string, Lines :: non_neg_integer()}
                   | {unbalanced_brace, Lines :: non_neg_integer()}.

-type hooks() :: #{assign := fun((atom(), erl_anno:anno()) -> erl_parse:abstract_expr()),
                   local := fun((atom()) -> atom())}.
-type parsed() :: #{assigns := [atom()], free := [atom()], bound := [atom()],
                    atom() => term()}.
-type error() :: {invalid_expression, binary(), {pos_integer(), string()}}
               | {not_a_single_expression, binary()}
               | {assign_in_pattern, atom()}
               | {rebound_variable, atom()}
               | {reserved_variable, atom()}.

-define(MARKER, "_Weberl_assign_").
-define(RESERVED, "_Weberl_").
%% Characters of a variable or atom name; `@' too when looking behind (`user@host').
-define(ident(C), (C >= $a andalso C =< $z orelse C >= $A andalso C =< $Z
                   orelse C >= $0 andalso C =< $9 orelse C =:= $_)).
-define(in_name(C), (?ident(C) orelse C =:= $@)).

%% ---------------------------------------------------------------------
%% Parsing

%% @doc One expression: `#{form, assigns, free, bound => []}'.
-spec expression(binary(), pos_integer()) -> {ok, parsed()} | {error, error()}.
expression(Text, Line) ->
    maybe
        {ok, [Form]} ?= forms(Text, Line, Text, ""),
        ok ?= check_reserved(Form),
        {ok, (facts(Form, [], [Form]))#{form => Form}}
    else
        {ok, _} -> {error, {not_a_single_expression, Text}};
        {error, _} = Error -> Error
    end.

%% @doc A `case' branch head, `Pattern' or `Pattern when Guard':
%% `#{pattern, guard, assigns, free, bound}'. `guard' is the abstract guard (a list of
%% guard sequences, `[]' for none).
-spec clause(binary(), pos_integer()) -> {ok, parsed()} | {error, error()}.
clause(Text, Line) ->
    maybe
        {ok, [{'case', _, _, [{clause, A, [Pattern], Guard, _Body}]}]} ?=
            forms(Text, Line, Text, "case 0 of ", " -> ok end"),
        ok ?= check_reserved(Pattern),
        ok ?= no_assign(Pattern),
        Bound = variables(Pattern),
        %% as a fun, so that the pattern binds what the guard sees
        Fun = {'fun', A, {clauses, [{clause, A, [Pattern], Guard, [{atom, A, ok}]}]}},
        {ok, (facts(Fun, Bound, [Guard]))#{pattern => Pattern, guard => Guard}}
    else
        {ok, _} -> {error, {invalid_expression, Text, {Line, "not a case clause"}}};
        {error, _} = Error -> Error
    end.

%% @doc The qualifiers of a `for', what follows `||' in a comprehension: generators
%% (`P <- L', `<<P>> <= B', `K := V <- M') and filters, in any number:
%% `#{qualifiers, assigns, free, bound}'. A generator may not bind a name an
%% earlier qualifier bound.
-spec qualifiers(binary(), pos_integer()) -> {ok, parsed()} | {error, error()}.
qualifiers(Text, Line) ->
    maybe
        {ok, [{lc, _, _, Quals}]} ?= forms(Text, Line, Text, "[ok || ", "]"),
        ok ?= check_reserved(Quals),
        {ok, Bound} ?= bind_qualifiers(Quals, []),
        Comprehension = {lc, Line, {atom, Line, ok}, Quals},
        Facts = facts(Comprehension, [], [Quals]),
        {ok, Facts#{qualifiers => Quals, bound => Bound}}
    else
        {ok, _} -> {error, {invalid_expression, Text, {Line, "not a list of qualifiers"}}};
        {error, _} = Error -> Error
    end.

%% In order: each generator's pattern binds names for what follows.
bind_qualifiers([], Bound) ->
    {ok, lists:sort(Bound)};
bind_qualifiers([Q | Rest], Bound) ->
    case generator_pattern(Q) of
        none ->
            bind_qualifiers(Rest, Bound);
        {ok, Pattern} ->
            case no_assign(Pattern) of
                ok ->
                    New = variables(Pattern),
                    case [V || V <- New, lists:member(V, Bound)] of
                        [] -> bind_qualifiers(Rest, New ++ Bound);
                        [V | _] -> {error, {rebound_variable, V}}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

generator_pattern({generate, _, P, _}) -> {ok, P};
generator_pattern({generate_strict, _, P, _}) -> {ok, P};
generator_pattern({b_generate, _, P, _}) -> {ok, P};
generator_pattern({b_generate_strict, _, P, _}) -> {ok, P};
generator_pattern({m_generate, _, P, _}) -> {ok, P};
generator_pattern({m_generate_strict, _, P, _}) -> {ok, P};
generator_pattern(_Filter) -> none.

%% ---------------------------------------------------------------------
%% Scanning and parsing

%% `Prefix'/`Suffix' wrap the text so that the Erlang parser accepts it; they
%% hold no newline, so the lines of the template are kept.
forms(Text, Line, Original, Prefix) -> forms(Text, Line, Original, Prefix, "").

forms(Text, Line, Original, Prefix, Suffix) ->
    Source = Prefix ++ prescan(unicode:characters_to_list(Text)) ++ Suffix ++ " .",
    case erl_scan:string(Source, Line) of
        {ok, Tokens, _} ->
            case erl_parse:parse_exprs(Tokens) of
                {ok, Forms} -> {ok, Forms};
                {error, {ErrLine, Mod, Reason}} -> invalid(Original, ErrLine, Mod, Reason)
            end;
        {error, {ErrLine, Mod, Reason}, _} ->
            invalid(Original, ErrLine, Mod, Reason)
    end.

invalid(Text, Line, Mod, Reason) ->
    Message = lists:flatten(Mod:format_error(Reason)),
    {error, {invalid_expression, Text, {anno_line(Line), Message}}}.

anno_line({Line, _Col}) -> Line;
anno_line(Line) when is_integer(Line) -> Line.

%% `@name' to a marker variable, outside literals and comments.
prescan(Chars) -> prescan(Chars, $\s, []).

prescan([], _Prev, Acc) ->
    lists:reverse(Acc);
prescan([Q | Rest], _Prev, Acc) when Q =:= $"; Q =:= $' ->
    {Literal, After} = literal(Q, Rest, [Q]),
    prescan(After, Q, Literal ++ Acc);
prescan([$$, $\\, C | Rest], _Prev, Acc) ->
    prescan(Rest, C, [C, $\\, $$ | Acc]);
prescan([$$, C | Rest], _Prev, Acc) ->
    prescan(Rest, C, [C, $$ | Acc]);
prescan([$% | Rest], _Prev, Acc) ->
    {Comment, After} = lists:splitwith(fun(C) -> C =/= $\n end, Rest),
    prescan(After, $\s, lists:reverse([$% | Comment]) ++ Acc);
prescan([$@, C | Rest], Prev, Acc) when C >= $a, C =< $z, not ?in_name(Prev) ->
    {Name, After} = lists:splitwith(fun(X) -> ?ident(X) end, [C | Rest]),
    prescan(After, $x, lists:reverse(?MARKER ++ Name) ++ Acc);
prescan([C | Rest], _Prev, Acc) ->
    prescan(Rest, C, [C | Acc]).

%% The rest of a quoted string or atom, with its closing quote (kept in reverse).
literal(_Q, [], Acc) -> {Acc, []};
literal(Q, [$\\, C | Rest], Acc) -> literal(Q, Rest, [C, $\\ | Acc]);
literal(Q, [Q | Rest], Acc) -> {[Q | Acc], Rest};
literal(Q, [C | Rest], Acc) -> literal(Q, Rest, [C | Acc]).

%% ---------------------------------------------------------------------
%% Facts about parsed forms

%% `Bound' are names the text binds itself (a clause pattern); `Trees' what to
%% look at for assigns.
facts(Tree, Bound, Trees) ->
    Annotated = erl_syntax_lib:annotate_bindings(Tree, ordsets:new()),
    Free = case lists:keyfind(free, 1, erl_syntax:get_ann(Annotated)) of
               {free, F} -> F;
               false -> []
           end,
    Used = used_assigns(Trees),
    #{assigns => Used,
      free => lists:sort([V || V <- Free, local(V)]),
      bound => lists:sort(Bound)}.

used_assigns(Trees) ->
    lists:usort(collect(Trees, [])).

collect({var, _, Name}, Acc) ->
    case marker(Name) of
        {assign, N} -> [N | Acc];
        none -> Acc
    end;
collect(T, Acc) when is_tuple(T) -> collect(tuple_to_list(T), Acc);
collect([H | T], Acc) -> collect(T, collect(H, Acc));
collect(_, Acc) -> Acc.

%% Names of the local variables in a pattern.
variables(Pattern) ->
    lists:sort([V || V <- sets:to_list(erl_syntax_lib:variables(Pattern)), local(V)]).

local(Name) -> Name =/= '_' andalso marker(Name) =:= none.

marker(Name) when is_atom(Name) ->
    case atom_to_list(Name) of
        ?MARKER ++ Assign -> {assign, list_to_atom(Assign)};
        _ -> none
    end.

no_assign(Tree) ->
    case used_assigns([Tree]) of
        [] -> ok;
        [Name | _] -> {error, {assign_in_pattern, Name}}
    end.

%% A template must not use the names the engine reserves.
check_reserved(Tree) ->
    case reserved(Tree) of
        none -> ok;
        {ok, Name} -> {error, {reserved_variable, Name}}
    end.

reserved({var, _, Name}) ->
    case atom_to_list(Name) of
        ?MARKER ++ _ -> none;
        ?RESERVED ++ _ -> {ok, Name};
        _ -> none
    end;
reserved(T) when is_tuple(T) -> reserved(tuple_to_list(T));
reserved([H | T]) ->
    case reserved(H) of
        none -> reserved(T);
        Found -> Found
    end;
reserved(_) -> none.

%% ---------------------------------------------------------------------
%% Rendering

%% @doc Put the consumer's code in the forms: each `@name' becomes
%% `Assign(Name, Anno)' (a form: a map lookup, a call...) and each local `Name'
%% becomes `Local(Name)' (a prefix keeps it from clashing with the consumer's own
%% variables). Works on any form or list of forms from this module.
-spec render(term(), hooks()) -> term().
render({var, Anno, Name} = Var, #{assign := Assign, local := Local}) ->
    case marker(Name) of
        {assign, N} -> Assign(N, Anno);
        none when Name =:= '_' -> Var;
        none -> {var, Anno, Local(Name)}
    end;
render(T, Hooks) when is_tuple(T) ->
    list_to_tuple([render(E, Hooks) || E <- tuple_to_list(T)]);
render(L, Hooks) when is_list(L) ->
    [render(E, Hooks) || E <- L];
render(Other, _Hooks) ->
    Other.

%% ---------------------------------------------------------------------
%% Finding the end of a tag

%% @doc Where the tag whose text starts at `Text' ends: the byte offset of the first
%% `Close' (`}}', `}}}' or `:}') that is not part of the Erlang inside.
%%
%% The text is read as Erlang: strings, quoted atoms, character literals (`$}') and
%% comments are opaque, and a depth is kept for `(', `[', `{' and `<<', so `Close'
%% counts only at depth 0. `{{ #{k => #{j => 1}} }}' and `{{ f("}}") }}' therefore
%% end where the author means. A closing bracket that matches nothing is
%% `{unbalanced_brace, Lines}', a string that never ends `{unterminated_string,
%% Lines}'; running out of text is `unterminated'.
-spec tag_end(binary(), binary()) -> {ok, non_neg_integer()} | {error, tag_error()}.
tag_end(Text, Close) ->
    tag_end(Text, Close, byte_size(Close), 0, [], 0).

tag_end(<<>>, _Close, _Size, _Pos, _Stack, _Lines) ->
    {error, unterminated};
tag_end(Bin, Close, Size, Pos, [], _Lines) when binary_part(Bin, 0, min(Size, byte_size(Bin))) =:= Close ->
    {ok, Pos};
tag_end(<<Q, Rest/binary>>, Close, Size, Pos, Stack, Lines) when Q =:= $"; Q =:= $' ->
    case quoted(Rest, Q, 1, 0) of
        {ok, Len, Newlines, After} -> tag_end(After, Close, Size, Pos + Len, Stack, Lines + Newlines);
        error -> {error, {unterminated_string, Lines}}
    end;
tag_end(<<$$, $\\, _, Rest/binary>>, Close, Size, Pos, Stack, Lines) ->
    tag_end(Rest, Close, Size, Pos + 3, Stack, Lines);
tag_end(<<$$, C, Rest/binary>>, Close, Size, Pos, Stack, Lines) ->
    tag_end(Rest, Close, Size, Pos + 2, Stack, Lines + newline(C));
tag_end(<<$%, Rest/binary>>, Close, Size, Pos, Stack, Lines) ->
    {Len, After} = comment(Rest, 1),
    tag_end(After, Close, Size, Pos + Len, Stack, Lines);
tag_end(<<"<<", Rest/binary>>, Close, Size, Pos, Stack, Lines) ->
    tag_end(Rest, Close, Size, Pos + 2, [$> | Stack], Lines);
tag_end(<<">>", Rest/binary>>, Close, Size, Pos, [$> | Stack], Lines) ->
    tag_end(Rest, Close, Size, Pos + 2, Stack, Lines);
tag_end(<<C, Rest/binary>>, Close, Size, Pos, Stack, Lines) when C =:= $(; C =:= $[; C =:= ${ ->
    tag_end(Rest, Close, Size, Pos + 1, [closer(C) | Stack], Lines);
tag_end(<<C, Rest/binary>>, Close, Size, Pos, [C | Stack], Lines) when C =:= $); C =:= $]; C =:= $} ->
    tag_end(Rest, Close, Size, Pos + 1, Stack, Lines);
tag_end(<<"}}", _/binary>>, <<"}}}">>, _Size, _Pos, [], _Lines) ->
    %% a raw tag closed with two braces: it is missing one, not unbalanced
    {error, unterminated};
tag_end(<<C, _/binary>>, _Close, _Size, _Pos, _Stack, Lines) when C =:= $); C =:= $]; C =:= $} ->
    {error, {unbalanced_brace, Lines}};
tag_end(<<C, Rest/binary>>, Close, Size, Pos, Stack, Lines) ->
    tag_end(Rest, Close, Size, Pos + 1, Stack, Lines + newline(C)).

closer($() -> $);
closer($[) -> $];
closer(${) -> $}.

newline($\n) -> 1;
newline(_) -> 0.

%% The rest of a quoted string or atom after the opening quote `Q': its length with
%% both quotes, the line breaks inside and what follows.
quoted(<<>>, _Q, _Len, _Newlines) -> error;
quoted(<<$\\, C, Rest/binary>>, Q, Len, Newlines) -> quoted(Rest, Q, Len + 2, Newlines + newline(C));
quoted(<<Q, Rest/binary>>, Q, Len, Newlines) -> {ok, Len + 1, Newlines, Rest};
quoted(<<C, Rest/binary>>, Q, Len, Newlines) -> quoted(Rest, Q, Len + 1, Newlines + newline(C)).

%% The rest of a comment after `%', up to the line break (which stays in the text).
comment(<<$\n, _/binary>> = Rest, Len) -> {Len, Rest};
comment(<<_, Rest/binary>>, Len) -> comment(Rest, Len + 1);
comment(<<>>, Len) -> {Len, <<>>}.
