# Handoff: live pages work (temporary)

Written 2026-11-04 to pick the work up in a new session. Delete once absorbed
into `README.md` / `ROADMAP.md`. Branch: `milestone2`.

**State at the end of the 2026-11-04 sessions:** Phases A-F are built and committed
(static assets, page kinds, sessions, WebSocket/SSE/long-poll, requests, tokens, topics,
the shared SharedWorker hub, downgrade and cache-control, regions, view data), plus the
browser test setup with a first pass of 30 specs. 523 Erlang tests, 61 JS unit tests, 30
Playwright specs (Chromium; 88/90 in all three browsers before two fixes) pass. The README
is the reference for what exists; "Next session" at the end of this file says what to do
next; `ROADMAP.md` and `E2E_ROADMAP.md` list what is deferred. The sections below are the
design record (why things are the way they are) and can be trimmed as the README absorbs
them. After this the user moves to the `agentic` project (`/home/witchcraft-dev/code/agentic`)
to build multi-tab agent interfaces on Weberl and see how its API holds up; expect feedback
about the framework from there.

## Goal

Reactive front-ends. A page is declared **normal**, **live 1-way** (SSE) or
**live 2-way** (WebSocket). The framework serves *beacons* (client JS) that
connect according to the kind, fall back to long-poll when WebSockets are
unavailable, may be shared across tabs/sessions/views, and apply server-sent
updates by surgically replacing DOM regions. Static assets came first because
the beacon JS has to be served from somewhere.

The original plan file is `/home/witchcraft-dev/.claude/plans/curious-napping-eagle.md`
(Context, phases A-F, critical files, verification). This document supersedes it
where they differ.

## Decisions already made (user-confirmed)

- **Page kind**: one mechanism, two spellings. Router 3-tuple
  `{Path, Handler, #{live => normal | one_way | two_way}}` and
  `-weberl_page(Kind).` in a view `.erl` (after `-module`). Both land in the
  `opts` field of `#route{}`; `weberl_route:live/1` reads it.
- **Static**: `#listener{static = [{Prefix, Source} | {Prefix, Source, Opts}]}`,
  delegated to `roadrunner_static` by the adapter. `Source` is a directory or
  `{priv, App, Sub}`.
- **Update model**: explicit **named regions** marked in templates; a per-page live
  process holds state and pushes `{region, Id, Html}` patches. No diffing.
  Transport-independent: the same session serves SSE, WebSocket and long-poll.
- **Template region syntax**: decided, see Phase F below (`{: region name :}` ... web
  component wrapper).
- **Tests**: per-view beacons are covered by EUnit against real HTTP/SSE/WS.
  Shared-beacon (cross-tab) behaviour needs real browsers: later e2e suite with
  headless browser automation, tool chosen when we get there.
- Process style: `gen_statem` (`handle_event_function`), per `PROCESSES.md`.
- Commit per phase when the user says so (they did for A, B, C).

- **Client-to-server naming** (user, 2026-11-04): what a page sends is a *request*
  (`handle_request/3` in `weberl_handler`); *event* stays for server pushes.
  `handle_event` is reserved for framework-level client interactions users may
  override; not implemented.
- **Fallback**: long-poll is the fallback for both kinds (WS -> poll, SSE -> poll),
  removable per kind with env `live_poll_fallback`. Parts of a page without the socket
  can use poll/POST against the same session.
- **Credential**: every live endpoint requires a page token (HMAC with a secret +
  per-page salt, `weberl_live_guard`), not just the page id; Origin must match Host
  when present. Browsers cannot set headers on EventSource/WebSocket, so `?t=` is
  accepted next to the `x-weberl-token` header.

## Phase E decisions (user-confirmed, discussed one point at a time 2026-11-04)

