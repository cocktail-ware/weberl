-module(weberl_fs_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_test_util, [with_tmp/1, write_tree/2, view_src/1]).

pairs(Routes) ->
    [{weberl_route:path(R), weberl_route:handler(R)} || R <- Routes].

root_route_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"home_view.erl", view_src(home_view)}]),
        {ok, [R]} = weberl_fs:discover(D, "/"),
        ?assertEqual("/", weberl_route:path(R)),
        ?assertEqual(home_view, weberl_route:handler(R)),
        ?assertEqual(filesystem, weberl_route:origin(R)),
        ?assertEqual(filename:join(D, "home_view.erl"), weberl_route:source(R))
    end).

nested_directories_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"home_view.erl", view_src(home_view)},
                       {"about/about_view.erl", view_src(about_view)},
                       {"blog/blog_view.erl", view_src(blog_view)},
                       {"blog/posts/posts_view.erl", view_src(posts_view)},
                       {"users/users_view.erl", view_src(users_view)}]),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        ?assertEqual([{"/", home_view}, {"/about", about_view}, {"/blog", blog_view},
                      {"/blog/posts", posts_view}, {"/users", users_view}],
                     lists:sort(pairs(Rs)))
    end).

arbitrary_filename_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"x/my_cool_page_view.erl", view_src(my_cool_page_view)}]),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        ?assertEqual([{"/x", my_cool_page_view}], pairs(Rs))
    end).

module_name_independent_of_directory_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"about/company_information_view.erl",
                        view_src(company_information_view)}]),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        ?assertEqual([{"/about", company_information_view}], pairs(Rs))
    end).

prefix_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"dash_view.erl", view_src(dash_view)},
                       {"users/users_admin_view.erl", view_src(users_admin_view)}]),
        {ok, Rs} = weberl_fs:discover(D, "/admin"),
        ?assertEqual([{"/admin", dash_view}, {"/admin/users", users_admin_view}],
                     lists:sort(pairs(Rs)))
    end).

invalid_prefix_test() ->
    with_tmp(fun(D) ->
        ?assertMatch({error, {invalid_prefix, "admin", _}}, weberl_fs:discover(D, "admin"))
    end).

empty_directory_test() ->
    with_tmp(fun(D) ->
        ?assertEqual({ok, []}, weberl_fs:discover(D, "/"))
    end).

missing_directory_test() ->
    with_tmp(fun(D) ->
        Missing = filename:join(D, "nope"),
        ?assertEqual({error, {root_not_a_directory, Missing}}, weberl_fs:discover(Missing, "/"))
    end).

directories_without_views_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"docs/readme.txt", <<"hi">>},
                       {"a/helper.erl", <<"-module(helper).\n">>},
                       {"a/b/c_view.erl", view_src(c_view)},
                       {dir, "empty"}]),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        ?assertEqual([{"/a/b", c_view}], pairs(Rs))
    end).

non_view_suffix_ignored_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"view.erl", view_src(view)},
                       {"_view.erl", view_src('_view')},
                       {"foo_view.erl.bak", view_src(foo_view)}]),
        ?assertEqual({ok, []}, weberl_fs:discover(D, "/"))
    end).

multiple_views_in_one_directory_are_discovered_test() ->
    %% Conflict detection is the table's job; discovery reports both.
    with_tmp(fun(D) ->
        write_tree(D, [{"about/about_view.erl", view_src(about_view)},
                       {"about/company_view.erl", view_src(company_view)}]),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        ?assertEqual([{"/about", about_view}, {"/about", company_view}], pairs(Rs))
    end).

module_mismatch_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "foo_view.erl"),
        write_tree(D, [{"foo_view.erl", view_src(bar_view)}]),
        ?assertEqual({error, {module_mismatch, File, bar_view, "foo_view"}},
                     weberl_fs:discover(D, "/"))
    end).

invalid_source_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "foo_view.erl"),
        write_tree(D, [{"foo_view.erl", <<"-module(foo_view\nbroken.\n">>}]),
        ?assertMatch({error, {invalid_source, File, _}}, weberl_fs:discover(D, "/"))
    end).

no_module_declaration_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "foo_view.erl"),
        write_tree(D, [{"foo_view.erl", <<"-export([]).\n">>}]),
        ?assertEqual({error, {no_module_declaration, File}}, weberl_fs:discover(D, "/"))
    end),
    with_tmp(fun(D) ->
        File = filename:join(D, "foo_view.erl"),
        write_tree(D, [{"foo_view.erl", <<"f() -> ok.\n">>}]),
        ?assertEqual({error, {no_module_declaration, File}}, weberl_fs:discover(D, "/"))
    end).

invalid_directory_name_for_url_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"my dir/x_view.erl", view_src(x_view)}]),
        ?assertMatch({error, {invalid_route_path, _, {invalid_segment, "my dir"}}},
                     weberl_fs:discover(D, "/"))
    end).

deterministic_order_test() ->
    %% Depth-first, entries sorted by name: dir "a", file "b_view.erl", dir "c".
    with_tmp(fun(D) ->
        write_tree(D, [{"c/c_view.erl", view_src(c_view)},
                       {"b_view.erl", view_src(b_view)},
                       {"a/a_view.erl", view_src(a_view)}]),
        {ok, Rs1} = weberl_fs:discover(D, "/"),
        {ok, Rs2} = weberl_fs:discover(D, "/"),
        ?assertEqual(Rs1, Rs2),
        ?assertEqual([{"/a", a_view}, {"/", b_view}, {"/c", c_view}], pairs(Rs1))
    end).

standard_compilation_test() ->
    %% Plain compile:file/2, no no_error_module_mismatch, no renaming.
    with_tmp(fun(D) ->
        write_tree(D, [{"about/company_information_view.erl",
                        view_src(company_information_view)}]),
        File = filename:join([D, "about", "company_information_view.erl"]),
        ?assertMatch({ok, company_information_view, _},
                     compile:file(File, [binary, return_errors])),
        {ok, [R]} = weberl_fs:discover(D, "/"),
        ?assertEqual(File, weberl_route:source(R))
    end).
