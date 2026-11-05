%% @doc Layouts: a template with a `{: content :}' marker that a view's template
%% is put into when the view is compiled.
%%
%% ```
%% <html><body><nav>...</nav>{: content :}</body></html>
%% '''
%%
%% Composition happens on the ASTs, before the view is compiled, so the result is
%% one template: regions of the layout and of the view live in the same
%% generated module (`render_region/3' finds both), and a variable of either is
%% an ordinary assign. Each file is validated on its own (a layout allows
%% `{: content :}' in HTML text, a view allows none); the splice point is in
%% text and the view ends in text, so the combination is valid too.
%%
%% Errors: `{syntax_error, File, Line, Reason}' from either file,
%% `{missing_content, LayoutFile}', `{multiple_content, LayoutFile, [Line]}' and
%% `{duplicate_region, Name, LayoutFile, ViewFile}' (a region name is used once
%% per template, and the layout and the view share one).
-module(weberl_template_layout).

-export([parse/1, compose/3]).
-export_type([layout/0]).

-opaque layout() :: {file:filename_all(), weberl_template_parser:ast()}.

%% @doc Read, parse and validate a layout file.
-spec parse(file:filename_all()) -> {ok, layout()} | {error, term()}.
parse(File) ->
    case file:read_file(File) of
        {ok, Source} -> parse_source(Source, File);
        {error, Posix} -> {error, {read_failed, File, Posix}}
    end.

parse_source(Source, File) ->
    case unicode:characters_to_binary(Source, utf8, utf8) of
        Source ->
            with(weberl_template_lexer:tokenize(Source, File),
                 fun(Tokens) ->
                     with(weberl_template_parser:parse(Tokens, File),
                          fun(Ast) -> checked(Ast, File) end)
                 end);
        _ ->
            {error, {invalid_utf8, File}}
    end.

checked(Ast, File) ->
    case weberl_template_parser:validate_layout(Ast, File) of
        ok ->
            case [L || {content, L} <- flatten(Ast)] of
                [_] -> {ok, {File, Ast}};
                [] -> {error, {missing_content, File}};
                Lines -> {error, {multiple_content, File, Lines}}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Put a view's AST into the layout's `{: content :}'.
-spec compose(layout(), weberl_template_parser:ast(), file:filename_all()) ->
    {ok, weberl_template_parser:ast()} | {error, term()}.
compose({LayoutFile, LayoutAst}, ViewAst, ViewFile) ->
    Both = maps:keys(weberl_template_parser:regions(LayoutAst))
        ++ maps:keys(weberl_template_parser:regions(ViewAst)),
    case Both -- lists:usort(Both) of
        [Name | _] -> {error, {duplicate_region, Name, LayoutFile, ViewFile}};
        [] -> {ok, splice(LayoutAst, ViewAst)}
    end.

splice(Ast, ViewAst) ->
    lists:flatmap(fun({content, _}) -> ViewAst;
                     ({region, Line, Name, Tag, Children}) ->
                          [{region, Line, Name, Tag, splice(Children, ViewAst)}];
                     (Node) -> [Node]
                  end, Ast).

flatten(Ast) ->
    lists:flatmap(fun({region, _, _, _, Children}) -> flatten(Children);
                     (Node) -> [Node]
                  end, Ast).

with({ok, V}, Next) -> Next(V);
with({error, _} = Error, _Next) -> Error.
