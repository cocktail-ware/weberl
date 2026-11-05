%% Links in URL attributes (HANDOFF decisions 8 and 9). The complaints behind them: a link
%% with an id in it, or a `next' parameter, needs a URL escape (HTML escaping is not enough),
%% and a template should fail to compile when a link points at a route that does not exist.
-module(weberl_template_urls_tests).
-include_lib("eunit/include/eunit.hrl").

view() -> weberl_test_handlers:unique("urlview").

table() ->
    Routes = [weberl_route:new(P, weberl_test_handlers, declarative, weberl_test_handlers)
              || P <- ["/", "/agents", "/agents/new", "/docs/intro", "/docs/api", "/about"]],
    {ok, Table} = weberl_table:assemble([], Routes),
    Table.

compile(Src) -> compile(Src, #{}).
compile(Src, Opts) -> weberl_template:compile_source(view(), Src, "t.weberl", none, Opts).

routed(Src) -> compile(Src, #{routes => table()}).

%% {Line, Reason} of a compile error
err(Result) ->
    {error, {syntax_error, "t.weberl", Line, Reason}} = Result,
    {Line, Reason}.

tpl(Src, Opts) ->
    View = view(),
    {ok, C} = weberl_template:compile_source(View, Src, "t.weberl", none, Opts),
    ok = weberl_template:load(C),
    View.

render(Src, Assigns) -> iolist_to_binary(weberl_template:render(tpl(Src, #{}), Assigns)).

render_error(Fun) ->
    try Fun() of V -> {no_error, V}
    catch error:{template_error, Reason} -> Reason end.

with_router(Fun) ->
    Name = list_to_atom("url_tpl_router_" ++ integer_to_list(erlang:unique_integer([positive]))),
    persistent_term:put({weberl_router, Name}, table()),
    try weberl_url:with_router(Name, Fun)
    after persistent_term:erase({weberl_router, Name})
    end.

%% ---------------------------------------------------------------------
%% The complaint: an id and a `next' parameter in a link

