%% @doc Basic HTML form helpers.
%%
%% They return `iodata()' to insert in a template with `{{{ @name }}}' (raw: the
%% helpers escape what they are given). Forms are protected against CSRF by
%% default: {@link open/3} adds the hidden token field unless told `csrf => false'.
%% Get the token for the page with {@link weberl_csrf:protect/2}.
%%
%% This is deliberately small. Naming inputs, live versus plain forms, bindings
%% on two-way pages and the like are a roadmap item (see `ROADMAP.md').
-module(weberl_form).

-export([open/2, open/3, csrf_input/1]).
-export_type([options/0]).

%% `method': `post' (default) or `get', the only methods a browser form submits;
%% `csrf': `false' leaves the token out; `enctype': `multipart' (or any value) for uploads,
%% see {@link open/3}; `attrs': more attributes as `[{Name, Value}]' (values escaped; names
%% are checked).
-type options() :: #{method => get | post,
                     csrf => boolean(),
                     enctype => multipart | iodata(),
                     attrs => [{iodata(), iodata()}]}.

-spec open(binary() | undefined, iodata()) -> iodata().
open(Token, Action) ->
    open(Token, Action, #{}).

%% @doc `<form method="post" action="...">' followed by the hidden `_csrf' input.
%% The input is left out for `method => get' (a safe method is not checked, and a
%% token in a URL would leak) and for `csrf => false'. `Token' may then be
%% `undefined'. `Action' must be a path on this site (`weberl_url:local/1') or an
%% `http(s)' URL; anything else (`javascript:', relative paths) raises `badarg'.
%%
%% `enctype => multipart' writes `enctype="multipart/form-data"', which a form with a file
%% input needs, and puts the token in the **query string of the action** (`?_csrf=...',
%% appended with `&' when the action has a query already) instead of a hidden field: a
%% browser sends the URL before the body, so a forged upload is refused before its body is
%% parsed (see {@link weberl_csrf}). The token then shows in server logs and can leave in a
%% `Referer' header; {@link weberl_csrf:protect/2} marks the page `referrer-policy:
%% same-origin' for that reason. Read the upload with `weberl_request:files/1'.
-spec open(binary() | undefined, iodata(), options()) -> iodata().
open(Token, Action, Opts) ->
    Method = maps:get(method, Opts, post),
    (Method =:= get orelse Method =:= post) orelse erlang:error(badarg),
    Url = iolist_to_binary(Action),
    (weberl_url:local(Url) orelse absolute(Url)) orelse erlang:error(badarg),
    Enctype = enctype(maps:get(enctype, Opts, undefined)),
    Protected = Method =/= get andalso maps:get(csrf, Opts, true),
    %% A multipart form carries its token in the URL of the action: the browser sends the
    %% body after the URL, so the token is checked before the body is parsed.
    InUrl = Protected andalso Enctype =:= <<"multipart/form-data">>,
    Target = case InUrl of
                 true -> with_token(Url, Token);
                 false -> Url
             end,
    Attrs = [{<<"method">>, atom_to_binary(Method)}, {<<"action">>, Target}]
        ++ [{<<"enctype">>, Enctype} || Enctype =/= undefined] ++ maps:get(attrs, Opts, []),
    Tag = ["<form", [[$\s, attr_name(N), "=\"", weberl_template_runtime:escape(to_bin(V)), $"]
                     || {N, V} <- Attrs], ">"],
    case {Protected, InUrl} of
        {true, false} -> [Tag, csrf_input(Token)];
        _ -> Tag
    end.

%% `multipart' is `multipart/form-data', the encoding a form with a file input needs (without
%% it a browser sends the name of the file, not its content).
enctype(undefined) -> undefined;
enctype(multipart) -> <<"multipart/form-data">>;
enctype(Other) -> string:lowercase(iolist_to_binary(Other)).

%% `?_csrf=TOKEN' (or `&_csrf=TOKEN' after an existing query), the token percent-encoded.
with_token(Url, Token) when is_binary(Token) ->
    Joiner = case binary:match(Url, <<"?">>) of
                 nomatch -> <<"?">>;
                 _ -> <<"&">>
             end,
    {weberl_url, component, Encoded} = weberl_url:component(Token),
    <<Url/binary, Joiner/binary, (weberl_csrf:field_name())/binary, "=", Encoded/binary>>;
with_token(_Url, _) ->
    erlang:error(badarg).

%% @doc `<input type="hidden" name="_csrf" value="...">'.
-spec csrf_input(binary()) -> iodata().
csrf_input(Token) when is_binary(Token) ->
    ["<input type=\"hidden\" name=\"", weberl_csrf:field_name(), "\" value=\"",
     weberl_template_runtime:escape(Token), "\">"];
csrf_input(_) ->
    erlang:error(badarg).

absolute(<<"https://", Rest/binary>>) -> clean(Rest);
absolute(<<"http://", Rest/binary>>) -> clean(Rest);
absolute(_) -> false.

clean(Bin) ->
    Bin =/= <<>> andalso lists:all(fun(C) -> C > 32 andalso C < 127 end, binary_to_list(Bin)).

%% Attribute names: letters, digits, `-', `_', `:' only.
attr_name(Name) ->
    N = to_bin(Name),
    case N =/= <<>> andalso lists:all(fun name_char/1, binary_to_list(N)) of
        true -> N;
        false -> erlang:error(badarg)
    end.

name_char(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 -> true;
name_char(C) -> C =:= $- orelse C =:= $_ orelse C =:= $:.

to_bin(V) -> iolist_to_binary(V).
