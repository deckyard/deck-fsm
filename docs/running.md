<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Running machines

## Firing events

The machine does not hold a current state; the caller does. `fire` takes it
with an event and returns the `Step` taken:

```jennifer
def s as fsm.Step init fsm.fire($m, $order.state, "submit", {"user": "ada"});
$order.state = $s.target;
```

`fire` then:

1. chooses the transition: the first, in the order added, that leaves the
   state on this event and whose guard passes;
2. runs the leave hook of the state left;
3. runs the enter hook of the state entered.

Each hook gets the context the step before returned; the `Step` carries the
last one. A transition from a state back to itself runs both hooks.

`fire` throws when the state is not one of the machine's, when no transition
leaves it on the event, or when every guard refused. The guards it tried may
have run, but no hook has, so the stored state is still right.

## Asking first

`can` says whether `fire` would succeed; `events` lists what can be fired
now, for the buttons a page should show. Both run the guards and no hooks:

```jennifer
if (fsm.can($m, $order.state, "approve", $ctx)) {
    # ...
}
for (def e in fsm.events($m, $order.state, $ctx)) {
    io.printf("[%s] ", $e);
}
```

A guard should only read its `Step`: `can`, `events` and `fire` may each
call it.

## Stored states

A state read back from a database may be from an older definition. Check it
before use:

```jennifer
if (not fsm.isState($m, $row["state"])) {
    # migrate it, or refuse the record
}
if (fsm.isFinal($m, $row["state"])) {
    # closed: nothing more can happen
}
```

## Cost

Every call into a module copies its arguments, so each call copies the
machine, at about 1 microsecond per state and 2 per transition. A machine of 50
transitions fires in about 0.2 ms, one of 1000 in about 2.5 ms; `isState` on a
16-state machine takes 20 microseconds. That suits business workflows, not a
lexer that fires per character. Inside the deck, finding a transition
depends only on how many share the state and event.

Build or load the machine once and keep it; each `add*` call copies it as
well.
