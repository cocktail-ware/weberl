%% @doc Minimal HTML context tracker used to validate where interpolation may
%% appear. It is not an HTML parser: it follows just enough of the tokenizer
%% states (text, comments, tags, attributes, `script'/`style' content) to know
%% where a `{{ @name }}' sits.
%%
%% HTML escaping makes a value safe in text and in quoted attribute values, and
%% nowhere else. Interpolation is therefore only allowed in:
%% <ul>
%%   <li>text nodes (escaped or raw);</li>
%%   <li>quoted attribute values (escaped only), except in event handlers (`on*'),
%%       `style' and a few similar attributes, which need context-specific encoding.
%%       The URL attributes (see {@link url_attribute/1}) take interpolation too, but
%%       only a value made by `weberl_url' (checked by `weberl_template_urls').</li>
%% </ul>
-module(weberl_template_html).

-export([initial/0, advance/2, check/2, url_attribute/1, url_policy/2, block_context/1, branch_end_ok/2,
         base_tag/1, json_context/1]).
-export_type([ctx/0, policy/0]).

%% What a URL attribute of an element accepts (HANDOFF decision 8): `web' a path on
%% this site or an `http(s)' URL, `local_only' a path on this site only (elements that
%% load code or change the base of every link).
-type policy() :: web | local_only.

-type ctx() :: text | lt | comment | declaration | end_tag
             | {raw_text, binary()}
             | {tag_name, binary()}
             | {in_tag, binary()}
             | {attr_name, binary(), binary()}
             | {after_attr_name, binary(), binary()}
             | {before_value, binary(), binary()}
             | {value, $" | $', binary(), binary()}
             | {unquoted, binary(), binary()}.

-define(WS(C), (C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r orelse C =:= $\f)).
-define(ALPHA(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z))).

-spec initial() -> ctx().
initial() -> text.

%% @doc Context after reading literal text `Bin' starting in context `Ctx'.
-spec advance(binary(), ctx()) -> ctx().
advance(Bin, Ctx) -> step(Bin, Ctx).

%% @doc May an interpolation of the given mode appear in this context?
-spec check(ctx(), escaped | raw | json) -> ok | {error, term()}.
%% `{: json :}' (see json_context/1): only in a data script and in an attribute value
check(Ctx, json) ->
    case json_context(Ctx) of
        none -> {error, {json_not_allowed_here, context_word(Ctx)}};
        _ -> ok
    end;
check(text, _) -> ok;
%% the type of a script decides what its content is: it stays literal
check({value, _, _, {type, _}}, _) -> {error, {interpolation_in_restricted_attribute, <<"type">>}};
check({value, _, _, Attr}, Mode) ->
    case {Mode, restricted(Attr)} of
        {raw, _} -> {error, {raw_interpolation_in_attribute, Attr}};
        {_, true} -> {error, {interpolation_in_restricted_attribute, Attr}};
        %% a URL attribute takes escaped interpolation; `weberl_template_urls' checks what is in it
        _ -> ok
    end;
check(comment, _) -> unsupported(comment);
check({raw_text, Tag}, _) -> unsupported(base_tag(Tag));
check({unquoted, _, _}, _) -> unsupported(unquoted_attribute);
check({before_value, _, _}, _) -> unsupported(unquoted_attribute);
check(declaration, _) -> unsupported(declaration);
check(end_tag, _) -> unsupported(end_tag);
check(_, _) -> unsupported(tag).

unsupported(Where) -> {error, {interpolation_in_unsupported_context, Where}}.

%% Attributes that stay literal: interpolation needs an encoding no helper provides.
restricted(<<"on", _/binary>>) -> true;
restricted(Attr) ->
    lists:member(Attr, [<<"style">>, <<"srcset">>, <<"data">>,
                        <<"background">>, <<"ping">>, <<"manifest">>, <<"codebase">>,
                        <<"longdesc">>, <<"usemap">>, <<"srcdoc">>, <<"is">>]).

