<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

Finite state machines as plain values: build a `Machine` in code or `load` it
from TOML, YAML or JSON, `check` it for unreachable states and dead ends,
`fire` events with guards and enter / leave hooks, and draw it as Mermaid or
Graphviz. Pure computation with no I/O, so the deck needs no capability and
runs on `jennifer-tiny`.

Out of scope:

- **Storing the current state.** The state is a string the caller keeps in a
  variable, a database column or a JSON field; the deck never holds it.
- **Hierarchical or parallel states** (statecharts), history states and
  timers. A flat machine covers order life cycles, workflows and protocol
  states; anything richer is a different library.
- **Running hooks asynchronously.** Guards and hooks are ordinary function
  calls inside `fire`.

## Decisions

- **The machine is a definition, not an instance.** `Machine` holds states,
  final states, transitions and hooks. `fire` takes the machine, the current
  state, an event and a context map, and returns a `Step` whose `target` is
  the next state. Every builder takes and returns the machine
  (`$m = fsm.addStates($m, ...)`), as values are copied in Jennifer.
- **Lookups are indexed.** The machine keeps two derived indexes, the
  outgoing events per state and the transitions per state and event, so
  `fire`, `can` and `events` do not scan every transition. Only the builders
  write them.
- **First match wins.** Candidates for a state and event are tried in the
  order they were added: the first unguarded one, or the first whose guard
  returns true. A transition added after an unguarded one for the same state
  and event could never fire, so the builder refuses it.
- **Hooks run in a fixed order**: the source's leave hook, then the target's
  enter hook, each receiving the context the previous returned. A
  self-transition runs both.
- **Guards and hooks are top-level functions** of the caller, taking one
  `Step`. A guard returns `bool`; a hook returns the context map. They may
  run several times per call (`can`, `events` and `fire` each run guards),
  so they should only read the `Step`.
- **`check` ignores guards.** It walks the graph from the initial state and
  reports `unreachable` states, `dead-end` states (not final, no exit) and
  `final-exit` states (final, but with an exit), in state order.
- **Names are restricted** to letters, digits, `_`, `.` and `-` (not starting
  with `.` or `-`), at most `MAX_NAME` (100) characters. They go into
  diagrams and messages as they are, so `mermaid` and `dot` need no escaping.
- **One reader for three formats.** `load` turns TOML, YAML and JSON into
  one document form and reads only that, so the three agree by construction.
  JSON is decoded and re-encoded first, so only strict JSON is accepted. A
  document may list the initial state among its states or not.
- **Functions come only from the caller.** A document names guards and
  hooks; `load` looks them up in the `funcs` map it is given, so a document
  cannot reach any other function.
- **Unknown keys are refused** in documents: a misspelt `gaurd` would
  otherwise silently drop a guard.
- **A wrong result is told by position, not text.** A guard's or hook's
  result is assigned to a typed local inside `try`. A result of the wrong
  type is a runtime error positioned in this module's file; a fault inside
  the guard or hook is positioned in the caller's file, since guards and
  hooks are the caller's top-level functions. The deck compares the error's
  `file` with its own (found once at load by failing on purpose) and never
  reads the message. Jennifer has no untyped local and no `any` parameter,
  so the value cannot be held first and checked with `convert.typeOf`;
  calling the function twice (once to check, once to use) would run a hook's
  side effects twice.
- **Calling a function value copies its arguments**, so the guard loop
  receives the candidate list rather than the whole machine. Keep that split
  when changing `fire`.

## Errors

Every failure of the deck is `Error{kind: "fsm"}` (`ERROR_KIND`) with a
message starting `fsm: `. Errors from `load` name the place in the document
as a JSON pointer (`fsm: load: /transitions/2/to: ...`). A guard that does
not return a `bool`, or a hook that does not return the context map, becomes
an `"fsm"` error naming the function. Anything a guard or hook throws passes
through unchanged.

A document past a cap (`MAX_STATES`, `MAX_EDGES`, or the decoder's nesting
and node caps) is the generic `Error{kind: "limit"}` (since 0.2.0); every
other decoder error is rewrapped into `"fsm"` with the place in the
document.

## Security and limits

Machines built in code have no limit. Documents given to `load` are treated
as hostile:

- `MAX_STATES` and `MAX_EDGES` (10,000 each) cap the lists, because YAML
  aliases can expand a few bytes into huge lists.
- Unknown keys are refused, and functions are reachable only through the
  caller's `funcs` map.
- TOML floats and date-times are refused as values; names must match the
  name rule.

## Testing and validation

- One overlay with inline fixtures: the same machine as TOML, YAML and JSON,
  each loaded and compared for equality with the machine built in code.
- An alias-expansion document hits `MAX_EDGES`; a state with many events
  checks the indexes directly; wrong guard and hook results check the
  messages naming the function.
- The example runs in CI (no input, no network).

## Known limitations and open questions

- A guard or hook defined in this module's own file could not be told
  apart from a wrong result; guards and hooks are the caller's functions, so
  this does not arise in use.
- Every public call copies the machine; the cost is described in
  [Running machines](running.md).

## Dependencies on the interpreter

Floor `>=0.26.0` for `jennifer` and `jennifer-tiny`, no capability. It uses
`toml`, `yaml`, `json`, `regex` and the collection libraries, all in the tiny
build. M28.68 (decoder caps throw `"limit"`) changes what `load` receives from
the decoders, but `load` rewraps it, so the deck's behaviour is unchanged.
