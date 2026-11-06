# Roadmap / Revisit notes

Things deliberately deferred or worth revisiting. Not part of the Milestone 2
specification; kept here so they don't clutter active work.

## Dispatch / handler results
- `weberl_dispatch`: provide ways to convert selected exits/raises/throws into
  rendered, status-coded responses (for example, user-defined error pages or a
  catch-all handler hook) instead of only the fixed plain-text 500.
- `weberl_response`: the strict "handlers must return a `weberl_response`" rule
  is the default on purpose. Consider opt-in catch-all/convenience forms for
  cases where a lenient return is easier (for example, a bare iodata body, or
  `{Status, Body}`), without removing the strict default.

## Forms
- `weberl_form` is deliberately minimal (`open/2,3`, `csrf_input/1`). A real forms layer needs its own
  design: deriving input names (and ids/labels) from a schema or from the view's assigns; a live and a
  plain version of the same form according to the page kind (what a form is on a `normal`, `one_way` and
  `two_way` page); reactive bindings on two-way pages (an input bound to a view assign, validation on
  the way); what a form does on a one-way page (no way back except HTTP requests); error and value
  re-display after a failed submit; CSRF on live requests (they have page tokens today, see README
  "Credentials"). Multipart is built (`weberl_request:multipart/1,2`, `files/1,2`, `form/1,2` on both
  encodings, layered limits; HANDOFF decision 13). Still open: **streaming uploads** (Roadrunner buffers the
  whole body; its `manual` body mode would let Weberl read in chunks, write a file part to disk as it arrives
  and refuse early on a per-part limit), `filename*=` (RFC 5987) and per-part transfer encodings, and an
  event handler that Weberl installs itself for the transport's body-size refusals
  (`weberl_roadrunner_events` is opt-in because Roadrunner has one handler per node).
- Multipart CSRF: the token for a multipart form is the ordinary one, in the action's query string (HANDOFF
  decision 13), so a forged upload is rejected before the body is parsed. Revisit: either two tokens (a
  file-upload token in the URL, named and prefixed so it is recognisable and valid only on upload routes, whose
  decoded form says which form it was issued for, plus the general token in the body), or body-only tokens with
  other guard rails (a lower body limit on upload routes until the token is checked, rate limits). A token in a
  URL can end up in logs and Referer headers, and uploads are one of the easier ways to exhaust resources.
- Once templates have conditionals and URL-safe interpolation (feedback items 2 and 3), a plain
  `<form>` with `{{ @csrf_token }}` replaces the Erlang-built `{{{ }}}` form tag.

## Template blocks inside tags and attributes
- `{: if :}`, `{: case :}` and `{: for :}` (see HANDOFF "2") first stand only in HTML text. To extend, as a
  design of its own:
  - conditional **attributes**: boolean ones (`checked`, `disabled`, `selected`, `hidden`) and optional
    values, for example `<input {: if @on :}checked{: /if :}>` or an attribute with a computed value;
  - **class lists** and similar token lists (`class="{: for ... :}"`), where whitespace between tokens
    matters and a naive block leaves stray spaces;
  - conditionals **inside a start tag** in general (the HTML context after a branch must be the same as
    before it, which the tracker can check in `in_tag` just as it does in text) and inside **quoted
    attribute values**, with the escaping rules that go with each position;
  - what stays refused: `<script>`, `<style>` and event-handler attributes (they need context-specific
    encoding, as for interpolation today), and URL attributes until the safe-URL design (feedback item 3).
- Whitespace control for block tags (trimming a block tag that stands alone on its line, trimming around
  a tag) as a small additive marker; today output is literal and nothing is trimmed.

## Dynamic paths in the router and URL helpers
- Route parameters (`/agents/:id`, a `[id]` directory) are built (`HANDOFF.md`, decisions 11 and 12), and
  `router_path` verifies links against them. Still open: wildcard segments (`*rest`, several segments), the
  named link form `router_path("/agents/:id", #{params => #{id => @id}})` (checks the parameter names of a
  literal map at compile time), typed parameters (`:id` that must be an integer), and a way to build a link
  from a route name instead of a path.

