%% @doc Components: template files that views (and other components, and layouts) use with
%% `{: component name, #{key => Value} :} body {: /component :}'.
%%
%% ```
%% <!-- components/panel.weberl -->
%% {: param title :}
%% {: param open, false :}
%% <details class="panel" {: if @open :}open{: /if :}>
%%   <summary>{{ @title }}</summary>
%%   <div class="panel-body">{: content :}</div>
%% </details>
%% '''
%%
%% A component is read once, when the router starts ({@link load/2}): the files below the
%% router's `components' directories, named by their path without the extension
%% (`components/forms/field.weberl' is `forms/field'). It is checked alone, and its links are
%% analysed like those of a view; a use of it is checked where it stands.
%%
%% == Expansion ==
%% {@link expand/3} replaces every call by the component's template, inlined in the template
%% that makes the call, so regions, dependencies and the generated code of the page see ordinary
%% nodes. What it does for one call:
%% <ul>
%%   <li>the parameters become variables of a `{scope, Line, Binds, Children}' node: the values
%%       the call passes (or the defaults) are evaluated in the caller's scope and bound to them;</li>
%%   <li>inside the component, `@name' is such a variable, and its own locals are renamed for this
%%       use, so two uses (or a use inside the body of another) cannot clash. The component
%%       never reads the caller's assigns, and the caller's body never sees the component's names;</li>
%%   <li>`{: content :}' becomes the call's body and `{: slot name :}' the matching
%%       `{: fill name :}' of the call, or its own default, as in a layout.</li>
%% </ul>
%%
%% Errors, as `{error, {syntax_error, File, Line, Reason}}' (the file being the one the line is
%% in): `{unknown_component, Name}', `{component_cycle, Names}', `{missing_component_param, Name,
%% Param}', `{unknown_component_param, Name, Param}', `{unknown_fill, Slot, Name}',
%% `{component_without_content, Name}', and for a component file `{undeclared_assign, Name}',
%% `{param_not_at_top, Name}', `{duplicate_param, Name}', `{param_default_not_constant, Name}',
%% `{duplicate_content, Name}'; and `{duplicate_components, [{Name, Files}]}',
%% `{invalid_component_name, File}' when the files are loaded.
-module(weberl_template_component).

-export([load/2, parse/3, expand/3]).
-export_type([component/0, components/0]).

-opaque component() :: #{name := binary(), file := file:filename_all(),
                         params := [{atom(), required | {default, map()}}],
                         ast := weberl_template_parser:ast(), slots := [atom()],
                         content := boolean(), calls := [{pos_integer(), binary()}]}.
-type components() :: #{binary() => component()}.

%% ---------------------------------------------------------------------
%% Loading

%% @doc Read, check and analyse every component below `Dirs' (`routes' of `Opts' is the route
%% table the links are checked against). Names are the paths relative to the directory.
-spec load([file:filename()], map()) -> {ok, components()} | {error, term()}.
load(Dirs, Opts) ->
    Files = [{name(Dir, File), File} || Dir <- Dirs, File <- weberl_template:discover(Dir)],
    case [F || {error, F} <- Files] of
        [Bad | _] ->
            {error, {invalid_component_name, Bad}};
        [] ->
            Named = [{N, F} || {{ok, N}, F} <- Files],
            Groups = lists:foldl(fun({N, F}, Acc) -> maps:update_with(N, fun(L) -> [F | L] end, [F], Acc) end,
                                 #{}, Named),
            case [{N, lists:sort(Fs)} || {N, [_, _ | _] = Fs} <- lists:sort(maps:to_list(Groups))] of
                [] -> parse_all(Named, Opts);
                Dups -> {error, {duplicate_components, Dups}}
            end
    end.

%% `components/forms/field.weberl' is `forms/field'
name(Dir, File) ->
    Words = lists:nthtail(length(filename:split(Dir)), filename:split(File)),
    Base = lists:droplast(Words) ++ [filename:basename(lists:last(Words), ".weberl")],
    case lists:all(fun(W) -> re:run(W, "^[a-z][a-z0-9_]*$", [{capture, none}]) =:= match end, Base) of
        true -> {ok, unicode:characters_to_binary(lists:join("/", Base))};
        false -> {error, File}
    end.

parse_all(Named, Opts) ->
    Results = [{N, parse(F, N, Opts)} || {N, F} <- lists:sort(Named)],
    case [E || {_, {error, _} = E} <- Results] of
        [Error | _] ->
            Error;
        [] ->
            Components = maps:from_list([{N, C} || {N, {ok, C}} <- Results]),
            case graph(Components) of
                ok -> {ok, Components};
                {error, _} = Error -> Error
            end
    end.

%% Every component a component uses exists and none uses itself, even through others.
graph(Components) ->
    try
        [visit(Name, [], Components) || Name <- lists:sort(maps:keys(Components))],
        ok
    catch
        throw:{graph_error, Error} -> {error, Error}
    end.

visit(Name, Stack, Components) ->
    case lists:member(Name, Stack) of
        true ->
            #{file := File} = maps:get(Name, Components),
            throw({graph_error, {syntax_error, File, 1, {component_cycle, lists:reverse([Name | Stack])}}});
        false ->
            #{file := File, calls := Calls} = maps:get(Name, Components),
            [case Components of
                 #{Used := _} -> visit(Used, [Name | Stack], Components);
                 _ -> throw({graph_error, {syntax_error, File, Line, {unknown_component, Used}}})
             end || {Line, Used} <- Calls]
    end.

%% @doc Read and check one component file. `Name' is its name.
-spec parse(file:filename_all(), binary(), map()) -> {ok, component()} | {error, term()}.
parse(File, Name, Opts) ->
    case file:read_file(File) of
        {ok, Source} ->
            case unicode:characters_to_binary(Source, utf8, utf8) of
                Source -> parse_source(Source, File, Name, Opts);
                _ -> {error, {invalid_utf8, File}}
            end;
        {error, Posix} ->
            {error, {read_failed, File, Posix}}
    end.

parse_source(Source, File, Name, Opts) ->
    maybe
        {ok, Tokens} ?= weberl_template_lexer:tokenize(Source, File),
        {ok, Ast} ?= weberl_template_parser:parse(Tokens, File),
        ok ?= weberl_template_parser:validate_component(Ast, File),
        {ok, Params, Rest} ?= params(Ast, File),
        {ok, Content} ?= content(Rest, Name, File),
        Prepared = weberl_template_attrs:prepare(Rest),
        {ok, Analyzed, _Warnings} ?= weberl_template_urls:analyze(Prepared, File, maps:with([routes], Opts)),
        Component = #{name => Name, file => File, params => Params, ast => Analyzed,
                      slots => slot_names(Analyzed), content => Content, calls => calls(Analyzed)},
        %% every assign the file reads has to be a parameter
        ok ?= sweep_checked(Component),
        {ok, Component}
    end.

sweep_checked(#{ast := Ast, params := Params, file := File}) ->
    try sweep(Ast, 0, [P || {P, _} <- Params]) of
        _ -> ok
    catch throw:{undeclared, Assign, Line} ->
              {error, {syntax_error, File, Line, {undeclared_assign, Assign}}}
    end.

%% The `param' declarations open the file (white space around them is ignored); a later one is an error.
params(Ast, File) ->
    {Leading, Rest} = lists:splitwith(fun({param, _, _, _}) -> true; (N) -> blank(N) end, Ast),
    Declared = [N || {param, _, _, _} = N <- Leading],
    try
        Params = lists:foldl(
                   fun({param, Line, Param, Default}, Seen) ->
                           lists:keymember(Param, 1, Seen) andalso
                               throw({Line, {duplicate_param, Param}}),
                           Value = case Default of
                                       none -> required;
                                       #{assigns := [], free := []} -> {default, Default};
                                       _ -> throw({Line, {param_default_not_constant, Param}})
                                   end,
                           Seen ++ [{Param, Value}]
                   end, [], Declared),
        case misplaced_param(Rest) of
            {Line2, Param2} -> throw({Line2, {param_not_at_top, Param2}});
            none -> ok
        end,
        {ok, Params, trim_start(Rest)}
    catch
        throw:{Line3, Reason} -> {error, {syntax_error, File, Line3, Reason}}
    end.

%% White space between the declarations and the content is not part of the content.
trim_start([{text, Line, Bin} | Rest]) ->
    case string:trim(Bin, leading, " \t\r\n") of
        <<>> -> Rest;
        Trimmed -> [{text, Line + length(binary:matches(Bin, <<"\n">>)) - length(binary:matches(Trimmed, <<"\n">>)),
                     Trimmed} | Rest]
    end;
trim_start(Ast) ->
    Ast.

misplaced_param(Ast) ->
    lists:foldl(fun(_, {_, _} = Found) -> Found;
                   ({param, Line, Name, _}, none) -> {Line, Name};
                   (Node, none) ->
                        lists:foldl(fun(Children, none) -> misplaced_param(Children);
                                       (_, Found) -> Found
                                    end, none, weberl_template_parser:children(Node))
                end, none, Ast).

blank({text, _, Bin}) -> string:trim(Bin, both, " \t\r\n") =:= <<>>;
blank(_) -> false.

%% At most one `{: content :}'.
content(Ast, Name, File) ->
    case content_lines(Ast) of
        [] -> {ok, false};
        [_] -> {ok, true};
        [_, Second | _] -> {error, {syntax_error, File, Second, {duplicate_content, Name}}}
    end.

content_lines(Ast) ->
    lists:flatmap(fun({content, Line}) -> [Line];
                     (Node) -> lists:flatmap(fun content_lines/1, weberl_template_parser:children(Node))
                  end, Ast).

slot_names(Ast) ->
    lists:flatmap(fun({slot, _, Name, _}) -> [Name];
                     (Node) -> lists:flatmap(fun slot_names/1, weberl_template_parser:children(Node))
                  end, Ast).

%% The components a file calls, with the lines.
calls(Ast) ->
    lists:flatmap(fun(Node) ->
                          Own = case Node of {component, Line, Name, _, _} -> [{Line, Name}]; _ -> [] end,
                          Own ++ lists:flatmap(fun calls/1, weberl_template_parser:children(Node))
                  end, Ast).

%% ---------------------------------------------------------------------
%% One component for one use: the parameters are variables and the locals are renamed

%% The variable holding a parameter, and a renamed local, in the use numbered `Id'. A local is
%% capitalised or starts with `_', a parameter's name here starts with `p_': they cannot meet.
param_var(Id, Param) -> list_to_atom("_Weberl_c" ++ integer_to_list(Id) ++ "_p_" ++ atom_to_list(Param)).
local_var(Id, Name) -> list_to_atom("_Weberl_c" ++ integer_to_list(Id) ++ "_" ++ atom_to_list(Name)).

%% Rewrite a component's nodes: `@param' becomes the parameter's variable (any other assign is
%% `throw({undeclared, Assign, Line})'), locals get the use's prefix. The parsed facts follow the
%% forms: `assigns' empties, `free' gains the variables, `free' and `bound' are renamed.
sweep(Ast, Id, Params) ->
    sweep_term(Ast, #{id => Id, params => Params}, 1).

sweep_term({var, Anno, Name}, C, Line) when is_atom(Name), is_tuple(Anno) orelse is_integer(Anno) orelse is_list(Anno) ->
    sweep_var(Anno, Name, C, Line);
sweep_term(Map, C, Line) when is_map(Map) ->
    Line2 = maps:get(line, Map, Line),
    Renamed = maps:map(fun(free, Names) -> [rename(N, C) || N <- Names];
                          (bound, Names) -> [rename(N, C) || N <- Names];
                          (assigns, Assigns) -> Assigns;
                          (_, Value) -> sweep_term(Value, C, Line2)
                       end, Map),
    case Renamed of
        #{assigns := [_ | _] = Assigns} ->
            #{id := Id} = C,
            check_declared(Assigns, C, Line2),
            Free = maps:get(free, Renamed, []),
            Renamed#{assigns := [], free => lists:usort(Free ++ [param_var(Id, A) || A <- Assigns])};
        _ ->
            Renamed
    end;
sweep_term(Tuple, C, Line) when is_tuple(Tuple) ->
    list_to_tuple([sweep_term(E, C, Line) || E <- tuple_to_list(Tuple)]);
sweep_term([H | T], C, Line) ->
    [sweep_term(H, C, Line) | sweep_term(T, C, Line)];
sweep_term(Other, _C, _Line) ->
    Other.

sweep_var(Anno, '_', _C, _Line) ->
    {var, Anno, '_'};
sweep_var(Anno, Name, #{id := Id, params := Params} = C, Line) ->
    case atom_to_list(Name) of
        "_Weberl_assign_" ++ Assign ->
            Param = list_to_atom(Assign),
            check_declared([Param], C, line(Anno, Line)),
            {var, Anno, param_var(Id, Param)};
        _ ->
            _ = Params,
            {var, Anno, rename(Name, C)}
    end.

rename(Name, #{id := Id}) -> local_var(Id, Name).

check_declared(Assigns, #{params := Params}, Line) ->
    case [A || A <- Assigns, not lists:member(A, Params)] of
        [] -> ok;
        [Undeclared | _] -> throw({undeclared, Undeclared, Line})
    end.

line(Anno, Default) ->
    case erl_anno:line(Anno) of
        L when is_integer(L), L > 0 -> L;
        _ -> Default
    end.

%% ---------------------------------------------------------------------
%% Expansion

%% @doc Replace the component calls of a template by the components (see the module
%% documentation). `File' is the template's file, for the errors. Nothing is changed when
%% there is no call.
-spec expand(weberl_template_parser:ast(), components(), file:filename_all()) ->
    {ok, weberl_template_parser:ast()} | {error, term()}.
expand(Ast, Components, File) ->
    put(?MODULE, 0),
    try
        {ok, expand_nodes(Ast, #{components => Components, stack => [], in_region => false, file => File})}
    catch
        throw:{expand_error, ErrFile, Line, Reason} -> {error, {syntax_error, ErrFile, Line, Reason}}
    after
        erase(?MODULE)
    end.

expand_nodes(Nodes, Ctx) ->
    lists:flatmap(fun(Node) -> node_(Node, Ctx) end, Nodes).

node_({component, Line, Name, Params, Children}, Ctx) ->
    call(Line, Name, Params, Children, Ctx);
node_({region, _, _, _, _} = Node, Ctx) ->
    [weberl_template_parser:map_children(fun(Cs) -> expand_nodes(Cs, Ctx#{in_region := true}) end, Node)];
node_(Node, Ctx) ->
    [weberl_template_parser:map_children(fun(Cs) -> expand_nodes(Cs, Ctx) end, Node)].

call(Line, Name, Given, Children0, #{components := Components, stack := Stack, file := File} = Ctx) ->
    Fail = fun(ErrFile, ErrLine, Reason) -> throw({expand_error, ErrFile, ErrLine, Reason}) end,
    Comp = case Components of
               #{Name := C} -> C;
               _ -> Fail(File, Line, {unknown_component, Name})
           end,
    lists:member(Name, Stack) andalso Fail(File, Line, {component_cycle, lists:reverse([Name | Stack])}),
    #{params := Declared, ast := Ast, slots := Slots, content := HasContent, file := CompFile} = Comp,
    %% the body and the fills belong to the caller: its own calls are expanded first
    Children = expand_nodes(Children0, Ctx),
    {Fills, Body} = lists:partition(fun(N) -> element(1, N) =:= fill end, Children),
    case [K || {K, _} <- Given, not lists:keymember(K, 1, Declared)] of
        [Unknown | _] -> Fail(File, Line, {unknown_component_param, Name, Unknown});
        [] -> ok
    end,
    case [P || {P, required} <- Declared, not lists:keymember(P, 1, Given)] of
        [Missing | _] -> Fail(File, Line, {missing_component_param, Name, Missing});
        [] -> ok
    end,
    case [{FLine, FName} || {fill, FLine, FName, _} <- Fills, not lists:member(FName, Slots)] of
        [{FLine2, FName2} | _] -> Fail(File, FLine2, {unknown_fill, FName2, Name});
        [] -> ok
    end,
    case HasContent orelse lists:all(fun blank/1, Body) of
        true -> ok;
        false -> Fail(File, Line, {component_without_content, Name})
    end,
    Id = next_id(),
    Swept = try sweep(Ast, Id, [P || {P, _} <- Declared])
            catch throw:{undeclared, Assign, ULine} -> Fail(CompFile, ULine, {undeclared_assign, Assign})
            end,
    Placed = case Ctx of #{in_region := true} -> in_region(Swept); _ -> Swept end,
    Inner = expand_nodes(Placed, Ctx#{stack := [Name | Stack], file := CompFile}),
    Binds = [{param_var(Id, P), case {lists:keyfind(P, 1, Given), How} of
                                    {{P, Value}, _} -> Value;
                                    {false, {default, Default}} -> Default
                                end}
             || {P, How} <- Declared],
    [{scope, Line, Binds, splice(Inner, Body, Fills)}].

next_id() ->
    Id = get(?MODULE) + 1,
    put(?MODULE, Id),
    Id.

%% A form of a component used inside a region is re-rendered with the region, without a request.
in_region(Nodes) ->
    [case Node of
         {form, Line, Head, Children} -> {form, Line, Head#{in_region := true}, in_region(Children)};
         _ -> weberl_template_parser:map_children(fun in_region/1, Node)
     end || Node <- Nodes].

%% The marker and the slots may stand inside the branches of an `if' or `case' and the body of
%% another call, so everything here looks through any block.
splice(Ast, Body, Fills) ->
    lists:flatmap(fun({content, _}) -> Body;
                     ({slot, _, Name, Default}) ->
                          case lists:keyfind(Name, 3, Fills) of
                              {fill, _, _, Children} -> Children;
                              false -> splice(Default, Body, Fills)
                          end;
                     (Node) ->
                          [weberl_template_parser:map_children(
                             fun(Children) -> splice(Children, Body, Fills) end, Node)]
                  end, Ast).
