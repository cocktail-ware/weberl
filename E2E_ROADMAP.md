# End-to-end (browser) test roadmap

Status (2026-11-04): **first pass done**. The setup exists (below) and 30 specs cover
scenarios A (except reconnect after a server restart), B, C, D, E (except back/forward
cache), F and H, all green in Chromium (see `HANDOFF.md` for the list). Still to write:
reconnect and backoff after a restart, back/forward cache, connection limits (G), more
security (wrong-channel tokens), and per-browser expectations for Firefox and WebKit.
Browser runs are heavy for the machine: Chromium only by default, limited containers.

## Why a browser suite

EUnit already tests the server side against real HTTP, SSE and WebSocket (hand-rolled
raw TCP clients in `test/weberl_live_test_util.erl`), and `test/node/unit/` runs
`priv/engine.js` and `priv/client.js` against fakes (WebSocket, EventSource, fetch, a DOM).
Neither can test what only a real browser does:

- The scripts in a real engine: transport choice, fallback to long-poll,
  reconnect/backoff, `Weberl.request`, DOM events, the `<weberl-region>` element and
  region patching with real focus.
- The shared **hub** (a real SharedWorker) and the behaviour of several tabs at once.
- Browser-imposed limits (per-origin connection limits, cookies, `Origin` headers,
  back/forward cache) and differences between Chromium, Firefox and WebKit.

## Setup (decided with the project owner)

- **Playwright** (`@playwright/test`) in a **second image**, `Dockerfile.e2e`, based on
  Microsoft's Playwright image. The Erlang image has no Node. Raw CDP stays possible for
  Chromium-only checks (`context.newCDPSession`).
- **Per run, a throwaway podman pod** (`test/e2e/run.sh`): container 1 is the Erlang image
  running the app under test (`e2e_app/`, TLS with HTTP/1.1 and HTTP/2), container 2 the
  Playwright image with only `test/node/` mounted. The pod maps `app.test` and
  `other.test` to localhost; nothing is published to the host. A fake CA and certificate
  are generated for each run. The browsers currently ignore certificate errors; trusting
  the fake CA in each browser is to do.
- `test/node/unit/` holds the old JS unit tests, run by the same script.
- Outside `rebar3 eunit`; one command: `test/e2e/run.sh`.
- Three projects (Chromium, Firefox, WebKit), one worker (the specs read the app's
  counters), traces kept for failures.
- The app under test serves `/_test/stats` (sessions, WebSockets, SSE streams) for
  assertions that the browser cannot make (a SharedWorker's sockets are not visible to
  Playwright).

## Architecture under test (summary of the Phase E decisions)

See `HANDOFF.md` "Phase E decisions" for the reasoning. In short:

- The beacon talks to a client `Hub` interface. `InPage` (own connection per tab) is
  always available; a **SharedWorker hub** (one connection per origin, tabs connect over
  MessagePorts) is the default when the browser has `SharedWorker`; otherwise each tab
  keeps its own connection. No leader election, no sub-workers.
- Frames carry a page id; one connection can subscribe several pages.
- **Topic-only pages** (same content for everyone, no process per viewer) subscribe to
  topics granted in the signed token; connection processes receive `publish/3` messages
  directly. **Session pages** keep a process per page.
- Optional `handle_subscribe/2` sends a snapshot to the subscribing client only.
- A handler can **narrow** a page's kind (`two_way` -> `one_way` -> `normal`); widening is
  a 500.
- Injected responses get `cache-control: private, no-store` unless the handler set one.

## Scenarios

Grouped by the feature that makes them testable; each lists what to assert.

### A. Beacon per tab (Phase D, exists today)
- `one_way` page uses SSE, `two_way` uses WebSocket: assert via network events.
- Server pushes arrive as `Weberl.on` callbacks and `weberl:<name>` DOM events.
- `Weberl.request` round trip over the socket and over POST; error mapping
  (`bad_request`, `unsupported`, `failed`).
- Fallback: make WS/SSE fail (server flag or blocked path) -> after 3 failures the beacon
  switches to long-poll, no event lost; `live_poll_fallback = [one_way]` disables it for
  `two_way`.
- Reconnect with backoff after a server restart; "closed" when the session ended or the
  token is refused; no reconnect storm.

### B. Hub (shared connection)
- Two tabs of the same origin -> exactly **one** WebSocket to the server; a third tab
  later reuses it; closing tabs keeps the connection until the last one closes; a new tab
  afterwards starts a new hub.
- Browser without `SharedWorker` (script injected before load) -> one connection per tab,
  same observable behaviour for the page's code. *(written: hub.spec.js)*
- Version mismatch between a tab and a running hub (serve a hub script of another
  `VERSION`): the tab warns in the console, fires `weberl:stale`, keeps working on its own
  connection, and the server logs `live_client_version_mismatch`.