## Layouts chosen at runtime
- Today a view's layout is fixed when the router starts: layout and view are composed at compile time
  into one generated module per view. The user wants templates rendered with a layout chosen at runtime
  (an admin layout versus a public one, an embedded versus a full page, per-tenant chrome). To design:
  - the API: for example `weberl_template:render(?MODULE, Assigns, #{layout => Name})`, or a layout
    returned by the handler; and what the choice may depend on (the request, the user, a header for
    partial/embedded renders);
  - how: compose each (view, layout) pair lazily on first use and cache the module (bounded: layouts are
    a fixed set, so views x layouts), versus compiling every layout for every view at startup, versus a
    runtime composition that renders the layout around already rendered view parts;
  - regions: with a runtime layout, a region of the layout exists only for some renders, so
    `render_region/3` and `regions/1` must be told which layout (the live session would have to remember
    it, as it remembers its assigns), and region names must still be unique across the pair;
  - validation: a view's `{: fill :}` blocks must match the slots of every layout it can be rendered
    with, which compile-time composition checks once and runtime selection would check per pair;
  - nested layouts (a layout inside a layout) belong to the same design.
- `weberl_template:layout/1` already reports what a view was compiled with; the runtime form would have
  to report the default and the allowed set.

## Session
- Automatic loading of the request's session into the handler's response (`weberl_session:run/2`, the
  process dictionary) is behind the internal env `session_autoload` (default `true`). Planned: make it
  switchable per route and globally (route option plus a documented setting); with it off, handlers call
  `weberl_response:load_session/2`. The ancillary code (a route option, validation, docs) is not written.
- Key rotation: sessions, CSRF tokens and page tokens share `live_secret`; rotating it ends every session.
  A `live_secret_previous` that is tried for decryption (and re-encrypted on write) would allow rotation.
