%% @doc Compiles a template AST into a generated Erlang module.
%%
%% For view `home_view' the module is `home_view__weberl_template' exporting
%% `render/1' (assigns map -> iodata) and `info/0'. The original view module is
%% never modified. The generated forms carry the template file as their source
%% file, so stack traces point at the template.
-module(weberl_template_compiler).

-export([generated_module/1, compile/3, compile/4]).

%% The element around a region: the `weberl-region' web component, or the
%% element the template asked for, marked with `data-weberl-region'. The browser
%% finds both by name.
wrapper(Name, default) ->
    {<<"<weberl-region name=\"", (atom_to_binary(Name))/binary, "\">">>, <<"</weberl-region>">>};
wrapper(Name, Tag) ->
    {<<"<", Tag/binary, " data-weberl-region=\"", (atom_to_binary(Name))/binary, "\">">>,
     <<"</", Tag/binary, ">">>}.

-spec generated_module(module()) -> module().
generated_module(View) ->
    list_to_atom(atom_to_list(View) ++ "__weberl_template").

%% @doc Compile an AST. Returns the generated module name and its object code;
%% nothing is loaded.
-spec compile(module(), weberl_template_parser:ast(), file:filename_all()) ->
    {ok, module(), binary()} | {error, term()}.
compile(View, Ast, File) ->
    compile(View, Ast, File, none).

%% @doc Like {@link compile/3}; `Layout' (the name of the layout the AST was
%% composed with, or `none') is recorded in `info/0'.
-spec compile(module(), weberl_template_parser:ast(), file:filename_all(), atom()) ->
    {ok, module(), binary()} | {error, term()}.
compile(View, Ast, File, Layout) ->
    Mod = generated_module(View),
    Forms = forms(Mod, View, Ast, File, Layout),
    case compile:forms(Forms, [return_errors, binary]) of
        {ok, Mod, Bin} -> {ok, Mod, Bin};
        {error, Errors, _Warnings} -> {error, {compile_failed, Errors}}
    end.

%% `render/1' renders the whole template. `render_region/2' renders the content
%% of one region (what goes inside its wrapper element) for the browser to swap
%% in; `info/0' lists the regions with their variables.
forms(Mod, View, Ast, File, Layout) ->
    Regions = weberl_template_parser:regions(Ast),
    Info = #{view => View, file => unicode:characters_to_binary(File),
             variables => weberl_template_parser:variables(Ast),
             regions => Regions, layout => Layout},
    RegionClauses = [{clause, Line, [{atom, Line, Name}, {var, Line, 'Assigns'}], [],
                      [body(Children, View)]}
                     || {Name, Line, Children} <- region_nodes(Ast)],
    Unknown = {clause, 1, [{var, 1, 'Region'}, {var, 1, '_Assigns'}], [],
               [{call, 1, {remote, 1, {atom, 1, erlang}, {atom, 1, error}},
                 [{tuple, 1, [{atom, 1, template_error},
                              {tuple, 1, [{atom, 1, unknown_region}, {atom, 1, View},
                                          {var, 1, 'Region'}]}]}]}]},
    [{attribute, 1, file, {unicode:characters_to_list(File), 1}},
     {attribute, 1, module, Mod},
     {attribute, 1, export, [{render, 1}, {render_region, 2}, {info, 0}]},
     {function, 1, render, 1,
      [{clause, 1, [{var, 1, 'Assigns'}], [], [body(Ast, View)]}]},
     {function, 1, render_region, 2, RegionClauses ++ [Unknown]},
     {function, 1, info, 0, [{clause, 1, [], [], [erl_parse:abstract(Info)]}]},
     {eof, 1}].

%% Every region (also the nested ones) with its content.
region_nodes(Ast) ->
    lists:flatmap(fun({region, Line, Name, _Tag, Children}) ->
                          [{Name, Line, Children} | region_nodes(Children)];
                     (_) -> []
                  end, Ast).

body([], _View) ->
    {nil, 1};
body([Node | Rest], View) ->
    {cons, 1, part(Node, View), body(Rest, View)}.

part({text, _Line, Bin}, _View) ->
    erl_parse:abstract(Bin);
part({region, Line, Name, Tag, Children}, View) ->
    {Open, Close} = wrapper(Name, Tag),
    {cons, Line, erl_parse:abstract(Open),
     {cons, Line, body(Children, View), {cons, Line, erl_parse:abstract(Close), {nil, Line}}}};
part({expr, Line, Mode, #{form := Form, source := Source}}, View) ->
    Fun = case Mode of escaped -> escaped; raw -> raw end,
    Value = weberl_blocks_expr:render(Form, hooks(View)),
    {call, Line, {remote, Line, {atom, Line, weberl_template_runtime}, {atom, Line, Fun}},
     [Value, {atom, Line, View}, erl_parse:abstract(Source, Line)]}.

%% What the expression front end needs from this consumer: an assign is read
%% from the `Assigns' argument of the generated function, and the template's
%% locals get a prefix so they cannot clash with the generated code's variables.
hooks(View) ->
    #{assign => fun(Name, A) ->
                        {call, A, {remote, A, {atom, A, weberl_template_runtime}, {atom, A, assign}},
                         [{atom, A, Name}, {var, A, 'Assigns'}, {atom, A, View}]}
                end,
      local => fun(Name) -> list_to_atom("W_" ++ atom_to_list(Name)) end}.
