%% @doc Template parser and validator.
%%
%% `parse/2' turns lexer tokens into an AST. `validate/2' checks it, tracking
%% the HTML context of each interpolation (see `weberl_template_html'). The two
%% steps are separate so new syntax can be added to the lexer/parser without
%% touching context validation, and vice versa.
%%
%% AST nodes:
%% <ul>
%%   <li>`{text, Line, Binary}'</li>
%%   <li>`{expr, Line, escaped | raw, Parsed}': `{{ Expr }}' / `{{{ Expr }}}'. `Parsed' is
%%       what `weberl_blocks_expr:expression/2' returned (`form', `assigns', `free',
%%       `bound') plus `source', the expression text.</li>
%%   <li>`{region, Line, Name, Tag, Children}': a region (`{: region name :}').
%%       `Tag' is `default' (the `weberl-region' web component) or the binary
%%       name of another element. Regions may nest; a name is used once per
%%       template.</li>
%%   <li>`{content, Line}': `{: content :}', the place a layout puts the view's
%%       template (see `weberl_template_layout').</li>
%%   <li>`{slot, Line, Name, Default}': `{: slot name :}...{: /slot name :}' in a
%%       layout; `{fill, Line, Name, Children}': `{: fill name :}...{: /fill name :}',
%%       a top-level block of a view that replaces the layout's slot of that name.</li>
%% </ul>
-module(weberl_template_parser).

-export([parse/1, parse/2, validate/2, validate_layout/2, validate_content/2, variables/1, regions/1]).
-export_type([ast/0, ast_node/0]).

-type ast_node() :: {text, pos_integer(), binary()}
              | {expr, pos_integer(), escaped | raw, map()}
              | {region, pos_integer(), atom(), default | binary(), ast()}
              | {content, pos_integer()}
              | {slot | fill, pos_integer(), atom(), ast()}.
-type ast() :: [ast_node()].

-type error() :: {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.

-spec parse([weberl_template_lexer:token()]) -> {ok, ast()} | error().
parse(Tokens) -> parse(Tokens, "").

%% Errors (`Reason'): `{unclosed_region, Name}' (reported at the line it was
%% opened), `{unexpected_region_end, Name}', `{mismatched_region_end, Expected, Got}'
%% and `{duplicate_region, Name, FirstLine}'.
-spec parse([weberl_template_lexer:token()], file:filename_all()) -> {ok, ast()} | error().
parse(Tokens, File) ->
    try
        {ok, build(Tokens, [], [], #{})}
    catch
        throw:{parse_error, Line, Reason} -> {error, {syntax_error, File, Line, Reason}}
    end.

%% Stack of open blocks: {Kind, Name, Line, Tag, NodesSoFarReversed}, Kind being
%% region, slot or fill. `Seen' remembers every {Kind, Name} opened.
build([], [], Acc, _Seen) ->
    lists:reverse(Acc);
build([], [{Kind, Name, Line, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {event(unclosed, Kind), Name}});
build([{text, Line, Bin} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{text, Line, Bin} | Acc], Seen);
build([{interp, Line, Mode, Content} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{expr, Line, Mode, expression(Content, Line)} | Acc], Seen);
build([{content, Line} | T], Stack, Acc, Seen) ->
    case [Name || {Kind, Name, _, _, _} <- Stack, Kind =/= region] of
        [] -> build(T, Stack, [{content, Line} | Acc], Seen);
        [Name | _] -> throw({parse_error, Line, {content_in_slot, Name}})
    end;
build([{block_open, Line, Kind, Name, Opts} | T], Stack, Acc, Seen) ->
    case Seen of
        #{{Kind, Name} := First} -> throw({parse_error, Line, {duplicate(Kind), Name, First}});
        _ -> ok
    end,
    nesting(Kind, Name, Line, Stack),
    Tag = maps:get(tag, Opts, default),
    build(T, [{Kind, Name, Line, Tag, Acc} | Stack], [], Seen#{{Kind, Name} => Line});
build([{block_close, Line, Kind, Name} | _], [], _Acc, _Seen) ->
    throw({parse_error, Line, {event(unexpected, Kind), Name}});
build([{block_close, Line, Kind, Name} | _], [{Kind, Open, _, _, _} | _], _Acc, _Seen)
  when Name =/= Open ->
    throw({parse_error, Line, {event(mismatched, Kind), Open, Name}});
build([{block_close, Line, Kind, Name} | _], [{Other, Open, _, _, _} | _], _Acc, _Seen)
  when Kind =/= Other ->
    throw({parse_error, Line, {mismatched_block_end, {Other, Open}, {Kind, Name}}});
build([{block_close, _, Kind, Name} | T], [{Kind, Name, Line, Tag, Outer} | Stack], Acc, Seen) ->
    build(T, Stack, [node(Kind, Line, Name, Tag, lists:reverse(Acc)) | Outer], Seen).

node(region, Line, Name, Tag, Children) -> {region, Line, Name, Tag, Children};
node(slot, Line, Name, _Tag, Children) -> {slot, Line, Name, Children};
node(fill, Line, Name, _Tag, Children) -> {fill, Line, Name, Children}.

%% A fill is a top-level block of a view; a slot may be inside a region of the
%% layout but not inside another slot (or a fill).
nesting(fill, Name, Line, [_ | _]) ->
    throw({parse_error, Line, {fill_not_top_level, Name}});
nesting(slot, Name, Line, Stack) ->
    case [K || {K, _, _, _, _} <- Stack, K =/= region] of
        [] -> ok;
        _ -> throw({parse_error, Line, {slot_in_slot, Name}})
    end;
nesting(_, _, _, _) ->
    ok.

%% The Erlang expression of an interpolation. Until blocks exist to bind them, a
%% local variable has no value: `{unbound_variable, Name}'.
expression(Content, Line) ->
    case weberl_blocks_expr:expression(Content, Line) of
        {ok, #{free := [Name | _]}} ->
            throw({parse_error, Line, {unbound_variable, Name}});
        {ok, Parsed} ->
            Parsed#{source => string:trim(Content, both, " \t\r\n")};
        {error, {invalid_expression, Text, {ErrLine, Message}}} ->
            throw({parse_error, ErrLine, {invalid_expression, Text, Message}});
        {error, Reason} ->
            throw({parse_error, Line, Reason})
    end.

duplicate(region) -> duplicate_region;
duplicate(slot) -> duplicate_slot;
duplicate(fill) -> duplicate_fill.

event(Event, Kind) -> list_to_atom(atom_to_list(Event) ++ "_" ++ atom_to_list(Kind)
                                   ++ case Event of unclosed -> ""; _ -> "_end" end).

%% @doc Reject interpolation in unsupported HTML contexts, and regions that do
%% not begin and end in HTML text. `{: content :}' is an error here: only a
%% layout has one (see {@link validate_layout/2}).
-spec validate(ast(), file:filename_all()) ->
    ok | {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.
validate(Ast, File) ->
    check(Ast, File, view).

%% @doc Like {@link validate/2} for a layout: `{: content :}' is allowed in HTML
%% text (not inside a tag, attribute, comment, `<script>' or `<style>').
-spec validate_layout(ast(), file:filename_all()) ->
    ok | {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.
validate_layout(Ast, File) ->
    check(Ast, File, layout).

%% @doc The part of a view that goes into a layout's `{: content :}' (the view
%% without its fills) has to end in HTML text, or it would leave a tag open in the
%% layout. Reported at the line of its last node.
-spec validate_content(ast(), file:filename_all()) ->
    ok | {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.
validate_content(Ast, File) ->
    case walk(Ast, weberl_template_html:initial(), {File, view}) of
        {ok, text} -> ok;
        {ok, Ctx} -> {error, {syntax_error, File, last_line(Ast), {content_unbalanced_markup, context_name(Ctx)}}};
        {error, _} = Error -> Error
    end.

last_line([]) -> 1;
last_line(Ast) -> element(2, lists:last(Ast)).

check(Ast, File, Mode) ->
    case walk(Ast, weberl_template_html:initial(), {File, Mode}) of
        {ok, _Ctx} -> ok;
        {error, _} = Error -> Error
    end.

walk([], Ctx, _Env) ->
    {ok, Ctx};
walk([{text, _, Bin} | Rest], Ctx, Env) ->
    walk(Rest, weberl_template_html:advance(Bin, Ctx), Env);
walk([{expr, Line, Mode, _Parsed} | Rest], Ctx, {File, _} = Env) ->
    case weberl_template_html:check(Ctx, Mode) of
        ok -> walk(Rest, Ctx, Env);
        {error, Reason} -> {error, {syntax_error, File, Line, Reason}}
    end;
walk([{content, Line} | _], _Ctx, {File, view}) ->
    {error, {syntax_error, File, Line, content_outside_layout}};
walk([{content, Line} | Rest], Ctx, {File, layout} = Env) ->
    case Ctx of
        text -> walk(Rest, Ctx, Env);
        _ -> {error, {syntax_error, File, Line, {content_in_unsupported_context, context_name(Ctx)}}}
    end;
walk([{slot, Line, Name, _} | _], _Ctx, {File, view}) ->
    {error, {syntax_error, File, Line, {slot_outside_layout, Name}}};
walk([{fill, Line, Name, _} | _], _Ctx, {File, layout}) ->
    {error, {syntax_error, File, Line, {fill_in_layout, Name}}};
walk([{Kind, Line, Name, Children} | Rest], Ctx, {File, _} = Env) when Kind =:= slot; Kind =:= fill ->
    %% like a region: begins in text and has to end in text
    case Ctx of
        text ->
            case walk(Children, weberl_template_html:initial(), Env) of
                {ok, text} -> walk(Rest, Ctx, Env);
                {ok, _Other} ->
                    {error, {syntax_error, File, Line, {unbalanced_markup, Kind, Name}}};
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, {syntax_error, File, Line, {in_unsupported_context, Kind, Name, context_name(Ctx)}}}
    end;
walk([{region, Line, Name, _Tag, Children} | Rest], Ctx, {File, _} = Env) ->
    case Ctx of
        text ->
            %% the wrapper element is written where the region starts, so the
            %% region begins in text and has to end in text
            case walk(Children, weberl_template_html:initial(), Env) of
                {ok, text} ->
                    walk(Rest, Ctx, Env);
                {ok, _Other} ->
                    {error, {syntax_error, File, Line, {region_unbalanced_markup, Name}}};
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, {syntax_error, File, Line, {region_in_unsupported_context, Name, context_name(Ctx)}}}
    end.

context_name(Ctx) when is_atom(Ctx) -> Ctx;
context_name({raw_text, Tag}) -> Tag;
context_name({value, _, _, _}) -> attribute_value;
context_name(Ctx) when is_tuple(Ctx) -> tag.

%% @doc The assigns (`@name') the template uses (also inside regions), sorted and
%% without duplicates.
-spec variables(ast()) -> [atom()].
variables(Ast) ->
    lists:usort(vars(Ast)).

vars(Ast) ->
    lists:flatmap(fun({expr, _, _, #{assigns := Assigns}}) -> Assigns;
                     ({region, _, _, _, Children}) -> vars(Children);
                     ({Slot, _, _, Children}) when Slot =:= slot; Slot =:= fill -> vars(Children);
                     (_) -> []
                  end, Ast).

%% @doc The regions of the template: `Name => #{tag, line, variables}', the
%% variables being those of the region's content (nested regions included).
-spec regions(ast()) -> #{atom() => #{tag := default | binary(), line := pos_integer(),
                                      variables := [atom()]}}.
regions(Ast) ->
    lists:foldl(
      fun({region, Line, Name, Tag, Children}, Acc) ->
              maps:merge(Acc#{Name => #{tag => Tag, line => Line, variables => variables(Children)}},
                         regions(Children));
         ({Slot, _, _, Children}, Acc) when Slot =:= slot; Slot =:= fill ->
              maps:merge(Acc, regions(Children));
         (_, Acc) -> Acc
      end, #{}, Ast).
