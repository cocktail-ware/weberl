%% Template engine tests; no HTTP and no router.
-module(weberl_template_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_test_util, [with_tmp/1, write_tree/2]).

%% ---------------------------------------------------------------------
%% helpers

unique_view() -> weberl_test_handlers:unique("tview").

%% Compile and load Source for a fresh view; returns the view.
tpl(Source) ->
    View = unique_view(),
    {ok, C} = weberl_template:compile_source(View, Source, "t.weberl"),
    ok = weberl_template:load(C),
    View.

render(View, Assigns) -> iolist_to_binary(weberl_template:render(View, Assigns)).

compile(Source) -> weberl_template:compile_source(unique_view(), Source, "t.weberl").

err(Source) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} = compile(Source),
    {Line, Reason}.

%% ---------------------------------------------------------------------
%% lexer

lex(Src) -> weberl_template_lexer:tokenize(Src, "t.weberl").

lexer_literal_test() ->
    ?assertEqual({ok, [{text, 1, <<"<p>hi</p>">>}]}, lex(<<"<p>hi</p>">>)),
    ?assertEqual({ok, []}, lex(<<>>)).

%% The lexer hands the expression over exactly as written (the parser reads it).
lexer_interpolation_test() ->
    ?assertEqual({ok, [{text, 1, <<"a ">>}, {interp, 1, escaped, <<" @name ">>},
                       {text, 1, <<" b ">>}, {interp, 1, raw, <<"@html">>}, {text, 1, <<" c">>}]},
                 lex(<<"a {{ @name }} b {{{@html}}} c">>)).

lexer_keeps_the_text_as_written_test() ->
    ?assertEqual({ok, [{interp, 1, escaped, <<"\n  x_1\t">>}]}, lex(<<"{{\n  x_1\t}}">>)),
    %% any text: it is the parser's business to read it as Erlang
    ?assertEqual({ok, [{interp, 1, escaped, <<" @a + length(@b) ">>}]}, lex(<<"{{ @a + length(@b) }}">>)),
    ?assertEqual({ok, [{interp, 1, raw, <<" f(x) ">>}]}, lex(<<"{{{ f(x) }}}">>)).

lexer_lines_test() ->
    ?assertEqual({ok, [{text, 1, <<"a\nb\n">>}, {interp, 3, escaped, <<"@x">>},
                       {text, 3, <<"\n">>}, {interp, 4, raw, <<"@y">>}]},
                 lex(<<"a\nb\n{{@x}}\n{{{@y}}}">>)).

lexer_backslash_escape_test() ->
    ?assertEqual({ok, [{text, 1, <<"{{ @x }} and ">>}, {interp, 1, escaped, <<"@y">>}]},
                 lex(<<"\\{{ @x }} and {{@y}}">>)),
    ?assertEqual({ok, [{text, 1, <<"a\\b">>}]}, lex(<<"a\\b">>)).

lexer_single_braces_are_literal_test() ->
    ?assertEqual({ok, [{text, 1, <<"{ a } }} {">>}]}, lex(<<"{ a } }} {">>)).

lexer_errors_test_() ->
    E = fun(Line, Reason) -> {error, {syntax_error, "t.weberl", Line, Reason}} end,
    [?_assertEqual(E(1, unterminated_interpolation), lex(<<"{{ x">>)),
     ?_assertEqual(E(2, unterminated_interpolation), lex(<<"a\n{{ x\n y">>)),
     ?_assertEqual(E(1, unterminated_raw_interpolation), lex(<<"{{{ @x }}">>)),
     ?_assertEqual(E(1, empty_interpolation), lex(<<"{{}}">>)),
     ?_assertEqual(E(1, empty_interpolation), lex(<<"{{  }}">>)),
     ?_assertEqual(E(3, empty_interpolation), lex(<<"\n\n{{ \n }}">>)),
     ?_assertEqual(E(1, empty_interpolation), lex(<<"{{{ }}}">>))].

%% ---------------------------------------------------------------------
%% rendering