an_id_in_a_path_is_percent_encoded_test() ->
    T = <<"<a href=\"/agents/{{ weberl_url:component(@id) }}\">x</a>">>,
    ?assertEqual(<<"<a href=\"/agents/7\">x</a>">>, render(T, #{id => 7})),
    ?assertEqual(<<"<a href=\"/agents/a%20b%2Fc\">x</a>">>, render(T, #{id => <<"a b/c">>})),
    %% HTML escaping alone would let these through
    ?assertEqual(<<"<a href=\"/agents/..%2F..%2Fsecret\">x</a>">>, render(T, #{id => <<"../../secret">>})),
    ?assertEqual(<<"<a href=\"/agents/%22%3E%3Cscript%3E\">x</a>">>, render(T, #{id => <<"\"><script>">>})).

a_next_parameter_is_encoded_as_a_query_value_test() ->
    T = <<"<a href=\"/login?next={{ weberl_url:component(@next) }}\">x</a>">>,
    ?assertEqual(<<"<a href=\"/login?next=%2Fa%3Fb%3D1%26c%3D2\">x</a>">>, render(T, #{next => <<"/a?b=1&c=2">>})),
    Q = <<"<form action=\"/login?{{ weberl_url:query(#{next => @next, tab => 2}) }}\"></form>">>,
    ?assertEqual(<<"<form action=\"/login?next=%2Fa%3Fb%3D1%26c%3D2&amp;tab=2\"></form>">>,
                 render(Q, #{next => <<"/a?b=1&c=2">>})).

a_whole_url_from_data_has_to_be_checked_test() ->
    T = <<"<a href=\"{{ weberl_url:ensure_path(@next) }}\">x</a>">>,
    ?assertEqual(<<"<a href=\"/home\">x</a>">>, render(T, #{next => <<"/home">>})),
    V = tpl(T, #{}),
    ?assertEqual({not_a_path, <<"javascript:alert(1)">>},
                 render_error(fun() -> weberl_template:render(V, #{next => <<"javascript:alert(1)">>}) end)),
    ?assertEqual({not_a_path, <<"//evil.com">>},
                 render_error(fun() -> weberl_template:render(V, #{next => <<"//evil.com">>}) end)),
    W = tpl(<<"<a href=\"{{ weberl_url:url(@link) }}\">x</a>">>, #{}),
    ?assertEqual(<<"<a href=\"https://example.com/a?b=1&amp;c=2\">x</a>">>,
                 iolist_to_binary(weberl_template:render(W, #{link => <<"https://example.com/a?b=1&c=2">>}))),
    ?assertEqual({not_a_url, <<"javascript:alert(1)">>},
                 render_error(fun() -> weberl_template:render(W, #{link => <<"javascript:alert(1)">>}) end)).

unsafe_url_skips_the_checks_but_not_the_html_escaping_test() ->
    T = <<"<a href=\"{{ weberl_url:unsafe_url(@l) }}\">x</a>">>,
    ?assertEqual(<<"<a href=\"mailto:a@b.c\">x</a>">>, render(T, #{l => <<"mailto:a@b.c">>})),
    ?assertEqual(<<"<a href=\"x&quot; onmouseover=&quot;y\">x</a>">>, render(T, #{l => <<"x\" onmouseover=\"y">>})).

%% ---------------------------------------------------------------------
%% Only values from the helpers

a_plain_value_in_a_url_attribute_raises_when_rendered_test() ->
    V = tpl(<<"<a href=\"{{ @next }}\">x</a>">>, #{}),
    ?assertEqual({untagged_url, V, 1, <<"/x">>},
                 render_error(fun() -> weberl_template:render(V, #{next => <<"/x">>}) end)),
    ?assertEqual({untagged_url, V, 1, <<"javascript:alert(1)">>},
                 render_error(fun() -> weberl_template:render(V, #{next => <<"javascript:alert(1)">>}) end)).

a_literal_in_a_url_attribute_is_a_compile_error_test() ->
    ?assertMatch({1, {untagged_url, _}}, err(compile(<<"<a href=\"{{ \"/x\" }}\">x</a>">>))),
    ?assertMatch({1, {untagged_url, _}}, err(compile(<<"<a href=\"{{ some_atom }}\">x</a>">>))),
    ?assertMatch({1, {untagged_url, _}}, err(compile(<<"<a href=\"{{ 42 }}\">x</a>">>))),
    %% a function of weberl_url that does not make a URL value
    ?assertMatch({1, {untagged_url, _}}, err(compile(<<"<a href=\"{{ weberl_url:local(@x) }}\">x</a>">>))).

raw_interpolation_stays_rejected_in_url_attributes_test() ->
    ?assertEqual({1, {raw_interpolation_in_attribute, <<"href">>}},
                 err(compile(<<"<a href=\"{{{ weberl_url:unsafe_url(@x) }}}\">x</a>">>))).

other_restricted_attributes_stay_literal_test() ->
    [?assertEqual({1, {interpolation_in_restricted_attribute, Attr}},
                  err(compile(<<"<p ", Attr/binary, "=\"{{ weberl_url:unsafe_url(@x) }}\">x</p>">>)))
     || Attr <- [<<"style">>, <<"onclick">>, <<"srcset">>, <<"data">>, <<"srcdoc">>, <<"ping">>, <<"is">>]].

%% ---------------------------------------------------------------------
%% Position and policy (what the element accepts)

a_part_helper_needs_literal_text_before_it_test() ->
    ?assertEqual({1, {misplaced_url_helper, component}},
                 err(compile(<<"<a href=\"{{ weberl_url:component(@x) }}\">x</a>">>))),
    ?assertEqual({1, {misplaced_url_helper, query}},
                 err(compile(<<"<a href=\"{{ weberl_url:query(#{}) }}\">x</a>">>))),
    %% a whole-URL helper after literal text would build `/x//y' or `/xhttps://..'
    ?assertEqual({1, {misplaced_url_helper, ensure_path}},
                 err(compile(<<"<a href=\"/x{{ weberl_url:ensure_path(@y) }}\">x</a>">>))),
    ?assertEqual({1, {misplaced_url_helper, url}},
                 err(compile(<<"<a href=\"/x{{ weberl_url:url(@y) }}\">x</a>">>))),
    %% fine
    ?assertMatch({ok, _}, compile(<<"<a href=\"/x/{{ weberl_url:component(@y) }}\">x</a>">>)),
    ?assertMatch({ok, _}, compile(<<"<a href=\"{{ weberl_url:ensure_path(@a) }}{{ weberl_url:component(@b) }}\">x</a>">>)),
    ?assertMatch({ok, _}, compile(<<"<a href=\"{{ weberl_url:ensure_path(@a) }}#top\">x</a>">>)),
    ?assertMatch({ok, _}, compile(<<"<a href=\"{{ weberl_url:unsafe_url(@a) }}\">x</a>">>)).

elements_that_load_code_take_local_paths_only_test() ->
    Sinks = [<<"<script src=\"~s\"></script>">>, <<"<iframe src=\"~s\"></iframe>">>,
             <<"<embed src=\"~s\">">>, <<"<link rel=\"stylesheet\" href=\"~s\">">>, <<"<base href=\"~s\">">>],
    [begin
         With = fun(Expr) -> iolist_to_binary(string:replace(Sink, "~s", Expr)) end,
         ?assertMatch({ok, _}, compile(With(<<"{{ weberl_url:ensure_path(@p) }}">>))),
         ?assertMatch({ok, _}, compile(With(<<"{{ weberl_url:unsafe_url(@p) }}">>))),
         ?assertMatch({ok, _}, compile(With(<<"/static/{{ weberl_url:component(@p) }}.js">>))),
         ?assertMatch({1, {url_not_allowed_here, url, _, _}}, err(compile(With(<<"{{ weberl_url:url(@p) }}">>)))),
         ?assertMatch({1, {url_not_allowed_here, component, _, _}},
                      err(compile(With(<<"https://cdn.example.com/{{ weberl_url:component(@p) }}">>))))
     end || Sink <- Sinks],
    ?assertEqual({1, {url_not_allowed_here, url, <<"script">>, <<"src">>}},
                 err(compile(<<"<script src=\"{{ weberl_url:url(@s) }}\"></script>">>))),
    ?assertEqual({1, {url_not_allowed_here, router_url, <<"base">>, <<"href">>}},
                 err(compile(<<"<base href=\"{{ weberl_url:router_url(\"/a\") }}\">">>))).

ordinary_elements_take_web_urls_test() ->
    [?assertMatch({ok, _}, compile(iolist_to_binary(string:replace(Tpl, "~s", <<"{{ weberl_url:url(@p) }}">>))))
     || Tpl <- [<<"<a href=\"~s\">x</a>">>, <<"<img src=\"~s\">">>, <<"<form action=\"~s\"></form>">>,
                <<"<button formaction=\"~s\">x</button>">>, <<"<video poster=\"~s\"></video>">>,
                <<"<blockquote cite=\"~s\">x</blockquote>">>, <<"<audio src=\"~s\"></audio>">>]].

a_kind_the_attribute_does_not_take_raises_when_rendered_test() ->
    %% the compiler cannot see through an assign: the render-time check does
    Script = tpl(<<"<script src=\"{{ @s }}\"></script>">>, #{}),
    ?assertEqual({unsafe_url, Script, 1, {weberl_url, url, <<"https://evil.example/x.js">>}},
                 render_error(fun() -> weberl_template:render(Script, #{s => weberl_url:url(<<"https://evil.example/x.js">>)}) end)),
    ?assertEqual(<<"<script src=\"/x.js\"></script>">>,
                 iolist_to_binary(weberl_template:render(Script, #{s => weberl_url:ensure_path(<<"/x.js">>)}))),
    Link = tpl(<<"<a href=\"{{ @s }}\">x</a>">>, #{}),
    ?assertMatch({unsafe_url, Link, 1, {weberl_url, component, <<"x">>}},
                 render_error(fun() -> weberl_template:render(Link, #{s => weberl_url:component(<<"x">>)}) end)),
    Inner = tpl(<<"<a href=\"/x/{{ @s }}\">x</a>">>, #{}),
    ?assertMatch({unsafe_url, Inner, 1, {weberl_url, path, <<"/y">>}},
                 render_error(fun() -> weberl_template:render(Inner, #{s => weberl_url:ensure_path(<<"/y">>)}) end)),
    %% a forged tuple of the wrong shape is simply untagged
    ?assertMatch({untagged_url, Link, 1, {weberl_url, path}},
                 render_error(fun() -> weberl_template:render(Link, #{s => {weberl_url, path}}) end)).

errors_carry_the_template_line_test() ->
    ?assertEqual({3, {untagged_url, <<"\"/x\"">>}},
                 err(compile(<<"<p>\n  ok\n  <a href=\"{{ \"/x\" }}\">x</a>\n</p>">>))).

blocks_and_loops_around_links_work_test() ->
    T = <<"{: for Id <- @ids :}<a href=\"/agents/{{ weberl_url:component(Id) }}\">{{ Id }}</a>{: /for :}">>,
    ?assertEqual(<<"<a href=\"/agents/1\">1</a><a href=\"/agents/b%2Fc\">b/c</a>">>,
                 render(T, #{ids => [1, <<"b/c">>]})),
    U = <<"{: if @in :}<a href=\"{{ weberl_url:ensure_path(@home) }}\">Home</a>{: else :}<a href=\"/login\">In</a>{: /if :}">>,
    ?assertEqual(<<"<a href=\"/h\">Home</a>">>, render(U, #{in => true, home => <<"/h">>})),
    ?assertEqual(<<"<a href=\"/login\">In</a>">>, render(U, #{in => false, home => <<"//x">>})).

%% ---------------------------------------------------------------------
%% Literal arguments are checked when the template compiles

literal_arguments_are_checked_test() ->
    ?assertEqual({1, {not_a_path, <<"https://x.com">>}},
                 err(compile(<<"<a href=\"{{ weberl_url:ensure_path(\"https://x.com\") }}\">x</a>">>))),
    ?assertEqual({1, {not_a_path, <<"relative">>}},
                 err(compile(<<"<a href=\"{{ weberl_url:ensure_path(<<\"relative\">>) }}\">x</a>">>))),
    ?assertEqual({1, {not_a_url, <<"javascript:x">>}},
                 err(compile(<<"<a href=\"{{ weberl_url:url(\"javascript:x\") }}\">x</a>">>))),
    ?assertMatch({ok, _}, compile(<<"<a href=\"{{ weberl_url:ensure_path(\"/ok\") }}\">x</a>">>)),
    ?assertMatch({ok, _}, compile(<<"<a href=\"{{ weberl_url:url(\"https://ok.example\") }}\">x</a>">>)).

%% ---------------------------------------------------------------------
%% router_path / router_url against the route table

a_literal_route_is_checked_against_the_table_test() ->
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/agents\") }}\">x</a>">>)),
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(<<\"/agents/new\">>) }}\">x</a>">>)),
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path('/about') }}\">x</a>">>)),
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/agents/\") }}\">x</a>">>)),
    ?assertEqual({1, {unknown_route, <<"/agnts">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"/agnts\") }}\">x</a>">>))),
    ?assertEqual({2, {unknown_route, <<"/agents/7">>}},
                 err(routed(<<"<p>\n<a href=\"{{ weberl_url:router_url(\"/agents/7\") }}\">x</a></p>">>))),
    ?assertEqual({1, {not_a_path, <<"agents">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"agents\") }}\">x</a>">>))).

without_a_table_the_route_check_is_skipped_test() ->
    ?assertMatch({ok, _}, compile(<<"<a href=\"{{ weberl_url:router_path(\"/nope\") }}\">x</a>">>)),
    %% what needs no table is still checked
    ?assertEqual({1, {unverifiable_route, router_path}},
                 err(compile(<<"<a href=\"{{ weberl_url:router_path(@target) }}\">x</a>">>))),
    ?assertEqual({1, {not_a_path, <<"agents">>}},
                 err(compile(<<"<a href=\"{{ weberl_url:router_path(\"agents\") }}\">x</a>">>))).

a_route_that_is_not_a_literal_cannot_be_verified_test() ->
    [?assertEqual({1, {unverifiable_route, Fun}}, err(routed(Src)))
     || {Fun, Src} <- [{router_path, <<"<a href=\"{{ weberl_url:router_path(@target) }}\">x</a>">>},
                       {router_url, <<"<a href=\"{{ weberl_url:router_url(@target) }}\">x</a>">>},
                       {router_path, <<"<a href=\"{{ weberl_url:router_path([\"/a\", @b]) }}\">x</a>">>},
                       {router_path, <<"{: for P <- @ps :}<a href=\"{{ weberl_url:router_path(P) }}\">x</a>{: /for :}">>}]].

route_options_are_checked_test() ->
    ?assertEqual({1, {bad_url_option, nope}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"/agents\", #{nope => 1}) }}\">x</a>">>))),
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/agents\", #{query => #{q => @q}}) }}\">x</a>">>)),
    %% another router that is not running: its table is not known, the check is left to render time
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/nope\", #{router => no_such_router}) }}\">x</a>">>)).

%% ---------------------------------------------------------------------
%% Placeholders in a route string: one segment each

a_placeholder_compiles_with_a_warning_test() ->
    {ok, C} = routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\") }}\">x</a>">>),
    ?assertEqual([{warning, "t.weberl", 1, {dynamic_route_segment, <<"/docs/{{ @page }}">>}}],
                 weberl_template:warnings(C)),
    {ok, Quiet} = routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\", #{no_warn => true}) }}\">x</a>">>),
    ?assertEqual([], weberl_template:warnings(Quiet)),
    {ok, Plain} = routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/intro\") }}\">x</a>">>),
    ?assertEqual([], weberl_template:warnings(Plain)),
    %% the warning is about the unknown value: it is given without a table too
    {ok, NoTable} = compile(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\") }}\">x</a>">>),
    ?assertMatch([{warning, _, 1, {dynamic_route_segment, _}}], weberl_template:warnings(NoTable)).

a_placeholder_has_to_match_the_shape_of_a_route_test() ->
    %% one segment per placeholder: /docs/{x} matches /docs/api, but not /agents/new/x
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @p }}\") }}\">x</a>">>)),
    ?assertEqual({1, {unknown_route, <<"/docs/{{ @p }}/x">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @p }}/x\") }}\">x</a>">>))),
    ?assertEqual({1, {unknown_route, <<"/nothing/{{ @p }}">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"/nothing/{{ @p }}\") }}\">x</a>">>))),
    %% one placeholder at the root matches the one-segment routes (`/about', `/agents'); no
    %% route has three segments
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/{{ @p }}\", #{no_warn => true}) }}\">x</a>">>)),
    ?assertEqual({1, {unknown_route, <<"/{{ @a }}/{{ @b }}/{{ @c }}">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"/{{ @a }}/{{ @b }}/{{ @c }}\") }}\">x</a>">>))),
    %% several placeholders, one segment each
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/{{ @a }}/{{ @b }}\", #{no_warn => true}) }}\">x</a>">>)),
    %% a trailing slash names the same route
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @p }}/\", #{no_warn => true}) }}\">x</a>">>)),
    %% a placeholder inside a segment
    ?assertMatch({ok, _}, routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/i{{ @p }}\", #{no_warn => true}) }}\">x</a>">>)),
    ?assertEqual({1, {unknown_route, <<"/docs/z{{ @p }}">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"/docs/z{{ @p }}\") }}\">x</a>">>))),
    %% a route has to start with a literal slash
    ?assertEqual({1, {not_a_path, <<"{{ @p }}/x">>}},
                 err(routed(<<"<a href=\"{{ weberl_url:router_path(\"{{ @p }}/x\") }}\">x</a>">>))).

placeholders_become_dependencies_and_locals_are_scoped_test() ->
    View = tpl(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\", #{no_warn => true}) }}\">x</a>">>, #{}),
    ?assertEqual([page], maps:get(variables, (weberl_template:generated_module(View)):info())),
    %% a local bound by a loop is usable in a placeholder, an unbound one is an error
    ?assertMatch({ok, _}, compile(<<"{: for P <- @ps :}<a href=\"{{ weberl_url:router_path(\"/docs/{{ P }}\", #{no_warn => true}) }}\">x</a>{: /for :}">>)),
    ?assertEqual({1, {unbound_variable, 'P'}},
                 err(compile(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ P }}\", #{no_warn => true}) }}\">x</a>">>))).

bad_placeholders_are_errors_test() ->
    ?assertEqual({1, {bad_placeholder, empty}},
                 err(compile(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{  }}\") }}\">x</a>">>))),
    ?assertMatch({1, {bad_placeholder, {invalid_expression, _, _}}},
                 err(compile(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ 1 + }}\") }}\">x</a>">>))),
    ?assertMatch({1, {bad_placeholder, unterminated}},
                 err(compile(<<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @p\") }}\">x</a>">>))).

%% ---------------------------------------------------------------------
%% At render time: the router of the request

a_dynamic_route_is_checked_when_rendered_test() ->
    T = <<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\", #{no_warn => true}) }}\">x</a>">>,
    %% compiled with the table: the routes the link can match are in the generated code, so
    %% no router is needed to render, in whichever process that happens
    V = tpl(T, #{routes => table()}),
    Check = fun() ->
        ?assertEqual(<<"<a href=\"/docs/api\">x</a>">>, iolist_to_binary(weberl_template:render(V, #{page => <<"api">>}))),
        ?assertEqual({unknown_route, <<"/docs/nope">>},
                     render_error(fun() -> weberl_template:render(V, #{page => <<"nope">>}) end)),
        %% a value with a slash cannot pass as two segments
        ?assertEqual({unknown_route, <<"/docs/a%2Fb">>},
                     render_error(fun() -> weberl_template:render(V, #{page => <<"a/b">>}) end)),
        ?assertEqual({unknown_route, <<"/docs/..%2Fabout">>},
                     render_error(fun() -> weberl_template:render(V, #{page => <<"../about">>}) end)),
        %% only the routes of the pattern's shape are known: /about is a route, but not /docs/about
        ?assertEqual({unknown_route, <<"/docs/about">>},
                     render_error(fun() -> weberl_template:render(V, #{page => <<"about">>}) end)),
        ?assertEqual({empty_segment, <<>>},
                     render_error(fun() -> weberl_template:render(V, #{page => <<>>}) end))
    end,
    Check(),
    Self = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Check(), Self ! {done, self()} end),
    receive {done, Pid} -> ok end,
    receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason) end.

without_the_table_the_router_of_the_process_is_used_test() ->
    T = <<"<a href=\"{{ weberl_url:router_path(\"/docs/{{ @page }}\", #{no_warn => true}) }}\">x</a>">>,
    V = tpl(T, #{}),
    ?assertEqual(no_router, render_error(fun() -> weberl_template:render(V, #{page => <<"api">>}) end)),
    with_router(fun() ->
        ?assertEqual(<<"<a href=\"/docs/api\">x</a>">>, iolist_to_binary(weberl_template:render(V, #{page => <<"api">>}))),
        ?assertEqual({unknown_route, <<"/docs/nope">>},
                     render_error(fun() -> weberl_template:render(V, #{page => <<"nope">>}) end))
    end).

several_placeholders_and_a_query_at_render_test() ->
    T = <<"<a href=\"{{ weberl_url:router_path(\"/{{ @a }}/{{ @b }}\", #{no_warn => true, query => #{q => @q}}) }}\">x</a>">>,
    V = tpl(T, #{}),
    with_router(fun() ->
        ?assertEqual(<<"<a href=\"/docs/api?q=a%20b\">x</a>">>,
                     iolist_to_binary(weberl_template:render(V, #{a => docs, b => api, q => <<"a b">>}))),
        ?assertEqual({unknown_route, <<"/docs/nope">>},
                     render_error(fun() -> weberl_template:render(V, #{a => <<"docs">>, b => <<"nope">>, q => 1}) end))
    end).

a_literal_route_renders_its_path_and_url_test() ->
    V = tpl(<<"<a href=\"{{ weberl_url:router_path(\"/agents\") }}\">x</a>">>, #{routes => table()}),
    ?assertEqual(<<"<a href=\"/agents\">x</a>">>, iolist_to_binary(weberl_template:render(V, #{}))),
    %% with the table the route is already known: a trailing slash is the same route
    W = tpl(<<"<a href=\"{{ weberl_url:router_path(\"/agents/\", #{query => #{a => 1}}) }}\">x</a>">>,
            #{routes => table()}),
    ?assertEqual(<<"<a href=\"/agents?a=1\">x</a>">>, iolist_to_binary(weberl_template:render(W, #{}))),
    %% router_url adds the public URL when rendering
    U = tpl(<<"<a href=\"{{ weberl_url:router_url(\"/agents\") }}\">x</a>">>, #{routes => table()}),
    ?assertEqual(no_public_url, render_error(fun() -> weberl_template:render(U, #{}) end)),
    application:set_env(weberl, public_url, "https://example.com"),
    try ?assertEqual(<<"<a href=\"https://example.com/agents\">x</a>">>, iolist_to_binary(weberl_template:render(U, #{})))
    after application:unset_env(weberl, public_url)
    end.

a_route_that_goes_missing_after_compiling_raises_when_rendered_test() ->
    %% compiled without a table: the render-time check is the only one
    V = tpl(<<"<a href=\"{{ weberl_url:router_path(\"/gone\") }}\">x</a>">>, #{}),
    with_router(fun() ->
        ?assertEqual({unknown_route, <<"/gone">>}, render_error(fun() -> weberl_template:render(V, #{}) end))
    end).
