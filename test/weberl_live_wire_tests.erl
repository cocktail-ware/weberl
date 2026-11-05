-module(weberl_live_wire_tests).
-include_lib("eunit/include/eunit.hrl").

decode_request_test_() ->
    D = fun weberl_live_wire:decode_request/1,
    [?_assertEqual({ok, #{name => <<"a">>, data => null}}, D(<<"{\"request\":\"a\"}">>)),
     ?_assertEqual({ok, #{name => <<"a">>, data => [1], ref => <<"r">>}},
                   D(<<"{\"request\":\"a\",\"data\":[1],\"ref\":\"r\"}">>)),
     ?_assertEqual({ok, #{name => <<"a">>, data => null, ref => 5}},
                   D(<<"{\"request\":\"a\",\"ref\":5}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"request\":\"a\",\"ref\":[1]}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"request\":\"\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"request\":1}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{}">>)),
     ?_assertEqual({error, bad_request}, D(<<"[]">>)),
     ?_assertEqual({error, bad_request}, D(<<"nope">>)),
     ?_assertEqual({error, bad_request}, D(<<>>)),
     ?_assertEqual({error, bad_request}, D(undefined))].

decode_frame_test_() ->
    D = fun weberl_live_wire:decode_frame/1,
    [?_assertEqual({ok, {subscribe, <<"P">>, <<"T">>}},
                   D(<<"{\"op\":\"subscribe\",\"page\":\"P\",\"token\":\"T\"}">>)),
     ?_assertEqual({ok, {unsubscribe, <<"P">>}}, D(<<"{\"op\":\"unsubscribe\",\"page\":\"P\"}">>)),
     ?_assertEqual({ok, {request, <<"P">>, #{name => <<"a">>, data => null}}},
                   D(<<"{\"op\":\"request\",\"page\":\"P\",\"request\":\"a\"}">>)),
     ?_assertEqual({ok, {request, <<"P">>, #{name => <<"a">>, data => 1, ref => <<"r">>}}},
                   D(<<"{\"op\":\"request\",\"page\":\"P\",\"request\":\"a\","
                       "\"data\":1,\"ref\":\"r\"}">>)),
     %% missing or malformed parts
     ?_assertEqual({error, bad_request}, D(<<"{\"op\":\"subscribe\",\"page\":\"P\"}">>)),
     ?_assertEqual({error, bad_request},
                   D(<<"{\"op\":\"subscribe\",\"page\":\"\",\"token\":\"T\"}">>)),
     ?_assertEqual({error, bad_request},
                   D(<<"{\"op\":\"subscribe\",\"page\":1,\"token\":\"T\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"op\":\"unsubscribe\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"op\":\"request\",\"request\":\"a\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"op\":\"request\",\"page\":\"P\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"op\":\"other\",\"page\":\"P\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"{\"request\":\"a\"}">>)),
     ?_assertEqual({error, bad_request}, D(<<"[]">>)),
     ?_assertEqual({error, bad_request}, D(<<"nope">>)),
     ?_assertEqual({error, bad_request}, D(undefined))].

server_frames_test() ->
    ?assertEqual(#{~"page" => ~"P", ~"event" => ~"e", ~"data" => ~"d"},
                 json:decode(iolist_to_binary(weberl_live_wire:event(~"P", ~"e", ~"d")))),
    ?assertEqual(#{~"page" => ~"P", ~"closed" => ~"closed"},
                 json:decode(iolist_to_binary(weberl_live_wire:frame(~"P", #{closed => ~"closed"})))).
