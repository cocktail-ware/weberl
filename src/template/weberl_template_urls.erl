%% @doc Compile-time analysis of the interpolations inside URL attributes
%% (`href', `src', `action', ...). HANDOFF.md, decisions 8 and 9.
%%
%% An interpolation there has to be a value made by `weberl_url'. This pass walks the
%% template with the HTML context, and for each such interpolation:
%% <ul>
%%   <li>works out its policy (what the element accepts, `weberl_template_html:url_policy/2')
%%       and its position: `start' (the interpolation begins the value, so it is a whole
%%       URL) or `inner' (literal text or another interpolation comes before: a part);</li>
%%   <li>when the expression is a direct call of a `weberl_url' helper, checks it:
%%       helper against position and policy, literal arguments, and `router_path' /
%%       `router_url' against the route table (option `routes');</li>
%%   <li>rewrites `router_path("/docs/{{ @page }}")' into a call of
%%       `weberl_url:router_path_parts/2' with the literal parts and one expression per
%%       placeholder;</li>
%%   <li>annotates the node with `url => #{policy, position}', for the compiler to emit the
%%       render-time check (`weberl_template_runtime:url/4'), which covers what is not
%%       visible here (a value from an assign, a variable, another function).</li>
%% </ul>
%%
%% Errors, as `{error, {syntax_error, File, Line, Reason}}': `{unknown_route, Path}',
%% `{unverifiable_route, Helper}' (a route that is not a literal), `{not_a_path, Text}',
%% `{not_a_url, Text}', `{url_not_allowed_here, Helper, Tag, Attr}',
%% `{misplaced_url_helper, Helper}', `{untagged_url, Source}', `{bad_url_option, Key}'
%% and, for a placeholder, `{bad_placeholder, Reason}'. A placeholder whose value is not
%% known yet is a warning `{dynamic_route_segment, Pattern}' (`#{no_warn => true}' silences it).
-module(weberl_template_urls).

-export([analyze/3]).
-export_type([warning/0]).

-type warning() :: {warning, file:filename_all(), pos_integer(), term()}.

%% The part of the attribute value before the interpolation being read: the literal text
%% so far and how many interpolations came before.
-type value() :: none | #{prefix := binary(), interps := non_neg_integer()}.

%% @doc Analyze a composed AST. `Opts': `routes' (a `weberl_table:t()'; without it the
%% route checks that need the table are skipped).
-spec analyze(weberl_template_parser:ast(), file:filename_all(), map()) ->
    {ok, weberl_template_parser:ast(), [warning()]}
    | {error, {syntax_error, file:filename_all(), pos_integer(), term()}}.
analyze(Ast, File, Opts) ->
    Env = #{file => File, routes => maps:get(routes, Opts, none)},
    try walk(Ast, {text, none}, Env) of
        {Ast2, _} -> {ok, Ast2, warnings(Ast2, File)}
    catch
        throw:{url_error, Line, Reason} -> {error, {syntax_error, File, Line, Reason}}
    end.

%% ---------------------------------------------------------------------
%% The walk: HTML context and the attribute value being read

walk([], State, _Env) ->
    {[], State};
walk([{text, _, Bin} = Node | Rest], {Ctx, Val}, Env) ->
    Ctx2 = weberl_template_html:advance(Bin, Ctx),
    {Rest2, State} = walk(Rest, {Ctx2, value_after(Bin, Ctx, Ctx2, Val)}, Env),
    {[Node | Rest2], State};
walk([{expr, Line, escaped, Parsed} | Rest], {{value, _, Tag, Attr} = Ctx, Val}, Env) ->
    case weberl_template_html:url_attribute(Attr) of
        true ->
            Node = {expr, Line, escaped, url_expr(Parsed, Tag, Attr, Val, Line, Env)},
            {Rest2, State} = walk(Rest, {Ctx, bump(Val)}, Env),
            {[Node | Rest2], State};
        false ->
            {Rest2, State} = walk(Rest, {Ctx, bump(Val)}, Env),
            {[{expr, Line, escaped, Parsed} | Rest2], State}
    end;
walk([{expr, _, _, _} = Node | Rest], {Ctx, Val}, Env) ->
    {Rest2, State} = walk(Rest, {Ctx, bump(Val)}, Env),
    {[Node | Rest2], State};
walk([Node | Rest], State, Env) ->
    %% a region, block, slot or fill: it stands in text, and each of its children starts in text
    Node2 = weberl_template_parser:map_children(
              fun(Children) -> {Children2, _} = walk(Children, {text, none}, Env), Children2 end, Node),
    {Rest2, State2} = walk(Rest, State, Env),
    {[Node2 | Rest2], State2}.

