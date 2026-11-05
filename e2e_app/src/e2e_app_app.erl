%% The app under test. Settings come from the environment so the run script
%% decides them:
%%   E2E_PORT   listener port (default 8443)
%%   E2E_CERT   certificate chain file (PEM), E2E_KEY its private key
%% Weberl is configured for tests here: a fixed live_secret (so tokens verify
%% on any node and across restarts) and a short idle timeout.
-module(e2e_app_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = application:set_env(weberl, live_secret, <<"e2e-secret-for-browser-tests-only">>),
    %% (live_attach_timeout stays at its default, 30 s: a page whose stream keeps
    %% failing needs about 10 s to fall back to long-poll before it first attaches)
    ok = application:set_env(weberl, live_idle_timeout, 5000),
    e2e_app_sup:start_link().

stop(_State) -> ok.
