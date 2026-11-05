# Weberl — Milestone 2
## Router Integration, HTTP Handlers & Template Engine

**Target:** Erlang/OTP 29  
**Implementation:** Pure Erlang/OTP  
**HTTP adapter:** Arizona Roadrunner  
**Status:** Implementation specification

---

## 1. Objective

Extend the existing Weberl library into a minimal, functioning web framework capable of:

1. Discovering and compiling the existing filesystem and declarative route definitions.
2. Starting HTTP listeners through a transport-independent Weberl API.
3. Dispatching incoming HTTP requests to their corresponding view/handler modules.
4. Rendering HTML from `.weberl` templates using a new Weberl-specific template DSL.
5. Organizing the implementation into clearly separated subsystems that can evolve independently.

Preserve the functionality implemented in Milestone 1.

Do not rewrite the existing routing logic unless necessary for integration.

## 2. Required project reorganization

Before implementing new features, reorganize the existing source tree.

All modules specific to route discovery, route normalization, route tables, conflict resolution, and route lookup must move under:

`src/router/`

Suggested structure:

```text
src/
├── weberl.erl
├── weberl_app.erl
├── weberl_sup.erl
│
├── router/
│   ├── weberl_router.erl
│   ├── weberl_route.erl
│   ├── weberl_table.erl
│   ├── weberl_route_discovery.erl
│   └── ...
│
├── handler/
│   ├── weberl_handler.erl
│   ├── weberl_request.erl
│   ├── weberl_response.erl
│   └── weberl_dispatch.erl
│
├── template/
│   ├── weberl_template.erl
│   ├── weberl_template_lexer.erl
│   ├── weberl_template_parser.erl
│   ├── weberl_template_compiler.erl
│   └── weberl_template_runtime.erl
│
└── adapters/
    └── roadrunner/
        ├── weberl_roadrunner.erl
        ├── weberl_roadrunner_handler.erl
        └── weberl_roadrunner_convert.erl
```

The filenames are suggestions, not mandatory names.

Retain existing module names and public APIs wherever possible.

Do not rename functioning modules solely to match the suggested structure.

### Important build consideration

Verify that the consuming application's build configuration compiles nested Erlang source directories.

The source reorganization must not introduce a new compilation requirement without documenting and testing it.

### Acceptance criteria

- Existing Milestone 1 tests pass unchanged.
- All routing-specific source files are organized under `src/router/`.
- Public routing APIs remain compatible.
- No cyclic dependencies between routing, handler, template, and adapter subsystems.
- The new directory structure is documented.

---

## 3. Architectural boundaries

Weberl must distinguish four responsibilities.

### Router

Responsible for:

- Filesystem route discovery.
- Declarative route collection.
- Route normalization.
- Conflict resolution.
- Route lookup.
- Producing route tables.

It must not depend on Roadrunner.

### Handler

Responsible for:

- Defining the Weberl request/response interface.
- Invoking the appropriate application module.
- Normalizing handler results.
- Integrating rendered templates into HTTP responses.

It must not depend on Roadrunner.

### Template engine

Responsible for:

- Reading `.weberl` templates.
- Lexical analysis and parsing.
- Validating template syntax.
- Compiling or transforming templates into renderable Erlang code.
- Rendering templates with supplied data.

It must not depend on the HTTP listener or router.

### Transport adapter

Responsible for:

- Starting and stopping listeners.
- Translating Weberl route definitions into the transport's route configuration.
- Converting incoming transport requests into Weberl requests.
- Converting Weberl responses into transport responses.
- Mapping transport errors into documented Weberl errors.

Roadrunner-specific code must remain isolated within `src/adapters/roadrunner/`.

---

## 4. Router startup API

Introduce a public API for starting and stopping routers.

The caller decides when a router starts. `weberl:start_link/3` starts one
process per router (registered under the given name, returning `{ok, Pid}`)
that owns the lifecycle, and `weberl:child_spec/3` lets the caller place it in
its own supervision tree. The Weberl application starts no routers by itself.

Conceptual example:

```erlang
weberl:start_link(
    my_router,
    #router{
        filesystem = [#filesystem_router{root = "src/views", prefix = "/"}],
        modules = [my_app_router]
    },
    #listener{
        adapter = weberl_roadrunner,
        port = 8888
    }
).
```

This is conceptual syntax; the records come from `weberl_config` via
`-import_record`. `weberl:stop/1` stops a router and its listener.

### Requirements

1. Validate configuration.
2. Build the complete route table using the existing router.
3. Validate handler module availability and required callbacks.
4. Initialize the selected transport adapter.
5. Start the listener with the complete route table.
6. Return a useful listener/router reference.
7. Support stopping a previously started router.
8. Return structured errors on startup failure.
9. Avoid leaving orphan listeners or processes after partial startup failure.

