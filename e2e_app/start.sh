#!/usr/bin/env bash
# Starts the app under test in the foreground (run by test/e2e/run.sh inside the
# Erlang container, with the repository mounted at /app).
set -euo pipefail
cd "$(dirname "$0")"
rebar3 compile
exec erl -noshell \
  -eval '[code:add_pathz(P) || P <- filelib:wildcard("_build/default/*/*/ebin")],
         {ok, _} = application:ensure_all_started(e2e_app),
         receive stop -> ok end.'
