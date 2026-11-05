%% Page kind (`live') declaration: router 3-tuples and `-weberl_page(Kind).'.
-module(weberl_page_kind_tests).
-include_lib("eunit/include/eunit.hrl").

-import(weberl_test_util, [with_tmp/1, write_tree/2, view_src/1, load_router/2, unique/1]).

kinds() -> [normal, one_way, two_way].

%% A view source with extra lines placed right after the -module attribute.
view(Mod, After) ->
    iolist_to_binary(
      io_lib:format("-module(~s).~n~s~n-export([render/0]).~nrender() -> ok.~n",
                    [Mod, After])).

%% ---------------------------------------------------------------------
%% weberl_route

default_is_normal_test() ->
    R = weberl_route:new("/", h, declarative, m),
    ?assertEqual(#{}, weberl_route:opts(R)),
    ?assertEqual(normal, weberl_route:live(R)).

route_with_opts_test() ->
    R = weberl_route:new("/", h, declarative, m, #{live => two_way}),
    ?assertEqual(two_way, weberl_route:live(R)),
    ?assertEqual(#{live => two_way}, weberl_route:opts(R)).

check_opts_test_() ->
    [?_assertEqual({ok, #{}}, weberl_route:check_opts(#{})),
     [?_assertEqual({ok, #{live => K}}, weberl_route:check_opts(#{live => K}))
      || K <- kinds()],
     ?_assertEqual({error, {invalid_live, sse}}, weberl_route:check_opts(#{live => sse})),
     ?_assertEqual({error, {unknown_options, [a, b]}},
                   weberl_route:check_opts(#{b => 1, a => 2, live => normal})),
     ?_assertEqual({error, {options_not_a_map, [live]}}, weberl_route:check_opts([live]))].

%% ---------------------------------------------------------------------
%% Declarative: {Path, Handler, Opts}

decl_routes(Entries) ->
    M = unique("kr"),
    load_router(M, Entries),
    weberl_decl:collect_module(M).

decl_three_tuple_test() ->
    {ok, [A, B, C]} = decl_routes([{"/a", h}, {"/b", h, #{live => one_way}},
                                   {"/c", h, #{}}]),
    ?assertEqual([normal, one_way, normal], [weberl_route:live(R) || R <- [A, B, C]]),
    ?assertEqual(declarative, weberl_route:origin(B)),
    ?assertEqual("/b", weberl_route:path(B)).

decl_invalid_options_test_() ->
    [?_assertMatch({error, {invalid_route, _, {"/a", h, #{live := sse}},
                            {invalid_options, {invalid_live, sse}}}},
                   decl_routes([{"/a", h, #{live => sse}}])),
     ?_assertMatch({error, {invalid_route, _, {"/a", h, #{x := 1}},
                            {invalid_options, {unknown_options, [x]}}}},
                   decl_routes([{"/a", h, #{x => 1}}])),
     ?_assertMatch({error, {invalid_route, _, {"/a", h, live},
                            {invalid_options, {options_not_a_map, live}}}},
                   decl_routes([{"/a", h, live}])),
     ?_assertMatch({error, {invalid_route, _, {"/a", "h", #{}}, {invalid_handler, "h"}}},
                   decl_routes([{"/a", "h", #{}}])),
     ?_assertMatch({error, {invalid_route, _, {"a", h, #{}}, {invalid_path, _}}},
                   decl_routes([{"a", h, #{}}])),
     ?_assertMatch({error, {invalid_route, _, {"/a", h, #{}, extra}, malformed_entry}},
                   decl_routes([{"/a", h, #{}, extra}]))].

%% ---------------------------------------------------------------------
%% Filesystem: -weberl_page(Kind).

fs_live(Files) ->
    with_tmp(fun(D) ->
        write_tree(D, Files),
        {ok, Rs} = weberl_fs:discover(D, "/"),
        lists:sort([{weberl_route:handler(R), weberl_route:live(R)} || R <- Rs])
    end).

fs_attribute_test_() ->
    [?_assertEqual([{a_view, K}],
                   fs_live([{"a_view.erl",
                             view(a_view, io_lib:format("-weberl_page(~s).", [K]))}]))
     || K <- kinds()].

fs_no_attribute_is_normal_test() ->
    ?assertEqual([{a_view, normal}], fs_live([{"a_view.erl", view_src(a_view)}])).

fs_mixed_test() ->
    ?assertEqual([{a_view, one_way}, {b_view, normal}, {c_view, two_way}],
                 fs_live([{"a_view.erl", view(a_view, "-weberl_page(one_way).")},
                          {"b/b_view.erl", view_src(b_view)},
                          {"c/c_view.erl", view(c_view, "-weberl_page(two_way).")}])).

fs_attribute_among_other_attributes_test() ->
    Src = view(a_view, "-behaviour(gen_server).\n-vsn(1).\n"
                       "-define(X, 1).\n-weberl_page(two_way).\n-type t() :: ok."),
    ?assertEqual([{a_view, two_way}], fs_live([{"a_view.erl", Src}])).

fs_attribute_after_unparseable_form_is_found_test() ->
    Src = view(a_view, "-define(X, ?Y +).\n-weberl_page(one_way)."),
    ?assertEqual([{a_view, one_way}], fs_live([{"a_view.erl", Src}])).

fs_attribute_after_function_is_ignored_test() ->
    Src = <<"-module(a_view).\n-export([render/0]).\nrender() -> ok.\n"
            "-weberl_page(two_way).\n">>,
    ?assertEqual([{a_view, normal}], fs_live([{"a_view.erl", Src}])).

fs_invalid_attribute_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "a_view.erl"),
        write_tree(D, [{"a_view.erl", view(a_view, "-weberl_page(sse).")}]),
        ?assertEqual({error, {invalid_page_attribute, File, sse}},
                     weberl_fs:discover(D, "/"))
    end).

fs_non_atom_attribute_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "a_view.erl"),
        write_tree(D, [{"a_view.erl", view(a_view, "-weberl_page(\"two_way\").")}]),
        ?assertEqual({error, {invalid_page_attribute, File, "two_way"}},
                     weberl_fs:discover(D, "/"))
    end).

fs_duplicate_attribute_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "a_view.erl"),
        write_tree(D, [{"a_view.erl",
                        view(a_view, "-weberl_page(one_way).\n-weberl_page(two_way).")}]),
        ?assertEqual({error, {duplicate_page_attribute, File}},
                     weberl_fs:discover(D, "/"))
    end).

%% -weberl_route(Opts): the whole options map of a view

fs_opts(After) ->
    with_tmp(fun(D) ->
        write_tree(D, [{"a_view.erl", view(a_view, After)}]),
        case weberl_fs:discover(D, "/") of
            {ok, [R]} -> {ok, weberl_route:opts(R)};
            {error, {Reason, File}} when is_list(File) -> {error, Reason};
            {error, Error} -> {error, Error}
        end
    end).

fs_route_attribute_test() ->
    ?assertEqual({ok, #{live => one_way, session => false}},
                 fs_opts("-weberl_route(#{live => one_way, session => false}).")),
    ?assertEqual({ok, #{live => two_way}}, fs_opts("-weberl_route(#{live => two_way}).")).

fs_route_attribute_with_page_shorthand_test() ->
    %% -weberl_page sets the kind, -weberl_route the other options, in any order
    ?assertEqual({ok, #{live => one_way, session => false}},
                 fs_opts("-weberl_page(one_way).\n-weberl_route(#{session => false}).")),
    ?assertEqual({ok, #{live => one_way, session => false}},
                 fs_opts("-weberl_route(#{session => false}).\n-weberl_page(one_way).")).

fs_route_attribute_errors_test() ->
    with_tmp(fun(D) ->
        File = filename:join(D, "a_view.erl"),
        Check = fun(After, Expected) ->
                        write_tree(D, [{"a_view.erl", view(a_view, After)}]),
                        ?assertEqual({error, Expected}, weberl_fs:discover(D, "/"))
                end,
        Check("-weberl_route(live).", {invalid_route_attribute, File, live}),
        Check("-weberl_route(#{live => sse}).",
              {invalid_route_attribute, File, {invalid_live, sse}}),
        Check("-weberl_route(#{nope => 1}).",
              {invalid_route_attribute, File, {unknown_options, [nope]}}),
        Check("-weberl_route(#{session => false}).",
              {invalid_route_attribute, File, session_option_needs_a_live_page}),
        Check("-weberl_route(#{live => one_way}).\n-weberl_route(#{live => two_way}).",
              {duplicate_route_attribute, File}),
        Check("-weberl_page(one_way).\n-weberl_route(#{live => two_way}).",
              {conflicting_page_attributes, File})
    end).

%% ---------------------------------------------------------------------
%% Through the table (public API)

table_exposes_kind_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"live/live_view.erl", view(live_view, "-weberl_page(two_way).")},
                       {"plain/plain_view.erl", view_src(plain_view)}]),
        M = unique("kt"),
        load_router(M, [{"/feed", h, #{live => one_way}}, {"/static", h}]),
        {ok, Fs} = weberl_fs:discover(D, "/"),
        {ok, Decl} = weberl_decl:collect_module(M),
        {ok, Table} = weberl_table:assemble(Fs, Decl),
        Kind = fun(P) ->
                       {ok, R} = weberl:lookup(P, Table),
                       weberl_route:live(R)
               end,
        ?assertEqual(two_way, Kind("/live")),
        ?assertEqual(normal, Kind("/plain")),
        ?assertEqual(one_way, Kind("/feed")),
        ?assertEqual(normal, Kind("/static"))
    end).

filesystem_wins_keeps_filesystem_kind_test() ->
    with_tmp(fun(D) ->
        write_tree(D, [{"x_view.erl", view(x_view, "-weberl_page(two_way).")}]),
        M = unique("ks"),
        load_router(M, [{"/", h, #{live => one_way}}]),
        {ok, Fs} = weberl_fs:discover(D, "/"),
        {ok, Decl} = weberl_decl:collect_module(M),
        {ok, Table} = weberl_table:assemble(Fs, Decl),
        {ok, R} = weberl:lookup("/", Table),
        ?assertEqual(x_view, weberl_route:handler(R)),
        ?assertEqual(two_way, weberl_route:live(R))
    end).
