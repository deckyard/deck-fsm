<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Defining machines

## States and transitions

`machine` starts a machine with its initial state; `addStates` adds the
rest. States must exist before anything refers to them, so a misspelt name
fails at once instead of creating a state nobody can reach.

```jennifer
def m as fsm.Machine init fsm.machine("order", "draft");
$m = fsm.addStates($m, ["review", "approved", "rejected", "cancelled"]);
$m = fsm.addFinals($m, ["approved", "rejected", "cancelled"]);
$m = fsm.addTransition($m, "submit", ["draft"], "review");
$m = fsm.addTransition($m, "edit", ["review"], "draft");
$m = fsm.addTransition($m, "cancel", ["draft", "review"], "cancelled");
```

A transition leaves from one or more states. For an event that every state
allows, pass `$m.states`.

## Guards

A guard decides whether a transition may be taken. It is a top-level
function taking a `Step` and returning `bool`; it sees the event, both states
and the context the caller passed to `fire`:

```jennifer
func isManager(s as fsm.Step) {
    return maps.has($s.ctx, "role") and $s.ctx["role"] == "manager";
}

$m = fsm.addGuarded($m, "approve", ["review"], "approved", isManager);
```

Jennifer has no closures, so a guard cannot capture variables: whatever it
needs goes in the context.

One event may have several transitions from a state. They are tried in the
order added and the first whose guard passes is taken, so an unguarded one
can come last as the fallback:

```jennifer
$m = fsm.addGuarded($m, "triage", ["open"], "escalated", isUrgent);
$m = fsm.addTransition($m, "triage", ["open"], "queued");
```

The reverse order is refused when it is built: after an unguarded
transition, a later one for the same event and state could never be taken.

## Hooks

`onEnter` and `onLeave` run a function when a state is entered or left. A
hook takes the `Step` and returns the context, changed or not; `fire` passes
it on and returns it in the `Step`:

```jennifer
func stamp(s as fsm.Step) {
    def c as map of string to string init $s.ctx;
    $c["approvedBy"] = $c["user"];
    return $c;
}

$m = fsm.onEnter($m, "approved", stamp);
```

A hook that has nothing to change returns `$s.ctx`. Each state has at most
one hook of each kind.

## Checking a definition

`check` reports what is legal but almost certainly wrong. Guards are not
run, so it reports what no context could fix:

| `kind` | means |
|---|---|
| `unreachable` | no path from the initial state leads here |
| `dead-end` | not final, but no transition leaves it: whatever gets here is stuck |
| `final-exit` | final, yet transitions leave it |

```jennifer
for (def p in fsm.check($m)) {
    io.printf("%s\n", $p.message);
}
```

A machine without final states, such as a traffic light, is fine. Run
`check` in a test, so a broken definition fails the build.

## Loading from a file

`load` reads a machine from TOML, YAML or JSON. Guards and hooks are named
in the document; the caller passes the functions it allows under those
names, so a document cannot reach any other function:

```toml
name = "order"
initial = "draft"
states = ["draft", "review", "approved", "rejected"]
final = ["approved", "rejected"]

[[transitions]]
event = "submit"
from = "draft"
to = "review"

[[transitions]]
event = "approve"
from = ["review"]
to = "approved"
guard = "isManager"

[enter]
approved = "stamp"
```

```jennifer
def m as fsm.Machine init fsm.load(fs.readString("order.toml"), "toml", {
    "isManager": isManager,
    "stamp": stamp
});
```

The map names functions as values, and only a function of the current file
can be written that way: `orders.isManager` is not a value outside the
`orders` module. When the guards and hooks live in a module, let that module
build the map (an exported `functions()` returning it) and pass the result to
`fsm.load`.

| Key | Holds |
|---|---|
| `name`, `initial` | strings, required |
| `states` | the states; the initial one may be listed or not |
| `final` | the final states |
| `transitions` | a list, required; each with `event`, `from` (a state or a list), `to`, and optionally `guard` |
| `enter`, `leave` | maps from a state to a function name |

The machine is built with the functions above, so it is refused for the
same reasons. Unknown keys are refused too: a misspelt `gaurd` would
otherwise drop the guard without a word. Messages give the place:
`fsm: load: /transitions/1: unknown key "gaurd"`.

A document may hold at most `MAX_STATES` (10000) states and final states,
and its transitions at most `MAX_EDGES` (10000) source states in all. YAML
aliases let a few bytes repeat a long list, so without a limit a small
document could build a huge machine. Past either cap, and past the decoder's
own nesting and node caps, `load` throws `Error{kind: "limit"}`. Machines
built in code have no limit.

YAML follows version 1.2: `on`, `off`, `yes` and `no` are strings, but a
state named `1` or `007` must be quoted. JSON must be strict JSON.

## Drawing

`mermaid` and `dot` draw the machine. Guarded transitions show the guard's
name in brackets:

```jennifer
fs.writeString("docs/order.mmd", fsm.mermaid($m));
fs.writeString("order.dot", fsm.dot($m));   # dot -Tsvg order.dot > order.svg
```

```text
stateDiagram-v2
    state "draft" as s0
    state "review" as s1
    state "approved" as s2
    [*] --> s0
    s0 --> s1 : submit
    s1 --> s2 : approve [isManager]
    s2 --> [*]
```
