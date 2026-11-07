%% @doc Template tokenizer.
%%
%% Splits a template into literal text and interpolation tokens:
%% <ul>
%%   <li>`{text, Line, Binary}'</li>
%%   <li>`{interp, Line, escaped | raw, Text}' for `{{ Expr }}' and `{{{ Expr }}}'; mode `json' for
%%       `{: json Expr :}'</li>
%% </ul>
%% `Line' is the line of the first character of the token. `Text' is the
%% Erlang expression exactly as written between the delimiters (the parser reads it
%% with `weberl_blocks_expr'; its newlines count towards the template's line
%% numbers). The tag ends at the first `}}' (`}}}' for the raw form) that is not part
%% of the Erlang inside: `weberl_blocks_expr:tag_end/2' reads strings, quoted atoms,
%% character literals and comments as opaque and keeps a bracket depth, so
%% `#{a => #{b => 1}}' and `f("}}")' need no care. A backslash directly
%% before `{{' yields a literal `{{'. Block tags `{: ... :}' (statements) give
%% <ul>
%%   <li>`{block_open, Line, region, Name, #{tag => Binary}}' for
%%       `{: region name [tag=element] :}'</li>
%%   <li>`{block_close, Line, region, Name}' for `{: /region name :}'</li>
%% </ul>
%% `{block_open, Line, slot | fill, Name, #{}}' and `{block_close, Line, slot | fill, Name}' for
%% `{: slot name :}' and `{: fill name :}' (names as for regions, but not `content'),
%% and `{content, Line}' for `{: content :}' (where a layout puts the view's
%% template). `\{:' is a literal `{:'.
%%
%% Statements: `{stmt, Line, Kind, Text, TextLine}' for `{: if Expr :}',
%% `{: elif Expr :}', `{: case Expr :}', `{: of Clause :}', `{: for Qualifiers :}'
%% (`Text' is the Erlang text as written, `TextLine' the line it starts on; the tag
%% ends at the first `:}') and, with `Text' `none', `{: else :}' and `{: empty :}';
%% `{stmt_end, Line, if | case | for}' for `{: /if :}', `{: /case :}', `{: /for :}'.
%% Errors:
%% `{error, {syntax_error, File, Line, Reason}}' with Reason
%% `unterminated_interpolation | unterminated_raw_interpolation |
%% unterminated_block_tag | unterminated_string | unbalanced_brace |
%% empty_interpolation | {missing_expression, Kind} |
%% {invalid_block_tag, Text} | {invalid_region_tag, Tag}'.
-module(weberl_template_lexer).

-export([tokenize/2]).
-export_type([token/0]).

-type token() :: {text, pos_integer(), binary()}
               | {interp, pos_integer(), escaped | raw | json, binary()}
               | {block_open, pos_integer(), region | slot | fill, atom(), #{tag => binary()}}
               | {block_close, pos_integer(), region | slot | fill, atom()}
               | {stmt, pos_integer(), 'if' | elif | 'case' | 'of' | 'for' | 'else' | empty,
                  binary() | none, pos_integer()}
               | {stmt_end, pos_integer(), 'if' | 'case' | 'for'}
               | {form_open, pos_integer(), binary(), binary() | none, pos_integer()}
               | {form_close, pos_integer()}
               | {content, pos_integer()}.

-spec tokenize(binary(), file:filename_all()) ->
    {ok, [token()]} | {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.
tokenize(Source, File) when is_binary(Source) ->
    try
        {ok, scan(Source, 1, <<>>, [])}
    catch
        throw:{lex_error, Line, Reason} ->
            {error, {syntax_error, File, Line, Reason}}
    end.

scan(<<>>, Line, Text, Acc) ->
    lists:reverse(flush(Text, Line, Acc));
scan(<<"\\{{", R/binary>>, Line, Text, Acc) ->
    scan(R, Line, <<Text/binary, "{{">>, Acc);
scan(<<"\\{:", R/binary>>, Line, Text, Acc) ->
    scan(R, Line, <<Text/binary, "{:">>, Acc);
scan(<<"{:", R/binary>>, Line, Text, Acc) ->
    block(R, Line, flush(Text, Line, Acc));
scan(<<"{{{", R/binary>>, Line, Text, Acc) ->
    interp(raw, <<"}}}">>, R, Line, flush(Text, Line, Acc));
scan(<<"{{", R/binary>>, Line, Text, Acc) ->
    interp(escaped, <<"}}">>, R, Line, flush(Text, Line, Acc));
scan(<<$\n, R/binary>>, Line, Text, Acc) ->
    scan(R, Line + 1, <<Text/binary, $\n>>, Acc);
scan(<<C, R/binary>>, Line, Text, Acc) ->
    scan(R, Line, <<Text/binary, C>>, Acc).

interp(Mode, Close, Rest, Line, Acc) ->
    case weberl_blocks_expr:tag_end(Rest, Close) of
        {error, unterminated} ->
            throw({lex_error, Line, case Mode of
                                        raw -> unterminated_raw_interpolation;
                                        escaped -> unterminated_interpolation
                                    end});
        {error, Error} ->
            tag_error(Error, Line);
        {ok, Pos} ->
            Len = byte_size(Close),
            Content = binary:part(Rest, 0, Pos),
            After = binary:part(Rest, Pos + Len, byte_size(Rest) - Pos - Len),
            string:trim(Content, both, " \t\r\n") =/= <<>>
                orelse throw({lex_error, Line, empty_interpolation}),
            Line2 = Line + count_newlines(Content),
            scan(After, Line2, <<>>, [{interp, Line, Mode, Content} | Acc])
    end.

%% A tag whose Erlang text cannot be delimited (see `weberl_blocks_expr:tag_end/2').
tag_error({Reason, Lines}, Line) -> throw({lex_error, Line + Lines, Reason}).

%% A block tag `{: ... :}' (statements, as opposed to the values of `{{ }}').
block(Rest, Line, Acc) ->
    case weberl_blocks_expr:tag_end(Rest, <<":}">>) of
        {error, unterminated} ->
            throw({lex_error, Line, unterminated_block_tag});
        {error, Error} ->
            tag_error(Error, Line);
        {ok, Pos} ->
            Content = binary:part(Rest, 0, Pos),
            After = binary:part(Rest, Pos + 2, byte_size(Rest) - Pos - 2),
            Token = block_token(Content, Line),
            scan(After, Line + count_newlines(Content), <<>>, [Token | Acc])
    end.

block_token(Content, Line) ->
    Trimmed = string:trim(Content, leading, " \t\r\n"),
    case statement(Trimmed, Content, Line) of
        {ok, Token} -> Token;
        none -> region_token(Content, Line)
    end.

%% Statements (`if', `case', `for' and their parts): the keyword, then the
%% Erlang text as written. The keyword has to be followed by white space.
statement(Trimmed, Content, Line) ->
    %% the text keeps the white space after the keyword, so its lines are counted right
    {Word, Rest} = case binary:match(Trimmed, [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>]) of
                       {Pos, _} -> {binary:part(Trimmed, 0, Pos),
                                    binary:part(Trimmed, Pos, byte_size(Trimmed) - Pos)};
                       nomatch -> {Trimmed, <<>>}
                   end,
    %% the text starts on the line of the keyword (its own newlines are counted
    %% when the Erlang text is scanned)
    TextLine = Line + count_newlines(binary:part(Content, 0, byte_size(Content) - byte_size(Trimmed))),
    case Word of
        <<"if">> -> with_text('if', Rest, Line, TextLine);
        <<"elif">> -> with_text(elif, Rest, Line, TextLine);
        <<"case">> -> with_text('case', Rest, Line, TextLine);
        <<"of">> -> with_text('of', Rest, Line, TextLine);
        <<"for">> -> with_text('for', Rest, Line, TextLine);
        <<"json">> -> json_tag(Rest, Line);
        <<"form">> -> form_tag(Rest, Line, TextLine);
        <<"/form">> -> form_close(Rest, Content, Line);
        <<"else">> -> bare('else', Rest, Content, Line);
        <<"empty">> -> bare(empty, Rest, Content, Line);
        <<"/if">> -> closer('if', Rest, Content, Line);
        <<"/case">> -> closer('case', Rest, Content, Line);
        <<"/for">> -> closer('for', Rest, Content, Line);
        _ -> none
    end.

with_text(Kind, Rest, Line, TextLine) ->
    case string:trim(Rest, both, " \t\r\n") of
        <<>> -> throw({lex_error, Line, {missing_expression, Kind}});
        _ -> {ok, {stmt, Line, Kind, Rest, TextLine}}
    end.

%% `{: json Expr :}': a value as JSON, for a data script or an attribute. It is an interpolation
%% of its own mode; the parser and the passes that know the HTML context do the rest.
json_tag(Rest, Line) ->
    case string:trim(Rest, both, " \t\r\n") of
        <<>> -> throw({lex_error, Line, {missing_expression, json}});
        _ -> {ok, {interp, Line, json, Rest}}
    end.

%% `{: form Action :}' / `{: form Action, Opts :}': the head is one or two Erlang expressions separated
%% by the first comma outside brackets and strings.
form_tag(Rest, Line, TextLine) ->
    case string:trim(Rest, both, " \t\r\n") of
        <<>> ->
            throw({lex_error, Line, {missing_expression, form}});
        _ ->
            case weberl_blocks_expr:tag_end(Rest, <<",">>) of
                {ok, Pos} ->
                    Action = binary:part(Rest, 0, Pos),
                    Opts = binary:part(Rest, Pos + 1, byte_size(Rest) - Pos - 1),
                    string:trim(Action, both, " \t\r\n") =/= <<>> andalso string:trim(Opts, both, " \t\r\n") =/= <<>>
                        orelse throw({lex_error, Line, {missing_expression, form}}),
                    {ok, {form_open, Line, Action, Opts, TextLine}};
                {error, unterminated} ->
                    {ok, {form_open, Line, Rest, none, TextLine}};
                {error, Error} ->
                    tag_error(Error, Line)
            end
    end.

form_close(Rest, Content, Line) ->
    case string:trim(Rest, both, " \t\r\n") of
        <<>> -> {ok, {form_close, Line}};
        _ -> throw({lex_error, Line, {invalid_block_tag, Content}})
    end.

bare(Kind, Rest, Content, Line) ->
    case string:trim(Rest, both, " \t\r\n") of
        <<>> -> {ok, {stmt, Line, Kind, none, Line}};
        _ -> throw({lex_error, Line, {invalid_block_tag, Content}})
    end.

closer(Kind, Rest, Content, Line) ->
    case string:trim(Rest, both, " \t\r\n") of
        <<>> -> {ok, {stmt_end, Line, Kind}};
        _ -> throw({lex_error, Line, {invalid_block_tag, Content}})
    end.

region_token(Content, Line) ->
    Words = binary:split(string:trim(Content, both, " \t\r\n"), [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
                         [global, trim_all]),
    case Words of
        [<<"region">>, Name | Options] ->
            {block_open, Line, region, block_name(Name, Content, Line), region_options(Options, Content, Line)};
        [<<"content">>] ->
            {content, Line};
        [<<"/region">>, Name] ->
            {block_close, Line, region, block_name(Name, Content, Line)};
        [<<"slot">>, Name] ->
            {block_open, Line, slot, slot_name(Name, Content, Line), #{}};
        [<<"fill">>, Name] ->
            {block_open, Line, fill, slot_name(Name, Content, Line), #{}};
        [<<"/slot">>, Name] ->
            {block_close, Line, slot, slot_name(Name, Content, Line)};
        [<<"/fill">>, Name] ->
            {block_close, Line, fill, slot_name(Name, Content, Line)};
        _ ->
            throw({lex_error, Line, {invalid_block_tag, Content}})
    end.

block_name(Name, Content, Line) ->
    case re:run(Name, "^[a-z][a-zA-Z0-9_]*$", [{capture, none}]) of
        match -> binary_to_atom(Name, utf8);
        nomatch -> throw({lex_error, Line, {invalid_block_tag, Content}})
    end.

%% Slot names are block names, except `content', which is `{: content :}'.
slot_name(Name, Content, Line) ->
    case block_name(Name, Content, Line) of
        content -> throw({lex_error, Line, {invalid_block_tag, Content}});
        Atom -> Atom
    end.

%% `tag=tbody': the element that wraps the region instead of `weberl-region'.
region_options(Options, Content, Line) ->
    lists:foldl(
      fun(<<"tag=", Tag/binary>>, Opts) ->
              case re:run(Tag, "^[a-z][a-z0-9]*$", [{capture, none}]) of
                  match ->
                      case lists:member(Tag, unusable_tags()) of
                          true -> throw({lex_error, Line, {invalid_region_tag, Tag}});
                          false -> Opts#{tag => Tag}
                      end;
                  nomatch ->
                      throw({lex_error, Line, {invalid_region_tag, Tag}})
              end;
         (_, _) ->
              throw({lex_error, Line, {invalid_block_tag, Content}})
      end, #{}, Options).

%% Elements whose content the browser does not treat as markup, and void
%% elements (which cannot have any).
unusable_tags() ->
    [<<"script">>, <<"style">>, <<"textarea">>, <<"title">>, <<"area">>, <<"base">>, <<"br">>,
     <<"col">>, <<"embed">>, <<"hr">>, <<"img">>, <<"input">>, <<"link">>, <<"meta">>,
     <<"source">>, <<"track">>, <<"wbr">>].

%% Text accumulated so far starts on the line where it began.
flush(<<>>, _Line, Acc) -> Acc;
flush(Text, Line, Acc) -> [{text, Line - count_newlines(Text), Text} | Acc].

count_newlines(Bin) ->
    length(binary:matches(Bin, <<"\n">>)).