literal_html_test() ->
    V = tpl(<<"<main class=\"home\">\n  <h1>Static</h1>\n</main>\n">>),
    ?assertEqual(<<"<main class=\"home\">\n  <h1>Static</h1>\n</main>\n">>, render(V, #{})),
    ?assertEqual(<<>>, render(tpl(<<>>), #{})).

spec_example_test() ->
    V = tpl(<<"<main class=\"home\">\n    <h1>{{ @title }}</h1>\n"
              "    <p>{{ @description }}</p>\n</main>\n">>),
    ?assertEqual(<<"<main class=\"home\">\n    <h1>Welcome</h1>\n"
                   "    <p>Built with Weberl</p>\n</main>\n">>,
                 render(V, #{title => <<"Welcome">>, description => <<"Built with Weberl">>})).

escaping_test() ->
    V = tpl(<<"<p>{{ @v }}</p>">>),
    ?assertEqual(<<"<p>&lt;a&gt; &amp; &quot;q&quot; &#39;s&#39;</p>">>,
                 render(V, #{v => <<"<a> & \"q\" 's'">>})).

escaping_order_does_not_double_escape_test() ->
    ?assertEqual(<<"&amp;lt;">>, render(tpl(<<"{{@v}}">>), #{v => <<"&lt;">>})).

raw_test() ->
    V = tpl(<<"<div>{{{ @html }}}</div>">>),
    ?assertEqual(<<"<div><b>bold</b> & more</div>">>,
                 render(V, #{html => <<"<b>bold</b> & more">>})).

attribute_interpolation_test() ->
    V = tpl(<<"<a class=\"{{ @c }}\" title='{{ @t }}'>x</a>">>),
    ?assertEqual(<<"<a class=\"a&quot;b\" title='it&#39;s'>x</a>">>,
                 render(V, #{c => <<"a\"b">>, t => <<"it's">>})).

utf8_is_preserved_test() ->
    ?assertEqual(<<"héllo ✓"/utf8>>, render(tpl(<<"{{@v}}"/utf8>>), #{v => <<"héllo ✓"/utf8>>})),
    ?assertEqual(<<"π: {{@x}}"/utf8>>, render(tpl(<<"π: \\{{@x}}"/utf8>>), #{})).

value_types_test() ->
    V = tpl(<<"{{@a}}|{{@b}}|{{@c}}|{{@d}}|{{@e}}|{{@f}}|{{@g}}">>),
    ?assertEqual(<<"text|chars|42|-7|1.5|true|false">>,
                 render(V, #{a => <<"text">>, b => "chars", c => 42, d => -7, e => 1.5,
                             f => true, g => false})),
    ?assertEqual(<<"é"/utf8>>, render(tpl(<<"{{@v}}"/utf8>>), #{v => [233]})),
    ?assertEqual(<<"0.1">>, render(tpl(<<"{{@v}}">>), #{v => 0.1})).

extra_assigns_are_ignored_test() ->
    ?assertEqual(<<"x">>, render(tpl(<<"{{@a}}">>), #{a => <<"x">>, other => <<"y">>})).

repeated_use_of_one_variable_test() ->
    ?assertEqual(<<"1 1">>, render(tpl(<<"{{@a}} {{@a}}">>), #{a => 1})).

rendering_with_different_values_test() ->
    V = tpl(<<"Hello {{ @who }}!">>),
    ?assertEqual(<<"Hello A!">>, render(V, #{who => <<"A">>})),
    ?assertEqual(<<"Hello B!">>, render(V, #{who => <<"B">>})),
    ?assertEqual(<<"Hello 3!">>, render(V, #{who => 3})).

render_returns_iodata_test() ->
    V = tpl(<<"a{{@x}}b">>),
    ?assert(is_list(weberl_template:render(V, #{x => <<"-">>}))).

%% ---------------------------------------------------------------------
%% render errors

render_error(Fun) ->
    try Fun() of
        R -> {no_error, R}
    catch
        error:{template_error, Reason} -> Reason
    end.

missing_variable_test() ->
    V = tpl(<<"{{ @a }} {{ @b }}">>),
    ?assertEqual({missing_variable, V, b},
                 render_error(fun() -> weberl_template:render(V, #{a => 1}) end)),
    ?assertEqual({missing_variable, V, a},
                 render_error(fun() -> weberl_template:render(V, #{}) end)).

%% Atoms render as their name; everything else that is not text or a number is refused.
unsupported_values_test_() ->
    Bad = [{a, tuple}, #{a => 1}, [not_chars], [-1], [$a, -1], self(), fun() -> ok end],
    [fun() ->
             V = tpl(<<"{{ @v }}">>),
             %% the error names the expression, as written
             ?assertEqual({unsupported_value, V, <<"@v">>, Value},
                          render_error(fun() -> weberl_template:render(V, #{v => Value}) end))
     end || Value <- Bad].

%% agentic: `<<"✓">>' in Erlang source is one byte (the code point modulo 256), not UTF-8;
%% the error said "unsupported" about a value that prints fine.
invalid_utf8_has_its_own_error_test_() ->
    Bad = [<<255, 254>>, <<"✓"/utf8, 200>>, [<<255>>], [$a, <<192>>], <<"ab", 226, 156>>],
    [fun() ->
             V = tpl(<<"{{ @v }}|{{{ @v }}}">>),
             ?assertEqual({invalid_utf8_value, V, <<"@v">>, Value},
                          render_error(fun() -> weberl_template:render(V, #{v => Value}) end))
     end || Value <- Bad]
    ++ [fun() ->
                V = tpl(<<"{{{ @v }}}">>),
                ?assertEqual({invalid_utf8_value, V, <<"@v">>, <<255>>},
                             render_error(fun() -> weberl_template:render(V, #{v => <<255>>}) end))
        end].

unsupported_value_in_raw_test() ->
    V = tpl(<<"{{{ @v }}}">>),
    ?assertEqual({unsupported_value, V, <<"@v">>, {an, atom}},
                 render_error(fun() -> weberl_template:render(V, #{v => {an, atom}}) end)).

invalid_assigns_test() ->
    V = tpl(<<"x">>),
    ?assertEqual({invalid_assigns, V, [{a, 1}]},
                 render_error(fun() -> weberl_template:render(V, [{a, 1}]) end)).

no_template_test() ->
    V = unique_view(),
    ?assertEqual({no_template, V}, render_error(fun() -> weberl_template:render(V, #{}) end)),
    ?assertEqual({error, {no_template, V}}, weberl_template:try_render(V, #{})),
    ?assertNot(weberl_template:has_template(V)).

try_render_test() ->
    V = tpl(<<"{{ @a }}">>),
    ?assert(weberl_template:has_template(V)),
    ?assertMatch({ok, _}, weberl_template:try_render(V, #{a => 1})),
    ?assertEqual({error, {missing_variable, V, a}}, weberl_template:try_render(V, #{})).

%% ---------------------------------------------------------------------
%% syntax and context validation

syntax_errors_carry_file_and_line_test() ->
    ?assertEqual({error, {syntax_error, "views/home_view.weberl", 3, unterminated_interpolation}},
                 weberl_template:compile_source(unique_view(), <<"a\nb\n{{ x">>,
                                                "views/home_view.weberl")).

allowed_contexts_test_() ->
    Ok = [<<"<p>{{@a}}</p>">>,
          <<"<p>{{{@a}}}</p>">>,
          <<"{{@a}}">>,
          <<"<a title=\"{{@a}}\">x</a>">>,
          <<"<a title='{{@a}}'>x</a>">>,
          <<"<input value=\"{{@a}}\" class=\"x\">">>,
          <<"<input class=\"x\" value = \"{{@a}}\"/>">>,
          <<"<!-- c --> {{@a}}">>,
          <<"<!DOCTYPE html><p>{{@a}}</p>">>,
          <<"<script>var x = 1 < 2;</script>{{@a}}">>,
          <<"<style>p { color: red }</style>{{@a}}">>,
          <<"1 < 2 {{@a}}">>,
          <<"<br/>{{@a}}">>,
          <<"<p data-x=\"1\" hidden>{{@a}}</p>">>,
          <<"<textarea>{{@a}}</textarea>">>,
          <<"<p title=\"a > b {{@a}}\">">>],
    [?_assertMatch({ok, _}, compile(Src)) || Src <- Ok].

rejected_contexts_test_() ->
    Cases =
        [{<<"<p {{@a}}>x</p>">>, {interpolation_in_unsupported_context, tag}},
         {<<"<p class={{@a}}>x</p>">>, {interpolation_in_unsupported_context, unquoted_attribute}},
         {<<"<p class=a{{@a}}>x</p>">>, {interpolation_in_unsupported_context, unquoted_attribute}},
         {<<"<{{@a}}>">>, {interpolation_in_unsupported_context, tag}},
         {<<"<p>x</{{@a}}>">>, {interpolation_in_unsupported_context, end_tag}},
         {<<"<div {{@a}}=\"x\">">>, {interpolation_in_unsupported_context, tag}},
         {<<"<div x{{@a}}=\"x\">">>, {interpolation_in_unsupported_context, tag}},
         {<<"<!-- {{@a}} -->">>, {interpolation_in_unsupported_context, comment}},
         {<<"<!DOCTYPE {{@a}}>">>, {interpolation_in_unsupported_context, declaration}},
         {<<"<script>var x = \"{{@a}}\";</script>">>, {interpolation_in_unsupported_context, <<"script">>}},
         {<<"<SCRIPT>{{@a}}</SCRIPT>">>, {interpolation_in_unsupported_context, <<"script">>}},
         {<<"<style>p { color: {{@a}} }</style>">>, {interpolation_in_unsupported_context, <<"style">>}},
         {<<"<img srcset=\"{{@a}}\">">>, {interpolation_in_restricted_attribute, <<"srcset">>}},
         {<<"<IMG SRCSET='{{@a}}'>">>, {interpolation_in_restricted_attribute, <<"srcset">>}},
         {<<"<object data=\"{{@a}}\">x</object>">>, {interpolation_in_restricted_attribute, <<"data">>}},
         {<<"<iframe srcdoc=\"/x/{{@a}}\">">>, {interpolation_in_restricted_attribute, <<"srcdoc">>}},
         {<<"<a onclick=\"{{@a}}\">x</a>">>, {interpolation_in_restricted_attribute, <<"onclick">>}},
         {<<"<p style=\"{{@a}}\">x</p>">>, {interpolation_in_restricted_attribute, <<"style">>}},
         {<<"<p title=\"{{{@a}}}\">x</p>">>, {raw_interpolation_in_attribute, <<"title">>}}],
    [?_assertEqual({1, Reason}, err(Src)) || {Src, Reason} <- Cases].

rejected_context_reports_line_test() ->
    ?assertEqual({3, {interpolation_in_restricted_attribute, <<"srcset">>}},
                 err(<<"<p>\n  ok {{ @a }}\n  <img srcset=\"{{ @b }}\">\n</p>">>)
                 ),
    ok.

context_resumes_after_script_test() ->
    ?assertMatch({ok, _}, compile(<<"<script>x</script>\n<p>{{@a}}</p>">>)),
    ?assertEqual({2, {interpolation_in_unsupported_context, <<"script">>}},
                 err(<<"<p>{{@a}}</p>\n<script>{{@b}}</script>">>)).

%% ---------------------------------------------------------------------
%% compile

invalid_utf8_source_test() ->
    ?assertEqual({error, {invalid_utf8, "t.weberl"}}, compile(<<"ok ", 255, "no">>)).

compile_file_errors_test() ->
    ?assertEqual({error, {read_failed, "/nonexistent/x.weberl", enoent}},
                 weberl_template:compile_file(unique_view(), "/nonexistent/x.weberl")).

compile_does_not_load_test() ->
    V = unique_view(),
    {ok, _} = weberl_template:compile_source(V, <<"x">>, "t.weberl"),
    ?assertNot(weberl_template:has_template(V)).

rendered_without_reading_the_file_again_test() ->
    with_tmp(fun(Dir) ->
        File = filename:join(Dir, "a.weberl"),
        ok = file:write_file(File, <<"v1 {{@x}}">>),
        V = unique_view(),
        ok = weberl_template:compile_and_load_file(V, File),
        ok = file:delete(File),
        ?assertEqual(<<"v1 1">>, render(V, #{x => 1})),
        ?assertEqual(<<"v1 2">>, render(V, #{x => 2}))
    end).

recompiling_replaces_template_test() ->
    with_tmp(fun(Dir) ->
        File = filename:join(Dir, "a.weberl"),
        V = unique_view(),
        ok = file:write_file(File, <<"one">>),
        ok = weberl_template:compile_and_load_file(V, File),
        ?assertEqual(<<"one">>, render(V, #{})),
        ok = file:write_file(File, <<"two">>),
        ok = weberl_template:compile_and_load_file(V, File),
        ?assertEqual(<<"two">>, render(V, #{})),
        ok = file:write_file(File, <<"three">>),
        ok = weberl_template:compile_and_load_file(V, File),
        ?assertEqual(<<"three">>, render(V, #{}))
    end).

generated_module_does_not_touch_view_test() ->
    V = tpl(<<"x">>),
    ?assertEqual(list_to_atom(atom_to_list(V) ++ "__weberl_template"),
                 weberl_template:generated_module(V)),
    ?assertEqual(non_existing, code:which(V)).

generated_module_info_test() ->
    V = tpl(<<"{{ @b }} {{{ @a }}} {{ @b }}">>),
    ?assertMatch(#{view := V, variables := [a, b]},
                 (weberl_template:generated_module(V)):info()).

%% ---------------------------------------------------------------------
%% discovery and association

discover_test() ->
    with_tmp(fun(Dir) ->
        write_tree(Dir, [{"home_view.weberl", <<>>}, {"home_view.erl", <<>>},
                         {"about/about_view.weberl", <<>>}, {"about/notes.txt", <<>>},
                         {"deep/er/x_view.weberl", <<>>}, {".weberl", <<>>}]),
        ?assertEqual([filename:join(Dir, P) ||
                         P <- ["about/about_view.weberl", "deep/er/x_view.weberl",
                               "home_view.weberl"]],
                     weberl_template:discover(Dir)),
        ?assertEqual([], weberl_template:discover(filename:join(Dir, "nope")))
    end).

associate_test() ->
    Views = [{home_view, "r/home_view.erl"}, {about_view, "r/about/about_view.erl"},
             {plain_view, "r/plain_view.erl"}],
    Templates = ["r/home_view.weberl", "r/about/about_view.weberl"],
    ?assertEqual({ok, [{about_view, "r/about/about_view.weberl"},
                       {home_view, "r/home_view.weberl"}]},
                 weberl_template:associate(Templates, Views)).

associate_view_without_template_is_fine_test() ->
    ?assertEqual({ok, []}, weberl_template:associate([], [{plain_view, "r/plain_view.erl"}])).

associate_normalizes_paths_test() ->
    ?assertEqual({ok, [{home_view, "r//home_view.weberl"}]},
                 weberl_template:associate(["r//home_view.weberl"], [{home_view, "r/home_view.erl"}])).

associate_template_must_be_in_same_directory_test() ->
    ?assertEqual({error, {unassociated_templates, ["r/other/home_view.weberl"]}},
                 weberl_template:associate(["r/other/home_view.weberl"],
                                           [{home_view, "r/home_view.erl"}])).

associate_unassociated_test() ->
    ?assertEqual({error, {unassociated_templates, ["r/a.weberl", "r/z.weberl"]}},
                 weberl_template:associate(["r/z.weberl", "r/a.weberl", "r/home_view.weberl"],
                                           [{home_view, "r/home_view.erl"}])).

associate_duplicates_test() ->
    %% one view module reachable from two source files with a template each
    ?assertEqual({error, {duplicate_template_associations,
                          [{home_view, ["r/a/home_view.weberl", "r/b/home_view.weberl"]}]}},
                 weberl_template:associate(["r/b/home_view.weberl", "r/a/home_view.weberl"],
                                           [{home_view, "r/a/home_view.erl"},
                                            {home_view, "r/b/home_view.erl"}])).
