%% The expression front end of the template blocks: Erlang text with @assigns turned
%% into abstract forms, with the facts a template compiler needs (assigns used, free
%% and bound locals). Includes the cases of agentic (nav, optional flash, agent list).
-module(weberl_blocks_expr_tests).
-include_lib("eunit/include/eunit.hrl").

%% Hooks that read an assign from the map in the variable `Assigns'.
hooks() ->
    #{assign => fun(Name, A) ->
                        {call, A, {remote, A, {atom, A, maps}, {atom, A, get}},
                         [{atom, A, Name}, {var, A, 'Assigns'}]}
                end,
      local => fun(Name) -> Name end}.

%% Evaluate rendered forms the way a one-shot consumer would (no module).
eval(Form, Assigns) ->
    {value, V, _} = erl_eval:expr(weberl_blocks_expr:render(Form, hooks()),
                                  erl_eval:add_binding('Assigns', Assigns, erl_eval:new_bindings())),
    V.

eval_expr(Text, Assigns) ->
    {ok, #{form := Form}} = weberl_blocks_expr:expression(Text, 1),
    eval(Form, Assigns).

%% ---------------------------------------------------------------------
%% Expressions

assigns_are_found_and_sorted_test() ->
    {ok, R} = weberl_blocks_expr:expression(<<"@user =/= undefined andalso @role =:= admin">>, 1),
    ?assertMatch(#{assigns := [role, user], free := [], bound := []}, R).

the_agentic_conditions_test() ->
    Signed = #{user => <<"ana">>, role => admin},
    Anon = #{user => undefined, role => undefined},
    Cond = <<"@user =/= undefined andalso @role =:= admin">>,
    ?assertEqual(true, eval_expr(Cond, Signed)),
    ?assertEqual(false, eval_expr(Cond, Anon)),
    ?assertEqual(true, eval_expr(<<"lists:member(@role, [admin, owner])">>, Signed)).

any_function_and_arithmetic_test() ->
    ?assertEqual(<<"ANA">>, eval_expr(<<"string:uppercase(@name)">>, #{name => <<"ana">>})),
    ?assertEqual(0.3, eval_expr(<<"@n / 10">>, #{n => 3})),
    ?assertEqual(3, eval_expr(<<"length(@items)">>, #{items => [a, b, c]})).

at_signs_in_literals_are_not_assigns_test() ->
    Check = fun(Text) ->
                    {ok, #{assigns := A, form := F}} = weberl_blocks_expr:expression(Text, 1),
                    {A, eval(F, #{})}
            end,
    ?assertEqual({[], "a@b"}, Check(<<"\"a@b\"">>)),
    ?assertEqual({[], 'a@b'}, Check(<<"'a@b'">>)),
    ?assertEqual({[], $@}, Check(<<"$@">>)),
    ?assertEqual({[], user@host}, Check(<<"user@host">>)),
    ?assertEqual({[], "say \"@x\""}, Check(<<"\"say \\\"@x\\\"\"">>)),
    ?assertEqual({[], 7}, Check(<<"7 % @comment\n">>)).

an_assign_next_to_a_literal_is_still_found_test() ->
    {ok, #{assigns := A}} = weberl_blocks_expr:expression(<<"@a =:= \"@b\" orelse @c">>, 1),
    ?assertEqual([a, c], A).

free_locals_exclude_what_funs_and_comprehensions_bind_test() ->
    {ok, R1} = weberl_blocks_expr:expression(<<"Name =:= admin">>, 1),
    ?assertMatch(#{free := ['Name']}, R1),
    {ok, R2} = weberl_blocks_expr:expression(<<"lists:map(fun(X) -> X + Y end, @l)">>, 1),
    ?assertMatch(#{free := ['Y'], assigns := [l]}, R2),
    {ok, R3} = weberl_blocks_expr:expression(<<"[X * 2 || X <- @l, X > Min]">>, 1),
    ?assertMatch(#{free := ['Min'], assigns := [l]}, R3),
    %% what a pattern inside the expression binds is not free
    {ok, R4} = weberl_blocks_expr:expression(<<"begin {_, X} = @pair, X end">>, 1),
    ?assertMatch(#{free := [], assigns := [pair]}, R4).

locals_are_renamed_by_the_hook_test() ->
    {ok, #{form := Form}} = weberl_blocks_expr:expression(<<"Name =:= @n">>, 1),
    Hooks = (hooks())#{local => fun(N) -> list_to_atom("W_" ++ atom_to_list(N)) end},
    Rendered = weberl_blocks_expr:render(Form, Hooks),
    {value, true, _} = erl_eval:expr(Rendered, erl_eval:add_binding('W_Name', 1,
                          erl_eval:add_binding('Assigns', #{n => 1}, erl_eval:new_bindings()))),
    %% the anonymous variable is left alone
    {ok, #{form := Form2}} = weberl_blocks_expr:expression(<<"begin {_, X} = {1, 2}, X end">>, 1),
    ?assertEqual(2, eval(Form2, #{})).

%% ---------------------------------------------------------------------
%% Errors

syntax_errors_carry_the_template_line_test() ->
    ?assertMatch({error, {invalid_expression, <<"1 +">>, {5, _}}},
                 weberl_blocks_expr:expression(<<"1 +">>, 5)),
    %% a multi-line expression reports the line inside it
    ?assertMatch({error, {invalid_expression, _, {7, _}}},
                 weberl_blocks_expr:expression(<<"@a andalso\n@b andalso\n)">>, 5)),
    ?assertMatch({error, {invalid_expression, _, {3, _}}},
                 weberl_blocks_expr:expression(<<"\"unterminated">>, 3)),
    ?assertMatch({error, {invalid_expression, _, {1, _}}},
                 weberl_blocks_expr:expression(<<"">>, 1)).

more_than_one_expression_is_refused_test() ->
    ?assertEqual({error, {not_a_single_expression, <<"1, 2">>}},
                 weberl_blocks_expr:expression(<<"1, 2">>, 1)).

an_at_sign_that_is_not_an_assign_is_a_syntax_error_test() ->
    ?assertMatch({error, {invalid_expression, _, _}}, weberl_blocks_expr:expression(<<"@Upper">>, 1)),
    ?assertMatch({error, {invalid_expression, _, _}}, weberl_blocks_expr:expression(<<"@ x">>, 1)),
    ?assertMatch({error, {invalid_expression, _, _}}, weberl_blocks_expr:expression(<<"1 @">>, 1)).

reserved_names_are_refused_test() ->
    ?assertEqual({error, {reserved_variable, '_Weberl_x'}},
                 weberl_blocks_expr:expression(<<"_Weberl_x">>, 1)),
    ?assertEqual({error, {reserved_variable, '_Weberl_'}},
                 weberl_blocks_expr:clause(<<"{ok, _Weberl_}">>, 1)).

%% ---------------------------------------------------------------------
%% Case clauses

clause_pattern_binds_test() ->
    {ok, R} = weberl_blocks_expr:clause(<<"{error, Msg}">>, 1),
    ?assertMatch(#{bound := ['Msg'], free := [], assigns := [], guard := []}, R).

clause_with_a_guard_test() ->
    {ok, R} = weberl_blocks_expr:clause(<<"{info, Msg} when is_binary(Msg), Msg =/= @hidden">>, 1),
    ?assertMatch(#{bound := ['Msg'], free := [], assigns := [hidden]}, R),
    #{guard := Guard} = R,
    ?assertMatch([[_, _]], Guard).

clause_guard_free_variable_test() ->
    {ok, R} = weberl_blocks_expr:clause(<<"{n, N} when N > Min">>, 1),
    ?assertMatch(#{bound := ['N'], free := ['Min']}, R).

clause_patterns_and_wildcards_test() ->
    {ok, R1} = weberl_blocks_expr:clause(<<"undefined">>, 1),
    ?assertMatch(#{bound := [], free := []}, R1),
    {ok, R2} = weberl_blocks_expr:clause(<<"_">>, 1),
    ?assertMatch(#{bound := []}, R2),
    {ok, R3} = weberl_blocks_expr:clause(<<"#{name := Name, role := admin}">>, 1),
    ?assertMatch(#{bound := ['Name']}, R3).

an_assign_cannot_be_in_a_pattern_test() ->
    ?assertEqual({error, {assign_in_pattern, x}}, weberl_blocks_expr:clause(<<"{ok, @x}">>, 1)).

clause_syntax_errors_test() ->
    ?assertMatch({error, {invalid_expression, _, {4, _}}}, weberl_blocks_expr:clause(<<"{ok,">>, 4)),
    %% text that closes the wrapper and adds more is not a clause
    ?assertMatch({error, {invalid_expression, _, _}}, weberl_blocks_expr:clause(<<"x -> 1; y">>, 1)).

%% ---------------------------------------------------------------------
%% Qualifiers

qualifiers_result(Text, Assigns) ->
    {ok, #{qualifiers := Quals}} = weberl_blocks_expr:qualifiers(Text, 1),
    %% build [Name || Quals] to run it
    Form = {lc, 1, {var, 1, 'Name'}, Quals},
    eval(Form, Assigns).

generator_pattern_binds_and_filters_test() ->
    {ok, R} = weberl_blocks_expr:qualifiers(<<"#{name := Name, active := true} <- @agents">>, 1),
    ?assertMatch(#{bound := ['Name'], free := [], assigns := [agents]}, R),
    Agents = [#{name => <<"a">>, active => true}, #{name => <<"b">>, active => false},
              #{name => <<"c">>, active => true}, #{other => 1}],
    %% a pattern that does not match skips the element (Erlang's own rule)
    ?assertEqual([<<"a">>, <<"c">>],
                 qualifiers_result(<<"#{name := Name, active := true} <- @agents">>, #{agents => Agents})).

filters_and_several_generators_test() ->
    {ok, R} = weberl_blocks_expr:qualifiers(<<"Name <- @names, Name =/= <<>>, Y <- @ys, Y > Min">>, 1),
    ?assertMatch(#{bound := ['Name', 'Y'], free := ['Min'], assigns := [names, ys]}, R),
    ?assertEqual([<<"a">>, <<"b">>],
                 qualifiers_result(<<"Name <- @names, Name =/= <<>>">>, #{names => [<<"a">>, <<>>, <<"b">>]})).

map_and_binary_generators_test() ->
    {ok, R1} = weberl_blocks_expr:qualifiers(<<"K := V <- @m">>, 1),
    ?assertMatch(#{bound := ['K', 'V']}, R1),
    {ok, R2} = weberl_blocks_expr:qualifiers(<<"<<C>> <= @bin">>, 1),
    ?assertMatch(#{bound := ['C']}, R2),
    {ok, #{qualifiers := Quals}} = weberl_blocks_expr:qualifiers(<<"K := V <- @m">>, 1),
    ?assertEqual([{a, 1}, {b, 2}],
                 lists:sort(eval({lc, 1, {tuple, 1, [{var, 1, 'K'}, {var, 1, 'V'}]}, Quals},
                                 #{m => #{a => 1, b => 2}}))).

a_later_generator_may_use_an_earlier_binding_test() ->
    {ok, R} = weberl_blocks_expr:qualifiers(<<"Row <- @rows, Cell <- Row">>, 1),
    ?assertMatch(#{bound := ['Cell', 'Row'], free := []}, R).

rebinding_is_an_error_test() ->
    ?assertEqual({error, {rebound_variable, 'X'}},
                 weberl_blocks_expr:qualifiers(<<"X <- @a, X <- @b">>, 1)),
    ?assertEqual({error, {rebound_variable, 'K'}},
                 weberl_blocks_expr:qualifiers(<<"K <- @a, K := _ <- @b">>, 1)).

assigns_in_generator_patterns_are_errors_test() ->
    ?assertEqual({error, {assign_in_pattern, x}}, weberl_blocks_expr:qualifiers(<<"@x <- @list">>, 1)).

qualifier_errors_test() ->
    ?assertMatch({error, {invalid_expression, _, {2, _}}}, weberl_blocks_expr:qualifiers(<<"X <-">>, 2)),
    %% a trailing `]' would close the wrapper: not accepted
    ?assertMatch({error, {invalid_expression, _, _}}, weberl_blocks_expr:qualifiers(<<"X <- [1]] ++ [">>, 1)).

%% ---------------------------------------------------------------------
%% Module independence: the block modules call nothing of Weberl

depends_only_on_otp_test() ->
    {ok, {_, [{imports, Imports}]}} = beam_lib:chunks(code:which(weberl_blocks_expr), [imports]),
    Modules = lists:usort([M || {M, _, _} <- Imports]),
    ?assertEqual([], [M || M <- Modules, lists:prefix("weberl", atom_to_list(M))]).
