-module(weberl_table_tests).
-include_lib("eunit/include/eunit.hrl").

-import_record(weberl_config, [router, filesystem_router]).

-import(weberl_test_util, [with_tmp/1, write_tree/2, view_src/1, unique/1, load_router/2]).

pairs(Table) ->
    [{weberl_route:path(R), weberl_route:handler(R)} || R <- weberl:routes(Table)].

fs(Root) -> #filesystem_router{root = Root}.
fs(Root, Prefix) -> #filesystem_router{root = Root, prefix = Prefix}.

%% Configuration errors surface through build/1

invalid_config_is_an_error_not_a_crash_test() ->
    ?assertMatch({error, {invalid_config, _}}, weberl:build(not_a_config)),
    ?assertMatch({error, {invalid_config, _}},
                 weberl:build(#router{filesystem = [{"a", "/"}]})).

empty_config_test() ->
    {ok, T} = weberl:build(#router{}),
    ?assertEqual([], weberl:routes(T)),
    ?assertEqual([], weberl:shadowed(T)),
    ?assertEqual({error, not_found}, weberl:lookup("/", T)).

%% Filesystem only

filesystem_only_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"home_view.erl", view_src(home_view)},
                       {"about/company_information_view.erl", view_src(company_information_view)},
                       {"blog/blog_view.erl", view_src(blog_view)},
                       {"blog/posts/posts_view.erl", view_src(posts_view)},
                       {"users/users_view.erl", view_src(users_view)}]),
        {ok, T} = weberl:build(#router{filesystem = [fs(D)]}),
        ?assertEqual([{"/", home_view}, {"/about", company_information_view},
                      {"/blog", blog_view}, {"/blog/posts", posts_view},
                      {"/users", users_view}], pairs(T))
    end).