The public API must not expose Roadrunner-specific configuration objects.

### Lifecycle

Router startup must be compatible with OTP supervision.

A router should have a well-defined lifecycle and be able to participate in the application's supervision tree.

Avoid introducing an unnecessary process per route.

### Native-record loading

The previous milestone revealed that native-record construction may require the defining module to be loaded.

Ensure the application startup and configuration lifecycle account for this, without requiring shell-specific commands such as `m/1`.

Document any necessary `code:ensure_loaded/1` behavior.

---

## 5. Transport adapter interface

Define a Weberl adapter contract.

Conceptual callbacks:

```erlang
start_listener(Name, Options, Routes) ->
    {ok, ListenerRef} | {error, Reason}.

stop_listener(ListenerRef) ->
    ok | {error, Reason}.
```

The implementation agent may refine these signatures.

The interface must allow future adapters to replace Roadrunner without changing application routing or handler definitions.

### Roadrunner adapter

Implement `weberl_roadrunner` as an adapter shipped inside the Weberl repository for Milestone 2. It is optional code: Weberl compiles and starts without Roadrunner (listed in `optional_applications`), the adapter reports `{error, {adapter_unavailable, roadrunner}}` when it is missing, and a consuming application that uses it declares `roadrunner` in its own dependencies. Roadrunner is a dependency of Weberl's test profile only.

Responsibilities:

- Translate Weberl routes into Roadrunner routes.
- Start Roadrunner listeners.
- Stop Roadrunner listeners.
- Provide a common Roadrunner entrypoint that dispatches into Weberl handlers.
- Convert request and response representations.
- Preserve transport-level errors and relevant metadata.

Prefer a shared adapter handler that dispatches through the Weberl route table over generating separate Roadrunner handler modules for every route.

Verify Roadrunner's actual routing and callback contracts before choosing the integration mechanism.

### Dependency isolation

Roadrunner must not be referenced by the router, template engine, or framework-level handler modules.

The adapter may depend on Roadrunner.

Do not introduce a generalized plugin manager in this milestone.

A simple adapter behaviour and configuration selection are sufficient.

### Protocol scope

For this milestone, implement and test ordinary HTTP/1.1 request/response handling.

Preserve an architecture that can later support:

- HTTP/2 and HTTP/3.
- Server-Sent Events.
- WebSockets.
- Streaming request and response bodies.

Do not implement those additional protocol features yet.

---

## 6. Handler interface

Introduce a Weberl-native handler interface.

A filesystem view module or declarative handler module should be invocable through the same dispatch system.

Conceptual handler:

```erlang
-module(home_view).

-behaviour(weberl_handler).

-export([handle/1]).

handle(Request) ->
    weberl_response:html(
        200,
        <<"Hello from Weberl">>
    ).
```

Define and document the handler callback contract.

### Request representation

Provide a Weberl-native request structure containing at least:

- HTTP method.
- Request path.
- Request headers.
- Query string or query parameters.
- Route parameters, initially empty for static routes.
- Request body access mechanism.
- Peer address where available.
- Request metadata.

Use native records where they improve the public API.

Do not eagerly read or buffer request bodies unless the underlying transport requires it.

Document any Roadrunner limitations.

### Response representation

Provide a Weberl-native response structure containing:

- Status code.
- Headers.
- Body.

Support at least:

- HTML responses.
- Plain text responses.
- Binary bodies.
- Explicit HTTP status codes.
- Custom response headers.

Define sensible defaults, including appropriate content types.

### Dispatch

The dispatch layer must:

1. Receive a Weberl request.
2. Resolve the matching route.
3. Invoke its handler.
4. Normalize the returned response.
5. Return a framework-level response to the adapter.

Return 404 for unmatched routes.

Provide a predictable 500 response for unexpected handler failures without leaking internal stack traces to clients.

Log errors with sufficient diagnostic context.

---

## 7. View module metadata

Prepare the handler subsystem for future module-specific configuration.

Future examples include:

- Middleware declarations.
- Authentication policies.
- Route metadata.
- Layout selection.
- Response defaults.
- Content negotiation.

For Milestone 2, only establish a clean extension point.

Do not implement middleware execution or a general metadata DSL yet.

The implementation may use module attributes or an optional metadata callback, but should not introduce complex compile-time transformations solely for this purpose.

Any metadata inspection must be deterministic and documented.

---

## 8. Weberl template convention

Introduce a new template format with extension:

`.weberl`

A view may have a corresponding template:

```text
src/views/
├── home_view.erl
├── home_view.weberl
│
└── about/
    ├── company_information_view.erl
    └── company_information_view.weberl
```

### Association rules

