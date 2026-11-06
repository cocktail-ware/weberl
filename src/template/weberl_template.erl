%% @doc Template engine entry point.
%%
%% A view module `home_view' may have a template `home_view.weberl' in the same
%% directory as `home_view.erl'. Templates are compiled once into a generated
%% module (`home_view__weberl_template', see `weberl_template_compiler') and
%% rendered from there; rendering never touches the file or the parser again.
%%
%% ```
%% handle(_Req) ->
%%     weberl_response:html(200, weberl_template:render(?MODULE, #{title => <<"Hi">>})).
%% '''
%%
%% == Syntax ==
%% `{{ Expr }}' inserts the value of an Erlang expression, HTML-escaped;
%% `{{{ Expr }}}' inserts it unescaped (unsafe for untrusted input). An assign is
%% only ever written `@name' (`{{ @title }}'; looked up as an atom key in the
%% assigns map): a bare `name' is the atom `name', rendered as the text `name'.
%% Capitalized names are local variables (bound by blocks, which come later).
%% Everything else is literal. `\{{' writes a literal `{{'. Supported values:
%% UTF-8 binaries, character lists, integers, floats and atoms (their name).
%% The tag ends at the first `}}' outside the Erlang inside (strings, atoms and brackets
%% are read, see `weberl_blocks_expr:tag_end/2'). See `weberl_blocks_expr' for the
%% expression language.
%%
%% Interpolation is allowed in HTML text and in quoted attribute values only
%% (see `weberl_template_html'); other places are rejected at compile time. In a URL
%% attribute (`href', `src', ...) it has to be a value made by `weberl_url', checked
%% against the element and, with `compile_source/5' and a route table, against the routes
%% (see `weberl_template_urls' and the README, "Links").
%%
%% == Regions ==
%% `{: region cart :} ... {: /region cart :}' marks a part of the page the server
%% can re-render alone (see {@link render_region/3}). It is written as the web
%% component `<weberl-region name="cart">' around the content, or, with
%% `{: region rows tag=tbody :}', as that element with
%% `data-weberl-region="rows"' (a custom element is not valid inside tables,
%% lists or selects). A region starts and ends in HTML text, may nest, and its
%% name is used once per template. `\{:' writes a literal `{:'.
%%
%% == Lifecycle ==
%% Templates are compiled and loaded when a router starts (see `weberl_views'),
%% or explicitly with {@link compile_and_load_file/2}. Loaded code stays until
%% the same view is compiled again (that replaces it); there is no file
%% watching. To pick up an edited template, restart the router.
%%
%% == Errors ==
%% Compilation returns `{error, Reason}': `{syntax_error, File, Line, Reason}',
%% `{invalid_utf8, File}', `{read_failed, File, Posix}' or
%% `{compile_failed, Errors}'. {@link render/2} raises
%% `error({template_error, Reason})' (`{no_template, View}',
%% `{invalid_assigns, View, Assigns}', `{missing_variable, View, Name}',
%% `{unsupported_value, View, Source, Value}', `Source' being the expression as
%% written); {@link try_render/2} returns
%% `{error, Reason}' instead.
-module(weberl_template).

-export([render/2, try_render/2, render_region/3, try_render_region/3, regions/1,
         has_template/1, generated_module/1, layout/1,
         compile_source/3, compile_source/4, compile_source/5, compile_file/2, compile_file/3, compile_file/4,
         parse_layout/1, load/1, compile_and_load_file/2, warnings/1,
         discover/1, associate/2]).
-export_type([compiled/0, layout/0, compile_opts/0]).

-opaque compiled() :: {module(), binary(), file:filename_all(), [weberl_template_urls:warning()]}.
-type layout() :: weberl_template_layout:layout().
%% `routes': the route table links are checked against at compile time (without it the
%% checks that need the table are skipped, and the render-time check still runs).
-type compile_opts() :: #{routes => weberl_table:t()}.

%% ---------------------------------------------------------------------------
%% Rendering

-spec render(module(), map()) -> iodata().
render(View, Assigns) when is_atom(View), is_map(Assigns) ->
    Mod = generated_module(View),
    case code:ensure_loaded(Mod) of
        {module, Mod} -> Mod:render(Assigns);
        {error, _} -> erlang:error({template_error, {no_template, View}})
    end;
render(View, Assigns) ->
    erlang:error({template_error, {invalid_assigns, View, Assigns}}).

%% @doc Like {@link render/2}, returning `{error, Reason}' instead of raising. An
%% expression of the template that raises (a `for' over something that is not a
%% list, a division by zero...) is `{error, {render_failed, Class, Reason}}': the
%% template is developer code, but one bad value must not take down the caller.
-spec try_render(module(), map()) -> {ok, iodata()} | {error, term()}.
try_render(View, Assigns) ->
    try
        {ok, render(View, Assigns)}
    catch
        error:{template_error, Reason} -> {error, Reason};
        Class:Reason -> {error, {render_failed, Class, Reason}}
    end.

%% @doc Render the content of one region (what the browser puts inside the
%% region's wrapper element) with the given assigns, which only need the
%% variables that region uses. Raises `error({template_error, Reason})' like
%% {@link render/2}, with `{unknown_region, View, Region}' for a region the
%% template does not have.
-spec render_region(module(), atom(), map()) -> iodata().
render_region(View, Region, Assigns) when is_atom(View), is_atom(Region), is_map(Assigns) ->
    Mod = generated_module(View),
    case code:ensure_loaded(Mod) of
        {module, Mod} -> Mod:render_region(Region, Assigns);
        {error, _} -> erlang:error({template_error, {no_template, View}})
    end;
render_region(View, _Region, Assigns) ->
    erlang:error({template_error, {invalid_assigns, View, Assigns}}).

%% @doc Like {@link render_region/3}, returning `{error, Reason}' instead of
%% raising; what a live page uses to re-render a region, so a failing expression
%% is logged and the page's session goes on (see {@link try_render/2}).
-spec try_render_region(module(), atom(), map()) -> {ok, iodata()} | {error, term()}.
try_render_region(View, Region, Assigns) ->
    try
        {ok, render_region(View, Region, Assigns)}
    catch
        error:{template_error, Reason} -> {error, Reason};
        Class:Reason -> {error, {render_failed, Class, Reason}}
    end.

%% @doc The regions of a view's template with their variables
%% (`Name => #{tag, line, variables}').
-spec regions(module()) -> {ok, map()} | {error, {no_template, module()}}.
regions(View) ->
    Mod = generated_module(View),
    case code:ensure_loaded(Mod) of
        {module, Mod} -> {ok, maps:get(regions, Mod:info())};
        {error, _} -> {error, {no_template, View}}
    end.

%% @doc The layout the view's template was compiled with: `{ok, Name}', or
%% `{ok, none}' for a standalone page (the layout of the view's route options).
-spec layout(module()) -> {ok, atom()} | {error, {no_template, module()}}.
layout(View) ->
    Mod = generated_module(View),
    case code:ensure_loaded(Mod) of
        {module, Mod} -> {ok, maps:get(layout, Mod:info())};
        {error, _} -> {error, {no_template, View}}
    end.

%% @doc Is a compiled template loaded (or loadable) for this view?
-spec has_template(module()) -> boolean().
has_template(View) ->
    case code:ensure_loaded(generated_module(View)) of
        {module, _} -> true;
        {error, _} -> false
    end.

-spec generated_module(module()) -> module().
generated_module(View) -> weberl_template_compiler:generated_module(View).

%% ---------------------------------------------------------------------------
%% Compilation

%% @doc Lex, parse, validate and compile template source. `File' is only used
%% in error messages and stack traces. Nothing is loaded.
-spec compile_source(module(), binary(), file:filename_all()) ->
    {ok, compiled()} | {error, term()}.
compile_source(View, Source, File) ->
    compile_source(View, Source, File, none).

%% @doc Like {@link compile_source/3}, with the template put into a layout
%% (`parse_layout/1'; `none' for a standalone page). See `weberl_template_layout'.
-spec compile_source(module(), binary(), file:filename_all(), none | layout()) ->
    {ok, compiled()} | {error, term()}.
compile_source(View, Source, File, Layout) ->
    compile_source(View, Source, File, Layout, #{}).

%% @doc Like {@link compile_source/4}, with options (`routes', see `compile_opts()').
%% Links in URL attributes are checked against the route table when it is given
%% (HANDOFF.md, decision 9); what the compiler warns about is {@link warnings/1}.
-spec compile_source(module(), binary(), file:filename_all(), none | layout(), compile_opts()) ->
    {ok, compiled()} | {error, term()}.
compile_source(View, Source, File, Layout, Opts) ->
    case unicode:characters_to_binary(Source, utf8, utf8) of
        Source ->
            compile_utf8(View, Source, File, Layout, Opts);
        _ ->
            {error, {invalid_utf8, File}}
    end.

compile_utf8(View, Source, File, Layout, Opts) ->
    case weberl_template_lexer:tokenize(Source, File) of
        {ok, Tokens} ->
            case weberl_template_parser:parse(Tokens, File) of
                {ok, Ast} -> validate_and_compile(View, Ast, File, Layout, Opts);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

validate_and_compile(View, Ast, File, Layout, Opts) ->
    case weberl_template_parser:validate(Ast, File) of
        ok ->
            case layout(Layout, Ast, File) of
                {ok, Full} -> analyze_and_compile(View, Full, File, Layout, Opts);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% URL attributes (links are checked, placeholders rewritten), then the locals of what
%% was rewritten are checked like any others.
analyze_and_compile(View, Full0, File, Layout, Opts) ->
    %% blocks between the attributes of a tag get their separating spaces first
    Full = weberl_template_attrs:prepare(Full0),
    case weberl_template_urls:analyze(Full, File, Opts) of
        {ok, Analyzed, Warnings} ->
            case weberl_template_parser:check_scope(Analyzed, File) of
                ok ->
                    case weberl_template_compiler:compile(View, Analyzed, File, layout_name(Layout)) of
                        {ok, Mod, Bin} -> {ok, {Mod, Bin, File, Warnings}};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc What the compiler warned about: `{warning, File, Line, Reason}', for example
%% `{dynamic_route_segment, Pattern}' for a `router_path' with a placeholder.
-spec warnings(compiled()) -> [weberl_template_urls:warning()].
warnings({_Mod, _Bin, _File, Warnings}) -> Warnings.

layout_name(none) -> none;
layout_name(Layout) -> weberl_template_layout:name(Layout).

layout(none, Ast, File) ->
    case [{L, N} || {fill, L, N, _} <- Ast] of
        [] -> {ok, Ast};
        [{Line, Name} | _] -> {error, {syntax_error, File, Line, {fill_without_layout, Name}}}
    end;
layout(Layout, Ast, File) -> weberl_template_layout:compose(Layout, Ast, File).

%% @doc Read, parse and validate a layout file (once; use the result for every
%% view that has that layout).
-spec parse_layout(file:filename_all()) -> {ok, layout()} | {error, term()}.
parse_layout(File) -> weberl_template_layout:parse(File).

-spec compile_file(module(), file:filename_all()) -> {ok, compiled()} | {error, term()}.
compile_file(View, File) ->
    compile_file(View, File, none).

-spec compile_file(module(), file:filename_all(), none | layout()) ->
    {ok, compiled()} | {error, term()}.
compile_file(View, File, Layout) ->
    compile_file(View, File, Layout, #{}).

-spec compile_file(module(), file:filename_all(), none | layout(), compile_opts()) ->
    {ok, compiled()} | {error, term()}.
compile_file(View, File, Layout, Opts) ->
    case file:read_file(File) of
        {ok, Source} -> compile_source(View, Source, File, Layout, Opts);
        {error, Posix} -> {error, {read_failed, File, Posix}}
    end.

%% @doc Load compiled templates, replacing any previous version.
-spec load(compiled()) -> ok.
load({Mod, Bin, File, _Warnings}) ->
    _ = code:purge(Mod),
    {module, Mod} = code:load_binary(Mod, unicode:characters_to_list(File), Bin),
    ok.

-spec compile_and_load_file(module(), file:filename_all()) -> ok | {error, term()}.
compile_and_load_file(View, File) ->
    case compile_file(View, File) of
        {ok, Compiled} -> load(Compiled);
        {error, _} = Error -> Error
    end.

%% ---------------------------------------------------------------------------
%% Discovery and association

%% @doc All `*.weberl' files below `Root', sorted. Pure file system scan.
-spec discover(file:filename()) -> [file:filename()].
discover(Root) ->
    lists:sort(filelib:fold_files(Root, "^.+\\.weberl$", true, fun(F, Acc) -> [F | Acc] end, [])).

%% @doc Pair templates with views. A template `Dir/name.weberl' belongs to the
%% view whose source file is `Dir/name.erl'. `ViewSources' is
%% `[{ViewModule, SourceFile}]'. Templates with no such view are an error
%% (`{unassociated_templates, Files}'), as are two templates for one view
%% (`{duplicate_template_associations, [{View, Files}]}'). Views without a
%% template are fine and simply do not appear in the result.
-spec associate([file:filename()], [{module(), file:filename()}]) ->
    {ok, [{module(), file:filename()}]} | {error, term()}.
associate(Templates, ViewSources) ->
    BySource = maps:from_list([{norm(Src), Mod} || {Mod, Src} <- ViewSources]),
    Pairs = [{maps:find(norm(filename:rootname(T, ".weberl") ++ ".erl"), BySource), T}
             || T <- Templates],
    case [T || {error, T} <- Pairs] of
        [] ->
            Assoc = [{Mod, T} || {{ok, Mod}, T} <- Pairs],
            case duplicates(Assoc) of
                [] -> {ok, lists:sort(Assoc)};
                Dups -> {error, {duplicate_template_associations, Dups}}
            end;
        Missing ->
            {error, {unassociated_templates, lists:sort(Missing)}}
    end.

duplicates(Assoc) ->
    Groups = lists:foldl(fun({M, T}, Acc) -> maps:update_with(M, fun(L) -> [T | L] end, [T], Acc) end,
                         #{}, Assoc),
    [{M, lists:sort(Ts)} || {M, Ts} <- lists:sort(maps:to_list(Groups)), length(Ts) > 1].

norm(Path) -> filename:join(filename:split(Path)).
