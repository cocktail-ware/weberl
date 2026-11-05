%% @doc Filesystem route discovery.
%%
%% Recursively scans a root directory for `*_view.erl' files. Source files are
%% only inspected (scanned and parsed up to their `-module' attribute); they
%% are never compiled or executed.
%%
%% Traversal is depth-first with directory entries sorted by name, so the
%% result order is deterministic. Symbolic links are not followed.
-module(weberl_fs).

-export([discover/2]).

-include_lib("kernel/include/file.hrl").

-define(SUFFIX, "_view.erl").

%% @doc Discover routes below `Root', mounted at URL `Prefix'.
-spec discover(file:filename(), term()) -> {ok, [weberl_route:t()]} | {error, term()}.
discover(Root, Prefix) ->
    case filelib:is_dir(Root) of
        false ->
            {error, {root_not_a_directory, Root}};
        true ->
            case weberl_route:normalize_path(Prefix) of
                {ok, P} -> walk_dir(Root, [], P);
                {error, Reason} -> {error, {invalid_prefix, Prefix, Reason}}
            end
    end.

walk_dir(Dir, Segs, Prefix) ->
    case file:list_dir(Dir) of
        {ok, Names} -> walk_entries(lists:sort(Names), Dir, Segs, Prefix, []);
        {error, Reason} -> {error, {cannot_read_dir, Dir, Reason}}
    end.

walk_entries([], _Dir, _Segs, _Prefix, Acc) ->
    {ok, lists:reverse(Acc)};
walk_entries([Name | Rest], Dir, Segs, Prefix, Acc) ->
    Full = filename:join(Dir, Name),
    case file:read_link_info(Full) of
        {ok, #file_info{type = directory}} ->
            case walk_dir(Full, Segs ++ [Name], Prefix) of
                {ok, Sub} ->
                    walk_entries(Rest, Dir, Segs, Prefix, lists:reverse(Sub) ++ Acc);
                {error, _} = Error ->
                    Error
            end;
        {ok, #file_info{type = regular}} ->
            case is_view_file(Name) of
                true ->
                    case view_route(Full, Segs, Prefix) of
                        {ok, Route} -> walk_entries(Rest, Dir, Segs, Prefix, [Route | Acc]);
                        {error, _} = Error -> Error
                    end;
                false ->
                    walk_entries(Rest, Dir, Segs, Prefix, Acc)
            end;
        {ok, _Other} ->
            walk_entries(Rest, Dir, Segs, Prefix, Acc);
        {error, Reason} ->
            {error, {cannot_read_file_info, Full, Reason}}
    end.

%% A directory `[id]' is the parameter segment `:id' (HANDOFF.md, decision 11). A directory
%% that really contains `:' is not turned into one: `normalize_pattern' refuses it.
segment("[" ++ Rest = Name) ->
    case lists:last(Name) of
        $] -> [$: | lists:droplast(Rest)];
        _ -> Name
    end;
segment(Name) ->
    Name.

is_view_file(Name) ->
    lists:suffix(?SUFFIX, Name) andalso Name =/= ?SUFFIX.

view_route(File, Segs, Prefix) ->
    case module_of(File) of
        {ok, Mod, Opts} ->
            Expected = filename:basename(File, ".erl"),
            case atom_to_list(Mod) of
                Expected ->
                    UrlPath = Prefix ++ "/" ++ lists:append(lists:join("/", [segment(S) || S <- Segs])),
                    case weberl_route:normalize_pattern(UrlPath) of
                        {ok, Path} ->
                            {ok, weberl_route:new(Path, Mod, filesystem, File, Opts)};
                        {error, Reason} ->
                            {error, {invalid_route_path, File, Reason}}
                    end;
                _ ->
                    {error, {module_mismatch, File, Mod, Expected}}
            end;
        {error, _} = Error ->
            Error
    end.

%% Read the module name from the first `-module(...)' attribute without
%% compiling. Forms are scanned and parsed one at a time. Preprocessor
%% directives (`-define', `-include' ...) before `-module' are not supported.
%% After `-module', the remaining attributes are read (up to the first
%% function) for `-weberl_page(Kind).' (the route's `live' option) and
%% `-weberl_route(Opts).' (all the route options, see `weberl_route:opts()').
%% Forms there that don't parse (for example ones using macros) are skipped.
module_of(File) ->
    case file:open(File, [read, {encoding, utf8}]) of
        {ok, Dev} ->
            try
                scan_forms(Dev, File, 1)
            after
                file:close(Dev)
            end;
        {error, Reason} ->
            {error, {cannot_read_file, File, Reason}}
    end.