bump(#{interps := N} = Val) -> Val#{interps := N + 1};
bump(Val) -> Val.

%% The attribute value after the text `Bin' (read from `Before' to `After').
-spec value_after(binary(), weberl_template_html:ctx(), weberl_template_html:ctx(), value()) -> value().
value_after(Bin, Before, {value, Q, _, _}, Val) ->
    case {Before, binary:matches(Bin, <<Q>>)} of
        {{value, _, _, _}, []} ->
            %% still the same value: more literal text
            Prefix = case Val of #{prefix := P} -> P; none -> <<>> end,
            Interps = case Val of #{interps := N} -> N; none -> 0 end,
            #{prefix => <<Prefix/binary, Bin/binary>>, interps => Interps};
        {_, [_ | _] = Matches} ->
            %% a value opened in this text: what follows its opening quote
            {Pos, _} = lists:last(Matches),
            #{prefix => binary:part(Bin, Pos + 1, byte_size(Bin) - Pos - 1), interps => 0};
        {_, []} ->
            none
    end;
value_after(_Bin, _Before, _After, _Val) ->
    none.

%% ---------------------------------------------------------------------
%% One interpolation in a URL attribute

url_expr(Parsed, Tag, Attr, Val, Line, Env) ->
    Policy = weberl_template_html:url_policy(Tag, Attr),
    {Prefix, Interps} = case Val of
                            #{prefix := P, interps := N} -> {P, N};
                            none -> {<<>>, 0}
                        end,
    Position = case {Prefix, Interps} of {<<>>, 0} -> start; _ -> inner end,
    C = #{policy => Policy, position => Position, tag => Tag, attr => Attr,
          prefix => Prefix, interps => Interps, line => Line, env => Env},
    Checked = analyze_form(maps:get(form, Parsed), Parsed, C),
    Checked#{url => #{policy => Policy, position => Position}}.

analyze_form({call, _, {remote, _, {atom, _, weberl_url}, {atom, _, Fun}}, Args}, Parsed, C) ->
    Kind = helper_kind(Fun, Parsed, C),
    check_position(Fun, Kind, C),
    check_literal(Fun, Args, C),
    case Kind of
        router_path -> route(Fun, Args, Parsed, C);
        router_url -> route(Fun, Args, Parsed, C);
        _ -> Parsed
    end;
