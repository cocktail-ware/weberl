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
%% == Slots ==
%% `{: slot head :}default{: /slot head :}' in a layout is a place a view can
%% fill: the view's top-level `{: fill head :}...{: /fill head :}' replaces the
%% slot's default (which may be empty). Everything in the view outside its fills
%% goes to `{: content :}'. Slots and fills are checked like regions: they start
%% and end in HTML text.
%%
%% Errors: `{syntax_error, File, Line, Reason}' from either file (Reason
%% includes `{unknown_fill, Name, LayoutFile}', `{content_unbalanced_markup, _}',
%% `{fill_without_layout, Name}', `{slot_outside_layout, Name}' and
%% `{fill_in_layout, Name}'), `{missing_content, LayoutFile}',
%% `{multiple_content, LayoutFile, [Line]}' and
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
    Fills = [F || {fill, _, _, _} = F <- ViewAst],
    Content = [N || N <- ViewAst, element(1, N) =/= fill],
    Slots = slot_names(LayoutAst),
    case [{Line, Name} || {fill, Line, Name, _} <- Fills, not lists:member(Name, Slots)] of
        [{Line, Name} | _] ->
            {error, {syntax_error, ViewFile, Line, {unknown_fill, Name, LayoutFile}}};
        [] ->
            case weberl_template_parser:validate_content(Content, ViewFile) of
                ok -> composed(splice(LayoutAst, Content, Fills), LayoutFile, ViewFile);
                {error, _} = Error -> Error
            end
    end.

%% A region name is used once per template, and the layout and the view share
%% one. (A slot's default that a fill replaces is not part of the result.)
composed(Ast, LayoutFile, ViewFile) ->
    Names = region_names(Ast),
    case Names -- lists:usort(Names) of
        [Name | _] -> {error, {duplicate_region, Name, LayoutFile, ViewFile}};
        [] -> {ok, Ast}
    end.

splice(Ast, Content, Fills) ->
    lists:flatmap(fun({content, _}) -> Content;
                     ({slot, _, Name, Default}) ->
                          case lists:keyfind(Name, 3, Fills) of
                              {fill, _, _, Children} -> Children;
                              false -> Default
                          end;
                     ({region, Line, Name, Tag, Children}) ->
                          [{region, Line, Name, Tag, splice(Children, Content, Fills)}];
                     (Node) -> [Node]
                  end, Ast).

slot_names(Ast) ->
    lists:flatmap(fun({slot, _, Name, _}) -> [Name];
                     ({region, _, _, _, Children}) -> slot_names(Children);
                     (_) -> []
                  end, Ast).

region_names(Ast) ->
    lists:flatmap(fun({region, _, Name, _, Children}) -> [Name | region_names(Children)];
                     (_) -> []
                  end, Ast).

flatten(Ast) ->
    lists:flatmap(fun({region, _, _, _, Children}) -> flatten(Children);
                     (Node) -> [Node]
                  end, Ast).

with({ok, V}, Next) -> Next(V);
with({error, _} = Error, _Next) -> Error.
