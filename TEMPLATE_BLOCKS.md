# Template blocks

The block language of Weberl's templates: `{{ Expr }}` interpolation and `{: if :}`, `{: case :}`,
`{: for :}` with **Erlang expressions and patterns**. This document describes the language, what the code
generates, the hooks a host provides, and how another library (a CSS preprocessor, say) can reuse it.
The decisions behind it are in `HANDOFF.md` ("2"); the user-facing description is in the README
("Templates"). Weberl is the first host; `~/code/csserl` (an Erlang port of the CSS preprocessor CSSEx) is the
expected second.

## Status of the boundary

Only part of the machinery is separated from Weberl today. Be exact about it before reusing anything:

| Piece | Where | Independent of Weberl/HTML? |
|---|---|---|
| Expression front end: text to Erlang abstract forms, `@name`, line offsets, free/bound locals, rebinding, `render/2` with hooks | `src/template/blocks/weberl_blocks_expr.erl` | **Yes.** Calls only OTP; a test asserts it imports nothing of Weberl |
| Tag lexing (`{{ }}`, `{: :}`) | `weberl_template_lexer` | No: also knows regions, slots, fills, void HTML elements |
| Block structure (frames for `if`/`case`/`for`, branch rules), scope pass, dependency collection | `weberl_template_parser` | No: interleaved with regions, layouts and the HTML context walker |
| Code generation for `if`/`case`/`for` | `weberl_template_compiler` | No: emitted next to region and wrapper code |
| Value rendering, escaping | `weberl_template_runtime` | No: HTML escaping, the supported value types |

The plan (HANDOFF decision 7) is to move the independent parts of rows 2 to 4 behind host hooks, as
`weberl_blocks_*` modules that call nothing of Weberl, and to extract the whole into its own application when a
second consumer exists. Until then, a second host can use `weberl_blocks_expr` as it is and copy or lift the
block structure, scope and code generation from the three Weberl modules above.

## The language

### Interpolation

`{{ Expr }}` inserts the value of an Erlang expression, escaped by the host; `{{{ Expr }}}` inserts it as
is. The tag ends at the first `}}` (`}}}`) that is not part of the Erlang inside: the text is read like
Erlang (strings, quoted atoms, `$x` character literals and comments are opaque; `( [ { <<` are counted), so
`{{ maps:get(k, #{k => #{j => 1}}) }}` and `{{ f("}}") }}` need no care. An unmatched closing bracket is
`{unbalanced_brace}`, a string that never ends `{unterminated_string}` (both with the line). Expressions may
span lines. A `%` starts an Erlang comment that runs to the end of the line, closing braces included.

### Assigns and locals

* An **assign** is a value the host supplies by name, written **`@name`** (lower case first letter). It is the
  only way to read one: a bare `name` is the atom `name`.
* A **local** is an ordinary Erlang variable (`Name`), bound by the patterns and generators of the enclosing
  blocks. The two namespaces cannot clash.
* `@` is recognised outside strings, quoted atoms, character literals (`$@`) and comments, and not inside an
  atom (`user@host`). `@Upper`, or a lone `@`, is a syntax error.
* Names starting `_Weberl_` are reserved.

### Blocks

```text
{: if Expr :} ... {: elif Expr :} ... {: else :} ... {: /if :}
{: case Expr :}  {: of Pattern [when Guard] :} ...  {: of ... :} ...  {: /case :}
{: for Qualifiers :} ... {: empty :} ... {: /for :}
```

* Keywords are followed by white space; a tag ends at the first `:}` outside the Erlang inside (read as
  for `{{ }}`); closing tags carry no name.
* **`if`**: each condition is exactly `true` or `false`, otherwise `{not_boolean, View, Line, Value}`. No
  truthiness. Only the taken branch is evaluated; no `else` renders nothing.
* **`case`**: Erlang's `case`. Between `case` and the first `of` only white space. No match raises
  `{case_clause, View, Line, Value}` (a trailing `{: of _ :}` opts out). A guard cannot call a function, so the
  assigns the guards read are fetched first (see "Generated code").