analyze_form(Form, Parsed, #{line := Line}) ->
    case literal_text(Form) =/= error orelse is_literal(Form) of
        true -> throw({url_error, Line, {untagged_url, maps:get(source, Parsed)}});
        false -> Parsed
    end.

helper_kind(ensure_path, _, _) -> path;
helper_kind(url, _, _) -> url;
helper_kind(component, _, _) -> component;
helper_kind(query, _, _) -> query;
helper_kind(router_path, _, _) -> router_path;
helper_kind(router_url, _, _) -> router_url;
helper_kind(unsafe_url, _, _) -> unsafe;
helper_kind(_Other, Parsed, #{line := Line}) ->
    %% a function of weberl_url that does not make a URL value
    throw({url_error, Line, {untagged_url, maps:get(source, Parsed)}}).

%% The helper against where it stands: `start' takes a whole URL (a path, or an absolute
%% URL where the element allows it), `inner' takes an encoded part; `unsafe_url' anywhere.
check_position(_Fun, unsafe, _C) ->
    ok;
check_position(Fun, Kind, #{position := start, line := Line}) when Kind =:= component; Kind =:= query ->
    throw({url_error, Line, {misplaced_url_helper, Fun}});
check_position(Fun, Kind, #{position := inner, line := Line}) when Kind =/= component, Kind =/= query ->
    throw({url_error, Line, {misplaced_url_helper, Fun}});
check_position(Fun, Kind, #{position := start, policy := local_only, tag := Tag, attr := Attr, line := Line})
  when Kind =:= url; Kind =:= router_url ->
    throw({url_error, Line, {url_not_allowed_here, Fun, Tag, Attr}});
check_position(Fun, _Kind, #{position := inner, policy := local_only, interps := 0, prefix := Prefix,
                             tag := Tag, attr := Attr, line := Line}) ->
    %% a part on an element that loads code: the literal text before it has to be a local path
    case weberl_url:local(Prefix) of
        true -> ok;
        false -> throw({url_error, Line, {url_not_allowed_here, Fun, Tag, Attr}})
    end;
check_position(_Fun, _Kind, _C) ->
    ok.

%% A literal argument is run through the helper itself, so the error is the helper's.
check_literal(Fun, [Arg | _], #{line := Line}) when Fun =:= ensure_path; Fun =:= url ->
    case literal_text(Arg) of
        {ok, Text} ->
            try weberl_url:Fun(unicode:characters_to_binary(Text))
            catch error:{template_error, Reason} -> throw({url_error, Line, literal_reason(Reason, Text)})
            end,
            ok;
        error ->
            ok
    end;
check_literal(_Fun, _Args, _C) ->
    ok.

literal_reason({not_a_path, _}, Text) -> {not_a_path, unicode:characters_to_binary(Text)};
literal_reason({not_a_url, _}, Text) -> {not_a_url, unicode:characters_to_binary(Text)};
literal_reason(Reason, _Text) -> Reason.

%% ---------------------------------------------------------------------
%% router_path / router_url

%% The route has to be a literal string (placeholders allowed). With the route table the
%% call is verified and rewritten to carry the routes it can match, so the render-time
%% check needs no router; without the table it is rewritten to the parts form, which
%% looks the router up when rendered.
route(Fun, Args, Parsed, #{line := Line} = C) ->
    {First, OptsForm} = case Args of
                            [F] -> {F, none};
                            [F, O] -> {F, O};
                            _ -> throw({url_error, Line, {bad_url_option, {arity, length(Args)}}})
                        end,
    Opts = options(OptsForm, Line),
    case literal_text(First) of
        {ok, Text} -> route_parts(Fun, unicode:characters_to_binary(Text), OptsForm, Opts, Parsed, C);
        error -> throw({url_error, Line, {unverifiable_route, Fun}})
    end.

route_parts(Fun, Route, OptsForm, Opts, Parsed, #{line := Line} = C) ->
    Parts = split(Route, Line),
    case Parts of
        [{lit, First = <<"/", _/binary>>} | _] ->
            weberl_url:local(First) orelse throw({url_error, Line, {not_a_path, Route}});
        _ ->
            throw({url_error, Line, {not_a_path, Route}})
    end,
    Dynamic = [Seg || {seg, Seg} <- Parts],
    Known = case table(Opts, C) of
                none -> none;
                Table -> matching(Parts, Dynamic, Route, Table, Line)
            end,
    Warnings = case {Dynamic, maps:get(no_warn, Opts, false)} of
                   {[], _} -> [];
                   {_, true} -> [];
                   {_, false} -> [{dynamic_route_segment, Route}]
               end,
    PartForms = [part_form(P, Line) || P <- Parts],
    List = lists:foldr(fun(F, Acc) -> {cons, Line, F, Acc} end, {nil, Line}, PartForms),
    OptForm = case OptsForm of none -> {map, Line, []}; _ -> OptsForm end,
    Call = case Known of
               none ->
                   call(parts_fun(Fun), [List, OptForm], Line);
               _ ->
                   call(known_fun(Fun), [List, erl_parse:abstract(Known, Line), OptForm], Line)
           end,
    Assigns = lists:usort(maps:get(assigns, Parsed) ++ lists:append([maps:get(assigns, S) || S <- Dynamic])),
    Free = lists:usort(maps:get(free, Parsed) ++ lists:append([maps:get(free, S) || S <- Dynamic])),
    Parsed#{form := Call, assigns := Assigns, free := Free, warnings => Warnings}.

parts_fun(router_path) -> router_path_parts;
parts_fun(router_url) -> router_url_parts.

known_fun(router_path) -> router_path_known;
known_fun(router_url) -> router_url_known.

call(Fun, Args, Line) ->
    {call, Line, {remote, Line, {atom, Line, weberl_url}, {atom, Line, Fun}}, Args}.

%% The routes of the table the call can match, as a map for the render-time lookup: the
%% one a literal route names, or every route with the shape of a pattern. None is an error.
matching(Parts, [], Route, Table, Line) ->
    [{lit, Bin}] = Parts,
    case weberl_table:lookup(unicode:characters_to_list(Bin), Table) of
        {ok, R} -> #{unicode:characters_to_binary(weberl_route:path(R)) => []};
        {error, not_found} -> throw({url_error, Line, {unknown_route, Route}})
    end;
matching(Parts, _Dynamic, Route, Table, Line) ->
    case [unicode:characters_to_binary(P) || P <- route_paths(Table), shape_matches(Parts, P)] of
        [] -> throw({url_error, Line, {unknown_route, Route}});
        Paths -> maps:from_list([{P, []} || P <- Paths])
    end.

%% The literal options of the call: `no_warn' and `router'. A key that is not an option is
%% an error here; anything that is not a literal is left to the render-time check.
options({map, _, Fields}, Line) ->
    lists:foldl(fun({map_field_assoc, _, {atom, _, Key}, Value}, Acc) ->
                        case lists:member(Key, [router, query, no_warn]) of
                            false -> throw({url_error, Line, {bad_url_option, Key}});
                            true -> literal_option(Key, Value, Acc)
                        end;
                   (_, Acc) -> Acc
                end, #{}, Fields);
options(_, _) ->
    #{}.

literal_option(no_warn, {atom, _, B}, Acc) when is_boolean(B) -> Acc#{no_warn => B};
literal_option(router, {atom, _, Name}, Acc) -> Acc#{router => Name};
literal_option(_, _, Acc) -> Acc.

%% The table to check against: the named router's when the call names one that is running,
%% else the table the template is compiled with (`none' for neither).
table(#{router := Name}, _C) ->
    case weberl_router_server:table(Name) of
        {ok, Table} -> Table;
        {error, not_running} -> none
    end;
table(_Opts, #{env := #{routes := Routes}}) ->
    Routes.

part_form({lit, Bin}, Line) ->
    {tuple, Line, [{atom, Line, lit}, erl_parse:abstract(Bin, Line)]};
part_form({seg, #{form := Form}}, Line) ->
    {tuple, Line, [{atom, Line, seg}, Form]}.

%% The literal parts and the parsed expressions of the placeholders of a route string.
split(Bin, Line) -> split(Bin, Line, []).

split(<<>>, _Line, Acc) ->
    lists:reverse(Acc);
split(Bin, Line, Acc) ->
    case binary:match(Bin, <<"{{">>) of
        nomatch ->
            lists:reverse([{lit, Bin} | Acc]);
        {Pos, 2} ->
            Before = binary:part(Bin, 0, Pos),
            Rest = binary:part(Bin, Pos + 2, byte_size(Bin) - Pos - 2),
            case weberl_blocks_expr:tag_end(Rest, <<"}}">>) of
                {ok, End} ->
                    Text = binary:part(Rest, 0, End),
                    After = binary:part(Rest, End + 2, byte_size(Rest) - End - 2),
                    string:trim(Text, both, " \t\r\n") =/= <<>>
                        orelse throw({url_error, Line, {bad_placeholder, empty}}),
                    Seg = case weberl_blocks_expr:expression(Text, Line) of
                              {ok, Parsed} -> Parsed;
                              {error, Reason} -> throw({url_error, Line, {bad_placeholder, Reason}})
                          end,
                    Acc2 = [{seg, Seg} | [{lit, Before} || Before =/= <<>>] ++ Acc],
                    split(After, Line, Acc2);
                {error, Reason} ->
                    throw({url_error, Line, {bad_placeholder, Reason}})
            end
    end.

route_paths(Table) ->
    [weberl_route:path(R) || R <- weberl_table:routes(Table)].

%% Does a route path have the shape of the parts? A placeholder is one non-empty segment
%% (or the non-empty text between two literals inside a segment).
shape_matches(Parts, Path) ->
    Regex = iolist_to_binary(["^", [shape_regex(P) || P <- trim_slash(Parts)], "$"]),
    case re:compile(Regex, [unicode]) of
        {ok, MP} -> re:run(Path, MP, [{capture, none}]) =:= match;
        {error, _} -> false
    end.

shape_regex({lit, Bin}) -> re:replace(Bin, <<"[\\\\.^$*+?()\\[\\]{}|]">>, <<"\\\\&">>, [global, {return, binary}]);
shape_regex({seg, _}) -> <<"[^/]+">>.

%% Routes have no trailing slash (the root is `/'): neither does the pattern.
trim_slash([{lit, <<"/">>}]) ->
    [{lit, <<"/">>}];
trim_slash(Parts) ->
    case lists:last(Parts) of
        {lit, Bin} -> lists:droplast(Parts) ++ [{lit, string:trim(Bin, trailing, "/")}];
        _ -> Parts
    end.

%% ---------------------------------------------------------------------
%% Literals of the expression forms

%% The text of a literal string, `<<"...">>' or atom.
literal_text({string, _, S}) -> {ok, S};
literal_text({bin, _, [{bin_element, _, {string, _, S}, default, default}]}) -> {ok, S};
literal_text({atom, _, A}) -> {ok, atom_to_list(A)};
literal_text(_) -> error.

is_literal({integer, _, _}) -> true;
is_literal({float, _, _}) -> true;
is_literal({nil, _}) -> true;
is_literal({bin, _, _}) -> true;
is_literal(_) -> false.

%% ---------------------------------------------------------------------
%% Warnings

warnings(Ast, File) ->
    lists:flatmap(fun(Node) ->
                          Own = case Node of
                                    {expr, Line, _, #{warnings := W}} -> [{warning, File, Line, X} || X <- W];
                                    _ -> []
                                end,
                          Own ++ lists:flatmap(fun(Children) -> warnings(Children, File) end,
                                               weberl_template_parser:children(Node))
                  end, Ast).