- Revocation needs server-side state; an optional store behaviour (as Arizona's `arizona_session_store`)
  could sit behind the same functions, with the cookie carrying only an id.
- Flash (`weberl_flash`) lives in the session under a reserved key. If a flash that has to survive
  much longer than `flash_ttl`, or one for a user with no session cookie at all, is ever wanted, it could
  have its own cookie; an automatic `take` (a route option or a layout hook) is possible if explicit
  `take` proves tedious.

## Request
- `weberl_request:path/1` is the raw requested path (not percent-decoded, not
  normalized). Keep it for inspection, and add a second, converted/decoded
  path (for example `decoded_path/1`) for application use.

## Router lifecycle / adapters
- `weberl:stop/1` stops the Roadrunner listener (no new connections) but does
  not close connections that are already open; they finish on their own.
  Consider a graceful drain (`roadrunner_listener:drain/2`) with a deadline.
- If a router process is killed without running `terminate/2`, its listener
  keeps serving the old route table until the restarted router replaces it
  (the adapter replaces a same-named leftover on start). A listener that dies
  with its router would need a monitoring process on the Roadrunner side.
- `weberl_roadrunner` accepts only `max_content_length`, `request_timeout`, `tls` and
  `protocols` in `listener.options`. Extend deliberately as needed, keeping
  Roadrunner-specific configuration out of the public API. (`protocols` allows
  HTTP/2 over TLS; HTTP/3 is Roadrunner's and untested here; WebSocket and SSE over
  HTTP/2 are only exercised through the browsers' own choice of protocol.)
- Roadrunner is started with `body_buffering => auto`: the whole body (up to
  `max_content_length`, 10 MB default) is in memory before the handler runs.
  True lazy/streaming reads need `manual` mode and threading the updated
  Roadrunner request back from the handler.
- Weberl routes are not translated into Roadrunner routes: one shared
  catch-all handler (after any static mounts) receives everything else and
  dispatches through the Weberl table. Method restrictions and per-route
  Roadrunner features would need that revisited.
- Static: other static knobs (`mime_types`, single-file mounts such as
  `/favicon.ico`) are not exposed yet. A missing static file returns the
  adapter's 404, not a Weberl error page.

- Monitor each listener from its router process, so a listener cannot outlive
  its router (and a dying listener is noticed). Low priority: today a restart
  of the same router name replaces the leftover, which only matters for
  routers started and decommissioned dynamically.
- Split adapter options in two: `options` for Weberl-level settings built on
  or beside the adapter, and an opaque `adapter_options` term handed straight
  to the underlying server (Roadrunner's listener opts map). The current
  whitelist is a stopgap; switching should not change handlers or routes.
- Bodies: do not pile new features on the "body is fully buffered" assumption
  (see `weberl_roadrunner` limitations); keep `weberl_request:read_body/1` the
  only access point so streaming can be added behind it.

## Live pages
Phases A-F are built (static assets, page kinds, sessions, WebSocket / long-poll /
requests / tokens, the shared hub with topics and downgrade, regions with view data).
What is left is below. The design decisions behind Phases E and F are in `HANDOFF.md`
until they are absorbed into the README.
- Browser (end-to-end) tests: a first pass of 30 specs exists (`test/node/e2e/`); what is
  still to write is in [`E2E_ROADMAP.md`](E2E_ROADMAP.md) (reconnect after a restart,
  back/forward cache, connection limits, wrong-channel tokens, per-browser expectations).
- Regions and view data, leftovers:
  - region names are static atoms: no `item-5` style regions for the rows of a list (needs
    a dynamic name in the tag, validated, plus a way to render one row);
  - a region is replaced with `innerHTML` (no morphing): focus is kept for a field with an
    `id`, but not scroll position, selection in non-text controls, or running animations;
  - nested regions that both use a changed assign are both re-rendered (the inner one
    twice); skip descendants of a region that is re-rendered anyway;
  - helpers on top of `weberl_live:mount/3`, e.g. `weberl_view:mount_html(Request, ViewData)`
    (user: later, thin layers, no magic), and possibly a `weberl_mount/1` callback;
  - `weberl_live:view/1` is a call to the session, so a busy session delays whoever asks
    (`handle_subscribe/2` in the connection process); consider a snapshot copy for readers;
  - `weberl_view_data` can grow more keys when needed (it is a native record).
- The hub cannot tell when its worker dies after the handshake, and a SharedWorker is not told
  when a tab crashes (only `pagehide` sends `bye`); consider a heartbeat/ping over the port.
- A page whose stream keeps failing needs ~10 s to fall back to long-poll (3 attempts at the
  browser's retry time); consider falling back sooner when the browser reports a closed
  stream (Firefox does), or a shorter first retry.
- `handle_event` (framework-level client interactions a user may override, as
  opposed to page-level `handle_request`) is reserved but not implemented.
- The live endpoints are hardcoded in `weberl_roadrunner:internal_routes/0`;
  make them an optional adapter capability when a second adapter exists.
- Default topics (`weberl_live:topics/2`): a session-less page without
  `weberl_topics/1` gets its route path. When dynamic routes (`/users/:id`) exist
  the default must be the concrete request path (`/users/42`), not the pattern,
  or every visitor would share one topic. Session pages have no default topic (they
  are reached through their session).
- The `connection => own` escape hatch (a page that opts out of sharing a hub's
  connection) was proposed in the Phase E design but is not implemented.
- Clustering of live pages. Topics already work across nodes (`publish/3` uses
  `pg:get_members`, tested with a second node), but: (a) every member pid gets its
  own message, so a publish to N remote connections sends N messages over
  distribution; a forwarder process per node (one message per node, then a local
  fan-out) would cut that; (b) sessions are local to the node that rendered them
  (`weberl_live:whereis/1`, `push/3`, `attach/2` only look at local members), so a
  `push/3` from another node, or a client reconnecting to another node, does not
  find the session; (c) the tokens of a cluster only verify across nodes when
  `live_secret` is set; (d) `pg` is eventually consistent, so a publish right after
  a subscribe on another node may miss it. Revisit with the cluster work.
- **Review once live pages work: callbacks that run in connection processes.**
  `handle_subscribe/2` and, for session-less pages (`session => false`),
  `handle_request/3` run inside the process that holds the connection (WS handler,
  SSE loop, or the HTTP request process). A hostile but valid user could make those
  callbacks slow or frequent and stall their own connection (or, if connections
  are shared, every tab on it), and flood the node. Likely fix: run the callback in
  a short-lived spawned process (monitored, with a timeout, a concurrency cap per
  connection and a rate limit) that sends only the results back to the connection
  process, which just writes to the wire. The same applies to session pages, where
  `handle_request` blocks the session (see below).
- Script version rules: today a connection declaring another (or no) `v` is only logged
  (`live_client_version_mismatch`) and the browser warns (`weberl:stale`). Decide later what
  a stale client may do (refuse, warn the user, block until reload); a stale script can be
  someone running an outdated script with a patched weakness. A digest of the served
  scripts should replace the integer once there is an asset pipeline.
- `priv/engine.js` and `priv/client.js` have unit tests (`test/node/unit/`, `node --test`,
  run through `test/e2e/run.sh`); the browser-level suite is `test/node/e2e/` (Playwright),
  planned in `E2E_ROADMAP.md`.
- Tokens have no expiry (they die with the session) and the per-node secret is
  random unless `live_secret` is set; consider key rotation (e.g. accept a list
  of secrets, sign with the first).
- A `live_secret` shorter than 16 bytes is silently ignored (a random one is
  used instead); log a warning or reject it at startup.
- Without `live_secret`, a restart invalidates the tokens of open pages and
  clustered nodes reject each other's; the README tells users to set it. Consider
  failing or warning loudly in a release/production profile.
- `live_poll_fallback` only affects pages rendered after a change (the channel
  set lives in the token), which is intended; the poll endpoint also re-checks it.
- `handle_request` runs inside the session process and blocks it; consider a
  worker or a timeout if handlers turn out to be slow.
- `live_poll_timeout` is application env like the other live timeouts.
- `live_attach_timeout` / `live_idle_timeout` are application env for now;
  consider per-listener or per-route settings.
- Sessions are local to the node (`pg` scope, local lookup). Clustering would
  need a different lookup and a place for session state to live.
- `Last-Event-ID` replay is not implemented: events missed while the stream was
  down are only kept (newest 100) if they were pushed after the session noticed
  the disconnect.
- Pushes to a page whose handler registered subscriptions leave cleanup to the
  application: `weberl_live:push/3` returns `{error, not_found}` once the session
  is gone.
- SSE connections are not drained gracefully on stop beyond closing the
  streams of that listener.

## Testing
- Browser test infrastructure (`test/e2e/run.sh`, `Dockerfile.e2e`, `e2e_app/`), to do:
  trust the fake CA in Firefox (policies) and WebKit instead of ignoring certificate errors
  (Chromium already trusts it); a plain HTTP/1.1 listener next to the TLS one for the
  connection-limit scenario; assert the server's `live_client_version_mismatch` log from a
  spec (needs a way to read the app's log); decide when the browser suite runs in CI (it is
  heavy: Chromium only and CPU/memory limits by default); pin a Playwright upgrade routine
  (the image tag and `test/node/package.json` must move together).
- The "adapter unavailable" path (`{error, {adapter_unavailable, roadrunner}}`)
  is verified manually against the default profile (no Roadrunner on the code
  path), not by an automated test. Add a test run in the default profile.
- `weberl_dispatch_tests:failure_is_logged_with_context_test_` lets the default
  logger handler print one error report to the console. Capture ("slurp") it.
