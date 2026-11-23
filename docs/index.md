<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/fsm

Finite state machines: an order that goes from draft to review to approved,
a ticket, a deployment, a document's life cycle. The deck holds the
definition, refuses transitions it does not allow, runs guards and hooks,
finds flaws in the definition and draws it.

Running one is the easy part. What the deck adds is that a misspelt state or
an impossible transition fails when the machine is built, not when an
order gets stuck in production, and that the diagram in the docs comes from
the same definition as the code.

## Conventions

Snippets assume this import and machine:

```jennifer
import "@deckyard/fsm/" as fsm;

def m as fsm.Machine init fsm.machine("order", "draft");
$m = fsm.addStates($m, ["review", "approved", "rejected"]);
$m = fsm.addFinals($m, ["approved", "rejected"]);
$m = fsm.addTransition($m, "submit", ["draft"], "review");
$m = fsm.addTransition($m, "approve", ["review"], "approved");
$m = fsm.addTransition($m, "reject", ["review"], "rejected");
```

A `Machine` is a value, like every Jennifer struct: each `add*` returns a new
one. The current state is not part of it. It is a string the caller keeps,
where it already keeps the order: a field, a database column, a JSON
document. `fire` takes the state and an event and says where to go next:

```jennifer
def s as fsm.Step init fsm.fire($m, "draft", "submit", {});
io.printf("%s\n", $s.target);   # review
```

Names of machines, states and events are letters, digits, `_`, `.` and `-`,
starting with a letter, digit or `_`, at most 100 characters.

## Errors

Every failure of the deck is `Error{kind: "fsm"}`:

- a definition the deck refuses, when it is built:
  `fsm: order: not a state: "reveiw"`;
- an event the state does not allow:
  `fsm: order: no "approve" transition from draft`;
- a guard that said no: `fsm: order: "approve" from review refused by its guard`;
- a document `load` cannot use, with the place in it:
  `fsm: load: /transitions/2/to: expected a string, found int`;
- a guard or hook that returned the wrong thing:
  `fsm: order: the guard (isManager) must return a bool`,
  `fsm: order: the enter hook of approved (stamp) must return the context map`
  (the name in brackets is left out when the interpreter does not give one).

A document past a cap in `load` (`MAX_STATES`, `MAX_EDGES`, or the decoder's
nesting and node caps) is the generic `Error{kind: "limit"}` instead, as in
every library. An error a guard or hook throws reaches the caller unchanged,
a runtime fault inside it included: the deck tells a wrong result from such a
fault by where the error happened, not by its text.

## Requirements

Jennifer 0.27.0 or newer, `jennifer` or `jennifer-tiny`. No capabilities.