1. **Client hosting**: build a `Hub` interface on the client (tab <-> hub protocol is
   the same whatever hosts the connection) and a wire protocol where frames carry a
   page id and a connection can subscribe several pages. First implementation `InPage`
   (each tab its own hub: one connection, one page = today's behaviour); then a
   **SharedWorker hub** behind the same interface, which becomes the default when it
   works. Browsers without SharedWorker **fall back to a connection per tab** (`InPage`);
   the Web Locks leader election is NOT planned (revisit only if a target browser needs
   it). No sub-workers: a worker handles many concurrent connections; only CPU work
   (never DOM) would justify a dedicated worker. Service workers are not connection hosts.

2. **Topics / fan-out** (settled parts):
   - Two first-class kinds of live page: **topic-only pages** (same content for everyone,
     e.g. a stock ticker: NO process per viewer, the signed token says which topics the
     page may subscribe to and the connection process subscribes itself) and
     **session pages** (a process per page/user, LiveView-like, as today). A page may
     have both.
   - A publisher (any process, e.g. the stock `gen_statem`) calls
     `weberl_live:publish(Topic, Name, Data)`; the connection processes (SSE loop / WS
     handler, already addressable: we attach `self()`) are members of a `pg` group
     `{topic, Topic}` and receive the message directly. Encode the frame once, send the
     same binary to every member.
   - **No replay buffers / sequence numbers for topics.** The render-to-connect gap is
     closed by the application: subscribe first, then fetch the current state from the
     owner (e.g. ask the stock `gen_statem`) and send it to THIS client as an update, so
     nothing published later is lost. Updates should be idempotent (full state) because a
     publish between subscribe and the snapshot may be seen twice. Weberl provides helper
     functions and documents the pattern for users. Topics therefore have no state owned
     by Weberl (just `pg` membership).
   - **Snapshot = optional handler callback `handle_subscribe(Topic, PageContext)`**
     (returns `{snapshot, Name, Data}` or `ok`), run in the connection-holder process
     (SSE loop / WS handler) right after the client's subscription took effect and the
     process joined the topic's `pg` group, synchronously, before the mailbox is
     processed; the result goes to THAT subscriber only. Optional: pages that update
     continuously and tolerate a brief mismatch skip it; it is the "correct by design"
     option. Rejected: per-topic snapshot registry (Weberl would hold state). Handler
     rendering at HTTP time stays as is (renders current data into the HTML). Details to
     implement: crash/timeout of the callback is logged and the subscription continues
     without a snapshot; it runs once per page subscription even when the connection
     already joined the topic (a new tab needs its own snapshot); join each topic once
     per connection (pg allows duplicate membership); users must document/know it blocks
     the connection process, so keep it short.
   - **Wire (decided 2026-11-04)**: a topic event is ONE frame per connection tagged by
     topic, `{"topic":T,"event":Name,"data":Data}`; the browser engine keeps a
     topic -> pages map and delivers it to each subscribed page's sink (so a SharedWorker
     hub receives one frame however many tabs subscribed). The server tracks no per-page
     state for topic-only pages. Snapshots are tagged by page
     (`{"page":ID,"event":..,"data":..}`) and go to that subscriber only. A connection
     leaves a topic's group when its last page using it unsubscribes. Topics are signed
     into the token, so a page cannot ask for more later.
   - **Reconnects (decided 2026-11-04)**: `handle_subscribe` runs again on every
     reconnect (WS resubscribe, SSE reconnect = new stream request). Long-poll: run it on
     the first poll after a gap / after switching to poll, not on every poll; events
     published between polls are lost (poll is itself the last-resort fallback; the user
     accepted this, no per-topic buffers).

   - **Session or topic-only (decided 2026-11-04)**: route option `session => false`
     (default true) makes a page session-less (no process; its topics come from
     `weberl_topics/1`); a page with both keeps the default and also has the callback.
     For session-less pages `handle_request/3` runs in the process that received the
     request (WS connection or HTTP request process) with the same `PageContext` as
     `handle_subscribe`. **User flagged a DoS concern** (a hostile valid user blocking
     connection processes with slow subscribe/request callbacks): ROADMAP.md has a
     review note proposing a monitored short-lived process per callback with timeout,
     caps and rate limit, sending only results back to the connection process. Build as
     planned first, review once everything works.

   - **Topic type and PageContext (decided 2026-11-04)**: a topic is a binary (JSON
     string on the wire, `pg` group name; no atoms/tuples). Validated at render time: at
     most 32 topics, 256 bytes each, token under ~2 KB (the SSE token travels in the
     query string); a violation is a logged 500 at render. Topics sit after the channel
     mask in the token, length-prefixed, inside the MAC. `PageContext` =
     `#{page => Id, kind => one_way | two_way, topics => [Topic]}`: read-only, from the
     verified token, passed to `handle_subscribe/2` and to `handle_request/3` (its third
     argument changes from the bare page id to this map, for session and session-less
     pages alike). No user/request data in it: per-user data goes into topic names
     (`<<"user:42:inbox">>`). A `claims` field next to `topics` is possible later.
   - **State for session pages (user wants it; Phase F)**: the session process should be
     able to hold handler state (initial state from mount, passed to and returned by
     `handle_request`); today it holds none. Not designed yet; do it with regions.

3. **Declaring topics**: optional handler callback `weberl_topics(Request) -> [Topic]`,
   evaluated per request (so it can include per-user topics); when absent the default is
   derived from the route (the derivation is static, so tools/tests can see it). NO static
   topics in route options or `weberl_metadata/0` (they would be overridden by the callback
   and are not needed for anything core). Weberl ships a resolver for tests/assertions,
   e.g. `weberl_live:topics(Path, Request)`, which runs the same resolution dispatch uses.
   Topics returned by the callback are validated at request time (invalid -> logged, page
   served without live). The topic names go into the signed page token, so a client can
   only subscribe to what the server granted. Sharing a connection between tabs is the
   hub's default (decision 1); an escape hatch for a tab that wants its own connection
   (assumed: route option `connection => own`) was proposed and not objected to, confirm
   when implementing.

4. **Downgrade**: narrow-only (`two_way` -> `one_way` -> `normal`; the route kind is the
   ceiling), done with a **response marker**, e.g. `weberl_response:live(Response, Kind)`,
   read by dispatch after `handle/1` returns (skip the beacon and close the session, or
   drop the `ws` channel from the token for two_way -> one_way). The session is opened
   eagerly before the handler as today and closed on downgrade (cheap; topic-only pages
   have no session so it costs nothing there). **Widening is a handler bug**: logged and
   served as a 500 like any invalid handler return. The user may revisit this if
   templating/forms end up rendering differently per page kind. Lazy session opening was
   rejected for now (can be added later without changing the marker).

5. **Cache-control**: when Weberl injects a beacon it adds `cache-control: private, no-store`
   if the handler did not set one; if the handler set a shared-caching directive (`public`,
   `s-maxage`, `max-age` without `private`) it is respected but a warning is logged at
   request time. Rationale (user): live HTML embeds a per-render page id/token and a
   session, and even a page whose main content is identical for everyone usually has
   personalised chrome (navbars, PII), so live HTML should practically never be cached.
   Document the pattern for cacheable pages: serve a cacheable "dead" shell (a normal or
   downgraded route) and let JS fetch/mount the live parts (SPA-style). Back/forward-cache
   behaviour of `no-store` pages varies by browser; to be observed in the e2e suite.