- A worker that fails to start (CSP `worker-src`, blocked script) -> per-tab fallback.
- Users never mix: two contexts (two logins) never share a hub or topics. *(written)*

### C. Topics and snapshots
- One `publish/3` reaches every subscribed tab; the server sends **one frame per
  connection**, not per tab.
- `handle_subscribe/2`: the subscribing tab gets the snapshot, other tabs do not; a tab
  opened later gets its own; an update published during the subscribe may appear twice
  but never out of order (publish concurrently with subscribing, assert final state).
- A page cannot subscribe to a topic its token does not grant.

### D. Downgrade
- A handler that narrows to `normal` -> no beacon tag, no connection, no session left.
- `two_way` narrowed to `one_way` -> SSE, no WebSocket attempt.
- Widening -> 500.

### E. Caching
- Live responses carry `private, no-store` unless the handler set `cache-control`;
  a shared-caching directive logs a warning and is respected.
- Back/forward navigation to a live page: record what each browser does (bfcache with
  `no-store` varies); the beacon must end in a working or cleanly reloaded page, never a
  silently dead one.

### F. Regions (Phase F)
- A request that changes an assign updates only the regions using it; a server-side
  `assign/2` from another process updates a region while the user types elsewhere.
  *(first cases written: counter.spec.js)*
- A region patch replaces only that region; focus, caret and scroll are kept where
  possible (a field with an `id` inside the region); unknown region names are ignored
  without errors.
- A `<weberl-region>` or `[data-weberl-region]` element added to the page by script after
  load is patched by the next update; `tag=` regions inside tables/lists keep valid markup.
- `display: contents` of the wrapper (no layout change); the page before the beacon loads.

### G. Connection limits
- Over HTTP/1.1 (about 6 connections per host), many tabs with per-tab SSE/long-poll
  starve other requests; with the hub they do not. Needs an HTTP/1.1 listener.

### H. Security (browser side of the server checks)
- A page from another origin cannot open the WebSocket/stream (`Origin` check, token).
- Tampered, foreign or wrong-channel tokens are refused (403) and the beacon gives up.

## Hooks the framework offers for testability

- `weberl_live:stats/0` (sessions, WebSockets, SSE streams), served by the app under test
  at `/_test/stats`. Built.
- Shortened timeouts via the application env (`live_attach_timeout`, `live_idle_timeout`,
  `live_poll_timeout`); the app under test sets the first two. Built.
- A way to force a transport failure (a test route that refuses or stalls the stream, the
  socket or the poll) for the fallback tests. Not built; Playwright's `page.route()` and
  `routeWebSocket()` may be enough.

## Principles

- Wait for conditions (events, DOM state, network frames), never fixed sleeps.
- One browser context per scenario unless the scenario is about sharing; always clean up
  tabs and routers.
- Assert on observable behaviour (frames on the wire, DOM, server counters), not on
  `client.js` internals, so the beacon can be refactored freely.
- Keep the suite runnable by one command in the dev container.

## Next session: scenarios still to write

Written down 2026-11-04 when the first pass was green (30 specs, Chromium; 88/90 in all three
browsers before two fixes). In value order:
1. **Reconnect and backoff after a server restart** (A): the app under test has to be
   stoppable and restartable from a spec (a test-only route that stops the listener, or
   restarting the container with the same `live_secret` so tokens stay valid); assert no
   reconnect storm (count connection attempts) and that the page resumes or ends cleanly.
2. **Back/forward cache** (E): navigate away and back; record what each browser does with a
   `no-store` live page; the page must end working or reloaded, never silently dead.
3. **Connection limits** (G): needs the plain HTTP/1.1 listener (see `ROADMAP.md`, Testing);
   open many tabs with per-tab SSE (no SharedWorker) and show other requests starve at about
   six connections per host, and that the hub does not.
4. **Wrong-channel and expired tokens** (H): a token of a `live_poll_fallback`-disabled kind
   on the poll endpoint (404), a `ws`-less token on the socket.
5. **Topic edge cases** (C): a publish racing a subscribe (assert the final state), a publish
   during a hub reconnect (the page gets a fresh snapshot), long-poll topic events.
6. **Per-browser expectations** where Firefox/WebKit differ (SharedWorker lifetime, bfcache).
7. **Version mismatch on the server** (B): assert `live_client_version_mismatch` was logged.
8. Real focus/caret/scroll behaviour of region patches in the three browsers.

## Open decisions

- Trusting the fake CA in each browser (Chromium NSS db, Firefox policies, WebKit) instead
  of `ignoreHTTPSErrors`.
- A plain HTTP/1.1 listener next to the TLS one, for the connection-limit scenario (G) and
  to compare HTTP/1.1 with HTTP/2.
- CI: whether browser tests run on every change or on demand.
- Per-browser expectations where behaviour differs (SharedWorker, bfcache).
