<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# fsm cheatsheet

Every export of `@deckyard/fsm`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/fsm/" as fsm;
```

Every failure is `Error{kind: "fsm"}`; errors a guard or hook throws pass
through unchanged. An `m` argument is a `Machine`. A `ctx` argument is a
`map of string to string`, `{}` when there is none.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"fsm"` | the `kind` of every error the deck throws |
| `MAX_NAME` | `100` | the longest machine, state or event name |
| `MAX_EDGES` | `10000` | the most transition sources `load` accepts, summed over all transitions |
| `MAX_STATES` | `10000` | the most entries `load` accepts in `states` and in `final` |

## Types

### `Machine`

| Field | Meaning |
|---|---|
| `name as string` | the machine's name, in messages and diagrams |
| `initial as string` | the state a new instance starts in |
| `states as list of string` | every state, in the order added |
| `finals as list of string` | the final states |
| `transitions as list of Transition` | in the order added |
| `enter as map of string to func` | enter hooks by state |
| `leave as map of string to func` | leave hooks by state |
| `exits as map of string to list of string` | each state's outgoing events; kept by the deck |
| `routes as map of string to list of int` | `"<state> <event>"` to its transitions; kept by the deck |

### `Transition`

| Field | Meaning |
|---|---|
| `event as string` | the event that takes it |
| `sources as list of string` | the states it leaves from |
| `target as string` | the state it enters |
| `guard as func` | the guard; the null function when there is none |

### `Step`

| Field | Meaning |
|---|---|
| `event as string` | the event fired |
| `source as string` | the state left |
| `target as string` | the state entered |
| `ctx as map of string to string` | the context; after `fire`, as the hooks returned it |

### `Problem`

| Field | Meaning |
|---|---|
| `kind as string` | `"unreachable"`, `"dead-end"` or `"final-exit"` |
| `state as string` | the state it is about |
| `message as string` | what is wrong |

## Defining

| Function | Returns | Does |
|---|---|---|
| `fsm.machine(name, initial)` | `Machine` | a machine with one state |
| `fsm.addStates(m, names)` | `Machine` | add states |
| `fsm.addFinals(m, names)` | `Machine` | mark states final |
| `fsm.addTransition(m, event, sources, target)` | `Machine` | add a transition |
| `fsm.addGuarded(m, event, sources, target, guard)` | `Machine` | add a transition taken when `guard(step)` is true |
| `fsm.onEnter(m, state, hook)` | `Machine` | run `hook(step)` on entering a state |
| `fsm.onLeave(m, state, hook)` | `Machine` | run `hook(step)` on leaving a state |
| `fsm.load(text, format, funcs)` | `Machine` | read a machine from `"toml"`, `"yaml"` or `"json"`; `funcs` maps the names it uses to functions |
| `fsm.check(m)` | `list of Problem` | unreachable states, dead ends, final states with exits |

## Running

| Function | Returns | Does |
|---|---|---|
| `fsm.fire(m, state, event, ctx)` | `Step` | take the transition, run the hooks |
| `fsm.can(m, state, event, ctx)` | `bool` | whether `fire` would succeed; runs guards, not hooks |
| `fsm.events(m, state, ctx)` | `list of string` | the events that can be fired now |
| `fsm.isState(m, state)` | `bool` | whether a string is a state |
| `fsm.isFinal(m, state)` | `bool` | whether a state is final |

## Drawing

| Function | Returns | Does |
|---|---|---|
| `fsm.mermaid(m)` | `string` | a Mermaid `stateDiagram-v2` |
| `fsm.dot(m)` | `string` | a Graphviz digraph |
