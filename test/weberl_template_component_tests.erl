%% Components: `{: component name, #{...} :}' ... `{: /component :}' with `{: param :}', `{: content :}' and
%% slots (feedback from agentic, item 4; decisions in HANDOFF.md).
-module(weberl_template_component_tests).
-include_lib("eunit/include/eunit.hrl").

-define(PANEL, {"panel.weberl",
                <<"{: param title :}\n{: param open, false :}\n"
                  "<details class=\"panel\" {: if @open :}open{: /if :}><summary>{{ @title }}</summary>"
                  "<div>{: content :}</div></details>">>}).

%% Compile `View' with the components (a list of {RelativePath, Source}) and render it.
render(Components, View, Assigns) ->
    case compile(Components, View) of
        {ok, Mod} -> {ok, iolist_to_binary(weberl_template:render(Mod, Assigns))};
        {error, _} = Error -> Error
    end.

compile(Components, View) ->
    weberl_test_util:with_tmp(
      fun(Dir) ->
              Root = filename:join(Dir, "components"),
              ok = filelib:ensure_path(Root),
              weberl_test_util:write_tree(Root, Components),
              case weberl_template_component:load([Root], #{}) of
                  {ok, Loaded} ->
                      Mod = weberl_test_handlers:unique("compview"),
                      case weberl_template:compile_source(Mod, View, "view.weberl", none,
                                                          #{components => Loaded}) of
                          {ok, C} -> ok = weberl_template:load(C), {ok, Mod};
                          {error, _} = Error -> Error
                      end;
                  {error, _} = Error ->
                      Error
              end
      end).

err(Components, View) ->
    {error, {syntax_error, File, Line, Reason}} = compile(Components, View),
    {filename:basename(File), Line, Reason}.

ok(Components, View, Assigns) ->
    {ok, Out} = render(Components, View, Assigns),
    Out.

%% ---------------------------------------------------------------------

parameters_and_content_test() ->
    ?assertEqual(<<"<details class=\"panel\" ><summary>Edit</summary><div><p>hi</p></div></details>">>,
                 ok([?PANEL], <<"{: component panel, #{title => \"Edit\"} :}<p>hi</p>{: /component :}">>, #{})),
    ?assertEqual(<<"<details class=\"panel\"  open ><summary>T</summary><div></div></details>">>,
                 ok([?PANEL], <<"{: component panel, #{title => @t, open => true} :}{: /component :}">>,
                    #{t => <<"T">>})).

values_are_escaped_where_the_component_writes_them_test() ->
    ?assertEqual(<<"<details class=\"panel\" ><summary>&lt;b&gt;</summary><div></div></details>">>,
                 ok([?PANEL], <<"{: component panel, #{title => @t} :}{: /component :}">>, #{t => <<"<b>">>})).

the_body_keeps_the_callers_scope_test() ->
    View = <<"{: for X <- @xs :}{: component panel, #{title => X} :}[{{ X }}/{{ @tail }}]{: /component :}{: /for :}">>,
    Out = ok([?PANEL], View, #{xs => [a, b], tail => <<"z">>}),
    ?assertMatch({match, _}, re:run(Out, "<summary>a</summary><div>\\[a/z\\]</div>.*<summary>b</summary><div>\\[b/z\\]</div>")).

the_component_cannot_read_the_callers_assigns_test() ->
    Bad = {"leak.weberl", <<"<p>{{ @secret }}</p>">>},
    ?assertEqual({"leak.weberl", 1, {undeclared_assign, secret}},
                 err([Bad], <<"{: component leak :}{: /component :}">>)).

nested_directories_name_the_component_test() ->
    Field = {"forms/field.weberl", <<"{: param name :}<label>{{ @name }}</label>">>},
    ?assertEqual(<<"<label>n</label>">>,
                 ok([Field], <<"{: component forms/field, #{name => \"n\"} :}{: /component :}">>, #{})).

slots_and_fills_test() ->
    Card = {"card.weberl", <<"<h1>{: slot head :}Default{: /slot head :}</h1>{: content :}"
                             "<i>{: slot foot :}-{: /slot foot :}</i>">>},
    ?assertEqual(<<"<h1>Default</h1>body<i>-</i>">>,
                 ok([Card], <<"{: component card :}body{: /component :}">>, #{})),
    ?assertEqual(<<"<h1>Mine</h1>body<i>F</i>">>,
                 ok([Card], <<"{: component card :}{: fill foot :}F{: /fill foot :}"
                              "{: fill head :}{{ @h }}{: /fill head :}body{: /component :}">>, #{h => <<"Mine">>})).

a_slot_default_sees_the_parameters_test() ->
    C = {"c.weberl", <<"{: param n :}{: slot s :}<b>{{ @n }}</b>{: /slot s :}">>},
    ?assertEqual(<<"<b>5</b>">>, ok([C], <<"{: component c, #{n => 5} :}{: /component :}">>, #{})).

defaults_are_used_when_a_parameter_is_left_out_test() ->
    C = {"c.weberl", <<"{: param a, 1 + 1 :}{{ @a }}">>},
    ?assertEqual(<<"2">>, ok([C], <<"{: component c :}{: /component :}">>, #{})),
    ?assertEqual(<<"7">>, ok([C], <<"{: component c, #{a => 7} :}{: /component :}">>, #{})).

the_same_component_twice_and_nested_test() ->
    Box = {"box.weberl", <<"{: param n :}[{{ @n }}{: content :}]">>},
    ?assertEqual(<<"[1[2x]]">>,
                 ok([Box], <<"{: component box, #{n => 1} :}{: component box, #{n => 2} :}x{: /component :}{: /component :}">>, #{})).

a_component_uses_another_test() ->
    Inner = {"inner.weberl", <<"{: param v :}<i>{{ @v }}</i>">>},
    Outer = {"outer.weberl", <<"{: param v :}<b>{: component inner, #{v => @v} :}{: /component :}{: content :}</b>">>},
    ?assertEqual(<<"<b><i>9</i>!</b>">>, ok([Inner, Outer], <<"{: component outer, #{v => 9} :}!{: /component :}">>, #{})).

a_component_passes_its_body_on_test() ->
    Inner = {"inner.weberl", <<"<i>{: content :}</i>">>},
    Outer = {"outer.weberl", <<"<b>{: component inner :}{: content :}{: /component :}</b>">>},
    ?assertEqual(<<"<b><i>x</i></b>">>, ok([Inner, Outer], <<"{: component outer :}x{: /component :}">>, #{})).

locals_of_the_component_do_not_meet_the_callers_test() ->
    C = {"c.weberl", <<"{: for X <- [1, 2] :}{{ X }}{: /for :}{: content :}">>},
    ?assertEqual(<<"12-a12-b">>,
                 ok([C], <<"{: for X <- [a, b] :}{: component c :}-{{ X }}{: /component :}{: /for :}">>, #{})).

%% ---------------------------------------------------------------------
%% Errors

parameter_errors_test() ->
    ?assertEqual({"view.weberl", 1, {missing_component_param, <<"panel">>, title}},
                 err([?PANEL], <<"{: component panel :}{: /component :}">>)),
    ?assertEqual({"view.weberl", 1, {unknown_component_param, <<"panel">>, tite}},
                 err([?PANEL], <<"{: component panel, #{title => 1, tite => 2} :}{: /component :}">>)),
    ?assertEqual({"view.weberl", 1, component_params_not_a_map_literal},
                 err([?PANEL], <<"{: component panel, @p :}{: /component :}">>)),
    ?assertEqual({"view.weberl", 1, {duplicate_component_param, title}},
                 err([?PANEL], <<"{: component panel, #{title => 1, title => 2} :}{: /component :}">>)).

unknown_component_and_fill_test() ->
    ?assertEqual({"view.weberl", 1, {unknown_component, <<"nope">>}},
                 err([], <<"{: component nope :}{: /component :}">>)),
    ?assertEqual({"view.weberl", 1, {unknown_fill, x, <<"panel">>}},
                 err([?PANEL], <<"{: component panel, #{title => 1} :}{: fill x :}a{: /fill x :}{: /component :}">>)).

a_body_needs_a_content_marker_test() ->
    C = {"c.weberl", <<"<p></p>">>},
    ?assertEqual({"view.weberl", 1, {component_without_content, <<"c">>}},
                 err([C], <<"{: component c :}text{: /component :}">>)),
    ?assertEqual(<<"<p></p>">>, ok([C], <<"{: component c :}  \n {: /component :}">>, #{})).

component_file_errors_test() ->
    ?assertEqual({"c.weberl", 2, {param_not_at_top, a}},
                 err([{"c.weberl", <<"<p></p>\n{: param a :}">>}], <<"x">>)),
    ?assertEqual({"c.weberl", 2, {duplicate_param, a}},
                 err([{"c.weberl", <<"{: param a :}\n{: param a :}">>}], <<"x">>)),
    ?assertEqual({"c.weberl", 1, {param_default_not_constant, a}},
                 err([{"c.weberl", <<"{: param a, @b :}">>}], <<"x">>)),
    ?assertEqual({"c.weberl", 1, {region_in_component, r}},
                 err([{"c.weberl", <<"{: region r :}x{: /region r :}">>}], <<"x">>)),
    ?assertEqual({"c.weberl", 1, {fill_in_component, r}},
                 err([{"c.weberl", <<"{: fill r :}x{: /fill r :}">>}], <<"x">>)),
    ?assertEqual({"c.weberl", 1, {duplicate_content, <<"c">>}},
                 err([{"c.weberl", <<"{: content :}{: content :}">>}], <<"x">>)),
    ?assertEqual({"view.weberl", 1, {param_outside_component, a}}, err([], <<"{: param a :}">>)).

cycles_and_unknown_uses_in_components_test() ->
    A = {"a.weberl", <<"{: component b :}{: /component :}">>},
    B = {"b.weberl", <<"{: component a :}{: /component :}">>},
    ?assertMatch({_, 1, {component_cycle, [<<"a">>, <<"b">>, <<"a">>]}}, err([A, B], <<"x">>)),
    ?assertMatch({"a.weberl", 1, {unknown_component, <<"zz">>}},
                 err([{"a.weberl", <<"{: component zz :}{: /component :}">>}], <<"x">>)).

duplicate_names_in_two_directories_test() ->
    weberl_test_util:with_tmp(
      fun(Dir) ->
              D1 = filename:join(Dir, "one"), D2 = filename:join(Dir, "two"),
              weberl_test_util:write_tree(D1, [{"x.weberl", <<"a">>}]),
              weberl_test_util:write_tree(D2, [{"x.weberl", <<"b">>}]),
              ?assertMatch({error, {duplicate_components, [{<<"x">>, [_, _]}]}},
                           weberl_template_component:load([D1, D2], #{}))
      end).

unbalanced_body_is_rejected_test() ->
    ?assertEqual({"view.weberl", 1, component_unbalanced_markup},
                 err([?PANEL], <<"{: component panel, #{title => 1} :}<div{: /component :}">>)).

mismatched_end_is_rejected_test() ->
    {error, {syntax_error, "view.weberl", 1, Reason}} =
        weberl_template:compile_source(weberl_test_handlers:unique("cv"),
                                       <<"{: component panel :}{: /form :}">>, "view.weberl"),
    ?assertMatch({mismatched_block_end, {component, none}, {form, none}}, Reason).
