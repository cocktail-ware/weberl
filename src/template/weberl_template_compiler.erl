%% @doc Compiles a template AST into a generated Erlang module.
%%
%% For view `home_view' the module is `home_view__weberl_template' exporting
%% `render/1' (assigns map -> iodata) and `info/0'. The original view module is
%% never modified. The generated forms carry the template file as their source
%% file, so stack traces point at the template.
-module(weberl_template_compiler).

-export([generated_module/1, generated_module/2, compile/3, compile/4, compile/5]).

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

%% @doc The module of one (view, layout) pair, `none' being the bare view:
%% `home_view__weberl_template__admin'. (The default pair is also `generated_module/1'.)
-spec generated_module(module(), atom()) -> module().
generated_module(View, Layout) ->
    list_to_atom(atom_to_list(View) ++ "__weberl_template__" ++ atom_to_list(Layout)).

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
    compile(View, Ast, File, Layout, #{}).

%% @doc Like {@link compile/4}. Options: `variant' (the module is the one of the (view, layout)
%% pair `variant', see {@link generated_module/2}, instead of the default pair's) and `layouts'
%% (the layouts the view may be rendered with, recorded in `info/0').
-spec compile(module(), weberl_template_parser:ast(), file:filename_all(), atom(),
              #{variant => atom(), layouts => [atom()]}) ->
    {ok, module(), binary()} | {error, term()}.
compile(View, Ast, File, Layout, Opts) ->
    Mod = case maps:find(variant, Opts) of
              {ok, Variant} -> generated_module(View, Variant);
              error -> generated_module(View)
          end,
    Forms = forms(Mod, View, Ast, File, Layout, maps:get(layouts, Opts, [Layout])),
    case compile:forms(Forms, [return_errors, binary]) of
        {ok, Mod, Bin} -> {ok, Mod, Bin};
        {error, Errors, _Warnings} -> {error, {compile_failed, Errors}}
    end.

%% `render/1' renders the whole template. `render_region/2' renders the content
%% of one region (what goes inside its wrapper element) for the browser to swap
%% in; `info/0' lists the regions with their variables.
forms(Mod, View, Ast, File, Layout, Layouts) ->
    Regions = weberl_template_parser:regions(Ast),
    Info = #{view => View, file => unicode:characters_to_binary(File),
             variables => weberl_template_parser:variables(Ast),
             regions => Regions, layout => Layout, layouts => Layouts},
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

%% Every region (also the nested ones, and those inside blocks) with its content.
region_nodes(Ast) ->
    lists:flatmap(fun(Node) ->
                          Inner = lists:flatmap(fun region_nodes/1, weberl_template_parser:children(Node)),
                          case Node of
                              {region, Line, Name, _Tag, Children} -> [{Name, Line, Children} | Inner];
                              _ -> Inner
                          end
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
%% inside a URL attribute: only a `weberl_url' value, checked against the attribute
part({expr, Line, escaped, #{form := Form, url := #{policy := Policy, position := Position}}}, View) ->
    Value = weberl_blocks_expr:render(Form, hooks(View)),
    {call, Line, {remote, Line, {atom, Line, weberl_template_runtime}, {atom, Line, url}},
     [Value, {atom, Line, View}, {integer, Line, Line},
      erl_parse:abstract({Policy, Position}, Line)]};
part({expr, Line, Mode, #{form := Form, source := Source}}, View) ->
    Fun = case Mode of escaped -> escaped; raw -> raw; json_script -> json_script; json_attr -> json_attr end,
    Value = weberl_blocks_expr:render(Form, hooks(View)),
    {call, Line, {remote, Line, {atom, Line, weberl_template_runtime}, {atom, Line, Fun}},
     [Value, {atom, Line, View}, erl_parse:abstract(Source, Line)]};
%% `{: form Action [, Opts] :}' ... `{: /form :}': the opening tag (with the CSRF field) is written by
%% the runtime, the closing tag is literal.
part({form, Line, #{action := #{form := ActionForm, url := #{policy := Policy, position := Position}} = _Action,
                    opts := Opts, in_region := InRegion}, Children}, View) ->
    ActionValue = weberl_blocks_expr:render(ActionForm, hooks(View)),
    OptsValue = case Opts of
                    none -> {map, Line, []};
                    #{form := OptsForm} -> weberl_blocks_expr:render(OptsForm, hooks(View))
                end,
    Open = {call, Line, {remote, Line, {atom, Line, weberl_template_runtime}, {atom, Line, form_open}},
            [ActionValue, OptsValue, {atom, Line, View}, {integer, Line, Line}, {atom, Line, InRegion},
             erl_parse:abstract({Policy, Position}, Line)]},
    {cons, Line, Open, {cons, Line, body(Children, View), {cons, Line, erl_parse:abstract(<<"</form>">>, Line), {nil, Line}}}};
%% `if' / `elif' / `else': each condition has to be exactly `true' or `false'.
part({'if', Line, Branches, Else}, View) ->
    if_chain(Branches, Else, Line, View);
%% `case': the clauses as written, and a last one for a value nothing matches.
part({'case', Line, #{form := Form}, Clauses}, View) ->
    Hooks = hooks(View),
    Scrutinee = weberl_blocks_expr:render(Form, Hooks),
    %% A guard cannot call a function, so the assigns the guards read are fetched
    %% first and passed in as the arguments of a fun that holds the `case'.
    GuardAssigns = lists:usort(lists:append([A || {#{assigns := A}, _} <- Clauses])),
    GuardHooks = Hooks#{assign := fun(Name, A) -> {var, A, guard_var(Name)} end},
    Branches = [{clause, Line, [weberl_blocks_expr:render(Pattern, Hooks)],
                 weberl_blocks_expr:render(Guard, GuardHooks), [body(Children, View)]}
                || {#{pattern := Pattern, guard := Guard}, Children} <- Clauses],
    Case = {'case', Line, Scrutinee, Branches ++ [no_clause(case_clause, Line, View)]},
    case GuardAssigns of
        [] ->
            Case;
        _ ->
            Read = maps:get(assign, Hooks),
            Fun = {'fun', Line, {clauses, [{clause, Line, [{var, Line, guard_var(N)} || N <- GuardAssigns],
                                            [], [Case]}]}},
            {call, Line, Fun, [Read(N, Line) || N <- GuardAssigns]}
    end;
%% `for': a list comprehension building the pieces; `empty' when it built none.
part({'for', Line, #{qualifiers := Quals}, Body, Empty}, View) ->
    Hooks = hooks(View),
    Comprehension = {lc, Line, body(Body, View), weberl_blocks_expr:render(Quals, Hooks)},
    case Empty of
        none ->
            Comprehension;
        _ ->
            {'case', Line, Comprehension,
             [{clause, Line, [{nil, Line}], [], [body(Empty, View)]},
              {clause, Line, [{var, Line, 'Items'}], [], [{var, Line, 'Items'}]}]}
    end.

if_chain([{#{form := Form, line := CondLine}, Children} | Rest], Else, Line, View) ->
    Cond = weberl_blocks_expr:render(Form, hooks(View)),
    Otherwise = case Rest of
                    [] when Else =:= none -> {nil, Line};
                    [] -> body(Else, View);
                    _ -> if_chain(Rest, Else, Line, View)
                end,
    {'case', CondLine, Cond,
     [{clause, CondLine, [{atom, CondLine, true}], [], [body(Children, View)]},
      {clause, CondLine, [{atom, CondLine, false}], [], [Otherwise]},
      no_clause(not_boolean, CondLine, View)]}.

%% The variable holding an assign read by a `case' guard (cannot clash with a
%% template local: those are `W_' and a capital or underscore).
guard_var(Name) -> list_to_atom("W_guard_" ++ atom_to_list(Name)).

%% `error({template_error, {Reason, View, Line, Value}})' for a value no clause took.
no_clause(Reason, Line, View) ->
    {clause, Line, [{var, Line, 'Value'}], [],
     [{call, Line, {remote, Line, {atom, Line, erlang}, {atom, Line, error}},
       [{tuple, Line, [{atom, Line, template_error},
                       {tuple, Line, [{atom, Line, Reason}, {atom, Line, View},
                                      {integer, Line, Line}, {var, Line, 'Value'}]}]}]}]}.

%% What the expression front end needs from this consumer: an assign is read
%% from the `Assigns' argument of the generated function, and the template's
%% locals get a prefix so they cannot clash with the generated code's variables.
hooks(View) ->
    #{assign => fun(Name, A) ->
                        {call, A, {remote, A, {atom, A, weberl_template_runtime}, {atom, A, assign}},
                         [{atom, A, Name}, {var, A, 'Assigns'}, {atom, A, View}]}
                end,
      local => fun(Name) -> list_to_atom("W_" ++ atom_to_list(Name)) end}.
