%% Test helpers (no tests of its own).
-module(weberl_test_util).

-export([with_tmp/1, write_tree/2, view_src/1, unique/1,
         load_router/2, load_crashing_router/1, load_plain_module/1,
         fixture_dir/1]).

with_tmp(Fun) ->
    Base = case os:getenv("TMPDIR") of
               false -> "/tmp";
               D -> D
           end,
    Dir = filename:join(Base, "weberl_" ++ os:getpid() ++ "_" ++
                            integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    try
        Fun(Dir)
    after
        file:del_dir_r(Dir)
    end.

%% Files: [{RelPath, Content} | {dir, RelPath}]
write_tree(Root, Files) ->
    lists:foreach(
      fun({dir, Rel}) ->
              ok = filelib:ensure_path(filename:join(Root, Rel));
         ({Rel, Content}) ->
              Path = filename:join(Root, Rel),
              ok = filelib:ensure_dir(Path),
              ok = file:write_file(Path, Content)
      end, Files).

view_src(Mod) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n-export([render/0]).~nrender() -> ok.~n", [Mod])).

unique(Prefix) ->
    list_to_atom(Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

%% Load a module exporting routes/0 that returns Routes.
load_router(Mod, Routes) ->
    load_forms(Mod, [{attribute, 1, module, Mod},
                     {attribute, 2, export, [{routes, 0}]},
                     {function, 3, routes, 0,
                      [{clause, 3, [], [], [erl_parse:abstract(Routes)]}]},
                     {eof, 4}]).

load_crashing_router(Mod) ->
    Call = {call, 3, {remote, 3, {atom, 3, erlang}, {atom, 3, error}}, [{atom, 3, boom}]},
    load_forms(Mod, [{attribute, 1, module, Mod},
                     {attribute, 2, export, [{routes, 0}]},
                     {function, 3, routes, 0, [{clause, 3, [], [], [Call]}]},
                     {eof, 4}]).

%% Load a module that does not export routes/0.
load_plain_module(Mod) ->
    load_forms(Mod, [{attribute, 1, module, Mod},
                     {attribute, 2, export, [{other, 0}]},
                     {function, 3, other, 0, [{clause, 3, [], [], [{atom, 3, ok}]}]},
                     {eof, 4}]).

load_forms(Mod, Forms) ->
    {ok, Mod, Bin} = compile:forms(Forms, [return_errors]),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Bin),
    ok.

%% Locate fixtures/<Name> by walking up from this module's beam file to the
%% project root (the directory holding rebar.config and fixtures/).
fixture_dir(Name) ->
    find_fixture(filename:dirname(code:which(?MODULE)), Name).

find_fixture(Dir, Name) ->
    Candidate = filename:join([Dir, "fixtures", Name]),
    case filelib:is_regular(filename:join(Dir, "rebar.config"))
        andalso filelib:is_dir(Candidate) of
        true ->
            Candidate;
        false ->
            case filename:dirname(Dir) of
                Dir -> error({fixture_not_found, Name});
                Parent -> find_fixture(Parent, Name)
            end
    end.