6. **E2E plan**: lives in [`E2E_ROADMAP.md`](E2E_ROADMAP.md) at the repo root (confirmed by
   the user; linked from `README.md` project documents and `ROADMAP.md`). Tooling is
   undecided (user prefers headless Chrome driven from Erlang, via a library or CDP); the
   e2e suite starts only after the framework's base cases work. The user wants a complete,
   working framework first, then reviews it as a whole (patterns, module organisation,
   conventions) before paying attention to commits/diffs; the test suite is what makes
   such refactors safe.

**Phase E implementation status**

- **Step 1 DONE (wire protocol, multiplexed connection, Hub interface, in-page hub), 435
  tests passing:**
  - `/_weberl/ws` (no id in the path) is a multiplexed WebSocket: `subscribe` /
    `unsubscribe` / `request` frames name their page, server frames carry `page`
    (`weberl_live_wire` documents the format). The connection process attaches many
    page sessions (the session API did not change: one `attach/2` per page with the
    same pid). A page's `close`/`replaced` only closes that page (frame
    `{"page","closed"}`), not the socket. `live_subscribe_timeout` (10 s) closes sockets
    that never subscribe. Token channel `ws` is checked per subscribe (one_way tokens
    now carry `ws` too, see below).
  - SSE events are now unnamed messages with `{"event","data"}` JSON (same shape on all
    transports, no per-name EventSource listeners).
  - Browser side split in two scripts, both injected by `weberl_live_beacon:tag/2`:
    `priv/engine.js` (DOM-free transport engine = the Hub interface; runs in a window or a
    worker; owns the shared socket, SSE per page, long-poll fallback, backoff) and
    `priv/client.js` (thin page API: `Weberl.on/request/close`, DOM events). The in-page
    hub is `WeberlEngine.create()`; `chooseHub()` in `client.js` is where the SharedWorker
    hub plugs in.
  - (superseded) Node used to be in the Erlang Dockerfile; the JS tests now live in
    `test/node/` and run in the Playwright image, see "E2E setup" below.
- **Decided (user, 2026-11-04)**: `one_way` tokens carry `ws` as well as `sse`, because a
  SharedWorker hub subscribes all tabs' pages over the one socket (kind is the capability,
  the hub picks the transport). The user will review the whole flow later.
- **Step 2 DONE (topics; 456 Erlang tests + 34 JS tests passing):**
  - Token = `Salt ++ Mask ++ Claims ++ MAC`; `weberl_live_guard:issue/3` / `claims/3`.
    Claims (kind, session flag, handler module, topics) are signed: a session-less page has
    no session to look anything up in, so the connection reads them from the token.
  - `weberl_live`: `publish/3` (encodes the topic frame once, sends
    `{weberl_live_topic, Topic, Name, Data, Frame}` to the local `pg` group `{topic,T}`),
    `topics/2` (resolver: `weberl_topics/1` callback, default `[]` for a session page and
    `[route path]` for a session-less one; validated with `check_topics/1`: <= 32 topics,
    non-empty UTF-8, <= 256 bytes each; deduplicated), `new_page_id/0`.
  - `weberl_live_topics` (per-connection membership: join the group on a topic's first
    page, leave with the last), `weberl_live_callbacks` (runs `handle_request/3` and
    `handle_subscribe/2` with try/catch + logging; `snapshots/2`; used by the session and
    by the connection processes). `handle_request/3` now gets the page context map.
  - Route option `session => false` (declarative routes only; filesystem views have no
    attribute for it yet - see ROADMAP). Dispatch calls `weberl_live:topics/2` per
    render, opens a session only when `session` is true, signs claims into the token, and
    the beacon adds `data-weberl-topics` (JSON, HTML-escaped).
  - Transports: WS subscribe verifies claims, attaches the session if any, joins topics,
    sends `subscribed` then the snapshots (page-tagged events); topic events are one
    `{"topic","event","data"}` frame per connection. SSE (snapshots written before any
    event; membership ends with the stream), long-poll (`?snapshot=1` on the first poll and
    after a failure; joins/leaves the topics per poll and flushes stale topic messages),
    POST requests (session-less: handler runs in the request process).
  - `engine.js`: routes topic frames to the WS pages whose `topics` contain it; sink
    `event(name, data, topic)`; poll asks for snapshots as above. `client.js` reads
    `data-weberl-topics`; handlers get `(data, topic)`.
  - Decisions taken while implementing (tell the user): default topics (above);
    snapshots for SSE/poll are also sent for pages that have a session; a re-subscribe of
    a page already on a socket replaces its claims and re-sends snapshots.
  - Follow-ups the user asked for (done): `publish/3` is cluster-wide (`pg:get_members`;
    tested with a `peer` node + `erpc`, the test starts epmd itself; `peer:call` hangs with
    noconnection in the container, use `erpc`); filesystem views set route options with
    `-weberl_route(Opts)` (the same map as a declarative route; `-weberl_page(Kind)`
    stays as shorthand for `live`).
  - **Not done / open**: the `connection => own` escape hatch (proposed in design point 3,
    the user did not object; not implemented); the DoS review note (callbacks in
    connection processes) and the clustering notes (remote fan-out per pid, local sessions)
    are in ROADMAP.md.
- **Step 3 DONE (downgrade + cache-control; 466 Erlang tests passing):**
  - `weberl_response:live(Response, Kind)` / `live/1` (a `live` field in the native record,
    default `undefined`). Dispatch (`final_kind/3`, `finish/5`) reads it after `handle/1`:
    narrowing only (rank normal < one_way < two_way), widening = logged 500 and the session
    is closed; `normal` closes the session and serves the plain response (no cache header
    added); a narrower live kind keeps the session (`weberl_live:downgrade/2` tells it the
    new kind so callbacks see it) and the beacon/token follow the final kind. Ignored on
    normal routes. A one_way -> normal downgrade works too (user asked).
  - `weberl_live_beacon:cache_control/2`: `private, no-store` unless the handler set a
    `cache-control`; a header with `public` / `s-maxage` / `max-age` and without `private` or
    `no-store` is kept but logged (`live_page_allows_shared_caching`).
  - README: "One handler, several kinds of page" and "Caching".
