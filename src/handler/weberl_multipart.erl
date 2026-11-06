%% @doc `multipart/form-data' requests, independent of the transport (HANDOFF.md, decision 13).
%%
%% The adapter splits the body into raw parts (`[{Headers, Body}]', header names lowercased);
%% this module reads each part's `Content-Disposition', builds the parts the application sees
%% and applies the {@link weberl_limits}. It is what `weberl_request:multipart/1,2', `form/1'
%% and `files/1,2' use.
%%
%% A part is `#{name, filename, content_type, headers, body}'. `filename' is `undefined' for a
%% text field and the client's file name otherwise (`<<>>' for a file input left empty, which
%% browsers send as a part with `filename=""' and no content: {@link files/1} leaves those out).
%% `name' and `filename' are client input, `content_type' is the client's claim about the
%% bytes: none of them is checked against the content. {@link safe_filename/1} turns a
%% client file name into one that is safe to store.
%%
%% In a `Content-Disposition' parameter browsers write `"' as `%22' and line breaks as `%0D'
%% and `%0A' (the HTML standard); exactly those three escapes are undone, any other `%' stays
%% as it is. Clients such as curl write `\"' and `\\' instead: those two are undone in a quoted
%% value, while any other backslash stays (a browser does not escape it, so `C:\dir\x.txt' is
%% kept as sent). `filename*=' (RFC 5987) is not read: browsers do not send it.
-module(weberl_multipart).

-export([parts/3, files/1, fields/1, safe_filename/1, disposition/1]).
-export_type([part/0, raw/0]).

-type raw() :: {[{binary(), binary()}], binary()}.
-type part() :: #{name := binary(), filename := binary() | undefined, content_type := binary(),
                  headers := [{binary(), binary()}], body := binary()}.

%% @doc The parts of a request from the adapter's raw parts, within the limits. Errors:
%% `malformed_multipart' (no usable `Content-Disposition' or `name', a text field that is not
%% UTF-8) and `{limit_exceeded, Limit}' (logged by {@link weberl_limits:exceeded/4}).
-spec parts([raw()], weberl_limits:limits(), weberl_request:t()) ->
    {ok, [part()]} | {error, malformed_multipart | {limit_exceeded, weberl_limits:limit()}}.
parts(Raw, Limits, Request) ->
    build(Raw, Limits, Request, {0, 0}, []).

build([], _Limits, _Request, _Counts, Acc) ->
    {ok, lists:reverse(Acc)};
build([{Headers, Body} | Rest], Limits, Request, {Fields, Files}, Acc) ->
    case disposition_of(Headers) of
        {ok, Name, Filename} ->
            Part = #{name => Name, filename => Filename, content_type => content_type(Headers, Filename),
                     headers => Headers, body => Body},
            case check(Part, Limits, Request, {Fields, Files}) of
                {ok, Counts} -> build(Rest, Limits, Request, Counts, [Part | Acc]);
                {error, _} = Error -> Error
            end;
        error ->
            {error, malformed_multipart}
    end.

%% One part against the limits; the counts are the text fields and files seen so far.
check(#{filename := undefined, body := Body}, Limits, Request, {Fields, Files}) ->
    #{max_fields := MaxFields, max_field_bytes := MaxBytes} = Limits,
    if
        Fields + 1 > MaxFields -> weberl_limits:exceeded(max_fields, MaxFields, Fields + 1, Request);
        byte_size(Body) > MaxBytes -> weberl_limits:exceeded(max_field_bytes, MaxBytes, byte_size(Body), Request);
        true ->
            case unicode:characters_to_binary(Body, utf8, utf8) of
                Body -> {ok, {Fields + 1, Files}};
                _ -> {error, malformed_multipart}
            end
    end;
check(#{filename := <<>>, body := <<>>}, _Limits, _Request, Counts) ->
    %% a file input left empty: nothing was chosen
    {ok, Counts};
check(#{filename := Filename, body := Body}, Limits, Request, {Fields, Files}) ->
    #{max_files := MaxFiles, max_file_bytes := MaxBytes, max_filename_bytes := MaxName} = Limits,
    if
        Files + 1 > MaxFiles -> weberl_limits:exceeded(max_files, MaxFiles, Files + 1, Request);
        byte_size(Filename) > MaxName -> weberl_limits:exceeded(max_filename_bytes, MaxName, byte_size(Filename), Request);
        byte_size(Body) > MaxBytes -> weberl_limits:exceeded(max_file_bytes, MaxBytes, byte_size(Body), Request);
        true -> {ok, {Fields, Files + 1}}
    end.

%% @doc The text fields of the parts as `[{Name, Value}]'.
-spec fields([part()]) -> [{binary(), binary()}].
fields(Parts) ->
    [{Name, Body} || #{name := Name, filename := undefined, body := Body} <- Parts].

%% @doc The files of the parts: those with a file name, except a file input left empty.
-spec files([part()]) -> [#{name := binary(), filename := binary(), content_type := binary(),
                            body := binary(), size := non_neg_integer()}].
files(Parts) ->
    [#{name => Name, filename => Filename, content_type => Type, body => Body, size => byte_size(Body)}
     || #{name := Name, filename := Filename, content_type := Type, body := Body} <- Parts,
        Filename =/= undefined, not (Filename =:= <<>> andalso Body =:= <<>>)].

