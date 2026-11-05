%% @doc Minimal HTML context tracker used to validate where interpolation may
%% appear. It is not an HTML parser: it follows just enough of the tokenizer
%% states (text, comments, tags, attributes, `script'/`style' content) to know
%% where a `{{ @name }}' sits.
%%
%% HTML escaping makes a value safe in text and in quoted attribute values, and
%% nowhere else. Interpolation is therefore only allowed in:
%% <ul>
%%   <li>text nodes (escaped or raw);</li>
%%   <li>quoted attribute values (escaped only), except in URL-bearing
%%       attributes (`href', `src', ...), event handlers (`on*'), `style' and a
%%       few similar attributes, which need context-specific encoding.</li>
%% </ul>
-module(weberl_template_html).

-export([initial/0, advance/2, check/2]).
-export_type([ctx/0]).

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
-spec check(ctx(), escaped | raw) -> ok | {error, term()}.
check(text, _) -> ok;
check({value, _, _, Attr}, Mode) ->
    case {Mode, restricted(Attr)} of
        {raw, _} -> {error, {raw_interpolation_in_attribute, Attr}};
        {_, true} -> {error, {interpolation_in_restricted_attribute, Attr}};
        _ -> ok
    end;
check(comment, _) -> unsupported(comment);
check({raw_text, Tag}, _) -> unsupported(Tag);
check({unquoted, _, _}, _) -> unsupported(unquoted_attribute);
check({before_value, _, _}, _) -> unsupported(unquoted_attribute);
check(declaration, _) -> unsupported(declaration);
check(end_tag, _) -> unsupported(end_tag);
check(_, _) -> unsupported(tag).

unsupported(Where) -> {error, {interpolation_in_unsupported_context, Where}}.

restricted(<<"on", _/binary>>) -> true;
restricted(Attr) ->
    lists:member(Attr, [<<"style">>, <<"href">>, <<"src">>, <<"srcset">>, <<"action">>,
                        <<"formaction">>, <<"data">>, <<"poster">>, <<"cite">>,
                        <<"background">>, <<"ping">>, <<"manifest">>, <<"codebase">>,
                        <<"longdesc">>, <<"usemap">>, <<"srcdoc">>, <<"xlink:href">>,
                        <<"is">>]).

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
step(<<Q, R/binary>>, {before_value, T, A}) when Q =:= $"; Q =:= $' -> step(R, {value, Q, T, A});
step(<<$>, R/binary>>, {before_value, T, _}) -> open(T, R);
step(<<_, R/binary>>, {before_value, T, A}) -> step(R, {unquoted, T, A});
step(<<Q, R/binary>>, {value, Q, T, _}) -> step(R, {in_tag, T});
step(<<_, R/binary>>, {value, _, _, _} = Ctx) -> step(R, Ctx);
step(<<C, R/binary>>, {unquoted, T, _}) when ?WS(C) -> step(R, {in_tag, T});
step(<<$>, R/binary>>, {unquoted, T, _}) -> open(T, R);
step(<<_, R/binary>>, {unquoted, _, _} = Ctx) -> step(R, Ctx);
%% script / style content
step(<<"</", R/binary>>, {raw_text, T} = Ctx) ->
    case closes(R, T) of
        true -> step(R, end_tag);
        false -> step(R, Ctx)
    end;
step(<<_, R/binary>>, {raw_text, _} = Ctx) -> step(R, Ctx).

open(Tag, R) when Tag =:= <<"script">>; Tag =:= <<"style">> -> step(R, {raw_text, Tag});
open(_, R) -> step(R, text).

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