multiple_roots_with_prefixes_test() ->
    with_tmp(fun(D) ->
        Main = filename:join(D, "views"),
        Admin = filename:join(D, "admin_views"),
        write_tree(Main, [{"home_view.erl", view_src(home_view)}]),
        write_tree(Admin, [{"admin_home_view.erl", view_src(admin_home_view)},
                           {"users/admin_users_view.erl", view_src(admin_users_view)}]),
        {ok, T} = weberl:build(#router{filesystem = [fs(Main, "/"), fs(Admin, "/admin")]}),
        ?assertEqual([{"/", home_view}, {"/admin", admin_home_view},
                      {"/admin/users", admin_users_view}], pairs(T))
    end).

missing_root_directory_test() ->
    with_tmp(fun(D) ->
        Missing = filename:join(D, "nope"),
        ?assertEqual({error, {root_not_a_directory, Missing}},
                     weberl:build(#router{filesystem = [fs(Missing)]}))
    end).

empty_root_directory_test() ->
    with_tmp(fun(D) ->
        {ok, T} = weberl:build(#router{filesystem = [fs(D)]}),
        ?assertEqual([], weberl:routes(T))
    end).

%% Filesystem conflicts

multiple_views_in_one_directory_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"about/about_view.erl", view_src(about_view)},
                       {"about/company_view.erl", view_src(company_view)}]),
        A = filename:join([D, "about", "about_view.erl"]),
        C = filename:join([D, "about", "company_view.erl"]),
        ?assertEqual({error, {duplicate_routes, filesystem,
                              [{"/about", [{about_view, A}, {company_view, C}]}]}},
                     weberl:build(#router{filesystem = [fs(D)]}))
    end).

duplicate_routes_across_roots_test() ->
    with_tmp(fun(D) ->
        R1 = filename:join(D, "r1"),
        R2 = filename:join(D, "r2"),
        write_tree(R1, [{"about/x_view.erl", view_src(x_view)}]),
        write_tree(R2, [{"about/y_view.erl", view_src(y_view)}]),
        X = filename:join([R1, "about", "x_view.erl"]),
        Y = filename:join([R2, "about", "y_view.erl"]),
        ?assertEqual({error, {duplicate_routes, filesystem,
                              [{"/about", [{x_view, X}, {y_view, Y}]}]}},
                     weberl:build(#router{filesystem = [fs(R1), fs(R2)]})),
        %% Distinct prefixes resolve the conflict.
        ?assertMatch({ok, _},
                     weberl:build(#router{filesystem = [fs(R1), fs(R2, "/other")]}))
    end).

duplicate_module_names_test() ->
    with_tmp(fun(D) ->
        R1 = filename:join(D, "r1"),
        R2 = filename:join(D, "r2"),
        write_tree(R1, [{"a/x_view.erl", view_src(x_view)}]),
        write_tree(R2, [{"b/x_view.erl", view_src(x_view)}]),
        F1 = filename:join([R1, "a", "x_view.erl"]),
        F2 = filename:join([R2, "b", "x_view.erl"]),
        ?assertEqual({error, {duplicate_modules, [{x_view, [{"/a", F1}, {"/b", F2}]}]}},
                     weberl:build(#router{filesystem = [fs(R1), fs(R2)]}))
    end).

%% Declarative only

declarative_only_test() ->
    M = unique("tbl_decl"),
    load_router(M, [{"/health", health_handler},
                    {"/api/users", generic_api_handler},
                    {"/api/posts", generic_api_handler}]),
    {ok, T} = weberl:build(#router{modules = [M]}),
    ?assertEqual([{"/api/posts", generic_api_handler}, {"/api/users", generic_api_handler},
                  {"/health", health_handler}], pairs(T)),
    ?assertEqual({ok, generic_api_handler}, weberl:handler("/api/users", T)),
    ?assertEqual({ok, generic_api_handler}, weberl:handler("/api/posts", T)).

declarative_duplicate_in_one_module_test() ->
    M = unique("tbl_dup1"),
    load_router(M, [{"/a", h1}, {"/a/", h2}]),
    ?assertEqual({error, {duplicate_routes, declarative, [{"/a", [{h1, M}, {h2, M}]}]}},
                 weberl:build(#router{modules = [M]})).

declarative_duplicate_across_modules_test() ->
    M1 = unique("tbl_dup2a"),
    M2 = unique("tbl_dup2b"),
    load_router(M1, [{"/health", h1}]),
    load_router(M2, [{"/health", h2}]),
    ?assertEqual({error, {duplicate_routes, declarative,
                          [{"/health", [{h1, M1}, {h2, M2}]}]}},
                 weberl:build(#router{modules = [M1, M2]})).

declarative_error_propagates_test() ->
    M = unique("tbl_bad"),
    load_router(M, [{"nope", h}]),
    ?assertMatch({error, {invalid_route, M, _, _}}, weberl:build(#router{modules = [M]})).

%% Combined

combined_precedence_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"about/about_view.erl", view_src(about_view)}]),
        M = unique("tbl_comb"),
        load_router(M, [{"/about", legacy_about}, {"/extra", extra_handler}]),
        {ok, T} = weberl:build(#router{filesystem = [fs(D)], modules = [M]}),
        %% Filesystem wins for identical identity; non-conflicting declarative stays.
        ?assertEqual([{"/about", about_view}, {"/extra", extra_handler}], pairs(T)),
        {ok, R} = weberl:lookup("/about", T),
        ?assertEqual(filesystem, weberl_route:origin(R)),
        {ok, R2} = weberl:lookup("/extra", T),
        ?assertEqual(declarative, weberl_route:origin(R2)),
        ?assertEqual([{"/about", legacy_about}],
                     [{weberl_route:path(S), weberl_route:handler(S)}
                      || S <- weberl:shadowed(T)])
    end).

same_module_as_fs_and_declarative_handler_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"home_view.erl", view_src(home_view)}]),
        M = unique("tbl_samemod"),
        load_router(M, [{"/alias", home_view}]),
        {ok, T} = weberl:build(#router{filesystem = [fs(D)], modules = [M]}),
        ?assertEqual([{"/", home_view}, {"/alias", home_view}], pairs(T))
    end).

%% Ordering

deterministic_ordering_test() ->
    with_tmp(fun(D) ->
        A = filename:join(D, "a"),
        B = filename:join(D, "b"),
        write_tree(A, [{"home_view.erl", view_src(home_view)},
                       {"z/z_view.erl", view_src(z_view)}]),
        write_tree(B, [{"b_view.erl", view_src(b_view)}]),
        M = unique("tbl_ord"),
        load_router(M, [{"/m", m_handler}, {"/a", a_handler}]),
        {ok, T1} = weberl:build(#router{filesystem = [fs(A), fs(B, "/b")], modules = [M]}),
        {ok, T2} = weberl:build(#router{filesystem = [fs(B, "/b"), fs(A)], modules = [M]}),
        ?assertEqual(weberl:routes(T1), weberl:routes(T2)),
        ?assertEqual([{"/", home_view}, {"/a", a_handler}, {"/b", b_view},
                      {"/m", m_handler}, {"/z", z_view}], pairs(T1))
    end).

%% Lookup

exact_lookup_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"blog/blog_view.erl", view_src(blog_view)},
                       {"blog/posts/posts_view.erl", view_src(posts_view)}]),
        {ok, T} = weberl:build(#router{filesystem = [fs(D)]}),
        ?assertEqual({ok, blog_view}, weberl:handler("/blog", T)),
        ?assertEqual({ok, posts_view}, weberl:handler("/blog/posts", T)),
        %% Request path is normalized before lookup.
        ?assertEqual({ok, posts_view}, weberl:handler("/blog/posts/", T)),
        %% Exact match only.
        ?assertEqual({error, not_found}, weberl:handler("/blog/posts/1", T)),
        ?assertEqual({error, not_found}, weberl:handler("/Blog", T)),
        ?assertEqual({error, not_found}, weberl:handler("/", T)),
        ?assertEqual({error, not_found}, weberl:handler("blog", T)),
        ?assertEqual({error, not_found}, weberl:handler(<<"/blog">>, T)),
        {ok, Route} = weberl:lookup("/blog", T),
        ?assertEqual(filesystem, weberl_route:origin(Route))
    end).