%% ---------------------------------------------------------------------
%% Content-Disposition

disposition_of(Headers) ->
    case lists:keyfind(<<"content-disposition">>, 1, Headers) of
        {_, Value} ->
            case disposition(Value) of
                {ok, #{name := Name} = Params} -> {ok, Name, maps:get(filename, Params, undefined)};
                _ -> error
            end;
        false ->
            error
    end.

%% @doc The `name' and `filename' of a `form-data' `Content-Disposition' value. A missing
%% `name', another disposition type or text that is not UTF-8 is `error'.
-spec disposition(binary()) -> {ok, #{name := binary(), filename => binary()}} | error.
disposition(Value) ->
    case split_params(Value, <<>>, false, []) of
        [Type | Params] ->
            case string:lowercase(string:trim(Type)) of
                <<"form-data">> -> read_params(Params, #{});
                _ -> error
            end;
        [] ->
            error
    end.

read_params([], Acc) ->
    case Acc of
        #{name := _} -> {ok, Acc};
        _ -> error
    end;
read_params([Param | Rest], Acc) ->
    case binary:split(Param, <<"=">>) of
        [Key, Raw] ->
            case string:lowercase(string:trim(Key)) of
                K when K =:= <<"name">>; K =:= <<"filename">> ->
                    Atom = binary_to_atom(K),
                    case maps:is_key(Atom, Acc) of
                        true -> read_params(Rest, Acc);
                        false ->
                            case value(string:trim(Raw)) of
                                {ok, Value} -> read_params(Rest, Acc#{Atom => Value});
                                error -> error
                            end
                    end;
                _ ->
                    read_params(Rest, Acc)
            end;
        _ ->
            read_params(Rest, Acc)
    end.

%% A quoted string (with `\"' and `\\') or a token; the three browser escapes undone; UTF-8.
value(<<$", Rest/binary>>) ->
    case unquote(Rest, <<>>) of
        {ok, Text} -> utf8(unescape(Text));
        error -> error
    end;
value(Token) ->
    utf8(unescape(Token)).

unquote(<<$", _/binary>>, Acc) -> {ok, Acc};
unquote(<<$\\, C, Rest/binary>>, Acc) when C =:= $"; C =:= $\\ -> unquote(Rest, <<Acc/binary, C>>);
unquote(<<C, Rest/binary>>, Acc) -> unquote(Rest, <<Acc/binary, C>>);
unquote(<<>>, _Acc) -> error.

unescape(Bin) ->
    unescape(Bin, <<>>).

unescape(<<"%22", Rest/binary>>, Acc) -> unescape(Rest, <<Acc/binary, $">>);
unescape(<<$%, H, L, Rest/binary>>, Acc) when (H =:= $0), (L =:= $D orelse L =:= $d) ->
    unescape(Rest, <<Acc/binary, $\r>>);
unescape(<<$%, H, L, Rest/binary>>, Acc) when (H =:= $0), (L =:= $A orelse L =:= $a) ->
    unescape(Rest, <<Acc/binary, $\n>>);
unescape(<<C, Rest/binary>>, Acc) -> unescape(Rest, <<Acc/binary, C>>);
unescape(<<>>, Acc) -> Acc.

utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> {ok, Bin};
        _ -> error
    end.

%% Split a header value at `;' outside quotes.
split_params(<<>>, Cur, _Quoted, Acc) ->
    lists:reverse([Cur | Acc]);
split_params(<<$\\, C, Rest/binary>>, Cur, true, Acc) when C =:= $"; C =:= $\\ ->
    split_params(Rest, <<Cur/binary, $\\, C>>, true, Acc);
split_params(<<$", Rest/binary>>, Cur, Quoted, Acc) ->
    split_params(Rest, <<Cur/binary, $">>, not Quoted, Acc);
split_params(<<$;, Rest/binary>>, Cur, false, Acc) ->
    split_params(Rest, <<>>, false, [Cur | Acc]);
split_params(<<C, Rest/binary>>, Cur, Quoted, Acc) ->
    split_params(Rest, <<Cur/binary, C>>, Quoted, Acc).

content_type(Headers, Filename) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
        {_, Type} when Type =/= <<>> -> Type;
        _ when Filename =:= undefined -> <<"text/plain">>;
        _ -> <<"application/octet-stream">>
    end.

%% ---------------------------------------------------------------------
%% File names

%% @doc A file name that is safe to store, from the client's: the part after the last `/' or
%% `\' (a client may send a whole path), without control characters, without leading or
%% trailing dots and spaces (no `.', `..' or hidden files). Nothing left gives `<<"file">>'.
%% It does not make a name unique or limit its length: choose the directory and the final name.
-spec safe_filename(binary()) -> binary().
safe_filename(Name) when is_binary(Name) ->
    Base = lists:last(binary:split(Name, [<<"/">>, <<"\\">>], [global])),
    Clean = << <<C>> || <<C>> <= Base, C > 31, C =/= 127 >>,
    case string:trim(Clean, both, ". ") of
        <<>> -> <<"file">>;
        Safe -> iolist_to_binary(Safe)
    end.