%% @doc Where may a block (`if', `case', `for') stand in this context? `text'; `tag', between the
%% attributes of a start tag (the engine adds the separating spaces, see `weberl_template_attrs');
%% `value', inside the quoted value of an attribute that takes plain text. The value of a URL attribute
%% or of a restricted one (`style', `on*', ...) is `{error, {block_in_restricted_attribute, Attr}}';
%% everything else is `unsupported'.
-spec block_context(ctx()) -> text | tag | value | unsupported | {error, term()}.
block_context(text) -> text;
block_context({in_tag, _}) -> tag;
%% after a finished attribute name and white space (`<input disabled {: if ... :}'): the next thing is a
%% new attribute
block_context({after_attr_name, _, _}) -> tag;
block_context({value, _, _, {type, _}}) -> {error, {block_in_restricted_attribute, <<"type">>}};
block_context({value, _, _, Attr}) ->
    case restricted(Attr) orelse url_attribute(Attr) of
        true -> {error, {block_in_restricted_attribute, Attr}};
        false -> value
    end;
block_context(_) -> unsupported.

%% @doc May a branch that started in context `Start' end in `End'? In text and in a value it has to be the
%% same context. Between attributes the branch is followed by a space the engine adds, so it may end between
%% attributes or after a complete attribute name (`checked'), but not inside a value, after `=' or in the
%% middle of a name that is not finished by a space.
-spec branch_end_ok(ctx(), ctx()) -> boolean().
branch_end_ok({after_attr_name, Tag, _}, End) -> branch_end_ok({in_tag, Tag}, End);
branch_end_ok({in_tag, Tag}, {in_tag, Tag}) -> true;
branch_end_ok({in_tag, Tag}, {attr_name, Tag, _}) -> true;
branch_end_ok({in_tag, Tag}, {after_attr_name, Tag, _}) -> true;
branch_end_ok({in_tag, _}, _) -> false;
branch_end_ok(Same, Same) -> true;
branch_end_ok(_, _) -> false.

%% @doc Attributes whose value is a URL: interpolation there has to be a `weberl_url'
%% value (see `weberl_template_urls').
-spec url_attribute(binary()) -> boolean().
url_attribute(Attr) ->
    lists:member(Attr, [<<"href">>, <<"src">>, <<"action">>, <<"formaction">>, <<"poster">>,
                        <<"cite">>, <<"xlink:href">>]).

%% @doc The policy of a URL attribute on an element: elements that run code or change
%% what every link means (`script', `iframe', `embed', `frame', `base', `link', and `use',
%% which pulls in another document) take paths on this site only.
-spec url_policy(binary(), binary()) -> policy().
url_policy(<<"script", _/binary>>, <<"src">>) -> local_only;
url_policy(Tag, <<"src">>) when Tag =:= <<"iframe">>;
                                Tag =:= <<"embed">>; Tag =:= <<"frame">> -> local_only;
url_policy(Tag, <<"href">>) when Tag =:= <<"base">>; Tag =:= <<"link">>; Tag =:= <<"use">> -> local_only;
url_policy(<<"use">>, <<"xlink:href">>) -> local_only;
url_policy(_, _) -> web.

%% Transitions

step(<<>>, Ctx) -> Ctx;
%% text
step(<<"<!--", R/binary>>, text) -> step(R, comment);
step(<<"<!", R/binary>>, text) -> step(R, declaration);
step(<<"</", R/binary>>, text) -> step(R, end_tag);
step(<<$<, C, R/binary>>, text) when ?ALPHA(C) -> step(R, {tag_name, <<(lower(C))>>});
step(<<$<>>, text) -> lt;
step(<<_, R/binary>>, text) -> step(R, text);
step(R, lt) -> step(<<$<, R/binary>>, text);
%% comment / declaration / end tag
step(<<"-->", R/binary>>, comment) -> step(R, text);
step(<<_, R/binary>>, comment) -> step(R, comment);
step(<<$>, R/binary>>, declaration) -> step(R, text);
step(<<_, R/binary>>, declaration) -> step(R, declaration);
step(<<$>, R/binary>>, end_tag) -> step(R, text);
step(<<_, R/binary>>, end_tag) -> step(R, end_tag);
%% tag name
step(<<C, R/binary>>, {tag_name, T}) when ?WS(C); C =:= $/ -> step(R, {in_tag, T});
step(<<$>, R/binary>>, {tag_name, T}) -> open(T, R);
step(<<C, R/binary>>, {tag_name, T}) -> step(R, {tag_name, <<T/binary, (lower(C))>>});
%% between attributes
step(<<C, R/binary>>, {in_tag, T}) when ?WS(C); C =:= $/ -> step(R, {in_tag, T});
step(<<$>, R/binary>>, {in_tag, T}) -> open(T, R);
step(<<C, R/binary>>, {in_tag, T}) -> step(R, {attr_name, T, <<(lower(C))>>});
%% attribute name
step(<<C, R/binary>>, {attr_name, T, A}) when ?WS(C) -> step(R, {after_attr_name, T, A});
step(<<$=, R/binary>>, {attr_name, T, A}) -> step(R, {before_value, T, A});
step(<<$>, R/binary>>, {attr_name, T, _}) -> open(T, R);
step(<<$/, R/binary>>, {attr_name, T, _}) -> step(R, {in_tag, T});
step(<<C, R/binary>>, {attr_name, T, A}) -> step(R, {attr_name, T, <<A/binary, (lower(C))>>});
step(<<C, R/binary>>, {after_attr_name, T, A}) when ?WS(C) -> step(R, {after_attr_name, T, A});
step(<<$=, R/binary>>, {after_attr_name, T, A}) -> step(R, {before_value, T, A});
step(<<$>, R/binary>>, {after_attr_name, T, _}) -> open(T, R);
step(<<$/, R/binary>>, {after_attr_name, T, _}) -> step(R, {in_tag, T});
step(<<C, R/binary>>, {after_attr_name, T, _}) -> step(R, {attr_name, T, <<(lower(C))>>});
%% attribute value
step(<<C, R/binary>>, {before_value, T, A}) when ?WS(C) -> step(R, {before_value, T, A});
%% the type of a <script> (first one wins, like in a browser) decides whether its content is data
step(<<Q, R/binary>>, {before_value, <<"script">> = T, <<"type">>}) when Q =:= $"; Q =:= $' ->
    step(R, {value, Q, T, {type, <<>>}});
step(<<Q, R/binary>>, {before_value, T, A}) when Q =:= $"; Q =:= $' -> step(R, {value, Q, T, A});
step(<<$>, R/binary>>, {before_value, T, _}) -> open(T, R);
step(<<_, R/binary>>, {before_value, T, A}) -> step(R, {unquoted, T, A});
step(<<Q, R/binary>>, {value, Q, T, {type, Type}}) -> step(R, {in_tag, typed_script(T, Type)});
step(<<C, R/binary>>, {value, Q, T, {type, Type}}) -> step(R, {value, Q, T, {type, <<Type/binary, (lower(C))>>}});
step(<<Q, R/binary>>, {value, Q, T, _}) -> step(R, {in_tag, T});
step(<<_, R/binary>>, {value, _, _, _} = Ctx) -> step(R, Ctx);
step(<<C, R/binary>>, {unquoted, T, _}) when ?WS(C) -> step(R, {in_tag, T});
step(<<$>, R/binary>>, {unquoted, T, _}) -> open(T, R);
step(<<_, R/binary>>, {unquoted, _, _} = Ctx) -> step(R, Ctx);
%% script / style content
step(<<"</", R/binary>>, {raw_text, T} = Ctx) ->
    case closes(R, base_tag(T)) of
        true -> step(R, end_tag);
        false -> step(R, Ctx)
    end;
step(<<_, R/binary>>, {raw_text, _} = Ctx) -> step(R, Ctx).

open(<<"script", _/binary>> = Tag, R) -> step(R, {raw_text, Tag});
open(<<"style">> = Tag, R) -> step(R, {raw_text, Tag});
open(_, R) -> step(R, text).

%% A script whose `type' is read is `script:data' (JSON that is data, not code) or `script:typed'
%% (anything else, which is not looked at again); a script without a `type' stays `script'.
typed_script(<<"script">>, Type) ->
    case data_type(string:trim(Type)) of
        true -> <<"script:data">>;
        false -> <<"script:typed">>
    end;
typed_script(T, _) ->
    T.

data_type(<<"application/json">>) -> true;
data_type(<<"application/ld+json">>) -> true;
data_type(<<"importmap">>) -> true;
data_type(<<"speculationrules">>) -> true;
data_type(<<"application/", Rest/binary>>) -> binary:longest_common_suffix([Rest, <<"+json">>]) =:= 5;
data_type(_) -> false.

%% @doc The element name without the marks of the tracker (`script:data' is a `script').
-spec base_tag(binary()) -> binary().
base_tag(<<"script", _/binary>>) -> <<"script">>;
base_tag(Tag) -> Tag.

%% @doc Where `{: json :}' may stand: `script' (the content of a `<script type="application/json">'
%% or another data type) or `attribute' (a quoted value of an attribute that takes plain text);
%% `none' elsewhere.
-spec json_context(ctx()) -> script | attribute | none.
json_context({raw_text, <<"script:data">>}) -> script;
json_context({value, _, _, Attr} = Ctx) ->
    case block_context(Ctx) of
        value -> case Attr of {type, _} -> none; _ -> attribute end;
        _ -> none
    end;
json_context(_) -> none.

context_word({raw_text, Tag}) -> case Tag of <<"script">> -> <<"script">>; <<"script:typed">> -> <<"script">>; _ -> base_tag(Tag) end;
context_word(text) -> text;
context_word({value, _, _, Attr}) when is_binary(Attr) -> Attr;
context_word(Ctx) when is_atom(Ctx) -> Ctx;
context_word(_) -> tag.

closes(R, Tag) ->
    N = byte_size(Tag),
    case R of
        <<Name:N/binary, After/binary>> ->
            string:lowercase(Name) =:= Tag andalso
                (After =:= <<>> orelse (case After of
                                            <<C, _/binary>> -> ?WS(C) orelse C =:= $> orelse C =:= $/
                                        end));
        _ ->
            false
    end.

lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.
