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
%%   <li>`{var, Line, Name, escaped | raw}'</li>
%%   <li>`{region, Line, Name, Tag, Children}': a region (`{: region name :}').
%%       `Tag' is `default' (the `weberl-region' web component) or the binary
%%       name of another element. Regions may nest; a name is used once per
%%       template.</li>
%%   <li>`{content, Line}': `{: content :}', the place a layout puts the view's
%%       template (see `weberl_template_layout').</li>
%% </ul>
-module(weberl_template_parser).

-export([parse/1, parse/2, validate/2, validate_layout/2, variables/1, regions/1]).
-export_type([ast/0, ast_node/0]).

-type ast_node() :: {text, pos_integer(), binary()}
              | {var, pos_integer(), atom(), escaped | raw}
              | {region, pos_integer(), atom(), default | binary(), ast()}
              | {content, pos_integer()}.
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

%% Stack of open regions: {Name, Line, Tag, NodesSoFarReversed}.
build([], [], Acc, _Seen) ->
    lists:reverse(Acc);
build([], [{Name, Line, _, _} | _], _Acc, _Seen) ->
    throw({parse_error, Line, {unclosed_region, Name}});
build([{text, Line, Bin} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{text, Line, Bin} | Acc], Seen);
build([{interp, Line, Mode, Name} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{var, Line, Name, Mode} | Acc], Seen);
build([{content, Line} | T], Stack, Acc, Seen) ->
    build(T, Stack, [{content, Line} | Acc], Seen);
build([{block_open, Line, region, Name, Opts} | T], Stack, Acc, Seen) ->
    case Seen of
        #{Name := First} -> throw({parse_error, Line, {duplicate_region, Name, First}});
        _ -> ok
    end,
    Tag = maps:get(tag, Opts, default),
    build(T, [{Name, Line, Tag, Acc} | Stack], [], Seen#{Name => Line});
build([{block_close, Line, region, Name} | _], [], _Acc, _Seen) ->
    throw({parse_error, Line, {unexpected_region_end, Name}});
build([{block_close, Line, region, Name} | _], [{Open, _, _, _} | _], _Acc, _Seen) when Name =/= Open ->
    throw({parse_error, Line, {mismatched_region_end, Open, Name}});
build([{block_close, _, region, Name} | T], [{Name, Line, Tag, Outer} | Stack], Acc, Seen) ->
    build(T, Stack, [{region, Line, Name, Tag, lists:reverse(Acc)} | Outer], Seen).

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

check(Ast, File, Mode) ->
    case walk(Ast, weberl_template_html:initial(), {File, Mode}) of
        {ok, _Ctx} -> ok;
        {error, _} = Error -> Error
    end.

walk([], Ctx, _Env) ->
    {ok, Ctx};
walk([{text, _, Bin} | Rest], Ctx, Env) ->
    walk(Rest, weberl_template_html:advance(Bin, Ctx), Env);
walk([{var, Line, _Name, Mode} | Rest], Ctx, {File, _} = Env) ->
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

%% @doc Variables used by the template (also inside regions), sorted and
%% without duplicates.
-spec variables(ast()) -> [atom()].
variables(Ast) ->
    lists:usort(vars(Ast)).

vars(Ast) ->
    lists:flatmap(fun({var, _, Name, _}) -> [Name];
                     ({region, _, _, _, Children}) -> vars(Children);
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
         (_, Acc) -> Acc
      end, #{}, Ast).
