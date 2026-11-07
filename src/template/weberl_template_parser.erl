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
%%   <li>`{'if', Line, [{Cond, Children}], Else}' for `{: if :}...{: elif :}...{: else :}
%%       ...{: /if :}' (`Else' is `none' or the children of the `else' branch);
%%       `{'case', Line, Expr, [{Clause, Children}]}' for `{: case :}{: of :}...{: /case :}';
%%       `{'for', Line, Qualifiers, Body, Empty}' for `{: for :}...{: empty :}...{: /for :}'
%%       (`Empty' is `none' or the children of the `empty' branch). `Cond', `Expr',
%%       `Clause' and `Qualifiers' are what `weberl_blocks_expr' returned, plus `source'
%%       and `line'.</li>
%%   <li>`{component, Line, Name, Params, Children}': `{: component name, #{...} :}...{: /component :}',
%%       a use of a component (see `weberl_template_component'); `Name' is a binary (`<<"forms/field">>'),
%%       `Params' is `[{Key, Parsed}]' (the values of the map literal), `Children' the body and the
%%       `fill' blocks. `{param, Line, Name, Default}': `{: param name[, Default] :}' in a component
%%       file (`Default' is `none' or what `weberl_blocks_expr:expression/2' returned).
%%       `{scope, Line, Binds, Children}' is what the expansion of a component call leaves: the values
%%       bound to the (renamed) parameters, `Binds' being `[{Var, Parsed}]', around the component's content.</li>
%%   <li>`{slot, Line, Name, Default}': `{: slot name :}...{: /slot name :}' in a
%%       layout; `{fill, Line, Name, Children}': `{: fill name :}...{: /fill name :}',
%%       a top-level block of a view that replaces the layout's slot of that name.</li>
%% </ul>
-module(weberl_template_parser).

-export([parse/1, parse/2, validate/2, validate_layout/2, validate_component/2, validate_content/2, variables/1, regions/1,
         children/1, map_children/2, check_scope/2]).

-define(IS_STMT(K), (K =:= 'if' orelse K =:= 'case' orelse K =:= 'for')).
-export_type([ast/0, ast_node/0]).

-type ast_node() :: {text, pos_integer(), binary()}
              | {expr, pos_integer(), escaped | raw | json | json_script | json_attr, map()}
              | {'if', pos_integer(), [{map(), ast()}], none | ast()}
              | {'case', pos_integer(), map(), [{map(), ast()}]}
              | {'for', pos_integer(), map(), ast(), none | ast()}
              | {region, pos_integer(), atom(), default | binary(), ast()}
              | {form, pos_integer(), map(), ast()}
              | {content, pos_integer()}
              | {component, pos_integer(), binary(), [{atom(), map()}], ast()}
              | {param, pos_integer(), atom(), none | map()}
              | {scope, pos_integer(), [{atom(), map()}], ast()}
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
        Ast = build(Tokens, [], [], #{}),
        ok = scope(Ast, [], #{}),
        {ok, Ast}
    catch
        throw:{parse_error, Line, Reason} -> {error, {syntax_error, File, Line, Reason}}
    end.

%% Stack of open blocks: {Kind, Name, Line, Tag, NodesSoFarReversed}, Kind being
%% region, slot or fill. `Seen' remembers every {Kind, Name} opened. A statement
%% block (`if', `case', `for') is a frame {Kind, State, Line, none, Outer} whose
%% State says which branch is being read (see `open_stmt/5').
build([], [], Acc, _Seen) ->
    lists:reverse(Acc);
build([], [{form, _Head, Line, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {unclosed_block, form}});
build([], [{component, _Head, Line, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {unclosed_block, component}});
build([], [{Kind, _State, Line, _, _} | _], _Acc, _Seen) when ?IS_STMT(Kind) ->
    throw({parse_error, Line, {unclosed_block, Kind}});
build([], [{Kind, Name, Line, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {event(unclosed, Kind), Name}});
build([{text, Line, Bin} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{text, Line, Bin} | Acc], Seen);
build([{interp, Line, Mode, Content} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{expr, Line, Mode, expression(Content, Line)} | Acc], Seen);
build([{content, Line} | T], Stack, Acc, Seen) ->
    %% the marker stands in `if' and `case' branches, not in a slot, a fill or a `for'
    case [{Kind, Name} || {Kind, Name, _, _, _} <- Stack, Kind =:= slot orelse Kind =:= fill orelse Kind =:= 'for'] of
        [] -> build(T, Stack, [{content, Line} | Acc], Seen);
        [{'for', _} | _] -> throw({parse_error, Line, content_in_for});
        [{_, Name} | _] -> throw({parse_error, Line, {content_in_slot, Name}})
    end;
%% `{: form Action [, Opts] :}' ... `{: /form :}': the head is two expressions (`action', `opts' or
%% `none') and whether a region is open around it (`in_region': the page may be re-rendered for other
%% browsers, see weberl_template_runtime:form_open/6). Forms do not nest.
build([{form_open, Line, ActionText, OptsText, TextLine} | T], Stack, Acc, Seen) ->
    case [ok || {form, _, _, _, _} <- Stack] of
        [] -> ok;
        _ -> throw({parse_error, Line, form_in_form})
    end,
    Head = #{action => expression(ActionText, TextLine),
             opts => case OptsText of none -> none; _ -> expression(OptsText, TextLine) end,
             in_region => lists:any(fun({K, _, _, _, _}) -> K =:= region end, Stack)},
    build(T, [{form, Head, Line, none, Acc} | Stack], [], Seen);
build([{form_close, Line} | _], [], _Acc, _Seen) ->
    throw({parse_error, Line, {unexpected_block_end, form}});
build([{form_close, _} | T], [{form, Head, Line, _, Outer} | Stack], Acc, Seen) ->
    build(T, Stack, [{form, Line, Head, lists:reverse(Acc)} | Outer], Seen);
build([{form_close, Line} | _], [{Open, Name, _, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {mismatched_block_end, {Open, case ?IS_STMT(Open) orelse Open =:= component of
                                                                 true -> none; false -> Name end},
                               {form, none}}});
%% `{: component Name [, #{Params}] :}' ... `{: /component :}': the call of a component. The head is the
%% name and the parameters, which have to be a literal map with atom keys. Calls may nest.
build([{component_open, Line, Name, ParamsText, TextLine} | T], Stack, Acc, Seen) ->
    Head = #{name => Name, params => component_params(ParamsText, TextLine)},
    build(T, [{component, Head, Line, none, Acc} | Stack], [], Seen);
build([{component_close, Line} | _], [], _Acc, _Seen) ->
    throw({parse_error, Line, {unexpected_block_end, component}});
build([{component_close, _} | T], [{component, #{name := Name, params := Params}, Line, _, Outer} | Stack],
      Acc, Seen) ->
    build(T, Stack, [{component, Line, Name, Params, lists:reverse(Acc)} | Outer], Seen);
build([{component_close, Line} | _], [{Open, Name, _, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {mismatched_block_end,
                               {Open, case ?IS_STMT(Open) orelse Open =:= form of true -> none; false -> Name end},
                               {component, none}}});
%% `{: param Name [, Default] :}': a parameter of the component file (checked where the file is read)
build([{param, Line, Name, DefaultText, TextLine} | T], Stack, Acc, Seen) ->
    Default = case DefaultText of
                  none -> none;
                  _ -> expression(DefaultText, TextLine)
              end,
    build(T, Stack, [{param, Line, Name, Default} | Acc], Seen);
%% statements: `{: if :}', `{: case :}', `{: for :}' open a block ...
build([{stmt, Line, Kind, Text, TextLine} | T], Stack, Acc, Seen)
  when Kind =:= 'if'; Kind =:= 'case'; Kind =:= 'for' ->
    build(T, [open_stmt(Kind, Text, TextLine, Line, Acc) | Stack], [], Seen);
%% ... `elif', `else', `of', `empty' start the next branch of the block on top ...
build([{stmt, Line, Kind, Text, TextLine} | T], Stack, Acc, Seen)
  when Kind =:= elif; Kind =:= 'else'; Kind =:= 'of'; Kind =:= empty ->
    case Stack of
        [{Open, State, OLine, Tag, Outer} | Rest] when ?IS_STMT(Open) ->
            State2 = next_branch(Kind, Open, State, Text, TextLine, Line, Acc),
            build(T, [{Open, State2, OLine, Tag, Outer} | Rest], [], Seen);
        _ ->
            throw({parse_error, Line, {misplaced_block_tag, Kind}})
    end;
%% ... and the end tag closes it.
build([{stmt_end, Line, Kind} | _], [], _Acc, _Seen) ->
    throw({parse_error, Line, {unexpected_block_end, Kind}});
build([{stmt_end, _Line, Kind} | T], [{Kind, State, OLine, _, Outer} | Stack], Acc, Seen) ->
    build(T, Stack, [finish_stmt(Kind, State, OLine, Acc) | Outer], Seen);
build([{stmt_end, Line, Kind} | _], [{Open, Name, _, _, _} | _], _Acc, _Seen) ->
    case ?IS_STMT(Open) orelse Open =:= form orelse Open =:= component of
        true -> throw({parse_error, Line, {mismatched_block_end, {Open, none}, {Kind, none}}});
        false -> throw({parse_error, Line, {mismatched_block_end, {Open, Name}, {Kind, none}}})
    end;
build([{block_close, Line, Kind, Name} | _], [{form, _, _, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {mismatched_block_end, {form, none}, {Kind, Name}}});
build([{block_close, Line, Kind, Name} | _], [{component, _, _, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {mismatched_block_end, {component, none}, {Kind, Name}}});
build([{block_close, Line, Kind, Name} | _], [{Open, _State, _, _, _} | _], _Acc, _Seen)
  when ?IS_STMT(Open) ->
    throw({parse_error, Line, {mismatched_block_end, {Open, none}, {Kind, Name}}});
build([{block_open, Line, Kind, Name, Opts} | T], Stack, Acc, Seen) ->
    Key = seen_key(Kind, Name, Stack),
    case Seen of
        #{Key := First} -> throw({parse_error, Line, {duplicate(Kind), Name, First}});
        _ -> ok
    end,
    nesting(Kind, Name, Line, Stack),
    Tag = maps:get(tag, Opts, default),
    build(T, [{Kind, Name, Line, Tag, Acc} | Stack], [], Seen#{Key => Line});
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

%% A fill is named within the component call it stands in (or the view, for a layout's fills).
seen_key(fill, Name, [{component, _, Line, _, _} | _]) -> {fill, Name, Line};
seen_key(Kind, Name, _Stack) -> {Kind, Name}.

%% The parameters of a component call: the values of a map literal with atom keys, each with what
%% it uses. Anything else cannot be checked when the router starts.
component_params(none, _Line) ->
    [];
component_params(Text, Line) ->
    #{form := Form} = expression(Text, Line),
    case Form of
        {map, _, Assocs} ->
            Params = [param_entry(A, Text, Line) || A <- Assocs],
            Keys = [K || {K, _} <- Params],
            case Keys -- lists:usort(Keys) of
                [Dup | _] -> throw({parse_error, Line, {duplicate_component_param, Dup}});
                [] -> Params
            end;
        _ ->
            throw({parse_error, Line, component_params_not_a_map_literal})
    end.

param_entry({map_field_assoc, _, {atom, _, Key}, Value}, Text, Line) ->
    {Key, (weberl_blocks_expr:form_facts(Value))#{source => string:trim(Text, both, " \t\r\n"), line => Line}};
param_entry(_, _Text, Line) ->
    throw({parse_error, Line, component_params_not_a_map_literal}).

node(region, Line, Name, Tag, Children) -> {region, Line, Name, Tag, Children};
node(slot, Line, Name, _Tag, Children) -> {slot, Line, Name, Children};
node(fill, Line, Name, _Tag, Children) -> {fill, Line, Name, Children}.

%% A fill is a top-level block of a view; a slot may be inside a region of the
%% layout but not inside another slot (or a fill).
nesting(fill, _Name, _Line, [{component, _, _, _, _} | _]) ->
    ok;
nesting(fill, Name, Line, [_ | _]) ->
    throw({parse_error, Line, {fill_not_top_level, Name}});
nesting(slot, Name, Line, Stack) ->
    case [K || {K, _, _, _, _} <- Stack, K =:= slot orelse K =:= fill] of
        [] -> ok;
        _ -> throw({parse_error, Line, {slot_in_slot, Name}})
    end,
    %% a slot in a loop would be repeated with the loop
    case [ok || {'for', _, _, _, _} <- Stack] of
        [] -> ok;
        _ -> throw({parse_error, Line, {slot_in_for, Name}})
    end;
nesting(region, Name, Line, Stack) ->
    %% a region in the body of a `for' would be repeated, and a region name is
    %% used once (the `empty' branch is rendered at most once: fine)
    case [ok || {'for', {_, body, _}, _, _, _} <- Stack] of
        [] -> ok;
        _ -> throw({parse_error, Line, {region_in_for, Name}})
    end;
nesting(_, _, _, _) ->
    ok.

%% ---------------------------------------------------------------------
%% Statement blocks: `if', `case', `for'
%%
%% State of an open block:
%%   `if':   {Done, {test, Parsed} | else}, Done = finished [{Parsed, Children}] (reversed)
%%   `case': {Expr, Done, none | {clause, Parsed}}, Done as above; `none' until the first `of'
%%   `for':  {Qualifiers, body | empty, Body | undefined}

open_stmt('if', Text, TextLine, Line, Outer) ->
    {'if', {[], {test, expression(Text, TextLine)}}, Line, none, Outer};
open_stmt('case', Text, TextLine, Line, Outer) ->
    {'case', {expression(Text, TextLine), [], none}, Line, none, Outer};
open_stmt('for', Text, TextLine, Line, Outer) ->
    {'for', {parsed(weberl_blocks_expr:qualifiers(Text, TextLine), Text, TextLine), body, undefined},
     Line, none, Outer}.

%% `Acc' holds the nodes of the branch that ends here (reversed).
next_branch(elif, 'if', {Done, {test, Cond}}, Text, TextLine, _Line, Acc) ->
    {[{Cond, lists:reverse(Acc)} | Done], {test, expression(Text, TextLine)}};
next_branch('else', 'if', {Done, {test, Cond}}, none, _TextLine, _Line, Acc) ->
    {[{Cond, lists:reverse(Acc)} | Done], 'else'};
next_branch('of', 'case', {Expr, Done, none}, Text, TextLine, _Line, Acc) ->
    %% between `case' and the first `of' only white space is allowed
    case [N || N <- lists:reverse(Acc), not blank(N)] of
        [] -> {Expr, Done, {clause, clause(Text, TextLine)}};
        [Node | _] -> throw({parse_error, element(2, Node), content_before_first_of})
    end;
next_branch('of', 'case', {Expr, Done, {clause, Clause}}, Text, TextLine, _Line, Acc) ->
    {Expr, [{Clause, lists:reverse(Acc)} | Done], {clause, clause(Text, TextLine)}};
next_branch(empty, 'for', {Quals, body, undefined}, none, _TextLine, _Line, Acc) ->
    {Quals, empty, lists:reverse(Acc)};
next_branch(Kind, _Open, _State, _Text, _TextLine, Line, _Acc) ->
    throw({parse_error, Line, {misplaced_block_tag, Kind}}).

blank({text, _, Bin}) -> string:trim(Bin, both, " \t\r\n") =:= <<>>;
blank(_) -> false.

finish_stmt('if', {Done, {test, Cond}}, Line, Acc) ->
    {'if', Line, lists:reverse([{Cond, lists:reverse(Acc)} | Done]), none};
finish_stmt('if', {Done, 'else'}, Line, Acc) ->
    {'if', Line, lists:reverse(Done), lists:reverse(Acc)};
finish_stmt('case', {_Expr, _Done, none}, Line, _Acc) ->
    throw({parse_error, Line, case_without_of});
finish_stmt('case', {Expr, Done, {clause, Clause}}, Line, Acc) ->
    {'case', Line, Expr, lists:reverse([{Clause, lists:reverse(Acc)} | Done])};
finish_stmt('for', {Quals, body, undefined}, Line, Acc) ->
    {'for', Line, Quals, lists:reverse(Acc), none};
finish_stmt('for', {Quals, empty, Body}, Line, Acc) ->
    {'for', Line, Quals, Body, lists:reverse(Acc)}.

%% The Erlang expression of an interpolation or of an `if'/`case' head. Whether
%% the locals it uses are bound is checked afterwards (see `scope/3').
expression(Text, Line) ->
    parsed(weberl_blocks_expr:expression(Text, Line), Text, Line).

clause(Text, Line) ->
    parsed(weberl_blocks_expr:clause(Text, Line), Text, Line).

parsed({ok, Parsed}, Text, Line) ->
    Parsed#{source => string:trim(Text, both, " \t\r\n"), line => Line};
parsed({error, {invalid_expression, Original, {ErrLine, Message}}}, _Text, _Line) ->
    throw({parse_error, ErrLine, {invalid_expression, Original, Message}});
parsed({error, Reason}, _Text, Line) ->
    throw({parse_error, Line, Reason}).

%% ---------------------------------------------------------------------
%% Scope: which local variables a piece of the template may use. A pattern or a
%% generator binds names for its branch or body only; an already bound name may
%% not be bound again. A region renders alone, from the assigns, so it cannot use a
%% local bound outside it.

scope([], _Env, _Ctx) ->
    ok;
scope([Node | Rest], Env, Ctx) ->
    scope_node(Node, Env, Ctx),
    scope(Rest, Env, Ctx).

scope_node({expr, Line, _, Parsed}, Env, Ctx) ->
    check_free(Parsed, Line, Env, Ctx);
scope_node({region, Line, Name, _, Children}, Env, Ctx) ->
    Outer = Env ++ maps:get(outer, Ctx, []),
    scope(Children, [], Ctx#{region => {Name, Line}, outer => Outer});
scope_node({Kind, _, _, Children}, Env, Ctx) when Kind =:= slot; Kind =:= fill ->
    scope(Children, Env, Ctx);
scope_node({component, Line, _Name, Params, Children}, Env, Ctx) ->
    lists:foreach(fun({_, Value}) -> check_free(Value, Line, Env, Ctx) end, Params),
    scope(Children, Env, Ctx);
scope_node({scope, Line, Binds, Children}, Env, Ctx) ->
    lists:foreach(fun({_, Value}) -> check_free(Value, Line, Env, Ctx) end, Binds),
    scope(Children, [Var || {Var, _} <- Binds] ++ Env, Ctx);
scope_node({form, Line, #{action := Action, opts := Opts}, Children}, Env, Ctx) ->
    check_free(Action, Line, Env, Ctx),
    Opts =:= none orelse check_free(Opts, Line, Env, Ctx),
    scope(Children, Env, Ctx);
scope_node({'if', _, Branches, Else}, Env, Ctx) ->
    lists:foreach(fun({Cond, Children}) ->
                          check_free(Cond, maps:get(line, Cond), Env, Ctx),
                          scope(Children, Env, Ctx)
                  end, Branches),
    scope(case Else of none -> []; _ -> Else end, Env, Ctx);
scope_node({'case', _, Expr, Clauses}, Env, Ctx) ->
    check_free(Expr, maps:get(line, Expr), Env, Ctx),
    lists:foreach(fun({Clause, Children}) ->
                          Line = maps:get(line, Clause),
                          Bound = maps:get(bound, Clause),
                          ok = no_rebinding(Bound, Env, Line),
                          check_free(Clause, Line, Env, Ctx),
                          scope(Children, Bound ++ Env, Ctx)
                  end, Clauses);
scope_node({'for', _, Quals, Body, Empty}, Env, Ctx) ->
    Line = maps:get(line, Quals),
    Bound = maps:get(bound, Quals),
    ok = no_rebinding(Bound, Env, Line),
    check_free(Quals, Line, Env, Ctx),
    scope(Body, Bound ++ Env, Ctx),
    scope(case Empty of none -> []; _ -> Empty end, Env, Ctx);
scope_node(_, _Env, _Ctx) ->
    ok.

check_free(#{free := Free}, Line, Env, Ctx) ->
    case [N || N <- Free, not lists:member(N, Env)] of
        [] ->
            ok;
        [Name | _] ->
            case Ctx of
                #{region := {Region, _}, outer := Outer} ->
                    case lists:member(Name, Outer) of
                        true -> throw({parse_error, Line, {region_uses_outer_variable, Region, Name}});
                        false -> throw({parse_error, Line, {unbound_variable, Name}})
                    end;
                _ ->
                    throw({parse_error, Line, {unbound_variable, Name}})
            end
    end.

no_rebinding(Bound, Env, Line) ->
    case [N || N <- Bound, lists:member(N, Env)] of
        [] -> ok;
        [Name | _] -> throw({parse_error, Line, {rebound_variable, Name}})
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

%% @doc Like {@link validate/2} for a component file: `{: content :}' and slots as in a layout, no
%% regions (the file is inlined where it is used, so a region name could be used twice) and no
%% fill outside a component call.
-spec validate_component(ast(), file:filename_all()) ->
    ok | {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.
validate_component(Ast, File) ->
    check(Ast, File, component).

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
walk([{param, Line, Name, _} | _], _Ctx, {File, Mode}) when Mode =/= component ->
    {error, {syntax_error, File, Line, {param_outside_component, Name}}};
walk([{param, _, _, _} | Rest], Ctx, Env) ->
    walk(Rest, Ctx, Env);
walk([{region, Line, Name, _, _} | _], _Ctx, {File, component}) ->
    {error, {syntax_error, File, Line, {region_in_component, Name}}};
walk([{content, Line} | Rest], Ctx, {File, _} = Env) ->
    case Ctx of
        text -> walk(Rest, Ctx, Env);
        _ -> {error, {syntax_error, File, Line, {content_in_unsupported_context, context_name(Ctx)}}}
    end;
walk([{slot, Line, Name, _} | _], _Ctx, {File, view}) ->
    {error, {syntax_error, File, Line, {slot_outside_layout, Name}}};
walk([{fill, Line, Name, _} | _], _Ctx, {File, layout}) ->
    {error, {syntax_error, File, Line, {fill_in_layout, Name}}};
walk([{fill, Line, Name, _} | _], _Ctx, {File, component}) ->
    {error, {syntax_error, File, Line, {fill_in_component, Name}}};
walk([{Kind, Line, Name, Children} | Rest], Ctx, Env) when Kind =:= slot; Kind =:= fill ->
    case slot_or_fill(Kind, Line, Name, Children, Ctx, Env) of
        ok -> walk(Rest, Ctx, Env);
        {error, _} = Error -> Error
    end;
%% `{: component :}': like a form, the call begins in text; the fills are checked like those of a view
%% and everything else (the body) has to end in text, since it goes where the component's
%% `{: content :}' is.
walk([{component, Line, _Name, _Params, Children} | Rest], Ctx, {File, _} = Env) ->
    case Ctx of
        text ->
            {Fills, Body} = lists:partition(fun(N) -> element(1, N) =:= fill end, Children),
            Checked = [slot_or_fill(fill, FLine, FName, FChildren, Ctx, Env)
                       || {fill, FLine, FName, FChildren} <- Fills],
            case [E || {error, _} = E <- Checked] of
                [Error | _] ->
                    Error;
                [] ->
                    case walk(Body, Ctx, Env) of
                        {ok, text} -> walk(Rest, Ctx, Env);
                        {ok, _Other} -> {error, {syntax_error, File, Line, component_unbalanced_markup}};
                        {error, _} = Error -> Error
                    end
            end;
        _ ->
            {error, {syntax_error, File, Line, {component_in_unsupported_context, context_name(Ctx)}}}
    end;
walk([{form, Line, _Head, Children} | Rest], Ctx, {File, _} = Env) ->
    %% the tags are written here, so the form begins in text and its content has to end in text
    case Ctx of
        text ->
            case walk(Children, Ctx, Env) of
                {ok, text} -> walk(Rest, Ctx, Env);
                {ok, _Other} -> {error, {syntax_error, File, Line, form_unbalanced_markup}};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, {syntax_error, File, Line, {form_in_unsupported_context, context_name(Ctx)}}}
    end;
walk([{Kind, Line, _, _} = Node | Rest], Ctx, Env) when ?IS_STMT(Kind) ->
    block(Node, Kind, Line, Rest, Ctx, Env);
walk([{'for', Line, _, _, _} = Node | Rest], Ctx, Env) ->
    block(Node, 'for', Line, Rest, Ctx, Env);
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

%% A slot or a fill is like a region: it begins in text and has to end in text.
slot_or_fill(Kind, Line, Name, Children, Ctx, {File, _} = Env) ->
    case Ctx of
        text ->
            case walk(Children, weberl_template_html:initial(), Env) of
                {ok, text} -> ok;
                {ok, _Other} -> {error, {syntax_error, File, Line, {unbalanced_markup, Kind, Name}}};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, {syntax_error, File, Line, {in_unsupported_context, Kind, Name, context_name(Ctx)}}}
    end.

%% `if', `case' and `for' stand in HTML text, between the attributes of a start tag and inside the
%% quoted value of an attribute that takes plain text (`weberl_template_html:block_context/1'); every
%% branch and every body is read from the context the block stands in and has to end where it began
%% (`branch_end_ok/2'), so no tag or quote stays open across a branch (the elements themselves are not
%% matched, as in a region).
block(Node, Kind, Line, Rest, Ctx, {File, _} = Env) ->
    case weberl_template_html:block_context(Ctx) of
        unsupported ->
            {error, {syntax_error, File, Line, {block_in_unsupported_context, Kind, context_name(Ctx)}}};
        {error, Reason} ->
            {error, {syntax_error, File, Line, Reason}};
        _ ->
            case branches(children(Node), Env, Ctx) of
                ok -> walk(Rest, Ctx, Env);
                {error, unbalanced} -> {error, {syntax_error, File, Line, {block_unbalanced_markup, Kind}}};
                {error, _} = Error -> Error
            end
    end.

branches([], _Env, _Start) ->
    ok;
branches([Children | Rest], Env, Start) ->
    case walk(Children, Start, Env) of
        {ok, End} ->
            case weberl_template_html:branch_end_ok(Start, End) of
                true -> branches(Rest, Env, Start);
                false -> {error, unbalanced}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc The child ASTs of a node: the contents of a region, slot or fill, and every
%% branch or body of an `if', `case' or `for'. `[]' for a node without children.
-spec children(ast_node()) -> [ast()].
children({region, _, _, _, Children}) -> [Children];
children({Kind, _, _, Children}) when Kind =:= slot; Kind =:= fill -> [Children];
children({form, _, _, Children}) -> [Children];
children({component, _, _, _, Children}) -> [Children];
children({scope, _, _, Children}) -> [Children];
children({'if', _, Branches, Else}) ->
    [Children || {_, Children} <- Branches] ++ [Else || Else =/= none];
children({'case', _, _, Clauses}) -> [Children || {_, Children} <- Clauses];
children({'for', _, _, Body, Empty}) -> [Body] ++ [Empty || Empty =/= none];
children(_) -> [].

%% @doc The node with `Fun' applied to each of its child ASTs (see {@link children/1}).
-spec map_children(fun((ast()) -> ast()), ast_node()) -> ast_node().
map_children(Fun, {region, Line, Name, Tag, Children}) -> {region, Line, Name, Tag, Fun(Children)};
map_children(Fun, {Kind, Line, Name, Children}) when Kind =:= slot; Kind =:= fill ->
    {Kind, Line, Name, Fun(Children)};
map_children(Fun, {form, Line, Head, Children}) -> {form, Line, Head, Fun(Children)};
map_children(Fun, {component, Line, Name, Params, Children}) -> {component, Line, Name, Params, Fun(Children)};
map_children(Fun, {scope, Line, Binds, Children}) -> {scope, Line, Binds, Fun(Children)};
map_children(Fun, {'if', Line, Branches, Else}) ->
    {'if', Line, [{Cond, Fun(Children)} || {Cond, Children} <- Branches],
     case Else of none -> none; _ -> Fun(Else) end};
map_children(Fun, {'case', Line, Expr, Clauses}) ->
    {'case', Line, Expr, [{Clause, Fun(Children)} || {Clause, Children} <- Clauses]};
map_children(Fun, {'for', Line, Quals, Body, Empty}) ->
    {'for', Line, Quals, Fun(Body), case Empty of none -> none; _ -> Fun(Empty) end};
map_children(_Fun, Node) -> Node.

%% @doc Check which locals the AST may use (what `parse/2' does for one file) again,
%% for an AST put together from several, such as a view inside a layout.
-spec check_scope(ast(), file:filename_all()) -> ok | error().
check_scope(Ast, File) ->
    try scope(Ast, [], #{})
    catch
        throw:{parse_error, Line, Reason} -> {error, {syntax_error, File, Line, Reason}}
    end.

context_name(Ctx) when is_atom(Ctx) -> Ctx;
context_name({raw_text, Tag}) -> weberl_template_html:base_tag(Tag);
context_name({value, _, _, _}) -> attribute_value;
context_name(Ctx) when is_tuple(Ctx) -> tag.

%% @doc The assigns (`@name') the template uses (also inside regions), sorted and
%% without duplicates.
-spec variables(ast()) -> [atom()].
variables(Ast) ->
    lists:usort(vars(Ast)).

vars(Ast) ->
    lists:flatmap(fun(Node) -> own_assigns(Node) ++ lists:flatmap(fun vars/1, children(Node)) end, Ast).

%% What a node itself reads: an interpolation's expression, the heads of the blocks.
own_assigns({expr, _, _, #{assigns := Assigns}}) -> Assigns;
own_assigns({form, _, #{action := #{assigns := A}, opts := Opts}, _}) ->
    A ++ case Opts of none -> []; #{assigns := OA} -> OA end;
own_assigns({component, _, _, Params, _}) -> lists:flatmap(fun({_, #{assigns := A}}) -> A end, Params);
own_assigns({scope, _, Binds, _}) -> lists:flatmap(fun({_, #{assigns := A}}) -> A end, Binds);
own_assigns({'if', _, Branches, _}) -> lists:flatmap(fun({#{assigns := A}, _}) -> A end, Branches);
own_assigns({'case', _, #{assigns := A}, Clauses}) ->
    A ++ lists:flatmap(fun({#{assigns := CA}, _}) -> CA end, Clauses);
own_assigns({'for', _, #{assigns := A}, _, _}) -> A;
own_assigns(_) -> [].

%% @doc The regions of the template: `Name => #{tag, line, variables}', the
%% variables being those of the region's content (nested regions included).
-spec regions(ast()) -> #{atom() => #{tag := default | binary(), line := pos_integer(),
                                      variables := [atom()]}}.
regions(Ast) ->
    lists:foldl(
      fun({region, Line, Name, Tag, Children} = Node, Acc) ->
              Acc2 = Acc#{Name => #{tag => Tag, line => Line, variables => variables(Children)}},
              lists:foldl(fun(Inner, A) -> maps:merge(A, regions(Inner)) end, Acc2, children(Node));
         (Node, Acc) ->
              lists:foldl(fun(Inner, A) -> maps:merge(A, regions(Inner)) end, Acc, children(Node))
      end, #{}, Ast).