- Step 4 (SharedWorker hub), done:
  - `priv/hub.js` (worker script, served at `/_weberl/hub.js`) runs one engine and calls
    `WeberlEngine.serve(engine, port)` for each tab; `WeberlEngine.shared(options)` is the
    tab-side hub (same interface) used by `chooseHub()` in `client.js`. Message protocol
    documented at the end of `engine.js`. Fixed worker name `weberl-hub` (no version in the
    name: a digest in the URL will do that when there is an asset pipeline).
  - Fallback to `WeberlEngine.create()` per tab when there is no SharedWorker (silent),
    the worker errors / never says hello within 5 s / the constructor throws (console
    warning), or the hello version differs (console warning + `weberl:stale` event, detail
    `{hub, page}`). Requests not yet sent to the hub are re-asked on the fallback engine.
  - Version: `VERSION` in `engine.js`, `weberl_live:client_version/0` on the server. Every
    connection start declares `v` (ws URL, sse URL, a poll with `snapshot=1`);
    `weberl_roadrunner_live:check_version/3` logs `live_client_version_mismatch` (channel,
    page, declared, expected) and still serves. User wants stricter rules later (a stale
    script may be someone using an outdated script with a patched weakness).
  - Known limits: a SharedWorker is not told when a tab disappears, so only `pagehide`
    (non-persisted) sends `bye`; no leader election; client.js has no tests (the e2e suite
    will cover it with real browsers, including a real SharedWorker).
  - Tests: engine.test.js (serve/shared with fake MessagePorts, 44 JS tests),
    `weberl_live_version_tests.erl`; Erlang suite 471 tests.
- Downgraded-to-normal pages also get `private, no-store` (user's call: the downgrade is
  per request so the plain page varies like the live one).

### Phase F, step A (regions, explicit update): done
- Lexer: `{: region name [tag=el] :}` / `{: /region name :}` -> `block_open`/`block_close`
  tokens (`\{:` escapes). Parser: `parse/2` (File for errors) builds
  `{region, Line, Name, Tag, Children}`, unique names, nesting allowed; `validate/2` needs a
  region to begin and end in HTML text; `regions/1` gives name => tag/line/variables.
  Compiler: wrapper `<weberl-region name="x">` or `<tag data-weberl-region="x">`;
  generated `render_region/2` (content only) and `info/0` with `regions`.
  `weberl_template:render_region/3`, `try_render_region/3`, `regions/1`.
  Tests: `weberl_template_regions_tests.erl`.
