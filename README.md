# weberl

A small web framework for Erlang/OTP 29: filesystem and declarative routing,
HTTP handlers, and an HTML template engine, behind a transport-independent API.
Pure Erlang/OTP; the HTTP server (Roadrunner) is an optional dependency used
through an adapter.

```text
request ──► adapter ──► dispatch ──► route table ──► handler ──► template ──► response
 (Roadrunner)   (weberl_request)    (weberl_table)   (your view)  (.weberl)   (weberl_response)
```

## Contents

1. [Quick start](#quick-start)
2. [Architecture and source layout](#architecture-and-source-layout)
3. [Configuration](#configuration) (including [live pages settings](#live-pages-settings))
4. [Starting and stopping routers](#starting-and-stopping-routers)
5. [Filesystem routing](#filesystem-routing)
6. [Declarative routing](#declarative-routing)
7. [Conflicts, precedence and ordering](#conflicts-precedence-and-ordering)
8. [Handlers](#handlers)
9. [Templates](#templates)
10. [Transport adapters and Roadrunner](#transport-adapters-and-roadrunner)
11. [Static assets](#static-assets)
12. [Live pages](#live-pages) (requests, [topics and session-less pages](#topics-and-session-less-pages), transports, credentials)
13. [Build integration](#build-integration)
14. [Running the example](#running-the-example)
15. [Known limitations and future work](#known-limitations-and-future-work)
16. [Development](#development)

## Quick start

`rebar.config` of your application (weberl and the server it talks to):

```erlang
{deps, [
    {weberl,     {git, "<repository url>", {branch, "main"}}},
    {roadrunner, {git, "https://github.com/arizona-framework/roadrunner", {tag, "0.13.1"}}}
]}.
```

List `weberl` and `roadrunner` in your `.app.src` `applications`. A view
(`src/views/home_view.erl` and `src/views/home_view.weberl` next to it):

```erlang
-module(home_view).
-behaviour(weberl_handler).
-export([handle/1]).

handle(_Request) ->
    weberl_response:html(200, weberl_template:render(?MODULE, #{title => <<"Welcome">>})).
```

```html
<h1>{{ @title }}</h1>
```

Put the router under your own supervisor:

```erlang
-import_record(weberl_config, [router, filesystem_router, listener]).

init([]) ->
    Router   = #router{filesystem = [#filesystem_router{root = "src/views"}]},
    Listener = #listener{port = 8080},
    {ok, {#{strategy => one_for_one}, [weberl:child_spec(my_web, Router, Listener)]}}.
```

`GET /` now returns `<h1>Welcome</h1>`. See [Running the example](#running-the-example).

## Architecture and source layout

Four subsystems with one-way dependencies:

```text
adapters ──► handler ──► router          template (depends on nothing else)
```

| Subsystem | Responsibility | Depends on |
|---|---|---|
| `router` | filesystem discovery, declarative collection, normalization, conflicts, lookup | nothing |
| `handler` | request/response records, handler behaviour, dispatch (404/500) | router |
| `template` | lexer, parser, HTML-context validation, compiler, runtime, rendering | nothing |
| `adapters` | transport behaviour and the Roadrunner adapter | handler, router |

Top level modules tie them together: `weberl` (public API), `weberl_config`
(records and validation), `weberl_router_server` (one process per started
router), `weberl_views` (finds, associates, compiles templates at router start)
and `weberl_app` (see [native records](#native-record-loading)).

```text
src/
├── weberl.erl                  public API
├── weberl_app.erl              application callback (loads records, no children)
├── weberl_config.erl           router and listener records, validation
├── weberl_router_server.erl    gen_statem owning a router and its listener
├── weberl_views.erl            router <-> template integration
├── router/                     Milestone 1 routing, unchanged
│   ├── weberl_fs.erl           filesystem discovery
│   ├── weberl_decl.erl         declarative collection
│   ├── weberl_route.erl        route record, path normalization
│   └── weberl_table.erl        assembly, precedence, lookup
├── handler/
│   ├── weberl_handler.erl      behaviour, startup checks
│   ├── weberl_request.erl      request record (cookies, form, session through the adapter)
│   ├── weberl_response.erl     response record (headers, cookies, redirect, session)
│   ├── weberl_dispatch.erl     request -> response (CSRF check, session loading and writing)
│   ├── weberl_cookie.erl       validated Set-Cookie serializer
│   ├── weberl_csrf.erl         Origin check, signed double-submit token
│   ├── weberl_form.erl         form tag with the CSRF field (token in the action for multipart)
│   ├── weberl_multipart.erl    multipart parts: Content-Disposition, limits, files, safe_filename
│   ├── weberl_limits.erl       form limits: defaults, layers, validation, logging
│   ├── weberl_session.erl      the encrypted session cookie
│   ├── weberl_flash.erl        flash on top of the session
│   ├── weberl_sign.erl         the signing/encryption key shared by tokens and sessions
│   └── weberl_url.erl          URL checks and the URL helpers of templates (component, ensure_path, router_path...)
├── template/
│   ├── weberl_template.erl             public API: render, compile, discover
│   ├── weberl_template_lexer.erl       text, {{ }}, {: :} tags
│   ├── weberl_template_parser.erl      parse (blocks, scope) + validate
│   ├── weberl_template_html.erl        HTML context tracking, URL attributes and their policy
│   ├── weberl_template_urls.erl        links in URL attributes: checks, route verification, placeholders
│   ├── weberl_template_attrs.erl       blocks between attributes: the separating spaces
│   ├── weberl_template_layout.erl      layouts: content, slots, fills
│   ├── weberl_template_compiler.erl    AST -> generated module
│   ├── weberl_template_runtime.erl     assign lookup, value conversion, escaping, URL attribute check
│   └── blocks/
│       └── weberl_blocks_expr.erl      Erlang expressions in tags; no Weberl dependency (TEMPLATE_BLOCKS.md)
├── live/                       live pages
│   ├── weberl_live.erl         public API: open, push, publish, update, mount, assign, stats
│   ├── weberl_view_data.erl    what a session keeps for its page (assigns, private)
│   ├── weberl_live_session.erl gen_statem: one session per rendered page
│   ├── weberl_live_sup.erl
│   ├── weberl_live_beacon.erl  beacon tag and injection
│   ├── weberl_live_guard.erl   page tokens (channels, claims), origin check
│   ├── weberl_live_topics.erl  topic membership of one connection process
│   ├── weberl_live_callbacks.erl runs handle_request/3, handle_subscribe/2
│   └── weberl_live_wire.erl    JSON wire format of requests and events
└── adapters/
    ├── weberl_adapter.erl      adapter behaviour
    └── roadrunner/             the only code that touches Roadrunner
        ├── weberl_roadrunner.erl
        ├── weberl_roadrunner_handler.erl
        ├── weberl_roadrunner_convert.erl
        ├── weberl_roadrunner_live.erl      shared checks of the live endpoints
        ├── weberl_roadrunner_sse.erl       GET  /_weberl/sse/:id
        ├── weberl_roadrunner_ws.erl        GET  /_weberl/ws  (multiplexed)
        ├── weberl_roadrunner_poll.erl      GET  /_weberl/poll/:id
        └── weberl_roadrunner_request.erl   POST /_weberl/request/:id
```

Nested source directories need no extra configuration: rebar3 compiles `src/`
recursively (verified by the build and test suite). Nothing is required of
applications that depend on weberl.

## Configuration

Configuration uses OTP 29 native records exported by `weberl_config`:

```erlang
-import_record(weberl_config, [router, filesystem_router, listener]).

Router = #router{
    filesystem = [
        #filesystem_router{root = "src/views", prefix = "/"},
        #filesystem_router{root = "src/admin/views", prefix = "/admin"}
    ],
    modules = [my_app_router]
},
Listener = #listener{adapter = weberl_roadrunner, ip = {127, 0, 0, 1}, port = 8888}.
```

| Record | Field | Default | Notes |
|---|---|---|---|
| `router` | `filesystem` | `[]` | list of `filesystem_router` |
| | `modules` | `[]` | declarative router modules |
| | `layouts` | `[]` | directories of [layout](#layouts) templates |
| | `limits` | `#{}` | [form limits](#forms-and-uploads) for every route of the router (a route's own `limits` win) |
| `filesystem_router` | `root` | required | directory string |
| | `prefix` | `"/"` | URL prefix for the whole root |
| `listener` | `adapter` | `weberl_roadrunner` | module implementing `weberl_adapter` |
| | `ip` | `undefined` | interface to bind; `undefined` is all |
| | `port` | required | 0..65535; 0 picks a free port (`weberl:port/1`) |
| | `options` | `#{}` | adapter specific, validated by the adapter |
| | `static` | `[]` | static asset mounts, see [Static assets](#static-assets) |

Omitting `root` or `port` is a compile-time error. Everything else is checked at
startup (`weberl_config:validate/1`, `validate_listener/1`) and fails with
`{error, {invalid_config, Reason}}`, never a crash.

### Live pages settings

Live pages are tuned with the application environment of `weberl` (`sys.config`, or
`application:set_env/3` before the router starts). Everything has a default; the only
setting you should treat as required in production is `live_secret`.

```erlang
%% config/sys.config
[{weberl, [
    {live_secret, <<"change-me: at least 16 random bytes, same on every node">>},
    {live_attach_timeout, 30000},
    {live_idle_timeout, 60000},
    {live_poll_timeout, 25000},
    {live_poll_fallback, [one_way, two_way]}
]}].
```

| Key | Default | What it does |
|---|---|---|
| `live_secret` | random per node start | Key that signs page tokens (binary, at least 16 bytes; shorter values are ignored). **Set it in production**: with the default, every restart invalidates the tokens of pages already open (their beacons get 403 and give up), and nodes behind a load balancer reject each other's tokens. Keep it out of version control: read it from the environment at startup, e.g. `application:set_env(weberl, live_secret, list_to_binary(os:getenv("WEBERL_SECRET")))` before the first page is served. Rotating it invalidates open pages. |
| `csrf_origins` | `[]` | extra trusted origins for the [CSRF](#csrf-protection) Origin check (binaries such as `<<"https://app.example">>`). |
| `session_ttl` | `172800` | seconds a new [session](#session) lives (two days). |
| `session_warn_bytes`, `session_max_bytes` | `3000`, `3800` | session cookie size (name + value) that logs a warning, and the hard limit (a `500`); the limit never exceeds 4096. |
| `flash_ttl` | `300` | seconds an unread [flash](#flash) lives. |
| `public_url` | unset | the site's own origin (`<<"https://example.com">>`, no path), put in front of `weberl_url:router_url/1,2`. Without it `router_url` raises `no_public_url`; the `Host` header of a request is never used. |
| `secure_cookies` | `false` | `true` makes the cookies Weberl sets itself (CSRF, session, flash) `Secure` and `__Host-`-prefixed. **Set it in production** (HTTPS); a `Secure` cookie is dropped over plain HTTP, which breaks local development. |
| `live_subscribe_timeout` | `10000` | ms a freshly opened WebSocket may wait to subscribe its first page before it is closed. |
| `live_attach_timeout` | `30000` | ms a rendered page may wait for its first connection before the session ends. |
| `live_idle_timeout` | `60000` | ms a session waits for a reconnect after its transport dropped. |
| `live_poll_timeout` | `25000` | ms a long-poll request waits for an event. Keep it below any proxy/load balancer idle timeout. |
| `live_poll_fallback` | `[one_way, two_way]` | page kinds allowed to fall back to long-poll; `[]` turns the fallback off, `[one_way]` removes it for `two_way` pages. Applies to pages rendered after the change. |

Things the application also has to do for live pages:

- Use the Roadrunner adapter (the live endpoints are served by it) and keep the
  `weberl` application running (list it in your `applications`).
- If you put a proxy in front: pass WebSocket upgrades through, disable response
  buffering for `/_weberl/sse/` (the stream sends `x-accel-buffering: no` for nginx),
  and keep the `Host` header intact (the origin check compares it with `Origin`).
- Implement `handle_request/3` in a handler only if its page sends requests with
  `Weberl.request`; without it the client gets an `unsupported` error.
- Topics reach every node of a cluster (`pg` shares the groups), but a page with a session
  lives on the node that rendered it; see [Topics](#topics-and-session-less-pages).
- Do not mount a [static](#static-assets) prefix under `/_weberl`; it is reserved.

### Native-record loading

A native record can only be built after the module that defines it is loaded;
in interactive mode nothing loads it for you. Listing `weberl` in your
application's `applications` is enough: the weberl application loads
`weberl_config` when it starts, before your application. Starting weberl does
nothing else: it starts no routers and no listeners. If you build records without
the application running, call `code:ensure_loaded(weberl_config)` first. In
releases all modules are loaded at boot.

## Starting and stopping routers

You decide when a router starts by placing it in your own supervision tree:

```erlang
weberl:child_spec(Name, RouterConfig, ListenerConfig) -> supervisor:child_spec().
weberl:start_link(Name, RouterConfig, ListenerConfig) -> {ok, pid()} | {error, Reason}.
weberl:stop(Name) -> ok.
weberl:table(Name)  -> {ok, weberl_table:t()} | {error, not_running}.
weberl:port(Name)   -> inet:port_number().
```

`Name` is an atom; the router process is registered under it. Starting does, in
order: validate router and listener configuration, build the route table
(discovery, conflicts), check every handler (module loads and exports
`handle/1`), compile the templates, start the listener. If any step fails
everything already started is stopped and `start_link` returns `{error, Reason}`
(for example `{invalid_config, _}`, `{duplicate_routes, _, _}`,
`{invalid_handlers, [_]}`, `{unassociated_templates, [_]}`,
`{invalid_templates, [_]}`, `{adapter_unavailable, roadrunner}`,
`{listener_start_failed, _}`). Like any linked start, a failure also exits a
caller that is not trapping exits; supervisors trap them.

Stopping a router (`weberl:stop/1`, or terminating the child) stops its listener
so no new connections are accepted. Connections already open finish on their
own. One process runs per router, none per route.

## Filesystem routing

Every file named `*_view.erl` below a root yields one route. The URL path is the
file's directory relative to the root (plus the root's prefix); the module name
plays no part.

```text
src/views/
├── home_view.erl                        -> /
├── about/company_information_view.erl   -> /about
├── blog/blog_view.erl                   -> /blog
├── blog/posts/posts_view.erl            -> /blog/posts
└── users/users_view.erl                 -> /users
```

Naming rules:

- Filename ends in `_view.erl` (and has a non-empty base name).
- `-module(...)` must equal the filename without `.erl`. Ordinary compilation;
  no `no_error_module_mismatch`, no renaming, no generated copies.
- The module name need not match the directory. It must be unique across all
  filesystem roots.
- One view per directory. Directories without views produce no routes but may
  contain subdirectories that do.
- Directory names must be valid URL segments (no whitespace, control chars,
  `? # \`, and no `:` or `*`). A directory named `[name]` is a [route
  parameter](#route-parameters).

### Route parameters

A segment can be a parameter: `:id` in a declarative path, a directory `[id]` in the filesystem.

```text
src/views/agents/[id]/agent_view.erl            -> /agents/:id
src/views/agents/[id]/logs/[day]/log_view.erl   -> /agents/:id/logs/:day
```

```erlang
{"/agents/:id", agent_handler}    %% declarative
```

The handler reads the values with `weberl_request:params(Request)`:

```erlang
handle(Request) ->
    #{id := Id} = weberl_request:params(Request),     %% <<"7">> for /agents/7
    ...
```

- A parameter name is `[a-z][a-z0-9_]*` and appears once per route. A parameter is **exactly one
  non-empty segment**: `/agents/:id` matches `/agents/7`, not `/agents`, `/agents/` or `/agents/7/x`.
  There are no wildcards yet.
- Values are binaries, **percent-decoded once** after the path has been matched on its raw segments, so
  `/agents/a%2Fb` gives `<<"a/b">>` and cannot become two segments. `%` is valid in a URL only as an
  escape (`%HH`, a literal one is `%25`): a matched parameter with a bad escape (`%zz`, a lone `%`) or
  whose decoded value is not UTF-8 is answered with `400 Bad Request` without calling the handler.
  `weberl_request:path/1` stays the raw path.
- A static route wins over a parameter (`/agents/new` before `/agents/:id`), and otherwise the first
  segment where two routes differ decides, a static one before a parameter (`/a/b/:y` before
  `/a/:x/c`). Two routes of the same shape with different names (`/a/:x`, `/a/:y`) are a conflict
  (`{duplicate_routes, Origin, [{"/a/:", _}]}`, the shape written with `:` for each parameter). A
  filesystem route hides a declarative one of the same shape, as for static paths.
- Links to such routes are checked like any other (see [Links](#links)).

Discovery reads source files with `io:scan_erl_form/3` and
`erl_parse:parse_form/1`: up to `-module`, then the remaining attributes up to the
first function (to find `-weberl_page`, below). Nothing is compiled or executed.
Preprocessor directives (`-define`, `-include`) before `-module` are not
supported. Symbolic links are not followed. A missing root is an error; an empty
root yields no routes.

### Page kind

A page is `normal` (no reactivity, the default), `one_way` (server push) or
`two_way` (bidirectional). A view declares it with an attribute after `-module`:

```erlang
-module(feed_view).
-weberl_page(one_way).
```

The attribute must be a single literal atom; two of them, or any other value, are a
startup error (`{invalid_page_attribute, File, Value}`, `{duplicate_page_attribute,
File}`). The kind is stored on the route (`weberl_route:live/1`, reachable from
`weberl:lookup/2`). Live routes are served as described in [Live pages](#live-pages).

A view sets any other route option (the map a declarative route takes as its third
element, see [Declarative routing](#declarative-routing)) with `-weberl_route(Opts).`:

```erlang
-module(ticker_view).
-weberl_route(#{live => one_way, session => false}).
```

`-weberl_page(Kind)` is the shorthand for `#{live => Kind}` and may be combined with
`-weberl_route` as long as the map has no `live` key. Like `-weberl_page`, the attribute
must be a literal term, appear once, and come before the first function. Errors are
startup errors: `{invalid_route_attribute, File, Reason}` (not a map, or the options are
rejected), `{duplicate_route_attribute, File}`, `{conflicting_page_attributes, File}`.

## Declarative routing

```erlang
-module(my_app_router).
-export([routes/0]).

routes() ->
    [
        {"/health", health_handler},
        {"/api/users", generic_api_handler},
        {"/api/posts", generic_api_handler},
        {"/feed", feed_handler, #{live => one_way}}
    ].
```

An entry is `{Path, Handler}` or `{Path, Handler, Opts}`. `Opts` is a map with the keys
`live` (`normal | one_way | two_way`, see [Page kind](#page-kind)) and `session`
(`false` makes a live page [session-less](#topics-and-session-less-pages); only valid
with a live page); unknown keys or values are rejected
(`{invalid_route, Module, Entry, {invalid_options, _}}`). Filesystem views set the same
options with a [module attribute](#page-kind).

Declarative routing needs no filesystem roots. Several router modules may be
listed and a handler may serve several paths. Router modules must be loadable
when the router starts. Declarative handlers use the same `handle/1` contract as
views (they just have no associated template).

## Conflicts, precedence and ordering

1. Paths are normalized first: repeated slashes collapsed, trailing slash
   removed (`/a//b/` is `/a/b`).
2. All filesystem roots share one priority; all declarative modules share a
   lower one.
3. Within a level, two routes with the same normalized path are an error:
   `{duplicate_routes, filesystem | declarative, [{Path, [{Handler, Source}]}]}`.
4. Two filesystem views declaring the same module are an error:
   `{duplicate_modules, [{Module, [{Path, File}]}]}`. Checked before paths.
5. A declarative route whose path equals a filesystem route is dropped from the
   table and available from `weberl:shadowed/1`. Other declarative routes stay.
6. `weberl:routes/1` is sorted by path (string order), independent of root and
   module order. Filesystem discovery itself is depth-first with entries sorted
   by name.

The table can also be built and queried without any server:

```erlang
{ok, Table} = weberl:build(#router{...}),
{ok, Route} = weberl:lookup("/blog/posts", Table),
{ok, posts_view} = weberl:handler("/blog/posts", Table),
{error, not_found} = weberl:handler("/blog/posts/1", Table).
```

Lookup is exact static match after normalization (a map access, no file system
access). Routes are native `route` records; use the accessors in `weberl_route`
(`path/1`, `handler/1`, `origin/1`, `source/1`).

## Handlers

A handler is any module exporting `handle/1`. It receives a `weberl_request` and
must return a `weberl_response`:

```erlang
-module(home_view).
-behaviour(weberl_handler).
-export([handle/1]).

handle(Request) ->
    weberl_response:html(200, <<"Hello from Weberl">>).
```

Views and declarative handlers are called the same way, in the process of the
transport connection. There is no per-route process.

### Request (`weberl_request`)

| Function | Returns |
|---|---|
| `method/1` | upper-case binary, e.g. `<<"GET">>` |
| `path/1` | requested path as a string (raw: not percent-decoded or normalized) |
| `headers/1`, `header/2` | `[{LowercaseName, Value}]` binaries; `header/2` is case-insensitive, `{ok, V} \| error` |
| `query/1`, `query_params/1` | raw query binary; parsed `{ok, [{Name, Value \| true}]} \| {error, invalid_query}` |
| `params/1` | route parameters (`#{id => <<"7">>}` for `/agents/:id`, percent-decoded), `#{}` for static routes |
| `peer/1` | `{Address, Port}` or `undefined` |
| `meta/1` | transport metadata map (Roadrunner: `adapter`, `listener`, `scheme`, `version`, `request_id`) |
| `read_body/1` | `{ok, binary()} \| {error, Reason}` |
| `cookies/1`, `cookie/2` | `[{Name, Value}]` in wire order, values raw (not decoded); `cookie(Request, Name)` is `{ok, V} \| error` |
| `form/1,2` | the text fields of a form body as `{ok, [{Name, Value \| true}]}` (decoded, repeats kept), for `application/x-www-form-urlencoded` and `multipart/form-data`; `{error, unsupported_content_type \| no_content_type \| {limit_exceeded, Limit} \| malformed_multipart \| _}` |
| `multipart/1,2`, `files/1,2` | the parts and the files of a `multipart/form-data` body, see [Forms and uploads](#forms-and-uploads) |
| `safe_filename/1` | a file name that is safe to store, from a client's |

`cookies/1`, `form/1` and `multipart/1` are parsed by the adapter (callbacks of the `weberl_adapter`
behaviour), so the transport's limits apply (`max_content_length`). A request not built by an adapter (a hand-made
one in a test) raises `{no_adapter, cookies | form | multipart}`: give it `meta => #{adapter => Module}`.

The body is read only when `read_body/1` is called. With the Roadrunner adapter it
is already in memory (see [limitations](#known-limitations-and-future-work)).

### Response (`weberl_response`)

```erlang
weberl_response:html(200, Body)        % text/html; charset=utf-8
weberl_response:text(200, Body)        % text/plain; charset=utf-8
weberl_response:binary(200, Body)      % application/octet-stream
weberl_response:new(204, [{"cache-control", "no-store"}], <<>>)
weberl_response:with_header(Response, "x-custom", "yes")   % replaces, case-insensitive
weberl_response:header(Response, "x-custom")               % {ok, Value} | error
```

Bodies are `iodata()`, status is 100..599, header names are stored lower-case.
Invalid arguments raise `badarg`.

Convention: **functions take their subject first** (the request or the response), in
`weberl_request` and `weberl_response` alike: `weberl_request:header(Request, Name)`,
`weberl_response:with_header(Response, Name, Value)`.

#### Repeated headers, cookies and redirects

```erlang
weberl_response:add_header(Response, "x-a", "1")   % appends; with_header/3 replaces all of that name
weberl_response:header_values(Response, "set-cookie")      % every value, in order

R = weberl_response:redirect("/home"),             % 303 See Other (after a form POST)
weberl_response:redirect(301, "/new"),             % 301 | 302 | 303 | 307 | 308
weberl_response:set_cookie(R, "sid", Sid, #{max_age => 3600, secure => true}),
weberl_response:delete_cookie(R, "sid")            % empty value, Max-Age=0 (same path/domain as set)
```

`set_cookie/3,4` adds a `set-cookie` header per call (several cookies on one response work), with
`Path=/; HttpOnly; SameSite=Lax` unless the options say otherwise (`path`, `domain`, `max_age`,
`http_only`, `secure`, `same_site`). `secure` is off by default because Weberl cannot know the site is
served over HTTPS: set it in production. Names, values and attributes are checked against RFC 6265 and an
unsafe one raises (`{invalid_cookie_name | invalid_cookie_value | invalid_cookie_attribute |
invalid_cookie_option, _}`), so a `;` or a line break from user input cannot add attributes or headers;
encode other values yourself (base64url, percent-encoding). `same_site => none` requires `secure => true`.
Header names and values with control characters raise `badarg` everywhere (`new/3`, `with_header/3`,
`add_header/3`, `redirect/2`).

`redirect` points wherever you say. When the target comes from the client (`?next=/settings`), check it
with `weberl_url:local/1` first (true only for a path on this site: one leading `/`, not `//` or `/\`, no
control characters) and fall back to a fixed page.

### CSRF protection

Every route is protected against cross-site request forgery by default. For the unsafe methods
(`POST`, `PUT`, `PATCH`, `DELETE`; `GET`, `HEAD` and `OPTIONS` are never checked, so a handler must not
change state on them) dispatch checks, before the handler runs, the **Origin** and a **token**; a failure
is a logged `403 Forbidden`. A route chooses its mode with a route option (`{Path, Handler, #{csrf =>
Mode}}` or `-weberl_route(#{csrf => Mode}).`):

| `csrf` | Checks |
|---|---|
| `true` (default) | Origin and token |
| `origin` | Origin only: JSON APIs, webhooks, clients that cannot carry a token |
| `false` | nothing; say so on purpose |

*Origin*: a request with an `Origin` header must come from this site (its authority equals `Host`, and on
an HTTPS listener it is HTTPS too) or be listed in the `csrf_origins` env (`[<<"https://app.example">>]`,
for a proxy that rewrites `Host`). `Origin: null` is refused; no `Origin` passes (the token covers it).

*Token* (signed double submit): a cookie holds a random nonce and its HMAC (key: `live_secret`), and the
request must send the same value in the `x-csrf-token` header, in the `_csrf` query parameter (the token of
a [multipart form](#forms-and-uploads), so a forged upload is refused before its body is parsed), or in the
`_csrf` field of an urlencoded form, looked at in that order. A multipart body is never parsed to look for
the token. The page that shows the form gets its token, and the cookie, from `weberl_csrf:protect/2`:

```erlang
handle(Request) ->
    weberl_csrf:protect(Request, fun(Token) ->
        Html = weberl_template:render(?MODULE, #{form => weberl_form:open(Token, "/login")}),
        weberl_response:html(200, Html)
    end).
```

`protect/2` sets the cookie only when the browser has none, and adds `cache-control: private, no-store`
(the page carries a per-browser token) and `referrer-policy: same-origin` (the token of a multipart form is
in a URL) unless the handler set them. In the template, `{{{ @form }}}`
inserts the helper's HTML. `weberl_form:open(Token, Action[, Opts])` returns `<form method="post"
action="...">` plus the hidden `_csrf` input; `#{csrf => false}` leaves the input out (and needs no
token), `method => get` never carries one, `enctype` and `attrs` add attributes (escaped; a value may be an integer), and an
`Action` that is not a path on this site or an `http(s)` URL raises. `weberl_form:csrf_input/1` is just
the input. Scripts read the token from the form field or from the page and send `x-csrf-token`.

**In a template, `{: form :}` does all of this.** It opens and closes the form, writes the `_csrf` field and
takes the token of the request being served, so a view needs no `protect/2` and no `{{{ @form }}}`:

```html
{: form weberl_url:router_path("/login") :}
  <input name="user"> <button>Log in</button>
{: /form :}

{: form weberl_url:router_path("/search"), #{method => get} :} ... {: /form :}
{: form weberl_url:router_path("/avatar"), #{enctype => multipart, attrs => [{"class", "up"}]} :} ... {: /form :}
```

- The head is `Action` or `Action, Options`. The action is a [`weberl_url`](#links) value, checked like a link
  (`router_path` is verified when the router starts; a bare string is `untagged_url`). The options are the map of
  `weberl_form:open/3`: `method`, `enctype`, `attrs`, `csrf`; anything else is `{bad_form_options, ...}`.
- The token is the running handler's (the request is ambient while it renders, as for the session functions).
  After the handler returns, dispatch sets the cookie when the browser has none and adds `cache-control:
  private, no-store` and `referrer-policy: same-origin` unless the response has them; a page without a form gets
  none of that. Several forms (a layout's log-out form and the page's own) share one token. `protect/2` still
  works and shares it with the block.
- A form stands in HTML text and its content has to end in text (`{form_in_unsupported_context, Where}`,
  `form_unbalanced_markup`); forms do not nest (`form_in_form`); the close tag has to match
  (`{unclosed_block, form}`, `{unexpected_block_end, form}`, `{mismatched_block_end, ...}`).
- **In a region.** A region that the server re-renders for other pages (`update/3`, `update_topic/4,5`) has no
  request, and one rendering goes to many browsers. A form there is written with an empty field marked
  `data-weberl-csrf`, and the beacon fills it, after every patch, with the page's token (it is the
  `data-weberl-csrf` attribute of the beacon's `<script>`, present when the page rendered a form). The
  first full render of the page, which has the request, writes the real token. A multipart form cannot be filled
  later (its token is in the action), so in a region without a request it raises `{csrf_token_unavailable, View, Line}`,
  like any form rendered outside a request (a unit test: render inside `weberl_session:run/2` with a request).

Set `{secure_cookies, true}` in production (HTTPS): the cookie is then `Secure` and named
`__Host-weberl_csrf`, which browsers refuse to let a sibling subdomain overwrite. Without it a cookie
planted by a sibling subdomain is still rejected because it lacks our MAC, but the attacker can pair
their own valid cookie and field.

Not covered: forms are one helper for now (see "Forms" in `ROADMAP.md`); the live endpoints under
`/_weberl/` have their own page tokens and Origin check (see [Credentials](#credentials)).

### Forms and uploads

A form with a file input needs `enctype="multipart/form-data"` (without it a browser sends the file's *name*,
not its content). `weberl_form:open(Token, Action, #{enctype => multipart})` writes it, and puts the CSRF token
in the **query string of the action** (`/up?_csrf=...`, or `&_csrf=` after an existing query) instead of a
hidden field: a browser sends the URL before the body, so a forged upload is refused (`403`) before its body is
parsed. The trade-off is that the token can appear in server logs and, without the header
`protect/2` adds (`referrer-policy: same-origin`), in a `Referer`; it is used for multipart forms only, and
`ROADMAP.md` notes the alternatives (a separate upload token, or body-only tokens with other guard rails).

```erlang
handle(Request) ->
    case weberl_request:files(Request) of
        {ok, [#{filename := Name, content_type := Type, body := Bytes, size := Size} | _]} ->
            Safe = weberl_request:safe_filename(Name),     %% never build a path from the raw name
            ok = file:write_file(filename:join("uploads", Safe), Bytes),
            weberl_response:redirect("/done");
        {ok, []} ->
            weberl_response:text(400, <<"choose a file">>);
        {error, Reason} ->
            weberl_response:form_error(Reason)             %% 413 limit, 415 not multipart, 400 malformed
    end.
```

- `multipart(Request)` is every part, in order: `#{name, filename, content_type, headers, body}`
  (`filename` is `undefined` for a text field). `form(Request)` gives the parts without a file name as
  `{Name, Value}`, so `_csrf` and ordinary fields work as for an urlencoded form. `files(Request)` gives
  `#{name, filename, content_type, body, size}` for the parts with a file name, **leaving out a file input
  that was left empty** (browsers send it as an empty part). A request that is not multipart is
  `{error, unsupported_content_type}` for `multipart/1` and `files/1`, so a form that forgot its `enctype`
  is an error and not silently "no files".
- Everything a part says is the client's: `name`, `filename` and `content_type` are not checked against the
  content. `safe_filename/1` returns the base name without path parts, control characters or leading dots
  (nothing left is `<<"file">>`); choose the directory and make the name unique yourself. Text fields
  must be UTF-8 (`malformed_multipart` otherwise), file bodies are raw bytes. In a `Content-Disposition`
  `%22`, `%0D` and `%0A` are undone as browsers write them, and so are `\"` and `\\` as curl writes them.
- The whole body is in memory (Roadrunner buffers it, up to the route's cap): large uploads need a
  streaming transport, which is not available yet.

**Limits** keep a form from exhausting memory. Six independent keys, with these defaults:

| Limit | Default | Meaning |
|---|---|---|
| `max_fields` | 100 | text fields (urlencoded pairs, or multipart parts without a file name) |
| `max_field_bytes` | 1 MiB | one text value |
| `max_files` | 10 | file parts |
| `max_file_bytes` | 5 MiB | one file |
| `max_filename_bytes` | 255 | the client's file name |
| `max_body_bytes` | the listener's `max_content_length` (Roadrunner: 10 MiB) | the whole body: files, fields and multipart framing |

They are layered, the most specific winning, each key on its own: **per call**
(`weberl_request:files(Request, #{max_file_bytes => 20_000_000})`), **route** (`{"/up", Handler, #{limits =>
#{...}}}` or `-weberl_route(#{limits => #{max_file_bytes => 52428800}}).`, literal integers in the attribute),
**router** (`#router{limits = #{...}}`), **global** (`application:set_env(weberl, form_limits, #{...})`) and the
defaults above. `max_body_bytes` is enforced by the transport (Roadrunner's per-route `max_content_length`)
before the body is read, so it is configuration only, not a per-call limit: an over-long declared body is
answered `413` at once, a route can set it **higher** than the listener's (an upload route at 100 MiB while
everything else stays at 10 MiB) or lower, and the router's value goes on every route that does not set its
own. To allow bigger uploads on one route, set `max_body_bytes` and `max_file_bytes` on it together; a router
start logs `form_limits_inconsistent` for a route whose body limit is under its file limit (such a file could
never arrive).

An exceeded limit is `{error, {limit_exceeded, Limit}}` and a warning in the log
(`form_limit_exceeded`: the limit, what is allowed, what was seen, the path and the handler; never the
content). `weberl_response:form_error(Reason)` turns the errors of these functions into responses: `413` for a
limit, `415` for `unsupported_content_type` and `no_content_type`, `400` for anything else; when Weberl reads a
urlencoded form itself (the CSRF token) and it is over a limit, it answers `413` on its own. A body refused by
Roadrunner for its size never reaches Weberl, and Roadrunner reports it only as an event that its default handler
drops: set `{roadrunner, [{event_handler, weberl_roadrunner_events}]}` to have it logged (`request_body_too_large`,
with the listener and the client's address).

### Session

Weberl does not own logins; it gives the application a safe place for what it needs between requests
(a user id, a "remember me" marker, a cart). The session is a map in one **encrypted and authenticated**
cookie (`weberl_session`, `HttpOnly`, `SameSite=Lax`, `Path=/`): the client can neither read nor change
it. What goes in, and what it means, is yours.

```erlang
handle(Request) ->
    UserId = maps:get(user_id, weberl_request:session(Request), undefined),   % or session_get/2
    ...

login(Request, UserId) ->
    R0 = weberl_response:redirect("/home"),
    R1 = weberl_response:reset_session(R0),                 % nothing of an earlier session carries over
    R2 = weberl_response:put_session(R1, user_id, UserId),
    weberl_response:session_ttl(R2, 30 * 86400).            % "remember me"; omit for the default

logout(_Request) ->
    weberl_response:reset_session(weberl_response:redirect("/")).    % deletes the cookie
```

| Function | |
|---|---|
| `weberl_request:session/1`, `session_get/2` | the session the browser sent: a map (`#{}` when missing, tampered with or expired); `{ok, V} \| error` |
| `weberl_response:put_session/3`, `delete_session/2` | change one key |
| `weberl_response:set_session/2`, `reset_session/1` | replace the whole session / empty it (the cookie is deleted); both start a new lifetime. `reset_session` keeps the flash this response already `put` (a login: reset + "Account created", in either order) but drops the one the request delivered (`weberl_flash:keep/2` restores it) |
| `weberl_response:session_ttl/2` | seconds from now, or `infinity` (no server-side expiry; the cookie lasts 400 days, a browser's maximum) |
| `weberl_response:session/1`, `session_get/2` | what this response will send: after `put_session(R, K, V)`, `session_get(R, K)` is `{ok, V}` and every other key is still there |
| `weberl_response:load_session/2` | start from a request's session explicitly |

The first change starts from the request's session, which dispatch makes available to the handler (in the
connection process), so `put_session/3` just works. A handler that builds its response in another
process must call `load_session(Response, Request)` first (otherwise `{session_not_loaded, Op}`). A response
that never touches the session sends no session cookie; an unchanged request session is not rewritten.

Lifetime is absolute: a new session lives `session_ttl` seconds (default two days), a changed one keeps its
expiry (using a session does not extend it), and `set_session/2`, `reset_session/1` and `session_ttl/2`
start a new lifetime. Terms are stored with `term_to_binary` (compressed), so atoms, tuples and maps work;
funs, pids and references do not belong in a session. Size: about 4 KB per cookie. `session_warn_bytes`
(3000) logs a warning; `session_max_bytes` (3800, never more than 4096) is a hard limit: a response over it
is a logged `500` rather than a login silently lost.

Limits to know: there is no server-side record, so a session **cannot be revoked**, and a stolen cookie
works until it expires (an application that needs revocation keeps an id or version in the session and
checks it against its own storage). The key comes from `live_secret`: without it a restart ends every
session (a warning is logged the first time a session is written), and rotating it does the same.

### Flash

Short messages for the next page, the post/redirect/get companion. A flash is a map `#{Key => Value}`
(any terms) kept in the [session](#session) under a reserved key, with its own expiry (`flash_ttl`, default
300 seconds, however long the session lives). Using flash creates a session cookie if there is none.

```erlang
%% after a POST: say it, then redirect
weberl_flash:put(weberl_response:redirect("/login"), error, <<"Wrong password">>)

%% the page that shows it: read it and clear it
{Flash, Response} = weberl_flash:take(Request, weberl_response:html(200, Html))
```

| Function | |
|---|---|
| `weberl_flash:put(Response, Key, Value)` | add to the flash this response sends (an unread flash is kept, the same key replaced) |
| `weberl_flash:get(Request)`, `get(Request, Key)` | what the request carried (`#{}` when none or expired); **does not clear** |
| `weberl_flash:take(Request, Response)` | `{Flash, Response}`: the request's flash, and the response with it removed |
| `weberl_flash:keep(Request, Response)` | put the request's flash into the response: for a handler that called `take` (or `reset_session`) and wants it to reach the next page after all |

Reading does not clear, so a handler that never calls `take` leaves the flash where it is: a redirect that
does not touch flash passes it on (it sends no cookie at all), and in a chain A → B → C the flash shows
at C when only C takes it. Only what the request delivered is removed: a flash the same response `put`
for the next page survives `take`, in either order. A page that only calls `get` shows the flash again
until something takes it. Put flash on pages that display it with `take`; `keep` gives the messages a fresh
`flash_ttl`.

### Dispatch and errors

`weberl_dispatch:dispatch(Request, Table)` returns a response and never raises:

- no matching route: `404` `Not Found` (text/plain);
- an unsafe method failing the route's [CSRF check](#csrf-protection): `403` `Forbidden`;
- the handler raises, throws, exits, or returns anything but a `weberl_response`:
  `500` `Internal Server Error`. The client sees no details; the cause is logged
  at error level with handler, method, path, class, reason and stacktrace.

Per-module settings (the page kind, the [CSRF](#csrf-protection) mode, the [layout](#layouts)) are
route options: `-weberl_route(Opts).` in a filesystem view, the third element of a declarative route.
`weberl_handler:check/1` (used at startup) rejects modules without `handle/1`.

## Templates

A view may have a template with the same base name in the same directory:

```text
src/views/
├── home_view.erl
├── home_view.weberl
└── about/
    ├── company_information_view.erl
    └── company_information_view.weberl
```

Templates never create routes; the URL still comes from the directory. Views
without templates are fine. A `.weberl` file with no `*.erl` of the same name
beside it is an error at router start (`{unassociated_templates, Files}`).

### Syntax

| | |
|---|---|
| literal HTML and text | copied as is |
| `{{ @name }}` | the assign `name`, HTML-escaped |
| `{{ Expr }}` | any Erlang expression, HTML-escaped: `{{ @n + 1 }}`, `{{ string:uppercase(@name) }}` |
| `{{{ Expr }}}` | the same, **not** escaped. Unsafe for untrusted input |
| `\{{` | literal `{{` |
| `{: if Expr :}` ... `{: elif Expr :}` ... `{: else :}` ... `{: /if :}` | a [conditional](#conditionals-case-and-loops) |
| `{: case Expr :}` `{: of Pattern :}` ... `{: /case :}` | match a value, binding variables |
| `{: for Qualifiers :}` ... `{: empty :}` ... `{: /for :}` | a loop (an Erlang comprehension) |
| `{: region name :}` ... `{: /region name :}` | a [region](#regions) |
| `{: region name tag=tbody :}` | a region wrapped in that element |
| `{: content :}` | in a [layout](#layouts): where the view's template goes |
| `{: slot name :}` ... `{: /slot name :}` | in a layout: a [slot](#slots) a view can fill; the body is the default |
| `{: fill name :}` ... `{: /fill name :}` | in a view: replaces the layout's slot of that name |
| `\{:` | literal `{:` |

`{{ }}` is for values only; statements use `{: :}`. What is inside is an **Erlang expression**, and
the only way to read an assign is `@name` (`[a-z][a-zA-Z0-9_]*`, looked up as an atom key in the
assigns map; a missing one is `{missing_variable, View, Name}`). There is **no shorthand**: a bare
`{{ name }}` is the atom `name` and renders as the text `name`. Capitalized names are local variables,
bound by the [blocks](#conditionals-case-and-loops) (a local that nothing binds is a compile error,
`{unbound_variable, Name}`). An `@` inside a string, a quoted atom, a character literal or a comment is
just text. Expressions are developer code, evaluated on every render (and every region re-render): keep
them pure and cheap. User input is rendered, never evaluated. There are no includes, components or
filters in this version.

The tag ends at the first `}}` (`}}}` for the raw form) outside the Erlang inside: strings, quoted atoms,
character literals and comments are skipped and brackets are counted, so
`{{ maps:get(k, #{k => #{j => 1}}) }}` and `{{ f("}}") }}` work as written. Expressions may span lines; a
syntax error reports the template line of the offending token (`{invalid_expression, Text,
Message}`), `{{ 1, 2 }}` is `{not_a_single_expression, Text}`.

Supported values (what an expression may evaluate to): UTF-8 binaries, character lists, integers,
floats and atoms (rendered as their name, so `true`, `false` and `undefined` render as such). Escaping
covers `& < > " '`.

Interpolation is allowed in **HTML text** and in **quoted attribute values**
(escaped only). Escaping alone is not enough in JavaScript, CSS or URLs, so these
are rejected when the template is compiled: inside `<script>` / `<style>`, HTML
comments, tags, attribute names, unquoted attribute values, raw `{{{ }}}` inside
an attribute, and the code and style attributes (`style`, `on*`, `srcdoc`, `srcset`,
`data` and a few similar ones). Literal values in those places are of course fine.
The URL attributes (`href`, `src`, `action`, `formaction`, `poster`, `cite`,
`xlink:href`) take interpolation too, but only a value made by `weberl_url`: see
[Links](#links).

### Data for scripts: `{: json :}`

To hand a value to JavaScript, use `{: json Expr :}` instead of building a string: it takes an Erlang
expression like `{{ }}` and writes it as JSON (`json:encode/1`: maps, lists, binaries, numbers, `true`,
`false`, `null`; other atoms as strings). It stands in two places only:

```html
<script type="application/json" id="state">{: json @state :}</script>
<script>const state = JSON.parse(document.getElementById("state").textContent);</script>

<div data-state="{: json #{user => @user, count => length(@items)} :}"></div>
```

- **A data script**: `<script type="application/json">`, `application/ld+json`, `importmap`,
  `speculationrules` or any `application/*+json` (quote the `type`; the first `type` wins). `<`, `>`, `&` and
  U+2028/9 are written as `\uXXXX`, so no value can close the script, open a comment or end a line; it still
  parses to exactly what was given. Not in `<script>` that runs code: JavaScript has contexts (strings,
  comments) a template cannot see, so there `{: json :}` is `{json_not_allowed_here, <<"script">>}`.
  `{{ }}` stays refused in every script.
- **A quoted attribute value** that takes plain text: the JSON is HTML-escaped (`JSON.parse(el.dataset.state)`).
  Not in URL attributes, `style`, `on*`, ...: `{json_not_allowed_here, Attr}`; not in text.
- The `type` of a `<script>` is read as literal text: `{{ }}` in it is
  `{interpolation_in_restricted_attribute, <<"type">>}` and a block `{block_in_restricted_attribute, <<"type">>}`, because it decides what the content is.
- A value JSON cannot hold (a pid, a tuple) raises `{template_error, {unsupported_value, View, Source, Value}}`
  when the page renders.
- Live pages: `{: json :}` inside a region is re-rendered with it, like any interpolation.

### Links

HTML escaping makes a value safe in an attribute, not in a URL: `javascript:alert(1)` survives it, and an
id with a `/` or a `?` changes what the link means. So in a URL attribute an interpolation has to be a
**tagged value** from `weberl_url`; anything else is an error (at compile time when the compiler can see
it, otherwise when the page renders).

```html
<a href="/agents/{{ weberl_url:component(@id) }}">agent</a>        <!-- one encoded path segment -->
<a href="/login?next={{ weberl_url:component(@next) }}">log in</a>  <!-- an encoded query value -->
<form action="/search?{{ weberl_url:query(#{q => @q, page => 2}) }}">  <!-- k=v&k=v, encoded -->
<a href="{{ weberl_url:ensure_path(@next) }}">back</a>              <!-- a path on this site, or an error -->
<a href="{{ weberl_url:url(@website) }}">site</a>                   <!-- a path or an http(s) URL -->
<a href="{{ weberl_url:router_path("/agents") }}">agents</a>        <!-- a route of this router -->
<a href="{{ weberl_url:unsafe_url(@link) }}">anything</a>           <!-- no checks (still HTML-escaped) -->
```

| Helper | Makes | Where |
|---|---|---|
| `component(V)` | `V` percent-encoded (`a b/c` is `a%20b%2Fc`; integers and atoms work) | after literal text |
| `query(Map or Pairs)` | `k=v&k=v`, each encoded | after literal text |
| `ensure_path(V)` | `V` if it is a path on this site (starts with one `/`, not `//` or `/\`, no control characters), else raises `{not_a_path, V}` | a whole value |
| `url(V)` | `V` if it is such a path or an `http(s)` URL with a host, else raises `{not_a_url, V}` | a whole value |
| `router_path(Path[, Opts])` | the path, if it is a route of the router, else `{unknown_route, Path}` | a whole value |
| `router_url(Path[, Opts])` | the same, in front of the `public_url` setting | a whole value |
| `unsafe_url(V)` | `V` unchecked, **escaped for HTML**; for links your code builds and vouches for | anywhere |

A *whole value* helper has to begin the attribute (`href="{{ ... }}"`, text after it is fine), a *part*
helper has to follow literal text (or another interpolation). A misplaced one is a compile error
(`{misplaced_url_helper, Helper}`). The elements that run code or change what every link means
(`<script src>`, `<iframe src>`, `<embed src>`, `<frame src>`, `<link href>`, `<base href>`, `<use href>`)
take local paths only: `ensure_path`, `router_path`, `unsafe_url`, or a part after a local prefix
(`src="/static/{{ weberl_url:component(@v) }}.js"`); anything else is
`{url_not_allowed_here, Helper, Tag, Attr}`. A literal argument is checked when the template compiles
(`ensure_path("https://x.com")` does not compile). The helpers are ordinary functions: they can be used in
handlers too, for example for a redirect target.

**Links to your own routes** are checked when the router starts. `router_path("/agents")` has to name a
route; a typo fails the start with the file and line (`{unknown_route, <<"/agnts">>}`) instead of
producing a dead link. The path has to be written out: `router_path(@target)` is a compile error
(`{unverifiable_route, router_path}`), use `ensure_path` for an unverified path. For a route with a dynamic
part, put `{{ }}` placeholders in the string:

```html
<a href="{{ weberl_url:router_path("/agents/{{ @id }}") }}">agent</a>   <!-- route /agents/:id -->
<a href="{{ weberl_url:router_path("/docs/{{ @page }}") }}">docs</a>    <!-- static /docs/intro, /docs/api -->
<a href="{{ weberl_url:router_path("/agents/7") }}">agent 7</a>         <!-- a literal id matches /agents/:id -->
```

Each placeholder is **exactly one path segment**: its value is percent-encoded (a value with a `/` cannot
turn into two segments), must not be empty, and the built path has to be a route. At compile time the
link is matched against the routes by segments (`{unknown_route, Pattern}` when none has its shape): a
literal segment matches the same static segment or a [route parameter](#route-parameters), a placeholder
matches a parameter or a static segment whose text fits. Where a placeholder stands at a **parameter** of the
route (`/agents/{{ @id }}` against `/agents/:id`) any value is a route, so there is nothing to warn about.
Where it stands at a **static** segment (`/docs/{{ @page }}` against `/docs/intro`) only some values are
routes, which gives a warning (`{dynamic_route_segment, Pattern}`, logged with file and line when the
router starts); `router_path("/docs/{{ @page }}", #{no_warn => true})` silences it. A route with several
dynamic segments needs one placeholder each. The options map takes `no_warn`, `query` (a map or
pairs, appended after `?`) and `router` (the name of another running router to check against). The route
patterns a link can match are compiled into the template, so rendering needs no router and works from any
process (a request, a live page, an agent's task).

`weberl_template:compile_source/5` and `compile_file/4` take `#{routes => Table}` for this; without it
(unit tests of a single template) the route check at compile time is skipped, `weberl_template:warnings/1`
returns what the compiler warned about, and the router named by `weberl_url:with_router/2` (or the
`router` option) answers at render time.

### Conditionals, case and loops

Blocks take Erlang: conditions, patterns and generators are Erlang expressions, with assigns written
`@name` and the variables they bind written as Erlang variables (`Name`).

```html
<nav>
{: if @user =/= undefined andalso @role =:= admin :}
  <a href="/admin">Admin</a>
{: elif @user =/= undefined :}
  <a href="/account">Account</a>
{: else :}
  <a href="/login">Log in</a>
{: /if :}
</nav>

{: case @flash :}
{: of undefined :}
{: of {error, Msg} :}<p class="flash error">{{ Msg }}</p>
{: of {info, Msg} when is_binary(Msg) :}<p class="flash">{{ Msg }}</p>
{: /case :}

<ul>
{: for #{name := Name, active := true} <- @agents :}
  <li>{{ Name }}</li>
{: empty :}
  <li>No agents yet</li>
{: /for :}
</ul>
```

- **`if`**: `{: if Expr :}`, any number of `{: elif Expr :}`, an optional `{: else :}`, closed by
  `{: /if :}`. A condition must be exactly `true` or `false`; anything else raises
  `{not_boolean, View, Line, Value}` (no truthiness: an optional value is passed as `undefined` and tested
  with `@error =/= undefined`, or matched with `case`). Only the taken branch is evaluated.
- **`case`**: `{: case Expr :}` and one or more `{: of Pattern [when Guard] :}` branches. Between `case` and
  the first `of` only white space is allowed (`content_before_first_of`). A value no branch matches raises
  `{case_clause, View, Line, Value}`; end with `{: of _ :}` to opt out. A guard cannot call a function, so
  the assigns the guards read (`when N > @limit`) are fetched once before the `case`: a missing one is an
  error even if an earlier branch would have matched.
- **`for`**: what Erlang allows after `||` in a comprehension: generators (`X <- List`, `K := V <- Map`,
  `<<C>> <= Binary`), filters (`X > @min`) and several of them. A generator pattern that does not match
  skips that element (Erlang's rule, so `#{active := true} <- @agents` filters). `{: empty :}` renders when
  nothing came out (after filtering). Order of a map's iteration is Erlang's.
- **Scope**: names bound by a pattern or generator exist only in their branch or body. Binding a name that is
  already bound is an error (`{rebound_variable, Name}`); siblings may reuse a name; using an unbound one is
  `{unbound_variable, Name}`. Capitalized names in `{{ Name }}` read these variables.
- **Where they may stand**: in HTML text, **between the attributes of a start tag**, and **inside the quoted
  value of an attribute that takes plain text** (not in `<script>`, `<style>`, a comment, a tag or attribute
  name or an unquoted value: `{block_in_unsupported_context, Kind, Where}`; not in the value of a URL
  attribute or of `style`, `on*`, `srcset`... : `{block_in_restricted_attribute, Attr}`). Every branch and body is
  read from the place where the block stands and has to end there, so a tag or a quote cannot stay open
  across a branch (`{block_unbalanced_markup, Kind}`). Elements themselves are not matched across branches, as
  in a region: keep them balanced. Blocks nest; in text they may contain regions (not in a tag or a value).
- **Attributes**: see [below](#conditional-attributes).
- **Regions and blocks**: a region may stand in a branch, and may contain blocks; its variables are the
  assigns they read. `render_region/3` renders only the region's content, not the surrounding condition, so
  **a conditional is only live inside a region**: wrap it (`{: region nav :}{: if ... :}...{: /region nav :}`)
  and a change of `user` re-renders the whole `nav`; an `if` outside any region is rendered once. A region
  cannot use a variable bound outside it (it renders alone: `{region_uses_outer_variable, Region, Name}`) and
  cannot stand in the body of a `for` (`{region_in_for, Region}`; the `empty` branch is fine).
- **Layouts**: `{: content :}` and `{: slot :}` may stand inside `if` and `case` branches of a layout (still one
  `content`), not inside a `for` (`content_in_for`, `{slot_in_for, Name}`); `{: fill :}` stays at the top level
  of a view. A view put inside a layout branch that binds a name the view binds too is an error after
  composition.
- Output is literal: block tags leave their line breaks behind, nothing is trimmed. Keywords need white space
  after them (`{: if @a :}`, not `{: if(@a) :}`); a tag ends at the first `:}` outside the Erlang inside; closing tags carry no name.
- Block structure errors: `{unclosed_block, Kind}`, `{unexpected_block_end, Kind}`,
  `{mismatched_block_end, Open, Got}`, `{misplaced_block_tag, Tag}` (`else`, `elif`, `of`, `empty` outside
  their block, twice, or after `else`), `case_without_of`, `{missing_expression, Kind}`.

Expressions are developer code, run on every render and region re-render: keep them pure and cheap.

#### Conditional attributes

An optional attribute no longer needs the element written twice:

```html
<input name="agent" {: if @on :}checked{: /if :}>                     <!-- between attributes -->
<a {: if @user :}href="{{ weberl_url:ensure_path(@home) }}"{: /if :}>home</a>
<button class="btn {: if @active :}active{: /if :}">go</button>       <!-- inside a value -->
<li class="{: for C <- @classes :}{{ C }} {: /for :}">
```

- **Between attributes** a branch is a list of whole attributes (an interpolation there would be an attribute
  name, so it is refused; interpolation *inside a value* of an attribute in the branch is fine). Weberl adds the
  separating white space itself: the body of a branch that is taken is rendered between a leading and a
  trailing space (HTML ignores more than one), so `checked{: /if :}name="x"` needs none written. A branch may
  end with a complete valueless attribute (`checked`), not in the middle of an attribute (`a=`, an open quote).
  A branch that is not taken, and an `if` without `else`, render nothing, so no white space is left behind. A
  block may also follow a finished valueless attribute (`<input disabled {: if ... :}`), but not a name that is
  still being written (`<input disabled{: if ... :}` is an error).
- **Inside a quoted value** nothing is added: a space there is data (`title="Hello{: if @x :}!{: /if :}"` is
  `Hello!` or `Hello`), so write the spaces a class list needs yourself (`class="btn {: if @on :}active {: /if :}big"`).
  Interpolation follows the value rules: escaped, never raw `{{{ }}}`.
- **Refused**: the value of a URL attribute (`href`, `src`, `action`...: whether a branch is a whole URL or a
  part is not known after it) and of `style`, `on*`, `srcset` and the other restricted attributes
  (`{block_in_restricted_attribute, Attr}`); a whole conditional URL attribute is fine, as in the second line
  above. Regions, slots and `{: content :}` stay in HTML text.
- On a live page the element is part of the region that re-renders, so the attributes follow the assigns.

### Rendering

```erlang
weberl_template:render(home_view, #{title => <<"Welcome">>}) -> iodata().
weberl_template:try_render(home_view, Assigns) -> {ok, iodata()} | {error, Reason}.
```

`render/2` raises `error({template_error, Reason})` with `{missing_variable, View,
Name}`, `{unsupported_value, View, Source, Value}` (`Source` is the expression as written,
for example `<<"@title">>`), `{not_boolean, View, Line, Value}` and `{case_clause, View, Line, Value}`
(see [blocks](#conditionals-case-and-loops)), `{invalid_assigns, View, Assigns}` or `{no_template, View}`.
An expression that raises (a `for` over something that is not a list, a division by zero) propagates as
the Erlang error. Inside a handler any of these becomes a logged 500. `try_render/2` and
`try_render_region/3` (what a live page uses to re-render a region) return the failure instead, an
expression that raises as `{error, {render_failed, Class, Reason}}`, so one bad value is logged and does
not end the page's session.

### Regions

A region is a part of the page the server can re-render on its own and the browser
can swap, without re-sending the page (see [Updating a region](#updating-a-region)):

```text
<h1>{{ @title }}</h1>
{: region cart :}
  <ul>{{{ @items_html }}}</ul>
{: /region cart :}
```

renders as `<weberl-region name="cart"> <ul>...</ul> </weberl-region>`: the web
component `<weberl-region>` (defined by the beacon script, it displays its children as
if it were not there). A custom element is not valid inside tables, lists or selects (the
browser's parser moves it out), so there the block names the element to use:
`{: region rows tag=tbody :}` renders `<tbody data-weberl-region="rows">`. Void and raw-text
elements (`img`, `script`, `style`, `textarea`, ...) cannot be used.

A region starts and ends in HTML text (not inside a tag, attribute, comment, `<script>` or
`<style>`), may contain other regions, and its name (`[a-z][a-zA-Z0-9_]*`) is used once per
template. The closing tag repeats the name; a mismatch is a compile error.

```erlang
weberl_template:render_region(home_view, cart, #{items_html => Html}) -> iodata().
weberl_template:regions(home_view) -> {ok, #{cart => #{tag, line, variables}}}.
```

`render_region/3` renders only the *content* of the region (no wrapper) and only needs
the variables that region uses; `{unknown_region, View, Region}` is an error like the
others. Regions are found in the browser by name when an update arrives, so one
added to the page later by other scripts, or written by hand as
`<div data-weberl-region="cart">`, can be updated too.

### Layouts

A layout is a template with one `{: content :}` where a view's template goes, so the
`<html>`, `<head>` and navigation are written once:

```html
<!-- src/layouts/main.weberl -->
<!DOCTYPE html>
<html lang="en">
<head><title>{{ @title }}</title></head>
<body>
  <nav>...</nav>
{: content :}
</body>
</html>
```

The router lists the directories with layouts, and a view picks one in its route options,
next to its page kind; a view without `layout` stays a standalone page:

```erlang
#router{filesystem = [...], layouts = ["src/layouts"]}

-weberl_page(one_way).                       %% in the view's .erl: how it is served ...
-weberl_route(#{layout => main}).            %% ... and what it looks like: src/layouts/main.weberl
```

`weberl_route:layout(Route)` is `{ok, main}` or `none` (what the route declares);
`weberl_template:layout(View)` is `{ok, main}` or `{ok, none}` (what the view was compiled with).
Only filesystem views have templates, so a declarative route that
names a layout is an error (`layout_needs_a_filesystem_view`). `layout` is the view's **default**; to
render it with another one see "Choosing the layout per render" below.

A layout is named by its file's base name (names must be unique across the directories).
Layout files are never associated with views, so they may also sit below a filesystem root.

The layout and the view are joined when the view is compiled, so the result is one
template: the layout's variables are ordinary assigns of the view (`render/2` needs both
sets), and regions of either file are regions of the view (`render_region/3`, `regions/1`;
a name may be used once across the two files). `{: content :}` may stand inside a layout
region, but must be in HTML text (not in a tag, attribute, `<script>` or `<style>`). Each
file is checked on its own, with its own file name in the errors. Layouts are read when the
router starts, like all templates.

Errors at router start: `{invalid_layouts, [{Name, Reason}]}` with `{missing_content,
File}`, `{multiple_content, File, Lines}` or a `syntax_error` (`{content_in_unsupported_context,
Where}`); `{duplicate_layouts, [{Name, Files}]}`; and in `{invalid_templates, [{View,
Reason}]}`: `{unknown_layout, Name}`, `layout_without_template` (the route options ask for a
layout but the view has no template), `content_outside_layout` (a view or a standalone
template uses `{: content :}`) and `{duplicate_region, Name, LayoutFile, ViewFile}`.

#### Choosing the layout per render

A route lists the layouts its view may be rendered with, and the handler picks one when it renders:

```erlang
-weberl_route(#{layout => main, layouts => [admin, none]}).   %% default main; also admin, and the bare view

handle(Request) ->
    Layout = case weberl_request:header(Request, <<"x-embed">>) of {ok, _} -> none; _ -> main end,
    weberl_response:html(200, weberl_template:render(?MODULE, #{...}, #{layout => Layout})).
```

- `layout` is the default (what `render/2` uses); `layouts` adds others; `none` is the view bare, with no
  layout; `layouts => all` allows every layout of the router's `layouts` directories. The allowed set is the
  default plus the list.
- **Every allowed pair is composed and compiled when the router starts**, so the checks of a layout (a fill
  the layout has no slot for, a region name used by both files, a fill in a view allowed as `none`) fail the
  start with file and line, never a render. Cost: one module per allowed pair, not views times all layouts.
  The default pair is the view's own generated module; the others are `<view>__weberl_template__<layout>`.
- A name outside the allowed set raises `{template_error, {unknown_layout, View, Name}}` (`try_render/3`
  returns it): it is the handler's decision, a programming error, and Weberl never reads it from the request.
  `weberl_template:layout/1` is the default and `layouts/1` the allowed set.
- **Regions**: the regions of the view are in every pair; those of a layout only in the pairs that use it. So
  `render_region/4` and `regions/2` take the layout too (`#{layout => Name}`); a region the pair does not have
  is `{unknown_region, View, Region}`.
- **Live pages**: `weberl_live:mount(View, Request, ViewData, #{layout => Name})` renders with that layout and
  the session remembers it in the view data (`weberl_view_data:layout/1`, `with_layout/2`), so the page's
  regions are re-rendered with the same pair; `weberl_live:update/3` reads it from the session, and a
  record built afresh by a callback keeps it. A page without a session names it itself:
  `weberl_live:update_topic(Topic, View, Region, Assigns, #{layout => Name})`.
- Not there yet: nested layouts (a layout inside a layout).

#### Slots

`{: content :}` is where the body of the view goes. For other parts of the page (scripts and
styles in `<head>`, a sidebar) the layout declares slots, and the view fills the ones it wants:

```html
<!-- layout -->
<head>
  <title>{{ @title }}</title>
  {: slot head :}{: /slot head :}
</head>
<body>{: content :}</body>

<!-- view -->
{: fill head :}<script src="/static/clock.js" defer></script>{: /fill head :}
<h1>Clock</h1>
```

A slot's body is its default, used when the view does not fill it (it may be empty, as above).
A fill is a top-level block of the view and replaces the slot of the same name; everything in
the view outside its fills goes to `{: content :}`. Slots and fills are named like regions
(`content` is reserved), are used once per file, and, like regions, start and end in HTML
text. A slot may stand inside a layout region, but not inside another slot; a fill cannot
nest in anything. A region may be inside a fill or a slot default; as for all regions, a name
is used once in the composed template. Variables of a default that a fill replaces are not
needed. The part of the view that goes into `{: content :}` has to end in HTML text too,
so it cannot leave a tag open in the layout.

Compile errors (all `{syntax_error, File, Line, Reason}`): `{unknown_fill, Name, LayoutFile}`,
`{fill_without_layout, Name}`, `{slot_outside_layout, Name}`, `{fill_in_layout, Name}`,
`{fill_not_top_level, Name}`, `{slot_in_slot, Name}`, `{content_in_slot, Name}`,
`{duplicate_slot, Name, FirstLine}`, `{duplicate_fill, Name, FirstLine}`,
`{unbalanced_markup, slot | fill, Name}`, `{in_unsupported_context, slot | fill, Name, Where}`,
`{content_unbalanced_markup, Where}` and, for unclosed or mismatched blocks,
`{unclosed_slot, Name}`, `{unexpected_fill_end, Name}`, `{mismatched_slot_end, Open, Got}` and
`{mismatched_block_end, {Kind, Open}, {Kind, Got}}` (a `/region` closing a slot, say).

### Compile errors

Errors carry file and line, e.g. `{syntax_error, "src/views/home_view.weberl", 3,
unterminated_interpolation}`; other reasons are `empty_interpolation`,
`{invalid_expression, Text, Message}`, `{not_a_single_expression, Text}`, `{unbound_variable, Name}`,
`{reserved_variable, Name}` (names starting `_Weberl_` are the engine's), `unterminated_raw_interpolation`, `{interpolation_in_unsupported_context, Where}`,
`{interpolation_in_restricted_attribute, Attr}`, `{raw_interpolation_in_attribute,
Attr}`, `{invalid_utf8, File}`, for links `{unknown_route, Path}`, `{unverifiable_route, Helper}`,
`{not_a_path, Text}`, `{not_a_url, Text}`, `{url_not_allowed_here, Helper, Tag, Attr}`,
`{misplaced_url_helper, Helper}`, `{untagged_url, Source}`, `{bad_url_option, Key}` and
`{bad_placeholder, Reason}`, and for regions `unterminated_block_tag`,
`{invalid_block_tag, Text}`, `{invalid_region_tag, Tag}`, `{unclosed_region, Name}`,
`{unexpected_region_end, Name}`, `{mismatched_region_end, Open, Got}`,
`{duplicate_region, Name, FirstLine}`, `{region_in_unsupported_context, Name, Where}`
and `{region_unbalanced_markup, Name}`.

### Lifecycle

Templates are compiled **once, when the router starts**, into a generated module
per view (`home_view__weberl_template`, never a modification of your view).
Rendering calls that module; nothing is parsed or read again. All templates are
compiled before any is loaded, so a bad template fails the start without
replacing anything. To pick up an edited template, restart the router (there is
no file watching or hot reload). Because templates are read from the source tree,
the sources must exist when the router starts, as for filesystem routing.

The engine can be used on its own: `compile_file/2`, `compile_source/3`,
`load/1`, `discover/1` and `associate/2` in `weberl_template`.

### Render functions inside the view module

`weberl_template:render(?MODULE, Assigns)` is the supported interface. Having
`render/1` injected into the view module itself would need a parse transform
listed in each view source, which this version avoids so views stay ordinary
Erlang modules.

## Transport adapters and Roadrunner

The listener's `adapter` names a module implementing `weberl_adapter`
(`validate_options/1`, `start_listener/3`, `stop_listener/1`, `port/1`, and `cookies/1`,
`form/1` and `multipart/1`, which parse a request's cookies, urlencoded form and the raw parts of a
multipart body for `weberl_request:cookies/1`, `form/1` and `multipart/1`; optionally `validate_static/1`). Everything above the adapter is transport independent: an
adapter only has to send repeated response headers (several `set-cookie`) as separate headers.

`weberl_roadrunner` is included in weberl but optional. weberl compiles and starts
without Roadrunner (it is in `optional_applications`); the adapter then reports
`{error, {adapter_unavailable, roadrunner}}`. An application that uses it declares
`roadrunner` in its own `rebar.config` and `.app.src`, as in the quick start. It
starts the `roadrunner` application if it is not running. The tests use
Roadrunner 0.13.1 (test profile).

Static mounts are served by `roadrunner_static`; every other request goes to one
shared Roadrunner handler that dispatches through the Weberl route table; route
matching, normalization and 404s are Weberl's.

`#listener{options = ...}` accepts only `max_content_length` (bytes; the request body cap of every route that
does not set its own `max_body_bytes`, see [Forms and uploads](#forms-and-uploads); 10 MiB by default),
`request_timeout` (ms), `tls` (`ssl` server options) and `protocols` (Roadrunner's list:
`http1`, `http2`, `http3`; HTTP/2 over TLS is negotiated by ALPN). Other keys are rejected
at startup.

## Static assets

Mount directories on URL prefixes with `#listener{static = ...}`. Mounts are served
by the adapter before the route table is consulted:

```erlang
Listener = #listener{
    port = 8080,
    static = [{"/static", {priv, my_app, "static"}},            % my_app/priv/static
              {"/uploads", "/var/www/uploads", #{cache_control => <<"max-age=60">>}}]
}.
```

Each entry is `{UrlPrefix, Source}` or `{UrlPrefix, Source, Opts}`. `Source` is a
directory path or `{priv, App, SubPath}`. `GET /static/css/site.css` serves
`css/site.css` under the source. With Roadrunner you get content types, ETag and
`304`, ranges, precompressed `.br`/`.gz` siblings (never compressed on the fly) and
path-traversal protection (symlinks escaping the directory are refused by default).

`Opts` for the Roadrunner adapter: `cache_control` (header value), `symlink_policy`
(`refuse_escapes` | `follow` | `refuse`) and `cache_ttl_ms`. Prefixes must not be `/`,
must not be inside the reserved `/_weberl` namespace, and must not overlap each other.
A missing file is the adapter's own plain 404, not a Weberl handler response. An
adapter without static support rejects a listener that configures `static`
(`{static_unsupported, Adapter}`).

## Live pages

A route declared `one_way` or `two_way` (see [Page kind](#page-kind)) is a *live page*:
the server can push events to the browser after the page was rendered.

1. When the page is requested, dispatch opens a *live session* (a `gen_statem`,
   `weberl_live_session`) and gives the handler its id: `weberl_request:page/1`.
2. If the handler returns a 2xx HTML response, two scripts are inserted before the last
   `</body>` (or appended): the transport engine `/_weberl/engine.js` and the beacon
   `<script src="/_weberl/client.js" data-weberl-page=... data-weberl-token=... defer>`.
   Any other response closes the session again.
3. The beacon connects back: a Server-Sent Events stream (`/_weberl/sse/<id>`) for
   `one_way` pages, the multiplexed WebSocket (`/_weberl/ws`) for `two_way` pages, and
   long-poll (`/_weberl/poll/<id>`) when those keep failing (see
   [Transports](#transports)).
4. Any process pushes to it with `weberl_live:push(PageId, Name, Data)`.

```erlang
-module(clock_view).
-behaviour(weberl_handler).
-weberl_page(one_way).

handle(Request) ->
    PageId = weberl_request:page(Request),
    spawn(fun() -> tick(PageId) end),            % anything that will push later
    weberl_response:html(200, weberl_template:render(?MODULE, #{})).

tick(PageId) ->
    timer:sleep(1000),
    case weberl_live:push(PageId, <<"tick">>, timestamp()) of
        ok -> tick(PageId);
        {error, not_found} -> ok                 % page gone: stop
    end.
```

In the browser the beacon turns each event into a `weberl:<name>` `CustomEvent` on
`document` (`detail` is the data), and `Weberl.on(name, fn)` registers a callback.
The connection reports itself with events of Weberl's own: `weberl_connected` (data: the transport, also after
every reconnect), `weberl_reconnecting`, `weberl_transport`, `weberl_closed` (data: the reason) and `weberl_stale`
(see below). `Weberl.on("weberl_closed", fn)` registers a callback; on `document` they are the plain
`weberl:connected`, `weberl:reconnecting`, `weberl:transport`, `weberl:closed` and `weberl:stale` events. The
`weberl_` prefix is reserved: `push`, `publish` and `publish_json` raise `{reserved_event_name, Name}` for a name
that starts with it (and a snapshot from `handle_subscribe/2` with one is logged and dropped).

`Weberl.state()` answers the state at any time:

| State | Meaning |
|---|---|
| `"connecting"` | no connection has been up yet |
| `"connected"` | the page is receiving |
| `"reconnecting"` | a connection that **was** up dropped and the hub is retrying (backoff up to 30 s, **no limit**); it ends in `"connected"` or `"closed"`. A page that never connected stays `"connecting"` while it retries |
| `"closed"` | the page ended for good (session ended, replaced, refused, `Weberl.close()`) |

The beacon is inserted before the last `</body>`, so a script of your layout, even with `defer`, runs
before it and `window.Weberl` does not exist yet. Such a script waits for the `weberl:ready` document event
(fired once, after `window.Weberl` is set):

```js
if (window.Weberl) { start(); }
else { document.addEventListener("weberl:ready", start, { once: true }); }
```

`Weberl.ready(fn)` calls `fn(Weberl)` at once, for code that already holds `Weberl`. Note that every server
event also fires `weberl:<name>` on `document`, so an app event called `connected` (or `ready`, `closed`...)
would fire the same document event as Weberl's own: use `Weberl.on` for those, or other names.
See `example/src/views/clock/`.

### Requests from the page

The page can send requests to its handler with `Weberl.request(name, data)`, which
returns a Promise. They arrive in the optional `handle_request/3` callback of the
handler module (`weberl_handler`), which runs inside the page's live session:

```erlang
handle_request(<<"rename">>, #{<<"title">> := Title}, #{page := PageId}) ->
    ok = store:rename(Title),
    weberl_live:push(PageId, <<"renamed">>, Title),   % tell the page asynchronously
    {reply, #{<<"saved">> => true}};                   % or just: ok
handle_request(_Name, _Data, _Page) ->
    ok.
```

The third argument is the *page context*, `#{page => PageId, kind => one_way | two_way,
topics => [Topic]}`, taken from the page's verified token. It holds no user data: a
callback that needs to know which user it serves finds it in the topic names (see
[Topics](#topics-and-session-less-pages)) or, on a page with a session, in the page's
[view data](#the-pages-view-data), which the context then carries as `view`.

```javascript
Weberl.request("rename", { title: "New" }).then(function (reply) { /* {saved: true} */ });
```

`Data` is the decoded JSON value, `{reply, Term}` is answered as JSON (anything
`json:encode/1` takes) and `ok` as `true`. The promise rejects with an `Error`
(`.reason`: `bad_request`, `unsupported` when the handler has no `handle_request/3`,
`failed` when it crashed - logged, the session survives). Keep the callback quick, since
it blocks the session; push slow results later. `one_way` pages send requests over
`POST /_weberl/request/<id>`; `two_way` pages over their socket (and POST when it is down).
The word *event* is kept for server-to-client pushes; client-to-server messages are
*requests*. (`handle_event`, for framework-level client messages, is reserved.)

### Topics and session-less pages

Pushing to one page by id (`weberl_live:push/3`) fits per-user updates. For content the
same for many viewers (a stock ticker, a dashboard) Weberl has **topics**: a topic is a
UTF-8 binary such as `<<"stock:ACME">>`; any process publishes to it and every connected
page subscribed to it receives the event:

```erlang
weberl_live:publish(<<"stock:ACME">>, <<"price">>, <<"101.5">>).
```

`publish/3` delivers a string. For structured data use `weberl_live:publish_json(Topic, Name, Term)`: the term
is encoded once with `json:encode/1` and the browser gets the decoded value (`Weberl.on("tasks", function (d) {
d.running })`, `event.detail` of `weberl:tasks`), with no `JSON.parse` on the page. It works on every
transport, long-poll included. A term JSON cannot hold (a pid, a tuple) raises `error:{unsupported_type, Term}`
in the caller and nothing is sent.

There is no replay, buffering or sequence number: a client that is not connected misses
the event (a fire-and-forget fan-out). The frame is encoded once and the connection
processes (the WebSocket handler, the SSE loop) are members of a `pg` group per topic, so a
publish costs one message per connection, however many pages share it - including the
pages of several tabs that share one connection. `pg` keeps the groups in sync between
connected nodes, so a publish on any node reaches the connections on all of them.

A page subscribes to the topics its handler declares with the optional
`weberl_topics/1` callback, evaluated on every render, so it may include per-user topics:

```erlang
weberl_topics(Request) ->
    [<<"stock:", (symbol(Request))/binary>>, <<"user:", (user_id(Request))/binary, ":inbox">>].
```

Topics are validated when the page is rendered (at most 32, 256 bytes each, non-empty
UTF-8; a violation is a logged 500) and signed into the page's token, so a page cannot ask
for more later. `weberl_live:topics(Route, Request)` returns what a request would
subscribe to, for tests. In the browser `Weberl.on(name, function (data, topic) {...})`
receives these events; `topic` is set for them.

**Session-less pages.** A page with a session is a process per page (it can be pushed to
by id and keeps the newest 100 events while the client is away). A page whose content is
the same for everyone does not need one: declare the route with `session => false`
(`{"/ticker", ticker_handler, #{live => one_way, session => false}}`). No process is
started per viewer; the token says what the page may subscribe to, and the connection
process joins the topics. Without a `weberl_topics/1` callback a session-less page's
single topic is its route path. A page can have both a session and topics. Requests from
a session-less page run `handle_request/3` in the process that received them.

**Snapshots.** Rendering the page and connecting happen at different moments, so a
client may miss what was published in between. The optional `handle_subscribe/2` callback
closes that gap: it runs when the client's subscription took effect (the connection has
already joined the topic), so what it reads is current, and its result is sent to that
client only, as an ordinary event:

```erlang
handle_subscribe(<<"stock:", Symbol/binary>>, #{page := _PageId}) ->
    {snapshot, <<"price">>, stocks:current_price(Symbol)};     % or: ok
handle_subscribe(_Topic, _Page) ->
    ok.
```

`{snapshot_json, Name, Term}` sends a value instead: `Term` is encoded as JSON once and the browser
receives it decoded, like an event of `publish_json/3` (`Weberl.on("tasks", function (data) { data.running })`),
not as a string to parse. A term JSON cannot hold is logged and sends no snapshot.

It runs again on every reconnect (a WebSocket resubscribe, a new SSE stream) and, for
long-poll, on the first poll and the first poll after a failure (events published between
two polls are lost; the poll fallback accepts that). Make updates idempotent (send full
state): an event published just before the snapshot may arrive twice. A callback that
crashes is logged and the subscription continues without a snapshot. **It runs in the
connection process and blocks it** (and the other pages on that connection) while it runs,
so keep it short; the same holds for `handle_request/3` of a session-less page.

### One handler, several kinds of page

A route's kind is the widest the page can be. A handler may serve a narrower one for a
particular request by marking the response, so you do not need two handlers or views (say,
the live page for a logged-in user and a plain one for everybody else):

```erlang
handle(Request) ->
    Page = weberl_response:html(200, render(Request)),
    case logged_in(Request) of
        true -> Page;
        false -> weberl_response:live(Page, normal)    % served without the beacon
    end.
```

The allowed moves only narrow: `two_way` to `one_way` or `normal`, `one_way` to `normal`.
Asking for a wider kind than the route's is a bug of the handler and is a logged 500.
`normal` ends the session that was opened for the render and serves the page without the
beacon; `one_way` keeps it and injects the beacon for that kind (the token then follows the
narrower kind). The marker is ignored on routes that are not live.

### Caching

A live page embeds a token and an id that belong to one render, so it must not be served to
other visitors from a shared cache (it could also carry per-user content, like a navbar).
When Weberl injects the beacon and the handler set no `cache-control`, it adds
`cache-control: private, no-store`. A header the handler did set is kept, but one that allows
shared caching (`public`, `s-maxage`, or `max-age` without `private`) is logged as a warning
(`live_page_allows_shared_caching`), since it is almost always a mistake. Pages that should be
cacheable are better built as a static shell that is cached, with the live parts mounted by
JS. A page downgraded to `normal` gets the same treatment: the downgrade is decided per
request, so the same URL answers differently for different visitors and the plain page must
not be shared either.

### Updating a region

A view's template can mark [regions](#regions). Any process can re-render one and push it to
the page:

```erlang
%% a page with a session (the session knows the page's view)
weberl_live:update(PageId, cart, #{items_html => Html}) -> ok | {error, Reason}.

%% the pages following a topic, with or without a session, on any node
weberl_live:update_topic(<<"cart:42">>, home_view, cart, #{items_html => Html}) -> ok | {error, Reason}.
```

The region is rendered with the assigns you pass (only the variables that region uses; nothing
is remembered between calls) and sent as the event `weberl:region` with the data
`{"region": "cart", "html": "..."}`, on whatever transport the page uses. The beacon
(`client.js`) handles that event itself: it finds `<weberl-region name="cart">` and
`[data-weberl-region="cart"]` elements at that moment and replaces their content (keeping the
focus in a field that has an `id`), then dispatches `weberl:region` on `document` (detail
`{region, count}`). A region that is not on the page is not an error. `Weberl.on` handlers do
not see the event. An unknown region, a missing variable or a page without a template is
logged (`live_region_update_failed`), returned as `{error, Reason}`, and nothing is pushed.

### The page's view data

A page with a session can keep data for its whole life, in a `weberl_view_data` record
with two parts: `assigns` (the template variables, which the regions render from) and
`private` (the handler's own data, never rendered and never sent to the browser). The
handler builds it while rendering the page, from what the HTTP request knew (the cookie,
the authenticated user), and mounts it:

```erlang
handle(Request) ->
    User = my_auth:user(Request),
    ViewData = weberl_view_data:new(#{items => Items},        % assigns
                                    #{user_id => User}),      % private
    weberl_response:html(200, weberl_live:mount(?MODULE, Request, ViewData)).
```

`weberl_live:mount(View, Request, ViewData)` renders the template of `View` from the assigns
and, when the page has a session, keeps the whole record there. Without a session (a
session-less page, or one served as `normal` after a downgrade) it only renders and the record
is dropped. `weberl_template:render/2` stays a pure render that stores nothing.

After that the browser talks to the server only through the live connection, and the record
is what is left of the HTTP request:

```erlang
handle_request(<<"add">>, #{<<"id">> := Id}, #{view := View}) ->
    #{items := Items} = weberl_view_data:assigns(View),
    User = maps:get(user_id, weberl_view_data:private(View)),
    ok = store:add(User, Id),
    {reply, true, weberl_view_data:with_assigns(#{items => [Id | Items]}, View)}.
```

`handle_request/3` may return `{ok, ViewData}` or `{reply, Json, ViewData}`. The session
keeps the new record and re-renders and pushes every region that uses an assign whose value
changed (the variables of a region come from its template; regions are pushed in template
order). Other processes can do the same with `weberl_live:assign(PageId, Changes)` (merges
into the assigns) or `weberl_live:modify(PageId, Fun)` (a function from record to record, run
inside the session). `weberl_live:view(PageId)` reads the record, which is how
`handle_subscribe/2` (it runs in the connection process and has no `view` in its context)
gets at the private data when it needs it. A change to the private data alone pushes nothing.
The helpers are `new/1,2`, `assigns/1`, `private/1`, `with_assigns/2`, `with_private/2` (both
merge) and `set_assigns/2`, `set_private/2` (replace, e.g. to remove a key).

A page without a session has no record. What a callback needs about the user there goes into
the topic names or the token claims, as before. An assign that no region uses is simply kept.

### Transports

| Kind | Primary | Fallback | Client to server |
|---|---|---|---|
| `one_way` | SSE | long-poll | `POST /_weberl/request/<id>` |
| `two_way` | WebSocket | long-poll | socket frames, or POST |

The beacon falls back to long-poll after 3 failed connection attempts in a row
(reconnects back off exponentially, with jitter). A page the server ended, or that
another connection took over (close code 1000), is not reconnected. Long-poll is
`GET /_weberl/poll/<id>`: it waits up to `live_poll_timeout` (25 s) and answers
`{"events": [{"event": Name, "data": Data}], "closed": Bool}`. The session buffers
between polls, so nothing is lost. Turn the fallback off for a kind with the
application env `live_poll_fallback` (default `[one_way, two_way]`; `[one_way]` removes
it for `two_way` pages: the beacon is told and the poll endpoint refuses them).

The WebSocket is **multiplexed**: one socket carries any number of pages, every frame is
JSON text and names its page, and a page attaches with its own token:

| Client sends | Server answers |
|---|---|
| `{"op": "subscribe", "page": Id, "token": T}` | `{"page": Id, "subscribed": true}` or `{"page": Id, "error": Reason}` |
| `{"op": "request", "page": Id, "request": Name, "data": Json, "ref": Ref}` | `{"page": Id, "reply": Json, "ref": Ref}`, `{"page": Id, "ok": true, "ref": Ref}` or `{"page": Id, "error": Reason, "ref": Ref}` |
| `{"op": "unsubscribe", "page": Id}` | |
| | pushes: `{"page": Id, "event": Name, "data": Data}` (also a snapshot) |
| | topic events: `{"topic": T, "event": Name, "data": Data}`, one frame per connection however many of its pages use the topic |
| | `{"page": Id, "closed": "closed" or "replaced"}` when that page's session ended or another connection took it; the socket stays open for the other pages |

A socket that subscribes no page within `live_subscribe_timeout` (10 s) is closed.
The SSE stream carries one page; each event is an unnamed message whose data is
`{"event": Name, "data": Data}` (plus `"topic"` for a topic event; the same shape on every
transport, so a client needs no per-event listeners; long-poll entries have it too). See
`weberl_live_wire` for the details.

In the browser, `priv/engine.js` (no DOM: it can run in a worker) owns these connections
and the reconnect/fallback policy, and `priv/client.js` is the page-side API on top of it.
They talk through a small *hub* interface (documented in `engine.js`). By default the hub
is a **SharedWorker** (`/_weberl/hub.js`): all the tabs of the browser on the origin share
one engine, so one WebSocket carries every live page (`one_way` pages too: the hub's engine
puts them on the shared socket instead of opening an SSE stream per page), and a topic event
arrives once for all of them. A tab falls back to its own in-page engine (its own connection) when the browser has
no SharedWorker, the worker fails to start or does not answer, or the worker runs another
version of the scripts than the tab.

A version mismatch happens when a tab loaded before a deploy meets a worker started after it
(or the reverse). The tab warns in the console, dispatches a `weberl:stale` event on
`document` (detail `{hub, page}`; also `Weberl.on("weberl_stale", ...)`) so the app can ask the user to
reload, and keeps working on its own connection. The server sees versions too: every
connection start (the WebSocket, an SSE stream, a long-poll asking for snapshots) declares
the script version in the `v` query parameter, and one that declares another or none is
logged as `live_client_version_mismatch` (it is logged, not refused, for now).

A page whose tab closed is dropped from the worker when the tab says so (`pagehide`); a tab
that vanishes without it (a crash) leaves its pages in the worker until the server ends them.
Where a `Content-Security-Policy` is set, the worker needs `worker-src 'self'`.

### Credentials

Every live endpoint needs the page **token** from the beacon tag, as the `t` query
parameter (EventSource and WebSocket cannot set headers) or the `x-weberl-token`
header. The token is `Salt ++ Channels ++ Claims ++ HMAC-SHA256(Secret, "weberl-page" ++
PageId ++ Salt ++ Channels ++ Claims)`, base64url, where `Channels` is the set of channels
the page may use (`sse`, `ws`, `poll`, `request`) and `Claims` what the server needs to
know without a session to ask: the page kind, whether it has a session, its handler module
and its topics. It is bound to its page and, because the channel set is
inside the MAC, it cannot be widened or moved: each endpoint checks its own channel, so a
`two_way` page's token never opens the stream and a page rendered while the poll fallback is
off cannot poll. A `one_way` token includes `ws` as well as `sse`: a browser hub that
shares one WebSocket between tabs subscribes its pages there, and the server still only
pushes to them. A missing or
invalid token is a 403 whether the page exists or not. The token only proves the page
was served by this server; the page id alone is not enough.

Requests that carry an `Origin` header must have it match `Host` (a second layer
against cross-site use from browsers; behind a proxy, keep `Host` intact). Stricter
scopes (per-session, shared across tabs) are planned.

See [Live pages settings](#live-pages-settings) for what you configure, notably the
secret.

Notes:

- The page id is unguessable (128 random bits); the token is the credential.
- A session never attached ends after `live_attach_timeout` (30 s). After the transport
  drops it waits `live_idle_timeout` (60 s) for the browser to reconnect. Events pushed
  while no transport is attached are buffered (newest 100) and delivered on the next
  connect.
- A new connection for the same page replaces the previous one.
- Stopping a router ends the connections of its listener.
- Cross-tab shared beacons and region patching come in later phases (see `ROADMAP.md`).
- Adapters talk to a session with plain messages (`weberl_live` documents the
  protocol), so a transport other than the Roadrunner ones can be added.
- If live support is unavailable (the `weberl` application is not running), the page
  is served normally without the beacon and the failure is logged.

## Build integration

weberl never compiles your views; your application compiles them as ordinary
modules. rebar3 compiles `src/` recursively, so views under `src/views/**` need no
extra configuration. Roots outside `src/` must be added to `src_dirs`:

```erlang
{src_dirs, ["src", "admin/views"]}.
```

Discovery and template compilation need the **source tree** when the router
starts. In a release the sources are usually absent: ship the views directory
(e.g. under `priv/`) and point `root` at it, resolving the path at runtime (as the
example does with `code:lib_dir/1`).

## Running the example

`example/` is a complete application: a supervisor starting a router with a
filesystem root (`src/views`: `/` and `/about`, both with templates) and a
declarative route (`/health`).

Locally:

```text
cd example
rebar3 shell          # fetches roadrunner, starts the app on http://localhost:8080
```

Then open `http://localhost:8080/`, `/about`, `/health`, and the live pages: `/clock` (the
server pushes the time every second, one-way) and `/counter` (two-way, with
[regions](#regions) and [view data](#the-pages-view-data): a button sends a request that
changes the count region, a process updates the clock region every second with
`weberl_live:assign/2`). With podman and the
provided Dockerfile (`podman build -t weberl .`):

```text
podman run -it -p 8080 -v "$(pwd):/app:Z" -w /app/example weberl rebar3 shell
```

The example gets weberl through `example/_checkouts/weberl`, a symlink to the
repository root; in your project use a normal `deps` entry. Stop the listener
cleanly by stopping the application or terminating the router child
(`supervisor:terminate_child(example_sup, example_web)`).

## Known limitations and future work

See `ROADMAP.md` for the running list. Notable points:

- Request bodies are fully buffered by Roadrunner (up to `max_content_length`, 10 MiB by default, or a
  route's own `max_body_bytes`) before the handler runs: uploads are in memory, and large ones need a
  streaming transport.
- Only ordinary HTTP/1.1 request/response is implemented. Streaming, SSE,
  WebSockets, HTTP/2 and HTTP/3 are not exposed.
- Stopping a router does not close connections that are already open.
- A router process killed without cleanup leaves its listener serving until the
  same router name is started again.
- No wildcard routes (a parameter is one segment), middleware execution, authentication,
  nested layouts or components in templates, blocks (`if`, `case`, `for`) inside URL and other restricted
  attribute values or `<script>` and `<style>`, and no hot reloading.
- Regions are replaced wholesale (no DOM morphing), and their names are static (no
  `item-5` style regions for the rows of a list yet). Nested regions that both use a changed
  variable are both re-rendered.
- `srcset`, `data`, `ping` and the other attributes without a URL helper still reject interpolation.
- Request `path/1` is the raw path; a decoded variant is future work.

## Project documents

| File | Purpose |
|---|---|
| `README.md` | this document: usage, architecture, limitations |
| `MILESTONE_2.md` | the Milestone 2 specification (kept in sync with what was built) |
| `TEMPLATE_BLOCKS.md` | the template block language (`{{ Expr }}`, `if`, `case`, `for`): semantics, generated code, hooks |
| `ROADMAP.md` | deferred work and things to revisit |
| `E2E_ROADMAP.md` | plan for the future browser (end-to-end) test suite |
| `PROCESSES.md` | convention for long-running processes (`gen_statem`), followed by `weberl_router_server` |

Milestone 1 (routing library) is preserved unchanged under `src/router/`; its
tests still pass as written.

## Development

Erlang/OTP 29 and rebar3. With the provided Dockerfile:

```text
podman build -t weberl .
podman run -d --name weberl-dev -p 8080 -v "$(pwd):/app:Z" -w /app weberl sleep infinity
podman exec weberl-dev rebar3 eunit
```

(`-p 8080` publishes the example app on a free host port, so a busy 8080 never blocks the container; `podman port weberl-dev 8080` shows it. Use `-p 8080:8080` for a fixed port.)

`rebar3 eunit` runs everything, including real HTTP tests against Roadrunner on
ephemeral ports (Roadrunner is fetched for the test profile only). The Erlang image has no
Node.js.

### Node tests and browser tests

Everything JavaScript is in `test/node/` and runs in a second image, `Dockerfile.e2e`, which
is Microsoft's Playwright image (Node 24-line, Chromium, Firefox and WebKit):

- `test/node/unit/` - unit tests of `priv/engine.js` and `priv/client.js` against fake
  `WebSocket`/`EventSource`/`fetch` objects and a fake DOM (`node --test`);
- `test/node/e2e/` - Playwright specs run in the three real browsers against the app under
  test (`e2e_app/`), which is served over TLS (HTTP/1.1 and HTTP/2) at `https://app.test:8443`.

```text
podman build -f Dockerfile.e2e -t weberl-e2e .      # once, and when package.json changes
test/e2e/run.sh                                     # unit tests and browser tests (Chromium)
test/e2e/run.sh unit                                # only the unit tests (cheap)
test/e2e/run.sh e2e -g counter                      # arguments after the mode go to Playwright
E2E_BROWSERS=chromium,firefox,webkit test/e2e/run.sh e2e    # all three browsers
E2E_VARIANTS=plain test/e2e/run.sh e2e                  # only one variant of the app (see below)
```

The browser tests are heavy for the machine. They run in Chromium only unless `E2E_BROWSERS`
lists more, and the containers have CPU and memory limits (`E2E_CPUS`/`E2E_MEMORY` for the
browser, default 2 and 3g; `APP_CPUS`/`APP_MEMORY` for the app, 1 and 1g). Use the unit tests
and `rebar3 eunit` for everyday checks.

The app under test comes in two variants, and `run.sh` runs the specs once against each (twice
the time; `E2E_VARIANTS=plain` or `=layouts` runs one). `plain` serves the pages that have a
template (`clock`, `counter`, `regions`) as full HTML templates (`e2e_app/src/views_plain`);
`layouts` serves the same pages, same URLs and same behaviour, as views of a
[layout](#layouts) (`views_layouts`, `layouts/main.weberl`), with their scripts in its `head`
slot. Pages without a template (`views_common`) are the same in both. So every spec doubles as
a test of layouts, and `layouts.spec.js`, which only runs against `layouts`, checks the pages
are really built from the layout. `E2E_VARIANT` (set by `run.sh`) chooses the variant in
`e2e_app_sup.erl`.

`run.sh` creates a throwaway podman pod. Its two containers (the Erlang image running the app
under test, and the Playwright image running the tests with only `test/node/` mounted) share
the pod's network, which maps `app.test` and `other.test` to localhost, so the browser meets
the app as a remote host; nothing is published to the host. It copies `priv/*.js` to
`test/node/_priv/` (the unit tests read the scripts from there), generates a fake CA and a
server certificate (`test/node/gen-certs.sh`; Chromium trusts the CA through its certificate
database, Firefox and WebKit ignore certificate errors for now) and removes the pod when it
ends. Reports and traces of failures are written to `test/node/playwright-report/` and
`test/node/test-results/`.

The app under test serves `/_test/stats` (`weberl_live:stats()`: sessions, WebSockets, SSE
streams; `?handler=Module` adds that handler's sessions), which the specs use to assert from
the server's side, for instance that two tabs share one WebSocket, and `/_test/publish` to
publish to a topic. Its pages (`counter`, `clock`, `regions`, `topics`, `downgrade`, `widen`,
`cached`) exist for the specs. What is still to write is in `E2E_ROADMAP.md`. The `@playwright/test` version in `test/node/package.json` must match
the tag in `Dockerfile.e2e`.