* **`for`**: what Erlang allows after `||`: generators (`P <- L`, `K := V <- M`, `<<P>> <= B`) and filters,
  several of them. A generator pattern that does not match skips the element (Erlang's rule). `{: empty :}`
  renders when nothing came out after filtering.
* **Scope**: names bound by a pattern or generator exist in their branch or body only; binding an already bound
  name is an error (`{rebound_variable, Name}`); an unbound local is `{unbound_variable, Name}`.
* Output is literal: nothing is trimmed around tags.

### Facts the front end reports

For every expression, clause head or qualifier list: `assigns` (the dependencies, sorted), `free` (locals used
but not bound by the text itself, which an enclosing block must bind) and `bound` (locals the text binds).
`weberl_blocks_expr:expression/2`, `clause/2` and `qualifiers/2` return them with the forms.

## Generated code

The generator produces Erlang abstract forms; the host decides whether to compile them into a module (Weberl)
or run them (`erl_eval:expr/2` with bindings: no module, suited to a one-shot job).

| Block | Forms |
|---|---|
| `if` / `elif` / `else` | nested `case Cond of true -> ..; false -> ..; V -> error({template_error, {not_boolean, View, Line, V}}) end` |
| `case` | a native `case` with the clauses as written, plus a last clause raising `{template_error, {case_clause, View, Line, V}}` |
| `for` | a list comprehension `[Body \|\| Qualifiers]`; with `empty`: `case [..] of [] -> Empty; Items -> Items end` |
| `{{ Expr }}` | a call of the host's value renderer on the expression |

The body of a block is an iodata expression (a list of text and rendered parts), so a comprehension yields a list
of them. An assign `@name` becomes whatever the host's `assign` hook returns (Weberl: a call of
`weberl_template_runtime:assign(name, Assigns, View)`, which raises `missing_variable` when absent); locals are
renamed by the `local` hook (Weberl: prefix `W_`) so they cannot clash with the generated code.

**Guards.** An Erlang guard may not call functions, and an assign is a call, so the assigns read by the guards
of a `case` are read first and passed as the arguments of a fun that holds the `case`:
`(fun(W_guard_limit) -> case .. of N when N > W_guard_limit -> .. end end)(Assign(limit))`. A fun keeps the
variable out of the surrounding scope (sibling blocks cannot hit Erlang's "unsafe variable" error). The cost: a
missing guard assign raises even when an earlier clause would have matched.

## Hooks a host provides

| Hook | Weberl's | What a CSS host would do |
|---|---|---|
| `assign(Name, Anno) -> Form` and `local(Name) -> Name'` for `weberl_blocks_expr:render/2` | `weberl_template_runtime:assign/3`; `W_` prefix | read a map of theme variables; any prefix |
| Value rendering of an interpolation | binaries, character lists, integers, floats, atoms; HTML escaping | floats and units, colors, no HTML escaping (or CSS string escaping) |
| Context rules (where a block or interpolation may stand) | `weberl_template_html`: text and quoted attribute values only | none, or a small CSS context (inside a string, a url) |
| Delimiters | `{{ }}`, `{: :}` | the same: `{:` and `:}` do not occur in valid CSS, and `\{:` escapes |
| Host-only constructs | regions, slots, fills, `{: content :}`, layouts, live updates | its own (selector tables, mixins...), or none |

## Using it from a CSS preprocessor

The CSSEx test of `<%= for n <- 1..10, reduce: "" do ... %>` builds a string by code; with blocks the loop body
is the CSS text:

```css
{: for N <- lists:seq(1, 10) :}
.btn-op-{{ N }} { background-color: rgba(255, 0, 0, {{ N / 10 }}); }
{: /for :}
```

Differences from CSSEx to keep in mind: CSSEx evaluates a block at parse time and parses its result again as
CSS, whereas here a template renders to text in one pass (a second stage can still process the result); CSSEx
variables hold any Elixir term and are read as `@name` in blocks, which matches; expressions are Erlang, so
the Elixir-to-Erlang translation problem for blocks disappears. The CSSEx test suite (`test/eex_test.exs` and
others in github mnussbaumer/cssex) is the natural acceptance set for the port.

## Known limits

* A bracket that never closes inside a tag swallows text up to the next closing delimiter that fits (the
  scanner reports `unbalanced_brace` or `unterminated_*` when it can tell); a `%` comment inside a tag hides
  the rest of its line, closing delimiter included.
* An assign inside a guard that is not a `case` clause (for example a `fun` with a guard inside an expression)
  hits Erlang's guard rules; the compile error is Erlang's (`illegal_guard_expr`).
* A map generator iterates in Erlang's map order.
* Blocks stand only in HTML text in Weberl (extension to tags and attributes: `ROADMAP.md`).
* Expressions run on every render and region re-render: they are developer code and have to be pure and cheap.
  An expression that raises propagates from `render/2`; `try_render/2` and `try_render_region/3` (what a live
  page uses) return `{error, {render_failed, Class, Reason}}`.

## Where the tests are

`test/weberl_blocks_expr_tests.erl` (front end, including evaluation with `erl_eval`),
`test/weberl_template_expr_tests.erl` (interpolation), `test/weberl_template_blocks_tests.erl` (blocks, scope,
placement, regions, layouts), `test/weberl_live_blocks_tests.erl` (blocks on a live page).
