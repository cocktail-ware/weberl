%% Test helper: compile and load a module from source text.
-module(weberl_test_handlers).

-export([load/2, unique/1]).

%% Load Mod from Source (a string of Erlang forms).
load(Mod, Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    Forms = parse(Tokens, []),
    {ok, Mod, Bin} = compile:forms(Forms, [return_errors]),
    {module, Mod} = code:load_binary(Mod, atom_to_list(Mod) ++ ".beam", Bin),
    ok.

unique(Prefix) ->
    list_to_atom(Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))).

parse([], Acc) ->
    lists:reverse(Acc);
parse(Tokens, Acc) ->
    {Form, Rest} = split(Tokens, []),
    {ok, F} = erl_parse:parse_form(Form),
    parse(Rest, [F | Acc]).

split([{dot, _} = D | Rest], Acc) -> {lists:reverse([D | Acc]), Rest};
split([T | Rest], Acc) -> split(Rest, [T | Acc]).
