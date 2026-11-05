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
<h1>{{ title }}</h1>
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
│   ├── weberl_handler.erl      behaviour, startup checks, metadata
│   ├── weberl_request.erl      request record
│   ├── weberl_response.erl     response record
│   └── weberl_dispatch.erl     request -> response
├── template/
│   ├── weberl_template.erl             public API: render, compile, discover
│   ├── weberl_template_lexer.erl
│   ├── weberl_template_parser.erl      parse + validate
│   ├── weberl_template_html.erl        HTML context tracking
│   ├── weberl_template_compiler.erl    AST -> generated module
│   └── weberl_template_runtime.erl     value conversion, escaping
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
  `? # \`, and no `:` or `*`, which are reserved for later dynamic/wildcard
  routes).

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
| `params/1` | route parameters, `#{}` for static routes |
| `peer/1` | `{Address, Port}` or `undefined` |
| `meta/1` | transport metadata map (Roadrunner: `adapter`, `listener`, `scheme`, `version`, `request_id`) |
| `read_body/1` | `{ok, binary()} \| {error, Reason}` |

The body is read only when `read_body/1` is called. With the Roadrunner adapter it
is already in memory (see [limitations](#known-limitations-and-future-work)).

### Response (`weberl_response`)

```erlang
weberl_response:html(200, Body)        % text/html; charset=utf-8
weberl_response:text(200, Body)        % text/plain; charset=utf-8
weberl_response:binary(200, Body)      % application/octet-stream
weberl_response:new(204, [{"cache-control", "no-store"}], <<>>)
weberl_response:with_header("x-custom", "yes", Response)   % replaces, case-insensitive
```

Bodies are `iodata()`, status is 100..599, header names are stored lower-case.
Invalid arguments raise `badarg`.

### Dispatch, errors and metadata

`weberl_dispatch:dispatch(Request, Table)` returns a response and never raises:

- no matching route: `404` `Not Found` (text/plain);
- the handler raises, throws, exits, or returns anything but a `weberl_response`:
  `500` `Internal Server Error`. The client sees no details; the cause is logged
  at error level with handler, method, path, class, reason and stacktrace.

A handler may export `weberl_metadata/0` returning a map. Weberl attaches no
meaning to it yet; it is the extension point for future per-module settings
(middleware, authentication). `layout` selects a [layout](#layouts). Read it with `weberl_handler:metadata/1`.
`weberl_handler:check/1` (used at startup) rejects modules without `handle/1` and
metadata that is not a map.

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
| `{{ name }}` | value, HTML-escaped |
| `{{{ name }}}` | value, **not** escaped. Unsafe for untrusted input |
| `\{{` | literal `{{` |
| `{: region name :}` ... `{: /region name :}` | a [region](#regions) |
| `{: region name tag=tbody :}` | a region wrapped in that element |
| `{: content :}` | in a [layout](#layouts): where the view's template goes |
| `{: slot name :}` ... `{: /slot name :}` | in a layout: a [slot](#slots) a view can fill; the body is the default |
| `{: fill name :}` ... `{: /fill name :}` | in a view: replaces the layout's slot of that name |
| `\{:` | literal `{:` |

`{{ }}` is for values only; statements use `{: :}`. Names match `[a-z][a-zA-Z0-9_]*` and are looked up as atom keys in the assigns
map. There are no expressions, conditionals, loops, includes, components
or filters in this version.

Supported values: UTF-8 binaries, character lists, integers, floats, `true` and
`false` (rendered as text). Escaping covers `& < > " '`.

Interpolation is allowed in **HTML text** and in **quoted attribute values**
(escaped only). Escaping alone is not enough in JavaScript, CSS or URLs, so these
are rejected when the template is compiled: inside `<script>` / `<style>`, HTML
comments, tags, attribute names, unquoted attribute values, raw `{{{ }}}` inside
an attribute, and URL or code attributes (`href`, `src`, `action`, `style`, `on*`
and similar). Literal values in those places are of course fine.

### Rendering

```erlang
weberl_template:render(home_view, #{title => <<"Welcome">>}) -> iodata().
weberl_template:try_render(home_view, Assigns) -> {ok, iodata()} | {error, Reason}.
```

`render/2` raises `error({template_error, Reason})` with `{missing_variable, View,
Name}`, `{unsupported_value, View, Name, Value}`, `{invalid_assigns, View, Assigns}`
or `{no_template, View}`. Inside a handler this becomes a logged 500.

### Regions

A region is a part of the page the server can re-render on its own and the browser
can swap, without re-sending the page (see [Updating a region](#updating-a-region)):

```text
<h1>{{ title }}</h1>
{: region cart :}
  <ul>{{{ items_html }}}</ul>
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
<head><title>{{ title }}</title></head>
<body>
  <nav>...</nav>
{: content :}
</body>
</html>
```

The router lists the directories with layouts, and a view picks one in its metadata
(`weberl_metadata/0`); a view without `layout` stays a standalone page:

```erlang
#router{filesystem = [...], layouts = ["src/layouts"]}

weberl_metadata() -> #{layout => main}.      %% src/layouts/main.weberl
```

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
Reason}]}`: `{unknown_layout, Name}`, `layout_without_template` (the metadata asks for a
layout but the view has no template), `content_outside_layout` (a view or a standalone
template uses `{: content :}`) and `{duplicate_region, Name, LayoutFile, ViewFile}`.

#### Slots

`{: content :}` is where the body of the view goes. For other parts of the page (scripts and
styles in `<head>`, a sidebar) the layout declares slots, and the view fills the ones it wants:

```html
<!-- layout -->
<head>
  <title>{{ title }}</title>
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
unterminated_interpolation}`; other reasons are `{invalid_variable_name, Text}`,
`unterminated_raw_interpolation`, `{interpolation_in_unsupported_context, Where}`,
`{interpolation_in_restricted_attribute, Attr}`, `{raw_interpolation_in_attribute,
Attr}`, `{invalid_utf8, File}`, and for regions `unterminated_block_tag`,
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
(`validate_options/1`, `start_listener/3`, `stop_listener/1`, `port/1`). Everything
above the adapter is transport independent.

`weberl_roadrunner` is included in weberl but optional. weberl compiles and starts
without Roadrunner (it is in `optional_applications`); the adapter then reports
`{error, {adapter_unavailable, roadrunner}}`. An application that uses it declares
`roadrunner` in its own `rebar.config` and `.app.src`, as in the quick start. It
starts the `roadrunner` application if it is not running. The tests use
Roadrunner 0.13.1 (test profile).

Static mounts are served by `roadrunner_static`; every other request goes to one
shared Roadrunner handler that dispatches through the Weberl route table; route
matching, normalization and 404s are Weberl's.

`#listener{options = ...}` accepts only `max_content_length` (bytes),
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
`weberl:connected`, `weberl:transport` and `weberl:closed` report the connection state.
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
`document` (detail `{hub, page}`; also `Weberl.on("stale", ...)`) so the app can ask the user to
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
podman run -it -p 8080:8080 -v "$(pwd):/app:Z" -w /app/example weberl rebar3 shell
```

The example gets weberl through `example/_checkouts/weberl`, a symlink to the
repository root; in your project use a normal `deps` entry. Stop the listener
cleanly by stopping the application or terminating the router child
(`supervisor:terminate_child(example_sup, example_web)`).

## Known limitations and future work

See `ROADMAP.md` for the running list. Notable points:

- Request bodies are fully buffered by Roadrunner (up to `max_content_length`,
  10 MB by default) before the handler runs.
- Only ordinary HTTP/1.1 request/response is implemented. Streaming, SSE,
  WebSockets, HTTP/2 and HTTP/3 are not exposed.
- Stopping a router does not close connections that are already open.
- A router process killed without cleanup leaves its listener serving until the
  same router name is started again.
- No dynamic or wildcard routes, middleware execution, authentication,
  nested layouts, components, loops or conditionals in templates, and no hot reloading.
- Regions are replaced wholesale (no DOM morphing), and their names are static (no
  `item-5` style regions for the rows of a list yet). Nested regions that both use a changed
  variable are both re-rendered.
- Interpolation into URL attributes is rejected rather than URL-encoded.
- Request `path/1` is the raw path; a decoded variant is future work.

## Project documents

| File | Purpose |
|---|---|
| `README.md` | this document: usage, architecture, limitations |
| `MILESTONE_2.md` | the Milestone 2 specification (kept in sync with what was built) |
| `ROADMAP.md` | deferred work and things to revisit |
| `E2E_ROADMAP.md` | plan for the future browser (end-to-end) test suite |
| `PROCESSES.md` | convention for long-running processes (`gen_statem`), followed by `weberl_router_server` |

Milestone 1 (routing library) is preserved unchanged under `src/router/`; its
tests still pass as written.

## Development

Erlang/OTP 29 and rebar3. With the provided Dockerfile:

```text
podman build -t weberl .
podman run -d --name weberl-dev -p 8080:8080 -v "$(pwd):/app:Z" -w /app weberl sleep infinity
podman exec weberl-dev rebar3 eunit
```

(`-p 8080:8080` makes the example app reachable from your browser.)

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
