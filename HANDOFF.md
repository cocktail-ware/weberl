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

## Session of 2026-11-05: layouts built, feedback from `agentic` to work through

**Done and committed** (branch `main`; `649d05a`, `cee3c20`, `c186263`):
- **Layouts**: a template with one `{: content :}` where the view goes; a view selects a layout
  with `weberl_metadata() -> #{layout => main}`; the router lists layout directories in the new
  `layouts` field of the `router` record (`layouts = ["src/layouts"]`), a layout is named by its
  file's base name. Decisions: metadata selection only (for now), shared assigns (layout and
  view variables are one map), a view without `layout` stays a standalone page, `{: content :}`
  kept as its own marker (not folded into a general slot; revisit if it ever hurts).
- **Slots**: `{: slot head :}default{: /slot head :}` in a layout, `{: fill head :}...{: /fill head :}`
  at the top level of a view; the rest of the view goes to `{: content :}`.
- **Composition happens at compile time on the ASTs** (`weberl_template_layout`): one generated
  module per view, so regions of the layout and of the view work with `render_region/3` and
  `regions/1`, and each file is validated alone. Extra rule found on the way: the part of a view
  that goes into `{: content :}` must end in HTML text (`{content_unbalanced_markup, _}`).
- **Tests**: `test/weberl_template_layout_tests.erl` (eunit); the browser suite now runs against
  two builds of `e2e_app` (`E2E_VARIANT` = `plain` | `layouts`; `views_common`, `views_plain`,
  `views_layouts`) by default, plus `test/node/e2e/layouts.spec.js` (layouts build only).
  Last full run: 561 eunit, 61 JS unit, 30 specs (plain) and 34 (layouts), Chromium, all green.
- README: "Layouts" and "Slots" sections, the config table, the Development section.
- Not done on purpose: nested layouts (the user does not need them now). Nothing else of the
  layout plan is open.

**New input: `/home/witchcraft-dev/code/agentic/WEBERL_FEEDBACK.md`** (read it first; it is
short). The agentic project built its account pages (log in, register, settings, delete account)
on Weberl. Layouts and slots worked well. Six frictions, in the author's words and order:

1. No request/response helpers for plain HTML apps: they hand-wrote cookie parsing, `Set-Cookie`
   building (several cookies need `weberl_response:new/3` because `with_header/3` replaces),
   urlencoded form parsing, `303` redirects and a double-submit CSRF cookie
   (`src/web/agentic_web.erl` there). Suggested: `weberl_request:cookies/1`, `form/1`,
   `weberl_response:redirect/2`, `set_cookie/4`.
2. No conditionals in templates: nav for signed-in/out users, optional flash messages and form
   errors are built as HTML in Erlang and inserted with `{{{ }}}` (escaping by hand); an always
   present `<p class="form-error">{{ error }}</p>` hidden with CSS `:empty`. Suggested:
   `{: if name :}`, or a way to render a fragment into an assign.
3. Interpolation is rejected in `href`/`action` (correct for safety), but "next page" or a link
   with an id needs a safe URL-attribute escape.
4. Argument order: `weberl_request:header(Name, Request)` takes the request last, while `method/1`,
   `query_params/1`, `read_body/1` take it first (`weberl_response:header/2` has the same shape).
5. A layout can only be selected through `weberl_metadata/0`, not through `-weberl_route(...)`
   next to `-weberl_page(...)`; one place would be more predictable.
6. No flash or session helper: flash is a fixed-code query parameter mapped to messages in Erlang.

### Decisions on the feedback (user, 2026-11-05)

- **Order**: 4, 1, 6 (builds on 1), then 5, 2, 3 last (2 and 3 need design decisions the user
  wants to generalise to other libraries that need template conditionals; 2 should offer
  Erlang-like conditionals plus comprehensions/for; 5 is a discussion).
- **4 done** (breaking change accepted): functions take the subject first. `header/2`,
  `with_header/3`, `with_body/2`, `with_page/2` in `weberl_request` / `weberl_response`.
- **1**: homogenised Weberl helpers that use the underlying adapter; add the needed
  callbacks to the adapter behaviour. Basic form helpers are needed for CSRF; **CSRF is
  provided by the framework**. Each item gets tests for the exact complaint it solves.
- **1, split decided (option A)**: the adapter parses (new required callbacks `cookies/1`,
  `form/1` in `weberl_adapter`; Roadrunner keeps its request in `meta.raw`), Weberl builds
  (cookies, redirects, repeated headers: pure, validated, one serializer). **1a done**:
  `weberl_request:cookies/1`, `cookie/2`, `form/1` (urlencoded only), tests in
  `test/weberl_request_helpers_tests.erl` (real HTTP login-style POST). **1b done** (user agreed to
  the defaults): `weberl_response:add_header/3`, `header_values/2`, `set_cookie/3,4`,
  `delete_cookie/2,3`, `redirect/1,2` (303 default), `weberl_cookie` (validated serializer, defaults
  `Path=/; HttpOnly; SameSite=Lax`, `secure` off), `weberl_url:local/1`; headers with control chars
  raise `badarg`; `new/3` keeps repeated headers; fixed `with_header/3` leaving repeats behind. Tests:
  `test/weberl_response_helpers_tests.erl` (includes a 303 with two set-cookie over Roadrunner).
  **Multipart**: not supported by `form/1` yet; proposed `weberl_request:multipart/1` through the same
  adapter callback pattern (parts `#{name, filename, content_type, body}`), user has not decided.
