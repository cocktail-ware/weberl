%% @doc Template tokenizer.
%%
%% Splits a template into literal text and interpolation tokens:
%% <ul>
%%   <li>`{text, Line, Binary}'</li>
%%   <li>`{interp, Line, escaped | raw, Name}' for `{{ name }}' and `{{{ name }}}'</li>
%% </ul>
%% `Line' is the line of the first character of the token. Names match
%% `[a-z][a-zA-Z0-9_]*'; surrounding whitespace is ignored. A backslash directly
%% before `{{' yields a literal `{{'. Block tags `{: ... :}' (statements) give
%% <ul>
%%   <li>`{block_open, Line, region, Name, #{tag => Binary}}' for
%%       `{: region name [tag=element] :}'</li>
%%   <li>`{block_close, Line, region, Name}' for `{: /region name :}'</li>
%% </ul>
%% and `{content, Line}' for `{: content :}' (where a layout puts the view's
%% template). `\{:' is a literal `{:'. Errors:
%% `{error, {syntax_error, File, Line, Reason}}' with Reason
%% `unterminated_interpolation | unterminated_raw_interpolation |
%% unterminated_block_tag | {invalid_variable_name, Text} |
%% {invalid_block_tag, Text} | {invalid_region_tag, Tag}'.
-module(weberl_template_lexer).

-export([tokenize/2]).
-export_type([token/0]).

-type token() :: {text, pos_integer(), binary()}
               | {interp, pos_integer(), escaped | raw, atom()}
               | {block_open, pos_integer(), region, atom(), #{tag => binary()}}
               | {block_close, pos_integer(), region, atom()}
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
    case binary:match(Rest, Close) of
        nomatch ->
            throw({lex_error, Line, case Mode of
                                        raw -> unterminated_raw_interpolation;
                                        escaped -> unterminated_interpolation
                                    end});
        {Pos, Len} ->
            Content = binary:part(Rest, 0, Pos),
            After = binary:part(Rest, Pos + Len, byte_size(Rest) - Pos - Len),
            Name = name(Content, Line),
            Line2 = Line + count_newlines(Content),
            scan(After, Line2, <<>>, [{interp, Line, Mode, Name} | Acc])
    end.

%% A block tag `{: ... :}' (statements, as opposed to the values of `{{ }}').
block(Rest, Line, Acc) ->
    case binary:match(Rest, <<":}">>) of
        nomatch ->
            throw({lex_error, Line, unterminated_block_tag});
        {Pos, 2} ->
            Content = binary:part(Rest, 0, Pos),
            After = binary:part(Rest, Pos + 2, byte_size(Rest) - Pos - 2),
            Token = block_token(Content, Line),
            scan(After, Line + count_newlines(Content), <<>>, [Token | Acc])
    end.

block_token(Content, Line) ->
    Words = binary:split(string:trim(Content, both, " \t\r\n"), [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
                         [global, trim_all]),
    case Words of
        [<<"region">>, Name | Options] ->
            {block_open, Line, region, block_name(Name, Content, Line), region_options(Options, Content, Line)};
        [<<"content">>] ->
            {content, Line};
        [<<"/region">>, Name] ->
            {block_close, Line, region, block_name(Name, Content, Line)};
        _ ->
            throw({lex_error, Line, {invalid_block_tag, Content}})
    end.

block_name(Name, Content, Line) ->
    case re:run(Name, "^[a-z][a-zA-Z0-9_]*$", [{capture, none}]) of
        match -> binary_to_atom(Name, utf8);
        nomatch -> throw({lex_error, Line, {invalid_block_tag, Content}})
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

name(Content, Line) ->
    Trimmed = string:trim(Content, both, " \t\r\n"),
    case re:run(Trimmed, "^[a-z][a-zA-Z0-9_]*$", [{capture, none}]) of
        match -> binary_to_atom(Trimmed, utf8);
        nomatch -> throw({lex_error, Line, {invalid_variable_name, Content}})
    end.

%% Text accumulated so far starts on the line where it began.
flush(<<>>, _Line, Acc) -> Acc;
flush(Text, Line, Acc) -> [{text, Line - count_newlines(Text), Text} | Acc].

count_newlines(Bin) ->
    length(binary:matches(Bin, <<"\n">>)).