%% `Found' is `{Kind, Opts}': what `-weberl_page(Kind).' and
%% `-weberl_route(Opts).' declared so far (`undefined' for neither).
scan_page(Dev, File, Line, {Page, Route} = Found) ->
    case io:scan_erl_form(Dev, "", Line) of
        {ok, Tokens, EndLine} ->
            case erl_parse:parse_form(Tokens) of
                {ok, {attribute, _, weberl_page, Kind}} ->
                    case {Page, weberl_route:check_live(Kind)} of
                        {undefined, ok} -> scan_page(Dev, File, EndLine, {Kind, Route});
                        {undefined, {error, _}} ->
                            {error, {invalid_page_attribute, File, Kind}};
                        {_, _} ->
                            {error, {duplicate_page_attribute, File}}
                    end;
                {ok, {attribute, _, weberl_route, Opts}} ->
                    case {Route, is_map(Opts)} of
                        {undefined, true} -> scan_page(Dev, File, EndLine, {Page, Opts});
                        {undefined, false} -> {error, {invalid_route_attribute, File, Opts}};
                        {_, _} -> {error, {duplicate_route_attribute, File}}
                    end;
                {ok, {attribute, _, _, _}} ->
                    scan_page(Dev, File, EndLine, Found);
                {ok, _Form} ->
                    page_opts(File, Found);
                {error, _} ->
                    scan_page(Dev, File, EndLine, Found)
            end;
        {error, _, EndLine} ->
            scan_page(Dev, File, EndLine, Found);
        _ ->
            page_opts(File, Found)
    end.

%% The route options of the view: `-weberl_route(Opts)' is the map a declarative
%% route takes as its third element; `-weberl_page(Kind)' is a shorthand for
%% `#{live => Kind}' and may not be combined with a `live' key of the map.
page_opts(_File, {undefined, undefined}) ->
    {ok, #{}};
page_opts(File, {Page, Route}) ->
    case combine(Page, Route) of
        {ok, Opts} ->
            case weberl_route:check_opts(Opts) of
                {ok, _} = Ok -> Ok;
                {error, Reason} -> {error, {invalid_route_attribute, File, Reason}}
            end;
        error ->
            {error, {conflicting_page_attributes, File}}
    end.

combine(undefined, undefined) -> {ok, #{}};
combine(undefined, Route) -> {ok, Route};
combine(Page, undefined) -> {ok, #{live => Page}};
combine(Page, Route) ->
    case maps:is_key(live, Route) of
        true -> error;
        false -> {ok, Route#{live => Page}}
    end.

scan_forms(Dev, File, Line) ->
    case io:scan_erl_form(Dev, "", Line) of
        {ok, Tokens, EndLine} ->
            case erl_parse:parse_form(Tokens) of
                {ok, {attribute, _, module, Mod}} when is_atom(Mod) ->
                    case scan_page(Dev, File, EndLine, {undefined, undefined}) of
                        {ok, Opts} -> {ok, Mod, Opts};
                        {error, _} = Error -> Error
                    end;
                {ok, {attribute, _, module, Other}} ->
                    {error, {invalid_module_declaration, File, Other}};
                {ok, {attribute, _, _, _}} ->
                    scan_forms(Dev, File, EndLine);
                {ok, _Form} ->
                    {error, {no_module_declaration, File}};
                {error, ErrorInfo} ->
                    {error, {invalid_source, File, ErrorInfo}}
            end;
        {eof, _} ->
            {error, {no_module_declaration, File}};
        {error, ErrorInfo, _} ->
            {error, {invalid_source, File, ErrorInfo}};
        Other ->
            {error, {invalid_source, File, Other}}
    end.