- `weberl_live:update/3` (session pages: the session's handler is the view) and
  `update_topic/4` (view named by the caller; one render, published to the topic); event
  name `weberl:region`, data = JSON string `{"region","html"}` (so it rides every
  transport unchanged); failures are logged (`live_region_update_failed`) and returned.
  Tests: `weberl_live_regions_tests.erl` (incl. a real SSE stream).
- `client.js`: defines `<weberl-region>` (`display: contents` via CSSOM), patches
  `weberl-region[name=X], [data-weberl-region=X]` found at event time, keeps focus/selection
  of a field with an id inside the region, dispatches `weberl:region` ({region, count}); the
  event does not reach `Weberl.on`. `test/js/client.test.js` (14 tests, fake DOM).
- **Step B decision (user, 2026-11-04)**: the session gets the page's initial assigns
  through `weberl_live:mount(Request, Assigns) -> iodata()` (renders the handler's own
  template, records the assigns in the session; with no session, e.g. session-less or
  downgraded to normal, it just renders). `weberl_template:render/2` stays pure and stores
  nothing. Convenience helpers (e.g. `weberl_view:mount_html(Request, Assigns)` doing mount
  + `weberl_response:html`) come later as thin layers on top: the user prefers less magic,
  and anyone can compose the parts themselves. A `weberl_mount/1` callback (LiveView style)
  is possible later on top of `mount/2`.
- **Step B, done (user's decisions 2026-11-04)**: state is separate from assigns, in a native
  record `weberl_view_data` (`assigns`, `private`; more keys can be added). `mount` takes it
  (that is where the HTTP request's knowledge, e.g. the user, enters, as in Phoenix). The
  callback is `weberl_live:mount(View, Request, ViewData)` (the view module is explicit,
  like `weberl_template:render(?MODULE, ..)`, because a Request does not carry its route's
  handler and session-less pages have no session to ask); on a page without a session it only
  renders. `handle_request/3` context has `view` (session pages with a mounted record) and may
  return `{ok, V}` / `{reply, R, V}`; the session compares assigns key by key and pushes the
  regions that use a changed variable (template order; `weberl_live_session:apply_view/3`).
  `weberl_live:assign/2`, `modify/2` (runs in the session), `view/1` (a call to the session;
  the way `handle_subscribe/2`, which runs in the connection process and gets no `view`,
  reads the private data). A record returned for a page without a session is dropped. Tests:
  `weberl_live_view_tests.erl`. Open: nested regions that both changed are both re-rendered;
  helpers like `weberl_view:mount_html/2` later (user: less magic, thin layers on top).
- Example app: `/counter` (`example/src/views/counter/`, `priv/static/counter.js`): two_way,
  regions `clock` and `count`, `mount`, a request that returns a new view, a process calling
  `weberl_live:assign/2`, private data answering the `age` request; linked from the home page.
  Verified against the running example with a scratch HTTP client (requests answered, poll
  returned the region events). `rebar3 shell` exits at once without stdin; to run the
  example detached use `erl -noshell -eval` with the `_build/default/*/*/ebin` paths added.
### E2E setup (user's decisions 2026-11-04)
- Playwright (`@playwright/test` 1.64.1), runs in a second image, `Dockerfile.e2e`, based on
  `mcr.microsoft.com/playwright:v1.64.1-noble` (tag must match package.json). Node removed
  from the Erlang `Dockerfile`. The user asked for two images, a podman pod created per run
  with both containers, fake domains (pod `--add-host app.test/other.test`), a fake CA and
  certificates, only `test/node/` mounted into the Playwright container, the old JS unit
  tests moved there (`test/node/unit/`, reading `priv/*.js` from `test/node/_priv/`, a copy
  made by the run script), run command `test/e2e/run.sh [unit|e2e|all] [playwright args]`.
- App under test: `e2e_app/` (top level, NOT under `test/`: its `_checkouts/weberl` symlink
  points at the repo root and made `rebar3 eunit` recurse forever when it sat in `test/`),
  TLS with `protocols => [http1, http2]` (the Roadrunner adapter now allows the `protocols`
  option), fixed `live_secret`, short timeouts, `/_test/stats` (`weberl_live:stats/0`:
  sessions, websockets, streams; connections register with `weberl_live:register_connection/1`).
- Browsers ignore certificate errors for now (`ignoreHTTPSErrors`); trusting the fake CA in
  Chromium (NSS db), Firefox (policies) and WebKit is a later step.
- Specs (30, all green in Chromium): `counter`, `hub`, `transports` (SSE per tab without the
  hub, one_way over the hub's socket, unsupported request, fallback to long-poll),
  `version` (hub of another version, worker that fails to start), `regions` (display:
  contents, focus kept, `tag=` in a table, element added by script, region not on the page),
  `topics` (publish to every tab over one connection, snapshots, order), `downgrade`
  (normal / one_way / widen -> 500 / cache-control), `security` (cross-origin socket and
  stream refused, tampered/foreign/missing tokens 403, beacon gives up on a refused token).
  Support: `e2e_app` views clock, regions, topics (session-less), downgrade, widen, cached;
  `/_test/publish`; `static/hub-v2.js` (a fake hub saying hello with version 2).
- Found while writing them: the engine opened one SSE stream per `one_way` page even inside
  the hub, against the Phase E decision that the hub carries everything on one socket.
  Fixed: `create({oneWay: "ws"})`, which `priv/hub.js` uses (in-page engines keep SSE).
- Found: with the stream blocked a page needs ~10 s to fall back to long-poll, while a
  session that never attached expires after `live_attach_timeout` (default 30 s; the test
  app must not shorten it below that).
- Precautions (the user's machine nearly freezes on browser runs): Chromium only by default
  (`E2E_BROWSERS`), CPU/memory limits on both containers, run sparingly.
- (older note) Step B plan before the decision (session keeps assigns, `weberl_live:assign/2`, re-render regions
  whose variables changed; handler state in the session); dynamic region names (items in a
  list, e.g. `item-5`) are not supported yet (names are static atoms); no morphing (innerHTML
  replace); the example app does not use regions yet.

## Done

Phases A-D are committed (D together with the Phase E design docs); commit only when
the user says so (they said on 2026-11-04 that commits are fine to make for now).

| Commit | Phase | What |
|---|---|---|
| `c7bf38d` | A | Static asset mounts |
| `2817ef8` | B | Page kind (`live`) on routes |
| `a9448b9` | C | Live sessions, beacon injection, SSE transport |
| see `git log` | D | WebSocket, long-poll, client requests, page tokens, client.js |
| `git log` (Nov 4) | E | wire protocol + hub interface, topics, downgrade + cache-control, SharedWorker hub + version handshake |
| `97aacb4`, `7b18b74`, `650dad9` | F | regions (A: explicit update), view data (B), `/counter` example |
| `07b1011`, `27b8643` | e2e | Playwright image, pod, fake CA, `e2e_app`, 30 specs |

### D: what exists (409 tests passing)
- `weberl_live_guard`: `issue(PageId, Channels)`, `verify(PageId, Channel, Token)`,
  `origin_ok/1`; secret = env `live_secret` (>= 16 bytes) or random per node start
  (persistent_term, created by `weberl_app`). Token = base64url(Salt(8) ++ ChannelMask(1)
  ++ HMAC-SHA256 over label, page id, salt and mask). Channels (`sse | ws | poll |
  request`) are chosen by `weberl_live:channels/1` from the page kind and
  `live_poll_fallback`; each endpoint verifies its own channel (user asked for the
  purpose to live in the token). The last base64 char carries ignored padding bits:
  flipping only it may leave the token valid (tests flip the first char).
- `weberl_live_wire`: JSON request decode (`{"request","data","ref"}`), `run_request/2`
  -> `{HttpStatus, AnswerMap}`, `event/2`.
- `weberl_live`: `open/3` (opts `handler`), `release/2` (synchronous detach, used by
  poll so no event is lost), `request/3`, `poll_enabled/1`. Session runs the handler's
  optional `handle_request/3` in the session process (crash -> logged, `{error,failed}`).
- Adapter modules: `weberl_roadrunner_live` (shared authorize: method, token, origin,
  page lookup; 403 before 404 so unknown page == bad token), `_sse` (now token-checked),
  `_ws` (two_way only; attaches in `init/1`, JSON frames, 1000 "closed"/"replaced"),
  `_poll` (env `live_poll_timeout`, default 25000), `_request` (POST).
  All four routes are in `weberl_roadrunner:internal_routes/0`.
- `weberl_dispatch` passes the handler to the session; beacon tag now has
  `data-weberl-token` and `data-weberl-fallback="poll|none"`.
- `priv/client.js` rewritten: WS for two_way, SSE for one_way, poll fallback after 3
  failed connects, backoff with jitter, `Weberl.request` (socket or POST).
  (Since superseded by `engine.js` + `client.js`; both are now unit tested in
  `test/node/unit/` and exercised in real browsers by `test/node/e2e/`.)
- Tests: `weberl_live_test_util` (shared helpers, hand-rolled WS client, `quiet/1`),
  `weberl_live_guard_tests` (also covers the wire module), `weberl_live_transport_tests`
  (WS, poll, POST), `weberl_live_http_tests` (SSE + credentials, now token-aware).

Earlier Milestone 2 commits (`bd883e7`..`18c1600`) are routing, handlers,
templates, Roadrunner adapter, example. Test count: **357 passing**
(66 original Milestone 1 tests untouched).

### A: static assets
- `weberl_config`: `static` field on `#listener{}`; `normalize_static/1` (prefix
  normalized, `/` rejected, `/_weberl[/...]` reserved, duplicates and nested
  prefixes rejected, source shape checked); `listener_static/1`.
  Errors: `{invalid_config, {listener, {static, N, Reason}}}`.
- `weberl_adapter`: optional callback `validate_static/1`; an adapter without it
  rejects `static` (`{static_unsupported, Adapter}`).
- `weberl_roadrunner`: implements it (`cache_control`, `symlink_policy`,
  `cache_ttl_ms`); `routes/2` builds the Roadrunner route list: static mounts,
  `internal_routes/0`, then the catch-all `{~"/*path", weberl_roadrunner_handler, Table}`
  (a trailing wildcard also matches `/`).
- A missing static file is Roadrunner's plain 404, not a Weberl handler response.

### B: page kind
- `weberl_route`: `opts` field, `new/5`, `opts/1`, `live/1` (default `normal`),
  `check_opts/1` (only key `live`), `check_live/1`.
- `weberl_decl`: accepts `{Path, Handler}` and `{Path, Handler, Opts}`; errors
  `{invalid_route, Module, Entry, {invalid_options, _}}`; old 2-tuple error shapes
  unchanged.
- `weberl_fs`: after `-module` it keeps reading attributes up to the first
  function to find `-weberl_page(Kind)`; skips unparseable forms (macros);
  errors `{invalid_page_attribute, File, V}`, `{duplicate_page_attribute, File}`.
  Not read when placed before `-module`.

### C: live pages (src/live/, priv/client.js)
- `weberl_live`: public API. `open/2` (Owner = listener name, Kind),
  `push/3`, `attach/2`, `detach/2`, `close/1`, `close_owner/1`, `whereis/1`,
  `info/1`, `client_path/0`, `sse_path/1`. Page id = 16 random bytes, base64 url-safe
  (22 chars); it is the only credential of the stream.
- `weberl_live_sup` (simple_one_for_one, `temporary`) and `weberl_live_session`
  (gen_statem: states `waiting` / `attached` / `detached`). Registered via
  `pg` scope `weberl_live` with groups `{page, Id}` and `{owner, Owner}`; both
  started by `weberl_app` (`weberl_live_pg`, `weberl_live_sup`). Events pushed
  while detached are buffered (newest 100) and flushed on attach. A new attach
  replaces the old transport (`replaced` message). Timeouts, application env of
  `weberl`: `live_attach_timeout` (30000), `live_idle_timeout` (60000).
- **Transport protocol** (plain messages to the attached pid, documented in
  `weberl_live`): `{weberl_live, Id, {event, Name, Data}}`,
  `{weberl_live, Id, close}`, `{weberl_live, Id, replaced}`. A transport calls
  `attach/2` on start and `detach/2` on end.
- `weberl_live_beacon`: `injectable/1` (2xx and text/html or xhtml), `inject/2`
  (before the last `</body>`, case-insensitive, else append), `tag/2`.
- `weberl_dispatch`: for non-`normal` routes opens a session, sets
  `weberl_request:with_page/2`, injects the beacon or closes the session; if
  `open` fails the page is served without live and the error is logged.
- `weberl_request`: `page/1`, `with_page/2` (new `page` field).
  `weberl_response`: `with_body/2`.
- `weberl_roadrunner_sse` (`GET /_weberl/sse/:id`): attaches `self()` and returns
  `{loop, ...}`; Roadrunner runs the loop in the same connection process, so
  session messages arrive in `handle_info/3`. Sends `retry: 2000` first, a
  keepalive comment every 15 s, detaches on disconnect/drain. **Binding keys are
  binaries** (`#{~"id" := Id}`), not atoms.
- `internal_routes/0` also serves `/_weberl/client.js` via `roadrunner_static`
  (`{priv, weberl, ~"client.js"}`, `cache-control: no-cache`).
- `weberl_router_server:terminate/3` calls `weberl_live:close_owner(ListenerName)`
  before stopping the listener, so SSE streams end with the router.
- `priv/client.js` (vanilla JS): finds `script[data-weberl-page]`, opens an
  `EventSource`, exposes `window.Weberl = {pageId, kind, on(name, fn), close()}`,
  dispatches `weberl:<name>` CustomEvents on `document` (`weberl:connected`,
  `weberl:closed` too). Currently always uses SSE, even for `two_way`.
- Example: `example/src/views/clock/` (one-way clock), `example/priv/static/`
  (`site.css`, `clock.js`), `example_sup` mounts `/static`.
- `weberl.app.src`: added `crypto`, `weberl_live_sup` in `registered`.

## Remaining plan

### Phase D: DONE (see "Done" above). The original notes follow for reference only.
- New Roadrunner module (e.g. `weberl_roadrunner_ws`, route `/_weberl/ws/:id`)
  implementing `roadrunner_ws_handler`: `handle_frame/2` required;
  `init/1`, `handle_info/2`, `terminate/2` optional. Upgrade by returning
  `{{websocket, Mod, State}, Req}` from a handler. Server push works because the
  session sends the same `{weberl_live, Id, ...}` messages to the connection
  process, which arrive in `handle_info/2` (return `{reply, [{text, Payload}], S}`).
  Frames arrive as maps `#{opcode := text | binary, payload := ...}`.
- **Client-to-server events**: decide the wire format (JSON? use OTP `json`) and a
  handler callback (e.g. optional `handle_event/2` in `weberl_handler`, called by
  the session or the transport with the page id/assigns). Also a POST endpoint
  `/_weberl/event/:id` so 1-way pages can send events. Not implemented yet.
- **Long-poll fallback**: a blocking `GET /_weberl/poll/:id` handler (receive after
  timeout, then reply with buffered events) using the same `attach/detach`
  protocol; the beacon falls back from WS -> (SSE for 1-way) -> long-poll.
  Roadrunner handlers run in the connection/worker process, so `receive ... after`
  is fine.
- `weberl_adapter`: consider making the live endpoints an explicit optional
  capability rather than hardcoding them in `weberl_roadrunner:internal_routes/0`.
- `client.js`: choose transport from `data-weberl-kind`; reconnect/backoff.
- Tests: WS ping/close, event round trip, forced fallback. Use a raw TCP client
  (httpc is unreliable for streams, see Gotchas); for WS the OTP stdlib has no
  client, so hand-roll the handshake/frames in the test helper or add a test dep.

### Phase E: shared beacons: DONE
Built as the SharedWorker hub (not leader election; see "Phase E decisions" above and the
README "Transports"). The original ideas (beacon scopes, leader-tab election) were
replaced by those decisions.

### Phase F: regions and DOM patching
- **Decided (user, 2026-11-04) region syntax**: a block tag with its own delimiters,
  `{: region cart :} ... {: /region cart :}` (the closing tag repeats the region's name;
  a mismatch is a compile error naming both lines), so that `{{ }}`
  stays for values only and statements (regions now, flow control later) are visually
  distinct. It emits the web component `<weberl-region name="cart">`, the default wrapper;
  an option chooses another tag, `{: region rows tag=tbody :}` -> `<tbody
  data-weberl-region="rows">` (a custom element is invalid in table/list/select
  parents). The browser finds a region at patch time with
  `weberl-region[name=X], [data-weberl-region=X]`, so regions added later on the client
  (or hand-written attribute markup, or handler HTML without templates) are patchable with
  no registry or observer. The custom element is the extension point: client-added regions
  share default behaviour (connect/sync automatically, patch events, swap modes), and the
  user plans to design around first-class web component integration later. The wrapper gets
  `display: contents` from JS (CSSOM, so a strict CSP is fine).
  **Updates (user, 2026-11-04)**: step A first, then B. A = explicit and stateless:
  the caller passes the assigns for the region (`weberl_live:update(PageId, Region,
  Assigns)`), Weberl renders only that region and pushes `{region, Name, Html}`; no hidden
  state, works for every page kind. B = stateful, on session pages: the session keeps the
  page's assigns (the "state for session pages" item), `assign(PageId, Changed)` merges
  and re-renders only the regions that use a changed variable (from `info/0`). Add a new AST
  node in `weberl_template_parser` (it deliberately separates `parse/1` from
  `validate/2` so syntax can be added without touching context validation);
  extend `weberl_template_html` so regions begin/end in the same HTML context;
  compiler emits per-region render functions (`render_region/3`), `info/0` exposes
  region ids and their variable dependencies.
- Session API (e.g. `weberl_live:update/2`) renders affected regions and pushes
  `{region, Id, Html}`; the beacon replaces the region's DOM (preserve focus where
  possible).
- Current template facts: lexer tokens are only text and interpolation; the
  compiler builds a flat iodata list; interpolation inside `<script>`/`<style>` and
  in URL attributes is rejected; templates compile and load once at router start
  (no hot reload); only filesystem views have templates.

### Also queued (ROADMAP.md has the full list)
Dispatch/response catch-all conversions, decoded request path, listener monitor,
`options` vs opaque `adapter_options` split, graceful drain, lazy body reads,
automated default-profile test for `{adapter_unavailable, roadrunner}`, silencing
the console noise in `failure_is_logged_with_context_test_`, `mime_types` and
single-file static mounts, per-listener live timeouts, `Last-Event-ID` replay.

## How to work

- Sandbox: `podman run -d --name weberl-dev -p 8080:8080 -v "$(pwd):/app:Z" -w /app weberl sleep infinity`
  (image `weberl`, OTP 29.1.2, rebar3 3.27, no Node; `-p 8080:8080` so the example is
  reachable from the user's browser). The container may be gone; check
  `podman ps -a`. Run `podman exec weberl-dev rebar3 eunit` (add `--module=Name`
  for one module; it takes ~1-2 minutes). If a command seems to hang at "Verifying
  dependencies", look for a symlink loop under `test/` (see Gotchas).
- JavaScript and browser tests: `test/e2e/run.sh unit` (cheap), `test/e2e/run.sh e2e [-g
  title]` (heavy: Chromium only, CPU/memory limited; `E2E_BROWSERS=chromium,firefox,webkit`
  for all). Images: `weberl` (Erlang) and `weberl-e2e` (`podman build -f Dockerfile.e2e -t
  weberl-e2e .`). Do not run the browser suite casually: it nearly freezes the user's
  machine. Never redirect its output to `/dev/null` (the results are the point). The user asked for **plain `podman exec weberl-dev ...`
  commands**: no pipes, redirects, `sh -c`, or host-side python/heredocs in
  commands that need approval. Use Edit/Write for files. (I slipped on this twice;
  the user noted permission rules are not a real sandbox but wants the discipline.)
- Example app: `podman exec -w /app/example weberl-dev rebar3 compile`;
  `example/_checkouts/weberl` is a symlink to `../..`. When running it from an
  `erl -noshell`, use explicit `-pa` for `_build/default/lib/example/ebin`,
  `.../lib/roadrunner/ebin`, `.../checkouts/weberl/ebin`. Port comes from
  `application:get_env(example, port, 8080)` (setting env before start does not
  survive app load).
- The user runs agentic in a container; the weberl checkout symlink must resolve
  there (mount weberl at the same absolute path, or use a relative symlink with a
  shared parent mount; use `:z`, not `:Z`, on a shared parent).
- Commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`;
  commit only when asked.

## Gotchas learned

- OTP 29 native records: the defining module (`weberl_config`) must be loaded
  before records are constructed (`weberl_app` does it; tests use `-on_load`).
- Roadrunner route bindings have **binary keys**. `{loop, ...}` runs in the
  connection process, so `handle/1` may attach `self()` and the loop shares its
  mailbox. A wildcard route (`/*path`) also matches `/`. Routes are first-match;
  a fully shadowed route fails listener start with `{unreachable_route, ...}`.
- `httpc` with `{stream, self}` did **not** surface a chunk that arrived together
  with the response head (server had written it). SSE tests use a raw `gen_tcp`
  client (`weberl_live_http_tests`).
- `weberl_router_server_tests:app_loads_records_test` stops the `weberl`
  application; tests that need live sessions start it themselves
  (`application:ensure_all_started(weberl)`).
- Tests that make the listener fail log crash reports; wrap with
  `logger:set_primary_config(level, none)` and restore (see `weberl_static_tests`).
- `weberl:stop/1` on a dead name exits `noproc`; guard with `whereis/1` in cleanup.
- `rebar3 shell --eval` swallows output; use `erl -noshell -pa ... -eval`. `rebar3 shell`
  exits at once when stdin is closed (detached run): start apps with
  `erl -noshell -eval '[code:add_pathz(P) || P <- filelib:wildcard("_build/default/*/*/ebin")], ...'`
  as `e2e_app/start.sh` does.
- A symlink back to the repository root (`_checkouts/weberl`) inside `test/` makes
  `rebar3 eunit` recurse forever; apps with that symlink (`example/`, `e2e_app/`) live at the
  top level.
- Native records: a module that uses one from another module must not match on it
  unless it imports the record; the small modules here export predicates and accessors
  instead (`weberl_view_data:is_view_data/1`).
- Playwright: `ignoreHTTPSErrors` does not reach a SharedWorker's connections, and
  Playwright's `request` fixture runs in Node (needs `NODE_EXTRA_CA_CERTS`); Chromium
  trusts the fake CA through an NSS database set up by `test/node/run-e2e.sh`. Firefox
  closes a failed `EventSource` for good (the engine now asks long-poll in that case).
- A session that never attaches expires after `live_attach_timeout` (30 s default): a
  test that delays the first connection (blocked stream, slow fallback) must not shorten it.
- Sessions of earlier specs linger up to `live_idle_timeout` after their page closes:
  specs must compare against a baseline or count per handler (`/_test/stats?handler=`),
  never assert a global session count of zero.

## Next session

The framework's planned phases are built. In this order (the user decides):
1. **Use it for real**: the user is moving to the `agentic` project to build multi-tab
   agent interfaces (several tabs, one or more agents, everything through shared hub
   connections so no tab goes stale). Collect what is awkward in the API there and bring it
   back here: the likely pressure points are `weberl_live:mount/3` ergonomics (helpers like
   `weberl_view:mount_html/2` were deferred on purpose), list/row regions with dynamic
   names, topic naming for per-user and per-agent topics, and how a long-running agent
   process should push (`publish/3`, `update_topic/4`, `assign/2`).
2. **Remaining e2e scenarios**: "Next session: scenarios still to write" in `E2E_ROADMAP.md`
   (restart/reconnect, bfcache, connection limits, wrong-channel tokens, topic races, version
   log, per-browser expectations) and the infrastructure items under "Testing" in
   `ROADMAP.md` (trust the CA in Firefox/WebKit, an HTTP/1.1 listener).
3. **Deferred design items** (`ROADMAP.md`, "Live pages"): the review of callbacks running in
   connection processes (DoS), stricter rules for stale scripts, dynamic region names and
   morphing, `connection => own`, clustering of sessions, token expiry/rotation.
4. **Housekeeping**: the user wants to review the code for patterns and module organisation
   once the framework works (module naming such as `weberl_live_*`, the number of small
   modules, where the browser scripts live); then absorb this file into the README and delete
   it.

Rules that hold throughout: discuss design points one at a time and record each decision
here or in the README before building; plain `podman exec weberl-dev ...` commands, no
pipes/redirects/`sh -c`/host-side heredocs in commands that need approval, Edit/Write for
files; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and are
fine to make for now; run the heavy browser suite sparingly.
