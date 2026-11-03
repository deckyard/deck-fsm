# @deckyard/fsm

[![test](https://github.com/deckyard/deck-fsm/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-fsm/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-fsm/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-fsm)](https://github.com/deckyard/deck-fsm/releases/latest)

Finite state machines for [Jennifer](https://jennifer-lang.dev/): define
states and transitions, fire events with guards and enter and leave hooks,
and keep the current state wherever the program already keeps its data. A
misspelt state or a transition that could never be taken fails when the
machine is built; `check` finds unreachable states and dead ends. Machines
load from TOML, YAML or JSON and draw as Mermaid or Graphviz.

**[Documentation](https://deckyard.github.io/deck-fsm/)**

## Install

```sh
jvc add @deckyard/fsm
```

This vendors the deck to `vendor/<scope>/fsm/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-fsm-<version>.tar.gz`) there.

## Usage

```jennifer
import "@deckyard/fsm/" as fsm;

def m as fsm.Machine init fsm.machine("door", "closed");
$m = fsm.addStates($m, ["open", "locked"]);
$m = fsm.addTransition($m, "open", ["closed"], "open");
$m = fsm.addTransition($m, "close", ["open"], "closed");
$m = fsm.addTransition($m, "lock", ["closed"], "locked");
$m = fsm.addTransition($m, "unlock", ["locked"], "closed");

def state as string init "closed";
$state = fsm.fire($m, $state, "lock", {}).target;
io.printf("%s, can %v\n", $state, fsm.events($m, $state, {}));   # locked, can ["unlock"]
```

## Requirements

Jennifer 0.25.0 or newer, `jennifer` or `jennifer-tiny`. No capabilities:
the deck is pure computation.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/fsm_test.j         # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
