#!/usr/bin/env bash
# Runs the Node tests (unit tests of the browser scripts, browser tests) in a
# throwaway podman pod:
#
#   - the pod maps app.test and other.test to localhost, so the app under test
#     (container 1, the Erlang image, e2e_app/) and the browser (container 2,
#     the Playwright image, test/node/ mounted at /work) reach each other as if
#     they were remote hosts, over TLS with a fake CA (test/node/gen-certs.sh);
#   - nothing is published to the host.
#
# Usage: test/e2e/run.sh [unit|e2e|all] [playwright arguments...]
#   test/e2e/run.sh                       everything, in Chromium
#   test/e2e/run.sh unit                  only the unit tests (no app, no pod services)
#   test/e2e/run.sh e2e -g "counter"      browser tests whose title matches
#   E2E_BROWSERS=chromium,firefox,webkit test/e2e/run.sh e2e    all three browsers
# The browser tests are heavy for the machine: they run in Chromium only unless
# E2E_BROWSERS says otherwise, and the containers have CPU and memory limits.
#
# Needs the images localhost/weberl (Dockerfile) and localhost/weberl-e2e
# (Dockerfile.e2e). Override with APP_IMAGE and E2E_IMAGE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_IMAGE="${APP_IMAGE:-localhost/weberl:latest}"
E2E_IMAGE="${E2E_IMAGE:-localhost/weberl-e2e:latest}"
MODE="${1:-all}"
shift || true
POD="weberl-e2e-$$"
PORT=8443

cleanup() {
  podman pod rm -f "$POD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The browser scripts live in priv/, outside the folder that is mounted.
rm -rf "$ROOT/test/node/_priv"
mkdir -p "$ROOT/test/node/_priv"
cp "$ROOT"/priv/*.js "$ROOT/test/node/_priv/"

podman pod create --name "$POD" \
  --add-host app.test:127.0.0.1 --add-host other.test:127.0.0.1 >/dev/null

# The browsers are heavy: both containers get a CPU and memory ceiling (override
# with E2E_CPUS / E2E_MEMORY / APP_CPUS / APP_MEMORY).
node_run() {
  podman run --rm --pod "$POD" --init --ipc=host \
    --cpus "${E2E_CPUS:-2}" --memory "${E2E_MEMORY:-3g}" \
    -e E2E_BROWSERS="${E2E_BROWSERS:-chromium}" \
    -v "$ROOT/test/node:/work:Z" -w /work "$E2E_IMAGE" "$@"
}

status=0

if [ "$MODE" = "unit" ] || [ "$MODE" = "all" ]; then
  echo "== unit tests of the browser scripts"
  node_run npm run unit || status=$?
fi

if [ "$MODE" = "e2e" ] || [ "$MODE" = "all" ]; then
  echo "== fake CA and certificates"
  node_run bash gen-certs.sh

  echo "== starting the app under test"
  podman run -d --pod "$POD" --name "$POD-app" \
    --cpus "${APP_CPUS:-1}" --memory "${APP_MEMORY:-1g}" \
    -v "$ROOT:/app:Z" -w /app/e2e_app \
    -e E2E_PORT="$PORT" \
    -e E2E_CERT=/app/test/node/certs/server.pem -e E2E_KEY=/app/test/node/certs/server.key \
    "$APP_IMAGE" bash start.sh >/dev/null

  ready=0
  for _ in $(seq 1 180); do
    if podman exec "$POD-app" curl -skf "https://app.test:$PORT/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" != 1 ]; then
    echo "the app under test did not start; its log:" >&2
    podman logs "$POD-app" >&2 || true
    exit 1
  fi

  echo "== browser tests"
  node_run bash run-e2e.sh "$@" || status=$?
fi

exit "$status"