- A `.weberl` template belongs to the view module with the matching basename.
- The template must be in the same directory as its view source file.
- Templates do not independently create routes.
- View modules without templates remain valid.
- Unassociated templates must be reported during validation.
- Duplicate or ambiguous associations must produce errors.

For example:

`company_information_view.weberl`

is associated with:

`company_information_view.erl`

The URL remains determined by the containing directory.

---

## 9. Template language — initial DSL

Implement a small, deterministic HTML-oriented template DSL.

Milestone 2 must support:

1. Literal HTML.
2. Plain text.
3. Dynamic value interpolation.
4. HTML escaping by default.
5. Explicit trusted/raw HTML output.
6. Rendering using data supplied by the view module.
7. Syntax errors with filename and line information.

### Proposed syntax

Example `home_view.weberl`:

```html
<main class="home">
    <h1>{{ title }}</h1>
    <p>{{ description }}</p>
</main>
```

Example rendering call:

```erlang
weberl_template:render(
    home_view,
    #{
        title => <<"Welcome">>,
        description => <<"Built with Weberl">>
    }
).
```

Expected output:

```html
<main class="home">
    <h1>Welcome</h1>
    <p>Built with Weberl</p>
</main>
```

### Interpolation

Use:

`{{ name }}`

for HTML-escaped interpolation.

For explicit raw HTML, use:

`{{{ name }}}`

Raw HTML output must be documented as unsafe for untrusted input.

### Initial value types

Support:

- UTF-8 binaries.
- Character lists.
- Integers.
- Floats.
- Booleans.

Missing variables and unsupported values must produce documented errors rather than silently rendering arbitrary Erlang terms.

### Escaping

HTML escaping must cover at least:

- Ampersand.
- Less-than.
- Greater-than.
- Double quote.
- Single quote.

Use context-aware limitations in documentation: ordinary HTML text escaping alone is not sufficient to make interpolation safe in JavaScript, CSS, URLs, or arbitrary HTML attributes.

For Milestone 2, support interpolation in HTML text nodes and quoted ordinary HTML attributes only, or reject unsupported contexts clearly.

### DSL boundaries

Do not implement:

- Arbitrary Erlang expression evaluation inside templates.
- Loops.
- Conditional directives.
- Components.
- Slots.
- Layout inheritance.
- Template includes.
- Custom filters.
- JavaScript execution.

These belong in later milestones.

The parser should be structured so additional syntax can be introduced without rewriting the entire template engine.

---

## 10. Template compilation and rendering

Keep the following operations separate:

- Template discovery.
- Tokenization.
- Parsing.
- Validation.
- Compilation.
- Rendering.

The preferred design is to compile templates into a reusable representation or Erlang rendering functions.

Avoid reparsing template source on every HTTP request.

### Render integration

A view should be able to supply template variables and render its associated template.

Conceptual example:

```erlang
-module(home_view).

-behaviour(weberl_handler).

-export([handle/1]).

handle(_Request) ->
    weberl_response:html(
        200,
        weberl_template:render(
            ?MODULE,
            #{title => <<"Welcome">>}
        )
    ).
```

This is the minimum required integration.

### Generated render functions

The longer-term goal is to make rendering available directly from view modules, but Erlang cannot automatically inject exported functions into an already compiled module without an explicit compilation mechanism.

For Milestone 2:

- Investigate compile-time generation using OTP-native compiler facilities.
- Prefer a separate generated rendering module or a well-defined parse transform if appropriate.
- Do not require users to rename or rewrite their view source files.
- Do not require a custom rebar3 provider.
- Do not silently modify original view modules.

If automatic generation of `render/1` directly inside the view module is practical and robust, implement it.

Otherwise, provide `weberl_template:render(ViewModule, Assigns)` as the working public interface and document the direct-render-function enhancement as future work.

Do not compromise standard Erlang compilation compatibility to achieve generated functions.

### Performance

Compiled templates must be reusable.

Rendering must not repeatedly read template files from disk.

A simple compilation cache or generated module approach is acceptable, provided it has clear lifecycle and invalidation behavior.

---

## 11. End-to-end example

Provide a fixture application demonstrating the complete workflow.

Example structure:

```text
example/
├── src/
│   ├── example_app.erl
│   ├── example_sup.erl
│   ├── example_router.erl
│   │
│   └── views/
│       ├── home_view.erl
│       ├── home_view.weberl
│       │
│       └── about/
│           ├── about_view.erl
│           └── about_view.weberl
│
└── rebar.config
```

The example must:

1. Start a Weberl router.
2. Start a Roadrunner HTTP listener through the adapter.
3. Discover filesystem routes.
4. Include at least one declarative route.
5. Dispatch requests to the correct handlers.
6. Render a `.weberl` template.
7. Return valid HTTP responses.
8. Stop the listener cleanly.

The example should be runnable with documented commands.

---

## 12. Testing