**1c done: CSRF** (user decided: strict by default, option A; token and
  form helper in this step; forms are a future roadmap item, in `ROADMAP.md` "Forms"). Route option
  `csrf => true | origin | false` (default `true`); `weberl_dispatch` runs `weberl_csrf:check/2` for
  POST/PUT/PATCH/DELETE (403 + `csrf_rejected` log); Origin check (authority = Host, https listener
  refuses http origin, `csrf_origins` env, `null` refused, missing passes) + signed double-submit token
  (`weberl_csrf:protect/2`, `verify/1`, cookie `weberl_csrf` / `__Host-weberl_csrf` with `secure_cookies` (was `csrf_secure`),
  field `_csrf`, header `x-csrf-token`); `weberl_form:open/2,3`, `csrf_input/1`; the signing key moved to
  `weberl_sign` (shared with `weberl_live_guard`; flash can reuse it). Tests: `weberl_csrf_tests`
  (688 eunit tests pass). **Breaking**: POST routes now need a token or `csrf => false`/`origin`
  (two existing tests were switched to `csrf => false`). **Still to do**: reply in agentic's
  `WEBERL_FEEDBACK.md` (and note that its `agentic_web.erl` can drop cookie parsing, form parsing,
  Set-Cookie building, redirects and CSRF), then item 6 (flash/session on top of `weberl_sign` and
  `set_cookie`), then 5, 2, 3.
- **6, decisions (user, 2026-11-05): sessions first, then flash on top of the session.** Weberl does not
  own logins; it offers `session`: one encrypted + authenticated cookie (ChaCha20-Poly1305, key derived from
  `live_secret` with a label), Erlang terms (`term_to_binary`, `binary_to_term(.., [safe])` after
  authentication), `weberl_request:session/1`, `session_get/2`; on the response `load_session(Response,
  Request)` (explicit seed), `put_session/3`, `delete_session/2`, `set_session/2`, `reset_session/1`,
  `session_ttl/2`, `session/1`, `session_get/2`. After `put_session(R, K, V)`, `session_get(R, K)` returns V
  (the response holds the whole map once loaded). **Autoload**: dispatch makes the request ambient (process
  dictionary, handlers run in the dispatch process) so `put_session` etc. load the session by themselves;
  internal env `session_autoload` (default `true`, not public) turns it off, later per route / globally,
  then `load_session/2` is required (`{session_not_loaded, Op}` otherwise). Size: `session_warn_bytes`
  (3000, warning), `session_max_bytes` (3800, capped at 4096; over it the response is a logged 500). TTL:
  `session_ttl` default 2 days, absolute (expiry inside the payload and in `Max-Age`, kept on writes, renewed
  by `set_session`/`reset_session` or `session_ttl/2`); `infinity` = no server-side expiry, `Max-Age` 400
  days (browser cap). No server-side revocation (document). `csrf_secure` renamed `secure_cookies` (CSRF,
  session, flash). Flash: inside the session under a reserved key with its own short expiry; `get/1`
  (non-consuming), `take/2` (read + clear), `keep/2` (copy request flash into the response = pass-through).
- **6a, sessions: done** (721 eunit tests). `weberl_session` (cookie codec, ambient request,
  `finalize/2`), response/request functions as above, `weberl_sign:key/1`, `weberl_cookie:secure/0`;
  dispatch wraps the handler in `weberl_session:run/2` and finalizes. Tests: `weberl_session_tests`,
  `weberl_test_cookie_adapter` (cookie-parsing stub adapter for hand-built requests). **6b flash: done**
  (`weberl_flash`: `put/3`, `get/1,2`, `take/2`, `keep/2`; reserved session key `'$weberl_flash'` holding
  `{WrittenAt, Map}`, `flash_ttl` 300 s; `take` removes only what the request delivered; `weberl_flash_tests`,
  16 tests, incl. a 3-hop HTTP chain with a pass-through redirect). **Next: 5, then 2, then 3** (user's
  order; 5 and 2 are discussions, 2 and 3 need design decisions meant to generalise to other
  template libraries).
