%% GET /  -- renders home_view.weberl (same directory, same base name).
-module(home_view).
-behaviour(weberl_handler).

-export([handle/1]).

handle(_Request) ->
    weberl_response:html(
      200,
      weberl_template:render(?MODULE, #{
          title => <<"Welcome to Weberl">>,
          description => <<"Served by Erlang, rendered from a .weberl template.">>,
          visits => 1234,
          snippet => <<"<em>trusted</em> markup">>,
          untrusted => <<"<script>alert('not run')</script>">>
      })).
