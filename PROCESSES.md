# Long-Running Process Patterns (gen_statem)

> **Weberl note**: imported unchanged (below this note) from the Agentic project
> as the convention for long-running processes. Weberl uses `gen_statem` in
> `handle_event_function` mode, a record for state data, and `child_spec`/
> `start_link` as the supervision interface. `weberl_router_server` follows it
> (one locally registered process per router; startup stays in `init/1` so
> `start_link/3` can return structured errors). References to `statems/`,
> users, projects and `repo:` are Agentic examples and do not exist in weberl.

> **Purpose**: Canonical patterns for modeling long-running processes in Agentic using `gen_statem`. Use this file whenever implementing stateful, long-lived processes that require explicit state management, timeouts, or complex transitions.

---

## Table of Contents

1. [Registration Strategies](#registration-strategies)
2. [Process Lifecycle](#process-lifecycle)
3. [Interaction Patterns](#interaction-patterns)
4. [Directory Structure](#directory-structure)
5. [Complete Examples](#complete-examples)
   - [Global Process (User/Project)](#global-process-userproject)
   - [Local Process (Agent Manager)](#local-process-agent-manager)
6. [Best Practices](#best-practices)

---

## Registration Strategies

Choose based on **process scope** and **distribution requirements**:

### Global Registration (`{global, Name}`)
- **Use when**: Process must be unique across the entire cluster
- **Use when**: Process must be accessible from any node
- **Examples**: User sessions, Project state (one per user/project)
- **Pros**: Single instance guarantee, cluster-wide access
- **Cons**: Slightly higher overhead

### Local Registration (`{local, Name}`)
- **Use when**: Process is scoped to a single node
- **Use when**: Process represents node-level state
- **Examples**: Agent managers, local caches, node-specific services
- **Pros**: Lower overhead, node-isolated
- **Cons**: Must be started on each node

### No Registration (Pid-only)
- **Use when**: Process is managed by a supervisor that tracks pids
- **Use when**: Process is only accessed via the supervisor
- **Examples**: Worker pools, temporary processes
- **Pros**: Simplest, fastest
- **Cons**: No direct lookup capability

---

## Process Lifecycle

Process start strategy depends on **two dimensions**:

### Dimension 1: Scope (Who can access it?)
- **Cluster-wide**: Use `{global, Name}` registration
- **Node-local**: Use `{local, Name}` registration  
- **Supervised**: Use supervisor-managed (no direct registration)

### Dimension 2: Startup (When does it start?)
- **On-demand**: Started via `interact/2` or `cast/2` when first accessed
- **Application start**: Started via supervision tree at app startup

| Pattern | Scope | Startup | Registration | Use Case |
|---------|-------|---------|--------------|----------|
| Global On-Demand | Cluster-wide | On first access | `{global, Name}` | User sessions, Project state |
| Global Supervised | Cluster-wide | App startup | `{global, Name}` | Critical singleton services |
| Local On-Demand | Node-local | On first access | `{local, Name}` | Node-specific managers |
| Local Supervised | Node-local | App startup | `{local, Name}` | Node services |
| Supervised Worker | N/A | App startup | Pid-only | Worker pools |

---

## Interaction Patterns

Core interaction functions. The naming and exact implementation **can vary** based on the process type:

```erlang
%% For globally registered processes (User, Project)
-spec statem_name(id()) -> {atom(), id()}.
statem_name(Id) ->
    {user, Id}.  % or {project, Id}, etc.

-spec statem_global_name(id()) -> {global, {atom(), id()}}.
statem_global_name(Id) ->
    {global, statem_name(Id)}.

-spec whereis(id()) -> pid() | undefined.
whereis(Id) ->
    global:whereis_name(statem_name(Id)).

%% For locally registered processes (Agent Manager)
-spec whereis_local() -> pid() | undefined.
whereis_local() ->
    local:whereis_name(?MODULE).

%% Generic interaction - can use either registration strategy
-spec interact(id(), term()) -> {ok, term()} | {error, term()}.
interact(Id, Command) ->
    case whereis(Id) of
        undefined ->
            case start_link(Id) of
                {ok, Pid} -> gen_statem:call(Pid, Command);
                Error -> Error
            end;
        Pid -> gen_statem:call(Pid, Command)
    end.

-spec cast(id(), term()) -> ok.
cast(Id, Command) ->
    case whereis(Id) of
        undefined ->
            case start_link(Id) of
                {ok, Pid} -> gen_statem:cast(Pid, Command);
                _ -> ok
            end;
        Pid -> gen_statem:cast(Pid, Command)
    end.

-spec turn_off(id()) -> true.
turn_off(Id) ->
    case whereis(Id) of
        Pid when is_pid(Pid) -> exit(Pid, shutdown);
        _ -> true
    end.
```

---

## Directory Structure

```
statems/
├── user.erl              # Global process: one per user
├── project.erl           # Global process: one per project
├── user/
│   └── ...               # Delegated handlers (if needed)
├── project/
│   └── ...               # Delegated handlers (if needed)
└── agent_manager.erl     # Local process: one per node
```

---

## Complete Examples

### Global Process (User/Project)

**Use case**: One process per entity across the entire cluster.

#### statems/project.erl

```erlang
-module(statems_project).
-behaviour(gen_statem).

%% Public API - these are the only functions external modules should call
-export([
    get/2,
    create_node/2,
    create_attachment/2,
    statem_name/1,
    statem_global_name/1,
    whereis/1,
    interact/2
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    terminate/2
]).

%% Types
-type project_id() :: binary().
-type project_identifier() :: project_id() | #project{}).
-type state_name() :: loading | ready.

%% State record
-record(state, {
    id :: project_id(),
    title :: binary(),
    project :: #project{},
    mappings :: map(),
    timeout :: integer()
}).

%% ============================================================================
%% Public API
%% ============================================================================

statem_name(Id) ->
    {project, Id}.

statem_global_name(Id) ->
    {global, statem_name(Id)}.

whereis(Id) ->
    global:whereis_name(statem_name(Id)).

%% @doc Get project state. Tagged dispatch to handle in gen_statem.
get(ProjectId, UserId) ->
    interact(ProjectId, {dispatch, ?MODULE, {get, UserId}}).

%% @doc Create a node in the project. Delegated to modules/Nodes.
create_node(ProjectId, CreateRequest) ->
    interact(ProjectId, {dispatch, statems_modules_nodes, {create, CreateRequest}}).

create_attachment(ProjectId, CreateRequest) ->
    interact(ProjectId, {dispatch, statems_modules_attachments, {create, CreateRequest}}).

interact(Id, Command) ->
    case whereis(Id) of
        undefined ->
            case start_link(Id) of
                {ok, Pid} -> gen_statem:call(Pid, Command);
                Error -> Error
            end;
        Pid -> gen_statem:call(Pid, Command)
    end.

start_link(ProjectId) ->
    Name = statem_global_name(ProjectId),
    case gen_statem:start_link(Name, ?MODULE, ProjectId, []) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> 
            erlang:link(Pid), {ok, Pid};
        Error -> Error
    end.

%% ============================================================================
%% gen_statem Callbacks
%% ============================================================================

callback_mode() ->
    handle_event_function.

init(ProjectId) when is_binary(ProjectId) ->
    case repo:get(project, ProjectId) of
        #project{} = Project ->
            Timeout = get_timeout(),
            {ok, loading, #state{id=ProjectId, title=Project#project.title, 
                                  project=Project, timeout=Timeout},
             [internal(first_load)]};
        _ ->
            {stop, invalid}
    end.

handle_event(internal, first_load, loading, State=#state{id=ProjectId}) ->
    Nodes = contexts_projects:get_project_nodes(ProjectId),
    Mapping = create_mapping(Nodes, #{-top_level => [], hierarchy => [], ...}),
    Hierarchy = build_hierarchy(Mapping),
    NewState = State#state{mappings=Mapping#{"hierarchy" => Hierarchy}},
    {next_state, ready, NewState, [Timeout]};

handle_event({call, From}, {dispatch, Module, Payload}, StateName, State) ->
    Module:handle_event({call, From}, Payload, StateName, State);

handle_event({call, From}, {get, UserId}, ready, State=#state{project=#project{user_id=UserId}}) ->
    {keep_state, [{reply, From, {ok, State}}]};

handle_event({call, From}, {get, _}, _StateName, _State) ->
    {keep_state, [{reply, From, {error, loading}}]};

handle_event(timeout, _Timeout, _StateName, _State) ->
    {stop, normal}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Helper Functions (not exported)
%% ============================================================================
get_timeout() -> ...
create_mapping(Nodes, Base) -> ...
build_hierarchy(Mapping) -> ...
```

### Local Process (Agent Manager)

**Use case**: One process per node, locally registered.

#### statems/agent_manager.erl

```erlang
-module(statems_agent_manager).
-behaviour(gen_statem).

%% Public API - only these are exported
-export([
    get_agents/0,
    get_task_model/1,
    refresh/0,
    start_link/1,
    child_spec/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    terminate/2
]).

%% Types
-type state() :: #state{}.  
-type agent_type() :: atom().

%% State record
-record(state, {
    agents :: #{agent_type() => #agent{}} | map(),
    load_sequence :: [agent_type()]
}).

%% ============================================================================
%% Public API
%% ============================================================================

get_agents() ->
    gen_statem:call(?MODULE, get_agents).

get_task_model(Task) ->
    Agents = get_agents(),
    prepare_task_model(Task, Agents).

refresh() ->
    gen_statem:call(?MODULE, refresh).

%% ============================================================================
%% SupervisionIntegration
%% ============================================================================

child_spec(_) ->
    #{id => ?MODULE, start => {?MODULE, start_link, [#state{load_sequence = get_load_sequence()}]}, type => worker}.

start_link(State) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, State, []).

%% ============================================================================
%% gen_statem Callbacks
%% ============================================================================

callback_mode() ->
    handle_event_function.

init(State=#state{load_sequence=LoadSequence}) ->
    {ok, loading, State, [internal({load, LoadSequence})]}.

%% Loading sequence handlers
handle_event(internal, {load, [Current | Remaining]}, _StateName, State) ->
    case load_agent(Current, State) of
        {ok, NewState, Events} ->
            {keep_state, NewState, [internal({load, Remaining}) | Events]}
    end;

handle_event(internal, {load, []}, _StateName, State) ->
    {next_state, model_loading, State, [internal({model_load, State#state.load_sequence})]};

%% Model loading handlers  
handle_event(internal, {model_load, [Current | Remaining]}, _StateName, State) ->
    case load_model(Current, State) of
        {ok, NewState, Events} ->
            {keep_state, NewState, [internal({model_load, Remaining}) | Events]};
        {stop, Reason} ->
            {stop, Reason}
    end;

handle_event(internal, {model_load, []}, _StateName, State) ->
    {next_state, on, State, []};

%% API handlers
handle_event({call, From}, get_agents, _StateName, State=#state{agents=Agents}) ->
    {keep_state, [{reply, From, Agents}]};

handle_event({call, From}, refresh, on, State) ->
    {next_state, loading, State, [{reply, From, ok}, internal({load, State#state.load_sequence})]};

handle_event({call, From}, refresh, _StateName, _State) ->
    {keep_state, [{reply, From, ok}]}.

terminate(_Reason, _State) ->
    ok.

%% ============================================================================
%% Helper Functions (not exported)
%% ============================================================================
get_load_sequence() -> ...
load_agent(AgentType, State) -> ...
load_model(ModelType, State) -> ...
prepare_task_model(Task, Agents) -> ...
```

---

## Delegation Pattern

For complex statems, delegate to specialized modules:

### Main Module (statems/project.erl)

```erlang
-module(statems_project).
-behaviour(gen_statem).

-export([
    interact/2,
    create_node/2,
    create_attachment/2
    % ... other API functions
]).

-export([init/1, callback_mode/0, handle_event/4, terminate/2]).

%% In handle_event/4, delegate based on dispatch tag:
handle_event({call, From}, {dispatch, Module, Payload}, StateName, State) ->
    Module:handle_event({call, From}, Payload, StateName, State);

handle_event(cast, {dispatch, Module, Payload}, StateName, State) ->
    Module:handle_event(cast, Payload, StateName, State).
```

### Submodule (statems/modules/nodes.erl)

```erlang
-module(statems_modules_nodes).
-export([handle_event/4]).

handle_event({call, From}, {create, Request}, StateName, State) ->
    ...

handle_event(cast, Payload, StateName, State) ->
    ...
```

**Directory structure**:
```
statems/
├── project.erl
└── modules/
    ├── nodes.erl
    └── attachments.erl
```

---

## Best Practices

### 1. **Registration Choice**
- **Global** for unique cluster-wide entities (User, Project)
- **Local** for node-specific services (Agent Manager, caches)
- **No registration** for supervised worker pools

### 2. **Startup Strategy**
- **On-demand** for processes accessed sporadically
- **Supervised** for always-available services

### 3. **State Management**
- Use **records** for state data (better performance, dialyzer support)
- Keep state **immutable** - always return new record with updates
- Use **atoms for state names**: `loading`, `ready`, `on`

### 4. **Error Handling**
- Return `{error, Reason}` tuples (not exceptions)
- Catch process exits in `interact/2`:
  ```erlang
  interact(Id, Command) ->
      try
          do_interact(Id, Command)
      catch
          exit:{non_existing_process, _} -> {error, non_existing}
      end.
  ```

### 5. **Timeouts**
- Always set **idle timeouts** to prevent memory leaks
- Use environment-aware values:
  ```erlang
  get_timeout() ->
      case application:get_env(agentic, env) of
          dev -> 3600000;  % 1 hour
          _ -> 900000    % 15 minutes
      end.
  ```

### 6. **Convenience API**
- Export specific functions for common operations:
  ```erlang
  get_user(UserId) -> interact(UserId, {account, get}).
  create_node(ProjectId, Request) -> interact(ProjectId, {dispatch, nodes, {create, Request}}).
  ```

### 7. **Formatting**
- Use consistent tagging: `{module, action}` or `{dispatch, Module, Action}`
- Group related API functions together
- Document with `@doc` and `-spec`

---

## Quick Reference

| Task | Function | Global | Local | Supervised |
|------|----------|--------|-------|-----------|
| Start process | `start_link/1` | ✓ | ✓ | ✓ |
| Find process | `whereis/1` | global | local | N/A |
| Sync call | `interact/2` | ✓ | ✓ | ✓ |
| Async call | `cast/2` | ✓ | ✓ | ✓ |
| Stop | `turn_off/1` or exit | ✓ | ✓ | ✓ |
| Registration | `{global, Name}` or `{local, Name}` | global | local | either |

---

## When to Use This Guide

Refer to this file when:
- Implementing a new `gen_statem` process
- Choosing between global and local registration
- Designing the interaction API for a long-running process
- Deciding on startup strategy (on-demand vs supervised)
- Structuring complex statems with multiple concerns

See `AGENTS.md` for the complete project guidelines.