Use EUnit and/or Common Test.

### Router regression tests

All Milestone 1 tests must continue passing.

### Handler tests

- Successful handler invocation.
- Correct route-to-handler mapping.
- 404 handling.
- 500 handling.
- Custom status codes.
- Custom headers.
- HTML response.
- Plain text response.
- Binary response.
- Handler exceptions.
- Invalid handler return values.

### Adapter tests

- Roadrunner listener startup.
- Listener shutdown.
- Invalid listener configuration.
- Multiple listeners with distinct names.
- Correct route mapping.
- Request conversion.
- Response conversion.
- Real HTTP request/response integration.
- Cleanup after failed startup.

### Template tests

- Template discovery.
- Correct view association.
- Literal HTML rendering.
- Text interpolation.
- HTML escaping.
- Raw HTML interpolation.
- Missing variables.
- Unsupported variable types.
- Malformed interpolation.
- Invalid template syntax.
- Line-aware error reporting.
- Repeated rendering without reparsing.
- Rendering with different variable values.
- Templates without associated views.
- Views without templates.

### End-to-end tests

At least:

- GET `/` renders `home_view.weberl`.
- GET `/about` renders `about_view.weberl`.
- A declarative route returns a response.
- An unknown route returns 404.
- A failing handler returns 500.
- The router can be stopped and restarted.

Keep the test suite reasonably fast.

Avoid unnecessarily repeating expensive integration tests during development.

---

## 13. Explicitly out of scope

Do not implement:

- A new HTTP server.
- HTTP parser replacement.
- HTTP/2 or HTTP/3-specific features.
- WebSocket handlers.
- SSE handlers.
- Middleware execution.
- Authentication.
- Authorization.
- Dynamic route parameters.
- Wildcard routing.
- Template components.
- Template layouts.
- Template loops or conditionals.
- Hot reloading.
- Development file watchers.
- Custom rebar3 providers.
- Full HTML5 parser conformance.
- A general plugin management framework.

---

## 14. Acceptance criteria

Milestone 2 is complete when:

1. Existing routing code is organized under `src/router/`.
2. Milestone 1 functionality and tests remain intact.
3. Applications can start and stop routers through a Weberl API.
4. Router startup launches a Roadrunner listener through the adapter.
5. Roadrunner-specific code is isolated from framework-level code.
6. Incoming HTTP requests dispatch to the correct view/handler modules.
7. The framework exposes its own request and response interface.
8. Static filesystem and declarative routes both work.
9. `.weberl` templates are discovered and associated with view modules.
10. Templates support literal HTML, escaped interpolation, and explicit raw interpolation.
11. Templates are parsed or compiled once and reused across requests.
12. A view can render its associated template through a documented API.
13. A running example application serves rendered HTML over HTTP.
14. Invalid configuration, templates, and handler results produce meaningful errors.
15. All automated tests pass on Erlang/OTP 29.
16. The README documents architecture, configuration, handlers, templates, and running the example.

---

## 15. Implementation sequence

Implement in the following order.

### Phase A — Reorganization

Move the existing routing subsystem into `src/router/`.

Run regression tests.

Do not proceed until existing functionality is preserved.

### Phase B — Handler API

Implement the Weberl request, response, and dispatch contracts.

Test without starting a network listener.

### Phase C — Roadrunner adapter

Implement the adapter behaviour and Roadrunner integration.

Test listener startup, dispatch, and shutdown.

### Phase D — Template engine

Implement the template lexer, parser, validation, compilation, and rendering.

Test independently of HTTP.

### Phase E — Integration

Connect view rendering, handlers, router startup, and Roadrunner.

Create the example application.

### Phase F — Verification

Run unit tests and targeted integration tests.

Document known limitations and future extension points.

---

## 16. Instructions for the implementation agent

Before modifying the codebase:

1. Inspect the existing Weberl implementation and test suite.
2. Identify the current public APIs and native-record definitions.
3. Inspect the installed Roadrunner version and its actual listener/handler contracts.
4. Verify the existing Erlang/OTP 29 build configuration.
5. Present a concise implementation plan and module dependency structure.

Preserve working code and existing public behavior.

Do not invent Roadrunner APIs or assume compatibility without inspecting the dependency.

Prefer idiomatic Erlang/OTP and native records for public framework structures.

Avoid unnecessary dependencies and abstractions.

After implementation, provide:

- Summary of changes.
- Final module/directory structure.
- Public API examples.
- Tests executed and results.
- Known limitations.
- Deferred features.
- Any deviations from this specification.

**Primary success condition:** A consuming Erlang application can declare routes, start Weberl through the Roadrunner adapter, dispatch HTTP requests to Erlang view modules, and render HTML from associated `.weberl` templates without depending on Roadrunner-specific APIs in application code.