- **5 done (user: option A)**: `layout` is a route option (`-weberl_route(#{layout => main}).`,
  `check_opts` takes an atom); `weberl_route:layout/1` (`{ok, Name} | none`), `weberl_template:layout/1`
  (what was compiled; the generated `info/0` has `layout`), `weberl_template_layout:name/1`. A declarative
  route naming a layout is `layout_needs_a_filesystem_view`; the `none` sentinel problem is gone
  (`{ok, Name} | none`). **`weberl_metadata/0` was then removed** (user: nothing in the roadmap needs it;
  reintroduce if ever needed): callback, `weberl_handler:metadata/1`, the `check/1` validation, the
  `conflicting_layout` error, the example and e2e views (now `-weberl_route(#{layout => main}).`), tests and
  docs (`MILESTONE_2.md` section 7 has an update note); a leftover `weberl_metadata/0` in a view is ignored.
  Tests: `weberl_route_layout_tests` (747 eunit tests pass; the example app was started and its four pages
  render through their layout). User wants **runtime-chosen layouts** later: design notes in `ROADMAP.md`
  "Layouts chosen at runtime". **Next: 2 (conditionals, discuss first), then 3.** The e2e browser suite was
  not re-run after the e2e_app views changed (only compiled).
- **2 (template conditionals and loops), design in progress, one point at a time.** **Decision 1 (user,
  2026-11-05): option C, Erlang expressions and patterns inside block tags.** Assigns are written `@name`
  in expressions (`{{ name }}` stays as shorthand for `{{ @name }}`; names in `{{ }}` must start lowercase
  today, so `{{ Name }}` is free for pattern-bound loop variables); locals are ordinary Erlang variables;
  the two namespaces cannot clash. Region dependency tracking collects the `@` names. Implementation
  sketch: pre-scan the expression text turning `@name` into a reserved variable (skipping strings, quoted
  atoms, char literals), `erl_scan`/`erl_parse:parse_exprs`, then replace those variables with a runtime
  assign lookup (`missing_variable` as elsewhere). Templates are developer code (like `.erl`), user input is
  rendered, never evaluated. **Decision 2 (user, 2026-11-05): accepted.** `if` conditions must be exactly `true`
  or `false` (`{not_boolean, View, Line, Value}` otherwise); optional values are passed as `undefined` and
  tested explicitly (`@error =/= undefined`) or, better, matched with `case` (test and bind in one step);
  no Jinja-style truthiness. Rules: Erlang's operators as written (`andalso`/`orelse` short-circuit,
  `and`/`or` need booleans); a missing `@name` is `missing_variable` even inside a condition; `case` branches
  are Erlang patterns with an optional `when` guard and an unmatched `case` raises `{case_clause, ...}` (a
  trailing `_` opts out); `{{ Msg }}` (capitalized) reads a local variable through the same value rules as an
  assign (`unsupported_value` for other terms) and `{{{ Msg }}}` is raw. **Decision 3 (user): the forms accepted**: `{: if Expr :}` / `{: elif Expr :}` / `{: else :}` /
  `{: /if :}`; `{: case Expr :}` / `{: of Pattern [when Guard] :}` / `{: /case :}` (only whitespace between
  `case` and the first `of`); `{: for Qualifiers :}` / `{: empty :}` / `{: /for :}` (anything Erlang allows after
  `||`: generators, filters, several qualifiers, map generators; `empty` renders when nothing matched);
  closers carry no name, mismatches name both lines; `elif`/`else`/`of`/`empty` only inside their parent;
  pattern/generator variables are scoped to their branch or body (an already bound name is an error);
  the tag ends at the first `:}` (documented limitation); `if elif else case of for empty` become reserved
  block names. **Decision 4 (user): accepted, for now**: blocks only where the HTML context is plain text
  (`{block_in_unsupported_context, Kind, Where}` elsewhere: in tags, attribute values, script/style,
  comments); each branch/body is walked from text and must end in text (element nesting is not checked,
  as for regions); any nesting depth, regions may contain blocks; `{: content :}` and `{: slot :}` may stand
  inside `if`/`case` branches (content still at most once) but not inside `for`; `{: fill :}` stays top-level
  in a view; compile-time composition must find them at any depth of `if`/`case`; whitespace is literal
  (nothing trimmed); conditions inside tags and attributes are NOT in v1 (extension recorded in
  `ROADMAP.md`). **Decision 5 (user): accepted.** Regions may stand in `if`/`case` branches
  (`render_region/3` renders the content without the surrounding condition; a hidden branch simply has no
  element and the browser ignores the patch); a region may contain blocks (their variables are the region's
  dependencies); to make a conditional live put the block inside a region (document this: an `if`
  outside any region is rendered once); a region may not use a local variable bound outside it
  (`{region_uses_outer_variable, Region, Var, Line}`: it renders alone, from the assigns); no region in the
  body of a `for` (`{region_in_for, Region, Line}`; allowed in `empty`; dynamic region names would lift it);
  region names stay unique even across exclusive branches; `regions/1` marks nothing as conditional.
  **Decision 6 (user): accepted, compilation.** New AST nodes `{'if', Line, [{Cond, Children}], Else}`,
  `{'case', Line, Expr, [{Pattern, Guard, Children}]}`, `{for, Line, Qualifiers, Body, Empty}`,
  `{local, Line, Name, Mode}`; expression text parsed once with `erl_scan`/`erl_parse` at the tag's line
  offset (error `{syntax_error, File, Line, {invalid_expression, Text, Info}}`); `if` is nested
  `case Cond of true/false/V -> error({template_error, {not_boolean, View, Line, V}})`; `case` is a native
  `case` plus a last clause raising `{template_error, {case_clause, View, Line, V}}`; `for` is
  `[Body || Quals]`, with `empty`: `case [Body || Quals] of [] -> Empty; L -> L end` (a non-matching
  generator pattern skips the element, Erlang's rule); `@name` is
  `weberl_template_runtime:assign(name, Assigns, View)` (raw term, `missing_variable` when absent); locals
  are renamed with a reserved prefix (`Name` -> `W_Name`); `{{ Name }}` calls a runtime function taking a
  value with the same type rules (`unsupported_value`); `variables/1`/`regions/1` collect every `@name`
  (conditions, guards, qualifiers, funs) plus `{{ name }}`, never locals; a scope pass finds free locals in a
  region and rebinding; any function may be called in expressions (developer code; keep them pure and cheap,
  they run on every render and region re-render); `compose`/`walk`/region search recurse into blocks;
  generated forms compile with warnings off. **Decision 7 (user): accepted**, reuse boundary: the block
  machinery is modules in Weberl's source tree under `src/template/blocks/` (prefix `weberl_blocks_`) that call
  nothing else in Weberl, only OTP: expression front end (text -> Erlang abstract forms, `@name` rewriting, line
  offsets), scope analysis (free/bound locals, rebinding), dependency collection, block code generation; host
  hooks for assign access, local renaming and value rendering. The generator produces abstract forms, so they
  can be compiled into a module (Weberl) or run with `erl_eval`. HTML walker, regions/slots/fills/content,
  layouts, escaping and live updates stay Weberl-specific. `TEMPLATE_BLOCKS.md` documents the language, AST,
  errors and hooks. (2026-11-05, user: reuse by another library is parked; no extraction work until the user
  raises it again.) **Decision 8 (user): accepted**, expression interpolation: `{{ Expr }}` /
  `{{{ Expr }}}` is any Erlang expression rendered through the host's value rules; a bare lowercase name stays
  the assign shorthand, a bare capitalized name is a local; the tag ends at the first `}}` (`}}}` for raw), so an
  expression containing `}}` (nested maps) needs a space (`} }`); dependencies are its `@names`; the HTML
  context rules apply as for names; an unsupported result is `{unsupported_value, View, Source, Value}`
  (Source: the name atom, or the expression text for expressions). **Decision 8 revised (user, 2026-11-05):
  the lowercase assign shorthand is dropped.** `{{ ... }}` always holds an Erlang expression; an assign is
  only ever `@name` (`{{ @title }}`, `{{{ @html }}}`); `{{ name }}` is the atom `name` and renders as the text
  `name`; `{{ Name }}` is a local variable. **Breaking** for every existing template (`{{ title }}` becomes
  `{{ @title }}`): migrated in the repository (examples, e2e_app, tests, README) and the agentic project must
  do the same. Values rendered: binaries, character lists, integers, floats and atoms (so `true`/`false`/
  `undefined` render as their names). `unsupported_value` now names the expression text
  (`{unsupported_value, View, <<"@title">>, Value}`). **Build stages (re-planned)**: 1 expression module
  (done); 2 `{{ Expr }}` end to end: lexer, parser, compiler, runtime, template migration (keeps the suite
  green; free locals are errors until blocks bind them) **DONE, 786 eunit tests** (lexer hands over the raw
  text, `{interp, Line, Mode, Text}`; AST node `{expr, Line, Mode, Parsed}`; `weberl_template_runtime`
  `assign/3`, `escaped/3`, `raw/3` take `(Value, View, Source)`; atoms render; templates, tests, README and
  agentic's feedback file migrated/updated; the example app was started and renders; the e2e_app only
  compiled, its browser suite was not re-run; agentic's own `.weberl` files still need the rewrite); **3 + 4 + 5 DONE together (845 eunit tests)**:
  lexer tokens `{stmt, Line, Kind, Text, TextLine}` / `{stmt_end, Line, Kind}` (the text keeps the white space
  after the keyword so lines count right; `else`, `cond` and `of` are Erlang reserved words, hence quoted
  atoms and `{test, _}` as internal state); parser frames for `if`/`case`/`for` with the nodes of decision 6; scope
  pass in `parse/2` (`unbound_variable`, `rebound_variable`, `region_uses_outer_variable`) and again on a
  composed layout+view (`check_scope/2`); placement errors (`block_in_unsupported_context`,
  `block_unbalanced_markup`, `region_in_for`, `slot_in_for`, `content_in_for`, `content_before_first_of`,
  `case_without_of`, `misplaced_block_tag`, `unclosed_block`, `unexpected_block_end`,
  `mismatched_block_end`); compiler: `if` = nested `case` with a `not_boolean` clause, `case` = native `case` +
  `case_clause` clause, `for` = list comprehension (+ `empty` case); **decision made while building**: a guard
  cannot call a function, so the assigns read by the guards of a `case` are fetched first and passed as the
  arguments of a fun that holds the `case` (a missing one raises even if an earlier clause would match, and
  no "unsafe variable" clash between sibling cases); `weberl_template_parser:children/1`, `map_children/2`,
  `check_scope/2`; layout composition looks through blocks. **Verified (2026-11-05)**: live test
  `weberl_live_blocks_tests` (conditional, loop and case inside regions re-render on assign and are pushed; an
  `if` outside a region is not; a region in a branch) found a real bug, fixed: `try_render/2` and
  `try_render_region/3` now catch any exception from an expression and return
  `{error, {render_failed, Class, Reason}}` (before, a `for` over a non-list killed the live session);
  853 eunit tests; the e2e suite (`test/e2e/run.sh all`, Chromium) passed: 30 specs plain, 34 layouts, plus the JS
  unit tests. `TEMPLATE_BLOCKS.md` written (README links it); agentic's `WEBERL_FEEDBACK.md` updated. **Honest
  gap against decision 7**: only `weberl_blocks_expr` is separated from Weberl; block lexing/structure, the
  scope pass and the `if`/`case`/`for` code generation still live in `weberl_template_lexer`/`_parser`/`_compiler`
  next to regions and the HTML walker (TEMPLATE_BLOCKS.md says so); parked. No e2e spec exercises blocks in a real browser (the live test covers the server
  side; the browser patching of regions is covered by the existing region specs); 3 block tags: lexer, parser, validation, scope pass,
  region rules; 4 layout composition through blocks; 5 compiler and runtime for blocks; 6 README,
  `TEMPLATE_BLOCKS.md`, agentic feedback. Item 3 (safe URLs) follows and depends on this.
- Arizona checked (clone of `arizona-framework/arizona`, read 2026-11-05): its CSRF is an
  `Origin` check (same-origin or allowlist `csrf_origins`; a missing Origin passes), a default
  middleware on live and controller routes, no tokens; cookies are `arizona_req:cookies/1`
  (adapter callback `parse_cookies/1`) and `put_resp_cookie/4`, serialized by an
  adapter-independent `arizona_cookie:serialize/3` that raises on invalid name/value/attr bytes;
  `redirect/2,3` stashes a status and location; flash is a signed, expiring, one-time cookie
  (`arizona_flash`, HMAC with `secret_key`, purpose label); sessions are a signed cookie or a
  server-side store behind the `arizona_session_store` behaviour. It has no form parser.

- **Decision 8 (safe URLs, item 3; user accepted 2026-11-05; recorded before building).** Explicit, not
  implicit-by-position. In a URL attribute an interpolation must be a **tagged value** `{weberl_url, Kind, Data}`
  returned by a `weberl_url` helper; an untagged value raises `{untagged_url, View, Source, Value}`. The
  **attribute decides the policy at render time** (the helper does not know where it ends up):
  - helpers: `ensure_path(V)` (a path on this site: starts with a single `/`, not `//` or `/\`, no control
    characters; **not** a full URL; raises otherwise, via `weberl_url:local/1`), `url(V)` (local path or
    `http`/`https`, for user-supplied links), `component(V)` (one percent-encoded segment), `query(Map)`
    (encoded `k=v&k=v`), `router_path(Path)`/`router_path(Path, Query)` (a local path whose `Path` must be a
    route in the running router's table, else `{unknown_route, Path}`), `router_url(Path[, Query])` (the same
    check, absolute, using config `public_url`; `{no_public_url}` when unset; the `Host` header is not used),
    and `unsafe_url(V)` (skips every check: scheme, local-only, dangerous sink; **still HTML-escapes**, so a
    quote cannot leave the attribute).
  - `component` and `query` need a literal prefix in the attribute (a leading one is a compile error).
  - attributes: `href`, `action`, `formaction`, `cite`, `xlink:href` take local paths and `http(s)`; `src` and
    `poster` on `img`/`audio`/`video`/`source`/`track` the same; **dangerous sinks** (`<script src>`,
    `<iframe src>`, `<embed src>`, `<object data>`, `<base href>`, `<link href>`) take local paths only, and
    only `unsafe_url` goes beyond. Literal-only (interpolation still rejected): `style`, `on*`, `srcdoc`, `is`,
    `srcset`, `data`, `ping`, `usemap`, `manifest`, `codebase`, `longdesc`, `background`; raw `{{{ }}}` in any
    attribute stays rejected.
  - router checks are against **static paths only** (`weberl_table:lookup/2` is an exact lookup). Dynamic
    paths are future work (`ROADMAP.md`); until then an app uses `ensure_path` + `component` for unverified
    links (agentic does this).
  - still to decide (superseded by decision 9): how a helper reaches the router table from inside a render.
- **Decision 9 (router verification of links; user, 2026-11-05).** The route table exists before templates
  compile (`weberl_router_server:start/3`: `weberl:build` then `weberl_views:prepare(Router, Table)`), so the
  check is a **compile error**, with a render-time backstop.
  - `weberl_template:compile/3` (and `compile_file`) take an options map with `routes => Table`;
    `weberl_views:prepare` passes it. Without `routes` the compile-time route check is **explicitly skipped**
    (documented, with a test); no test wrapper. Tests build a table with `weberl_route:new/4` and
    `weberl_table:assemble/2`.
  - `router_path("/agents")` (literal): checked at compile time, a miss fails the router start with file and line
    (`{unknown_route, Path}`).
  - `router_path(@target)` (fully dynamic argument): **compile error**, nothing is verifiable; use `ensure_path`.
  - `router_path("/something/{{ @x }}/{{ @y }}")`: placeholders `{{ Expr }}` (same expression front end,
    so `@name` works) inside the first string argument of `router_path`/`router_url`; only recognised there, in
    any other string `{{` is plain text. This works because of the **tag-end scanner** (decision 10), which
    treats the string as opaque. (An earlier draft used `{: @x :}`; dropped: `{: :}` is the block-tag
    delimiter.) Each placeholder is **exactly one segment** (rendered percent-encoded like
    `component`). If no route has that shape: `unknown_route` compile error. If one does: a compile **warning**
    (the value is unknown), silenced by `#{no_warn => true}`. At render the built path is looked up in the table,
    else `{unknown_route, Path}`; `"/something/{{ @x }}/"` against a route `/something/a/b` raises, the author
    writes one placeholder per dynamic segment.
  - second argument is an options map `#{router => Name, no_warn => boolean()}`; `router` replaces the ambient
    router at render time and, at compile time, selects that router's table when it is running (else the compile
    check is skipped).
  - render-time backstop: the ambient router name (process dictionary; set by dispatch and by a live session,
    which remembers it like its assigns), raising `{no_router}` outside a request; applies for placeholders and
    any call the compiler cannot see.
  - warnings are returned with the compile result and logged by `weberl_views:prepare` with file and line.
  - known limit: a view mounted in two routers with different tables is compiled against the router that started
    last; the render-time check uses the request's own router.
- **Built so far (decisions 8 to 10).** Step 1: the tag-end scanner (`89fcbca`). Step 2: `weberl_url` helpers
  (`ensure_path`, `url`, `component`, `query`, `unsafe_url`, `router_path/1,2`, `router_url/1,2`, tagged value
  `{weberl_url, Kind, Binary}`, `is_tagged/kind/data`, `with_router/2`, `ambient_router/0`), tests in
  `weberl_url_helpers_tests`. Terms as built (helper level, `error:{template_error, Reason}`): `{not_a_path, V}`,
  `{not_a_url, V}`, `{bad_url_value, V}`, `{bad_url_option, Opt}`, `{unknown_route, Path}`, `no_router` and
  `no_public_url` (atoms, not one-tuples), `{router_not_running, Name}`, `{bad_public_url, V}`. `router_path`'s
  second argument is the options map (`router`, `query`, `no_warn`); `query` replaces the query argument of
  decision 8. Still to build: step 3 compile-time analysis (routes option, placeholders, attribute policy,
  warnings), step 4 render-time policy and ambient router set by dispatch and live sessions, README/guides.
- **Step 3 built (2026-11-05), item 3 complete on the Weberl side.** `weberl_template_urls:analyze/3` runs on
  the composed AST (after layout composition, before `check_scope`, which also covers placeholder locals);
  `weberl_template_html:url_attribute/1` and `url_policy/2`; `weberl_template_runtime:url/4` is the render-time
  check (`{untagged_url, View, Line, Value}`, `{unsafe_url, View, Line, Tagged}`); compile functions
  `compile_source/5`, `compile_file/4` with `#{routes => Table}` and `weberl_template:warnings/1`
  (`{warning, File, Line, Reason}`), `weberl_views:prepare` passes the table and logs warnings. Compile errors
  use the `{syntax_error, File, Line, Reason}` shape (not `{template_error, ...}`) like every other compile error.
  **Revision of decision 9 (render-time backstop)**: a render can run in any process (session, caller of
  `update/3`, an agent calling `update_topic/4`), so an ambient per-request router would be missing there.
  Instead, when the template is compiled with the table, the compiler embeds the routes a call can match (one
  for a literal, every route of the pattern's shape for placeholders) in the generated code
  (`weberl_url:router_path_known/3`, `router_url_known/3`); the render-time check is a lookup in that map and
  needs no router and no process state; dispatch and live sessions set nothing. The ambient router
  (`weberl_url:with_router/2`) and the `router` option remain only for templates compiled without a table
  (unit tests): those compile to `router_path_parts/2` and look the router up when rendered (`no_router` when
  there is none). Resolution of an inconsistency in decision 8: `<object data>` stays literal-only (`data` is in
  the literal-only list), so it is not a sink that takes paths; `use` (`href`, `xlink:href`) joins the
  local-only sinks; in `local_only` position `url` and `router_url` are refused statically and at render
  (even for a value that happens to be local). Tests: `weberl_template_urls_tests` (complaints: an id in a
  path, `next` as a query value, `javascript:`, a typo'd route, placeholders, policy per element),
  `weberl_live_urls_tests` (links in a region re-rendered by the session and by `update/3` from another
  process), `weberl_views_tests` (router start verifies links, a typo fails the start with file and line),
  `weberl_url_helpers_tests`; 915 eunit tests; the browser suite was not re-run (no browser-side change).
  README "Links" written. Roadmap order given by the user afterwards: dynamic router paths, multipart forms
  (agentic needs them), blocks inside tags and attributes, runtime layouts.
- **Decision 10 (tag ends are found by an Erlang-aware scanner; user, 2026-11-05).** Replaces "a tag ends at the
  first `}}`/`:}`". Delimiters stay `{{ }}`, `{{{ }}}`, `{: :}` (alternatives `{: :}`/`{:: ::}` for
  interpolation and a plain `{{`/`}}` counter were considered and rejected: the counter breaks on
  `{{ {{a, b}, c} }}` and `#{k => #{j => 1}}`; the swap merges the interpolation and block namespaces and
  collides with Erlang's `case`/`if` expressions). The scanner lives in `weberl_blocks_expr` (no Weberl or HTML
  knowledge). While looking for the end of a tag it treats strings `"..."`, quoted atoms,
  character literals (`$}`, `$"`) and comments as opaque, keeps a depth for `( [ { <<`, and ends the tag at
  `}}` (`}}}` for raw) / `:}` only at depth 0. Effects: `{{ f("{{ @x }}") }}` and
  `{{ #{k => #{j => 1}} }}` work without a space; `{{{ #{a => 1} }}}` works. Errors:
  `{unterminated_string, Line}`, `{unbalanced_brace, Line}`. The "Known limits" entry in `TEMPLATE_BLOCKS.md`
  and the README sentence about `}}` are rewritten when this is built. Tests: braces in strings, nested
  maps/tuples without a space, `$}` and `$"`, unterminated string, unbalanced brace, raw with a map.
- Plan for the feedback (proposal; the user decides order and each design point), continued below:

### Plan for the feedback (proposal; the user decides order and each design point)

Rules as always: **one design point at a time**, record the decision here or in the README
before building, small commits, eunit for everyday checks, the browser suite only when a batch
of specs is written (`E2E_VARIANTS=plain` is enough unless layouts are touched).

**Step 0: triage with the user (5 minutes).** Confirm the order below and which items to drop or
defer. My suggested order is by value for agentic and by risk: 4 and 1 (small, additive or
mechanical), then 2 (the biggest gain, a template language change), then 3 (depends on the
template work), then 5, then 6 (builds on 1).

**Step 1: argument order (item 4).** Smallest change, do it first so later helpers follow one
convention (subject first). Change `weberl_request:header/2` to `header(Request, Name)` and look at
`weberl_response:header/2` the same way. The framework is unreleased, so a plain break is fine (ask
if the user wants a deprecation instead). Callers to update: `test/weberl_request_tests.erl`,
`test/weberl_router_server_tests.erl`, README and any doc comment; grep `header(` in `src/`,
`example/`, `fixtures/`, `e2e_app/`. Also tell the agentic project (its `agentic_web.erl`).
Decision to record: "functions take the subject (request/response) first".

**Step 2: request and response helpers (item 1).** Design points, one at a time:
- `weberl_request:cookies/1` -> `[{Name, Value}]` (parse `cookie` headers; decide on duplicates and
  on quoted values; no decoding beyond what RFC 6265 says).
- `weberl_request:form/1` -> `{ok, [{Key, Value}]} | {error, Reason}` for
  `application/x-www-form-urlencoded` (decode `+` and percent escapes; reject other content
  types; respect `max_content_length` already enforced by the adapter; reuse the query parsing
  code of `query_params/1` if it exists). Multipart is out of scope; say so in the README.
- `weberl_response:redirect/2,3` (`303` by default for after-POST, allow `301/302/307/308`;
  validate the target has no CR/LF; decide whether to restrict to relative targets or leave the
  open-redirect question to the app and document it).
- `weberl_response:set_cookie/3,4` with options (`path`, `max_age`, `http_only`, `secure`,
  `same_site`); validate name/value (no control characters, `;`, spaces) so header injection is
  impossible; **several `set-cookie` headers must be possible**: add `weberl_response:add_header/3`
  (append, as `with_header/3` replaces) and make `set_cookie` use it. Check the Roadrunner
  adapter sends repeated headers (`weberl_roadrunner_convert`) and add a test with two cookies.
- CSRF: do not build it yet; first decide whether it belongs in Weberl (a thin `weberl_csrf`
  double-submit helper on top of cookies and `form/1`) or stays in the app. Ask the user.
- Tests: new eunit modules next to `weberl_request_tests` / `weberl_response_tests`, one
  integration test through Roadrunner (cookie round trip, redirect status and location).

**Step 3: conditionals (item 2).** The design needs the user's call before any code:
- Syntax: `{: if name :}...{: else :}...{: /if :}` (and maybe `{: if not name :}` or
  `{: unless name :}`). Truthiness: only booleans (strict, in the spirit of the engine), or also
  "non-empty binary"? Recommend strict booleans plus a documented convention, because the engine
  rejects unsupported values today (`unsupported_value`).
- Validation, like regions: each branch must start and end in HTML text (the same
  `walk` in `weberl_template_parser`); the variable is part of `variables/1`.
- Interactions to decide: regions inside an `if` (a region that is not rendered does not exist in
  the page, which the browser already tolerates; but `regions/1` and `render_region/3` need the
  assign of the condition), slots and `{: content :}` inside an `if` (probably not allowed in
  v1), the generated code (`case` on the assign; `weberl_template_runtime` gets a boolean check
  with `{unsupported_value, ...}` for others).
- The "fragment into an assign" alternative is a bigger feature (includes/components); keep it
  out of this step and note it in `ROADMAP.md` as the next template idea.
- Tests: lexer, parser, compiler tests in `weberl_template_tests` style; one layout example
  (nav signed in/out) in `weberl_template_layout_tests`; add an `if` to a layouts-variant page of
  `e2e_app` only if it adds value (the browser suite is heavy).

**Step 4: safe URLs in `href`/`src`/`action` (item 3).** Today these attributes reject
interpolation (`weberl_template_html`). Design points: (a) interpolation after a literal prefix
(`href="/items/{{ id }}"`, `href="?next={{ next }}"`) percent-encodes the value; (b) a whole-value
interpolation (`href="{{ url }}"`) is allowed only for values that pass a scheme check (relative
path starting with `/` and not `//`, or `http(s):`), otherwise a render error; (c) syntax: implicit
by context, or an explicit marker such as `{{ url next }}`. Recommend the explicit marker (no
magic: the template says what is safe), implemented as one more interpolation mode next to
`escaped | raw`. Keep `style` and `on*` rejected. Needs `weberl_template_runtime` functions,
lexer/parser/html-context changes, compile-time errors for the marker outside a URL attribute.

**Step 5: layout in `-weberl_route(...)` (item 5).** Small, but a decision first: the attribute
is read without loading the module (`weberl_fs`, `weberl_page_kind`), the metadata needs the
module. Options: (a) accept `layout` in the route options as well and make both agree or error
on conflict; (b) keep metadata only and document why. Recommend (a) only if the attribute parser
makes it cheap; otherwise (b), with a README sentence. Touches `weberl_route:opts()`,
`weberl_views:layout_of/1`.

**Step 6: flash and sessions (item 6).** Biggest and least defined; depends on step 2. Discuss
before designing: a signed cookie flash (`weberl_flash`: put a message on a redirect response,
read-and-clear on the next request) needs a signing facility; `weberl_live_guard` already signs
page tokens with `live_secret`, so a shared small `weberl_sign` module may be worth extracting.
Full login sessions (user id in a signed or server-side cookie) are probably the app's job; ask
the user how much Weberl should own. Record the answer in `ROADMAP.md` if deferred.

**Then:** reply to the agentic project with what changed (its `WEBERL_FEEDBACK.md` is the log;
add a short "Status" line per item there or in this file), update the README sections touched,
and keep this file's "Next session" list in sync.

### Small things to remember
- `HANDOFF.md` is temporary (see the top): the layout decisions above belong in the README,
  which already has them; delete this section once the feedback work is absorbed.
- A layout literally named `none` would be read as "no layout" (`weberl_views:layout_of/1`
  returns `none`); trivial to fix with a different sentinel if it ever matters.
- Stack-trace line numbers of a composed (layout + view) template point into the view file for
  lines that come from the layout.
- This session used shell heredocs/Python for some file writes against the user's rule (use
  Edit/Write); no harm done, but do not repeat. There is no `weberl-dev` container right now;
  tests ran with `podman run --rm -v "$(pwd):/app:Z" -w /app localhost/weberl:latest rebar3 eunit`.

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
1. **Use it for real** (in progress: see "Session of 2026-11-05" at the top for the feedback from agentic and its plan): the user is moving to the `agentic` project to build multi-tab
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
