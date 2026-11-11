# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * Finite state machines.
 *
 * A `Machine` is a value: build it with `machine` and the `add*` functions,
 * or `load` it from TOML, YAML or JSON. `check` finds unreachable states and
 * dead ends. The current state is a plain string the caller keeps (in a
 * variable, a database column, a JSON field); `fire` takes it and an event
 * and returns a `Step` naming the next one, after running the guards and the
 * enter and leave hooks. `mermaid` and `dot` draw the machine.
 *
 * Guards and hooks are the caller's own top-level functions, taking one
 * `Step`. A guard returns `bool`; a hook returns the context map, changed or
 * not. Every failure of the deck is `Error{kind: "fsm"}`; errors a guard or
 * hook throws pass through unchanged.
 *
 * @module fsm
 * @example
 *   def m as fsm.Machine init fsm.machine("door", "closed");
 *   $m = fsm.addStates($m, ["open"]);
 *   $m = fsm.addTransition($m, "open", ["closed"], "open");
 *   $m = fsm.addTransition($m, "close", ["open"], "closed");
 *   def s as fsm.Step init fsm.fire($m, "closed", "open", {});
 *   io.printf("%s\n", $s.target);   # open
 */
use convert;
use json;
use lists;
use maps;
use regex;
use strings;
use toml;
use yaml;

/** The `kind` of every error the deck throws. */
export def const ERROR_KIND as string init "fsm";

/** The longest machine, state or event name. */
export def const MAX_NAME as int init 100;

/**
 * The most transition sources `load` accepts, summed over the document's
 * transitions. YAML aliases let a few bytes name a long list of states again
 * and again; past this the document is refused instead of exhausting memory
 * and time. Machines built in code have no limit.
 */
export def const MAX_EDGES as int init 10000;

/** The most entries `load` accepts in a document's `states` and `final`. */
export def const MAX_STATES as int init 10000;

# What a name may hold: it goes into diagrams and error messages unquoted.
def const NAME_PATTERN as string init "^[A-Za-z0-9_][A-Za-z0-9_.-]*$";

# The keys `load` accepts, at the top and in a transition.
def const DOC_KEYS as list of string init [
    "name",
    "initial",
    "states",
    "final",
    "transitions",
    "enter",
    "leave"
];
def const TRANSITION_KEYS as list of string init ["event", "from", "to", "guard"];

/**
 * One transition taken, or about to be: what a guard and a hook receive, and
 * what `fire` returns.
 *
 * @field event {string} the event fired
 * @field source {string} the state left
 * @field target {string} the state entered
 * @field ctx {map of string to string} the caller's context; after `fire`,
 *   as the hooks returned it
 */
export def struct Step {
    event as string,
    source as string,
    target as string,
    ctx as map of string to string
};

/**
 * One transition of a machine.
 *
 * @field event {string} the event that takes it
 * @field sources {list of string} the states it leaves from
 * @field target {string} the state it enters
 * @field guard {func} the guard, a null function when there is none
 */
export def struct Transition {
    event as string,
    sources as list of string,
    target as string,
    guard as func
};

/**
 * A state machine definition. Build it through the deck; reading the fields
 * is fine.
 *
 * @field name {string} the machine's name, in messages and diagrams
 * @field initial {string} the state a new instance starts in
 * @field states {list of string} every state, in the order added
 * @field finals {list of string} the final states
 * @field transitions {list of Transition} in the order added; the first
 *   whose guard passes is taken
 * @field enter {map of string to func} enter hooks by state
 * @field leave {map of string to func} leave hooks by state
 * @field exits {map of string to list of string} every state, mapped to
 *   the events of the transitions leaving it, in the order added; kept by
 *   the deck
 * @field routes {map of string to list of int} `"<state> <event>"`, mapped
 *   to the indexes in `transitions` of the ones that event takes from that
 *   state, in the order added; kept by the deck
 */
export def struct Machine {
    name as string,
    initial as string,
    states as list of string,
    finals as list of string,
    transitions as list of Transition,
    enter as map of string to func,
    leave as map of string to func,
    exits as map of string to list of string,
    routes as map of string to list of int
};

/**
 * A flaw `check` found.
 *
 * @field kind {string} `"unreachable"`, `"dead-end"` or `"final-exit"`
 * @field state {string} the state it is about
 * @field message {string} a sentence saying what is wrong
 */
export def struct Problem {
    kind as string,
    state as string,
    message as string
};

/**
 * Throw the deck's error.
 *
 * @param message {string} what went wrong
 * @throws {Error} always, with `kind` `ERROR_KIND`
 */
func fail(message as string) {
    throw Error{kind: ERROR_KIND, message: "fsm: " + $message};
}

/**
 * Check a machine, state or event name.
 *
 * @param name {string} the name
 * @param what {string} what it names, for the message
 * @return {string} the name
 * @throws {Error} when it is empty, too long or holds other characters than
 *   letters, digits, `_`, `.` and `-` (and a leading `.` or `-`)
 */
func checkName(name as string, what as string) {
    if (len($name) > MAX_NAME) {
        fail("a " + $what + " name is longer than " + convert.toString(MAX_NAME) +
            " characters");
    }
    if (not regex.matches(NAME_PATTERN, $name)) {
        fail("not a valid " + $what + " name: " + json.encode($name));
    }
    return $name;
}

/**
 * Throw unless a name is a state of the machine.
 *
 * @param m {Machine} the machine
 * @param state {string} the name
 */
func known(m as Machine, state as string) {
    if (not maps.has($m.exits, $state)) {
        fail($m.name + ": not a state: " + json.encode($state));
    }
}

/**
 * A list's elements as map keys, for lookups that do not walk the list.
 *
 * @param names {list of string} the elements
 * @return {map of string to bool} each element mapped to true
 */
func setOf(names as list of string) {
    def out as map of string to bool init {};
    for (def name in $names) {
        $out[$name] = true;
    }
    return $out;
}

/**
 * Whether a function value is set.
 *
 * @param f {func} the value
 * @return {bool} false for the null function
 */
func isSet(f as func) {
    def none as func;
    return $f != $none;
}

/**
 * A new machine with one state, its initial one.
 *
 * @param name {string} the machine's name
 * @param initial {string} the initial state
 * @return {Machine} the machine
 * @throws {Error} on an invalid name
 * @example
 *   def m as fsm.Machine init fsm.machine("order", "draft");
 */
export func machine(name as string, initial as string) {
    checkName($name, "machine");
    checkName($initial, "state");
    return Machine{
        name: $name,
        initial: $initial,
        states: [$initial],
        finals: [],
        transitions: [],
        enter: {},
        leave: {},
        exits: {$initial: []},
        routes: {}
    };
}

/**
 * Add states.
 *
 * @param m {Machine} the machine
 * @param names {list of string} the new states
 * @return {Machine} the machine with them
 * @throws {Error} on an invalid name or one that is already a state
 */
export func addStates(m as Machine, names as list of string) {
    for (def name in $names) {
        checkName($name, "state");
        if (maps.has($m.exits, $name)) {
            fail($m.name + ": already a state: " + $name);
        }
        $m.states[] = $name;
        $m.exits[$name] = [];
    }
    return $m;
}

/**
 * Mark states as final. Marking one twice is harmless.
 *
 * @param m {Machine} the machine
 * @param names {list of string} states already added
 * @return {Machine} the machine with them marked
 * @throws {Error} on a name that is not a state
 */
export func addFinals(m as Machine, names as list of string) {
    def marked as map of string to bool init setOf($m.finals);
    for (def name in $names) {
        known($m, $name);
        if (not maps.has($marked, $name)) {
            $m.finals[] = $name;
            $marked[$name] = true;
        }
    }
    return $m;
}

/**
 * Add a transition with no guard.
 *
 * @param m {Machine} the machine
 * @param event {string} the event that takes it
 * @param sources {list of string} the states it leaves from
 * @param target {string} the state it enters
 * @return {Machine} the machine with it
 * @throws {Error} as `addGuarded`
 * @example
 *   $m = fsm.addTransition($m, "cancel", ["draft", "review"], "cancelled");
 */
export func addTransition(
    m as Machine,
    event as string,
    sources as list of string,
    target as string) {
    def none as func;
    $m = addEdge($m, $event, $sources, $target, $none);
    return $m;
}

/**
 * Add a transition taken only when its guard returns true. Transitions for
 * the same event and state are tried in the order added.
 *
 * @param m {Machine} the machine
 * @param event {string} the event that takes it
 * @param sources {list of string} the states it leaves from
 * @param target {string} the state it enters
 * @param guard {func} a top-level function taking a `Step`, returning `bool`
 * @return {Machine} the machine with it
 * @throws {Error} on an invalid name, an unknown state, a repeated source,
 *   a null guard, or when an unguarded transition for the event already
 *   leaves one of the sources (this one could never be taken)
 * @example
 *   func paid(s as fsm.Step) { return $s.ctx["paid"] == "yes"; }
 *   $m = fsm.addGuarded($m, "ship", ["approved"], "shipped", paid);
 */
export func addGuarded(
    m as Machine,
    event as string,
    sources as list of string,
    target as string,
    guard as func) {
    if (not isSet($guard)) {
        fail($m.name + ": " + $event + ": the guard is a null function");
    }
    $m = addEdge($m, $event, $sources, $target, $guard);
    return $m;
}

/**
 * Add a transition, guarded or not.
 *
 * @param m {Machine} the machine
 * @param event {string} the event
 * @param sources {list of string} the states it leaves from
 * @param target {string} the state it enters
 * @param guard {func} the guard, or the null function
 * @return {Machine} the machine with it
 */
func addEdge(
    m as Machine,
    event as string,
    sources as list of string,
    target as string,
    guard as func) {
    checkName($event, "event");
    if (len($sources) == 0) {
        fail($m.name + ": " + $event + ": no source states");
    }
    def seen as map of string to bool init {};
    for (def s in $sources) {
        known($m, $s);
        if (maps.has($seen, $s)) {
            fail($m.name + ": " + $event + ": " + $s + " is listed twice");
        }
        if (hasFallback($m, $s + " " + $event)) {
            fail($m.name + ": " + $event + " from " + $s +
                " already has an unguarded transition; this one could never be taken");
        }
        $seen[$s] = true;
    }
    known($m, $target);
    for (def s in $sources) {
        def key as string init $s + " " + $event;
        if (maps.has($m.routes, $key)) {
            $m.routes[$key][] = len($m.transitions);
        } else {
            $m.exits[$s][] = $event;
            $m.routes[$key] = [len($m.transitions)];
        }
    }
    $m.transitions[] = Transition{event: $event, sources: $sources, target: $target, guard: $guard};
    return $m;
}

/**
 * Whether an unguarded transition for an event already leaves a state. A
 * later one could never be taken. Since nothing is added after it, it can
 * only be the last.
 *
 * @param m {Machine} the machine
 * @param key {string} `"<state> <event>"`
 * @return {bool} whether there is one
 */
func hasFallback(m as Machine, key as string) {
    if (not maps.has($m.routes, $key)) {
        return false;
    }
    def last as int init lists.last($m.routes[$key]);
    return not isSet($m.transitions[$last].guard);
}

/**
 * Run a function when a state is entered, after the transition is chosen.
 * Each state has at most one.
 *
 * @param m {Machine} the machine
 * @param state {string} the state
 * @param hook {func} a top-level function taking a `Step`, returning the
 *   context map
 * @return {Machine} the machine with it
 * @throws {Error} on an unknown state, a null hook or a second hook
 */
export func onEnter(m as Machine, state as string, hook as func) {
    known($m, $state);
    if (not isSet($hook)) {
        fail($m.name + ": the enter hook of " + $state + " is a null function");
    }
    if (maps.has($m.enter, $state)) {
        fail($m.name + ": " + $state + " already has an enter hook");
    }
    $m.enter[$state] = $hook;
    return $m;
}

/**
 * Run a function when a state is left, before the one entered runs its
 * enter hook.
 *
 * @param m {Machine} the machine
 * @param state {string} the state
 * @param hook {func} a top-level function taking a `Step`, returning the
 *   context map
 * @return {Machine} the machine with it
 * @throws {Error} on an unknown state, a null hook or a second hook
 */
export func onLeave(m as Machine, state as string, hook as func) {
    known($m, $state);
    if (not isSet($hook)) {
        fail($m.name + ": the leave hook of " + $state + " is a null function");
    }
    if (maps.has($m.leave, $state)) {
        fail($m.name + ": " + $state + " already has a leave hook");
    }
    $m.leave[$state] = $hook;
    return $m;
}

/**
 * Whether a string is a state of the machine: check a state read back from
 * storage.
 *
 * @param m {Machine} the machine
 * @param state {string} the string
 * @return {bool} whether it is a state
 */
export func isState(m as Machine, state as string) {
    return maps.has($m.exits, $state);
}

/**
 * Whether a state is final.
 *
 * @param m {Machine} the machine
 * @param state {string} the state
 * @return {bool} whether it is final
 * @throws {Error} on an unknown state
 */
export func isFinal(m as Machine, state as string) {
    known($m, $state);
    return lists.contains($m.finals, $state);
}

/**
 * The transitions an event can take from a state, in the order added. It
 * calls no guard, so `m` is borrowed, not copied.
 *
 * @param m {Machine} the machine
 * @param state {string} the current state
 * @param event {string} the event
 * @return {list of Transition} the transitions
 */
func candidates(m as Machine, state as string, event as string) {
    def out as list of Transition init [];
    def key as string init $state + " " + $event;
    if (maps.has($m.routes, $key)) {
        for (def i in $m.routes[$key]) {
            $out[] = $m.transitions[$i];
        }
    }
    return $out;
}

/**
 * The first of the candidates whose guard passes. It takes the candidates,
 * not the machine: a function that calls a function value gets its
 * arguments copied, and a machine can be large.
 *
 * @param cands {list of Transition} from `candidates`
 * @param state {string} the current state
 * @param ctx {map of string to string} the context the guards see
 * @return {int} its index in `cands`; -1 when every guard refused; -2 when
 *   there are no candidates
 */
func choose(cands as list of Transition, state as string, ctx as map of string to string) {
    if (len($cands) == 0) {
        return -2;
    }
    def i as int init 0;
    for (def t in $cands) {
        if (not isSet($t.guard)) {
            return $i;
        }
        def s as Step init Step{event: $t.event, source: $state, target: $t.target, ctx: $ctx};
        if (runGuard($t.guard, $s)) {
            return $i;
        }
        $i = $i + 1;
    }
    return -1;
}

/**
 * Call a guard. A result that is not a `bool` becomes the deck's error, so
 * the message names the guard; anything the guard throws passes through.
 *
 * @param guard {func} the guard
 * @param s {Step} what it decides on
 * @return {bool} its answer
 */
func runGuard(guard as func, s as Step) {
    try {
        def guardAnswer as bool init $guard($s);
        return $guardAnswer;
    } catch (e) {
        if ($e.kind == "runtime" and
            strings.startsWith($e.message, "cannot initialize bool variable \"guardAnswer\"")) {
            fail("the guard " + funcName($guard) + " must return a bool");
        }
        throw $e;
    }
}

/**
 * Call a hook. A result that is not the context map becomes the deck's
 * error, so the message names the hook; anything it throws passes through.
 *
 * @param hook {func} the hook
 * @param s {Step} the step
 * @param what {string} which hook, for the message
 * @return {map of string to string} the context it returned
 */
func runHook(hook as func, s as Step, what as string) {
    try {
        def hookContext as map of string to string init $hook($s);
        return $hookContext;
    } catch (e) {
        if ($e.kind == "runtime" and
            strings.startsWith(
            $e.message,
            "cannot initialize map of string to string variable \"hookContext\"")) {
            fail($what + " (" + funcName($hook) + ") must return the context map");
        }
        throw $e;
    }
}

/**
 * Fire an event: choose the transition, run the leave hook of the state left,
 * then the enter hook of the state entered, each given the context the one
 * before returned. A transition back into the same state runs both.
 *
 * @param m {Machine} the machine
 * @param state {string} the current state
 * @param event {string} the event
 * @param ctx {map of string to string} the context for guards and hooks;
 *   `{}` when there is none
 * @return {Step} the transition taken, with the context the hooks returned
 * @throws {Error} on an unknown state, when the event has no transition from
 *   the state, or when every guard refused it
 * @example
 *   def s as fsm.Step init fsm.fire($m, $order.state, "submit", {});
 *   $order.state = $s.target;
 */
export func fire(m as Machine, state as string, event as string, ctx as map of string to string) {
    known($m, $state);
    def cands as list of Transition init candidates($m, $state, $event);
    def i as int init choose($cands, $state, $ctx);
    if ($i == -2) {
        fail($m.name + ": no " + json.encode($event) + " transition from " + $state);
    }
    if ($i == -1) {
        fail($m.name + ": " + json.encode($event) + " from " + $state + " refused by its guard");
    }
    def s as Step init Step{event: $event, source: $state, target: $cands[$i].target, ctx: $ctx};
    if (maps.has($m.leave, $state)) {
        $s.ctx = runHook($m.leave[$state], $s, $m.name + ": the leave hook of " + $state);
    }
    if (maps.has($m.enter, $s.target)) {
        $s.ctx = runHook($m.enter[$s.target], $s, $m.name + ": the enter hook of " + $s.target);
    }
    return $s;
}

/**
 * Whether `fire` would take a transition. Runs the guards, not the hooks.
 *
 * @param m {Machine} the machine
 * @param state {string} the current state
 * @param event {string} the event; one the machine lacks gives false
 * @param ctx {map of string to string} the context the guards see
 * @return {bool} whether the event can be fired
 * @throws {Error} on an unknown state
 */
export func can(m as Machine, state as string, event as string, ctx as map of string to string) {
    known($m, $state);
    return choose(candidates($m, $state, $event), $state, $ctx) >= 0;
}

/**
 * The events that can be fired from a state now, guards run, in the order
 * their transitions were added.
 *
 * @param m {Machine} the machine
 * @param state {string} the current state
 * @param ctx {map of string to string} the context the guards see
 * @return {list of string} the events
 * @throws {Error} on an unknown state
 */
export func events(m as Machine, state as string, ctx as map of string to string) {
    known($m, $state);
    def out as list of string init [];
    for (def event in $m.exits[$state]) {
        if (choose(candidates($m, $state, $event), $state, $ctx) >= 0) {
            $out[] = $event;
        }
    }
    return $out;
}

/**
 * The states the transitions leaving a state enter, guards ignored; a state
 * may repeat.
 *
 * @param m {Machine} the machine
 * @param state {string} the state
 * @return {list of string} the targets
 */
func targets(m as Machine, state as string) {
    def out as list of string init [];
    for (def event in $m.exits[$state]) {
        for (def i in $m.routes[$state + " " + $event]) {
            $out[] = $m.transitions[$i].target;
        }
    }
    return $out;
}

/**
 * The flaws of a definition, guards ignored: states the initial one cannot
 * reach, states that are not final but have no transition out, and final
 * states that have one. A machine with none returns `[]`.
 *
 * @param m {Machine} the machine
 * @return {list of Problem} the flaws, in the order the states were added
 * @example
 *   for (def p in fsm.check($m)) {
 *       io.printf("%s\n", $p.message);
 *   }
 */
export func check(m as Machine) {
    def reached as map of string to bool init {$m.initial: true};
    def queue as list of string init [$m.initial];
    def next as int init 0;
    while ($next < len($queue)) {
        for (def t in targets($m, $queue[$next])) {
            if (not maps.has($reached, $t)) {
                $reached[$t] = true;
                $queue[] = $t;
            }
        }
        $next = $next + 1;
    }
    def finals as map of string to bool init setOf($m.finals);
    def out as list of Problem init [];
    for (def s in $m.states) {
        def exits as list of string init $m.exits[$s];
        def final as bool init maps.has($finals, $s);
        if (not maps.has($reached, $s)) {
            $out[] = Problem{
                kind: "unreachable",
                state: $s,
                message: $m.name + ": " + $s + " cannot be reached from " + $m.initial
            };
        }
        if (not $final and len($exits) == 0) {
            $out[] = Problem{
                kind: "dead-end",
                state: $s,
                message: $m.name + ": " + $s + " is not final and has no transition out"
            };
        }
        if ($final and len($exits) > 0) {
            $out[] = Problem{
                kind: "final-exit",
                state: $s,
                message: $m.name + ": " + $s + " is final but has transitions out (" +
                    strings.join($exits, ", ") + ")"
            };
        }
    }
    return $out;
}

/**
 * A function value's name, for a diagram label.
 *
 * @param f {func} the function
 * @return {string} its name; `"guard"` when the interpreter does not say
 */
func funcName(f as func) {
    def shown as string init convert.toString($f);
    if (regex.matches("^<func [A-Za-z_][A-Za-z0-9_]*>$", $shown)) {
        return strings.substring($shown, 6, len($shown) - 1);
    }
    return "guard";
}

/**
 * A transition's label in a diagram: the event, and the guard's name in
 * brackets.
 *
 * @param t {Transition} the transition
 * @return {string} the label
 */
func label(t as Transition) {
    if (isSet($t.guard)) {
        return $t.event + " [" + funcName($t.guard) + "]";
    }
    return $t.event;
}

/**
 * The machine as a Mermaid state diagram, for Markdown that renders Mermaid
 * (GitHub, GitLab, mdBook with the plugin).
 *
 * @param m {Machine} the machine
 * @return {string} the `stateDiagram-v2` source, ending in a newline
 */
export func mermaid(m as Machine) {
    def ids as map of string to string init {};
    def out as list of string init ["stateDiagram-v2"];
    def i as int init 0;
    for (def s in $m.states) {
        $ids[$s] = "s" + convert.toString($i);
        $out[] = "    state \"" + $s + "\" as " + $ids[$s];
        $i = $i + 1;
    }
    $out[] = "    [*] --> " + $ids[$m.initial];
    for (def t in $m.transitions) {
        for (def s in $t.sources) {
            $out[] = "    " + $ids[$s] + " --> " + $ids[$t.target] + " : " + label($t);
        }
    }
    for (def s in $m.finals) {
        $out[] = "    " + $ids[$s] + " --> [*]";
    }
    return strings.join($out, "\n") + "\n";
}

/**
 * The machine as a Graphviz graph: `dot -Tsvg` draws it.
 *
 * @param m {Machine} the machine
 * @return {string} the DOT source, ending in a newline
 */
export func dot(m as Machine) {
    def out as list of string init [
        "digraph \"" + $m.name + "\" \{",
        "    rankdir=LR;",
        "    node [shape=box, style=rounded];",
        "    \"[*]\" [shape=point, label=\"\"];"
    ];
    def finals as map of string to bool init setOf($m.finals);
    for (def s in $m.states) {
        if (maps.has($finals, $s)) {
            $out[] = "    \"" + $s + "\" [peripheries=2];";
        } else {
            $out[] = "    \"" + $s + "\";";
        }
    }
    $out[] = "    \"[*]\" -> \"" + $m.initial + "\";";
    for (def t in $m.transitions) {
        for (def s in $t.sources) {
            $out[] = "    \"" + $s + "\" -> \"" + $t.target + "\" [label=\"" + label($t) + "\"];";
        }
    }
    $out[] = "\}";
    return strings.join($out, "\n") + "\n";
}

/**
 * A JSON Pointer reference token: `~` and `/` escaped.
 *
 * @param key {string} the key
 * @return {string} the token
 */
func token(key as string) {
    return strings.replace(strings.replace($key, "~", "~0"), "/", "~1");
}

/**
 * A TOML node as JSON text, for the one reader `load` has. Dates have no JSON
 * form, so they fail.
 *
 * @param doc {toml.Value} the document
 * @param ptr {string} the node
 * @return {string} the JSON
 */
func tomlJson(doc as toml.Value, ptr as string) {
    def kind as string init toml.typeOf($doc, $ptr);
    if ($kind == "string") {
        return json.encode(toml.asString($doc, $ptr));
    }
    if ($kind == "int") {
        return convert.toString(toml.asInt($doc, $ptr));
    }
    if ($kind == "bool") {
        return convert.toString(toml.asBool($doc, $ptr));
    }
    if ($kind == "float") {
        # No float has a place in a machine. Any float stands in, so the
        # reader reports the type, and `nan` / `inf` (which have no Jennifer
        # value) are not read at all.
        return "0.5";
    }
    def parts as list of string init [];
    if ($kind == "list") {
        def i as int init 0;
        while ($i < toml.length($doc, $ptr)) {
            $parts[] = tomlJson($doc, $ptr + "/" + convert.toString($i));
            $i = $i + 1;
        }
        return "[" + strings.join($parts, ",") + "]";
    }
    if ($kind == "map") {
        for (def k in toml.keys($doc, $ptr)) {
            $parts[] = json.encode($k) + ":" + tomlJson($doc, $ptr + "/" + token($k));
        }
        return "\{" + strings.join($parts, ",") + "\}";
    }
    docFail($ptr, "a " + $kind + " has no place in a machine");
}

/**
 * Throw a `load` error about a node.
 *
 * @param ptr {string} the node; "" is the document
 * @param message {string} what is wrong with it
 */
func docFail(ptr as string, message as string) {
    if ($ptr == "") {
        fail("load: /: " + $message);
    }
    fail("load: " + $ptr + ": " + $message);
}

/**
 * A string node.
 *
 * @param doc {yaml.Value} the document
 * @param ptr {string} the node
 * @return {string} its text
 */
func docString(doc as yaml.Value, ptr as string) {
    if (yaml.typeOf($doc, $ptr) != "string") {
        docFail($ptr, "expected a string, found " + yaml.typeOf($doc, $ptr));
    }
    return yaml.asString($doc, $ptr);
}

/**
 * A list of strings, or one string standing for a list of it.
 *
 * @param doc {yaml.Value} the document
 * @param ptr {string} the node
 * @param limit {int} the most strings it may hold
 * @param what {string} the message past the limit
 * @return {list of string} the strings
 */
func docStrings(doc as yaml.Value, ptr as string, limit as int, what as string) {
    if (yaml.typeOf($doc, $ptr) == "string") {
        return [yaml.asString($doc, $ptr)];
    }
    if (yaml.typeOf($doc, $ptr) != "list") {
        docFail($ptr, "expected a list of strings, found " + yaml.typeOf($doc, $ptr));
    }
    if (yaml.length($doc, $ptr) > $limit) {
        docFail($ptr, $what);
    }
    def out as list of string init [];
    def i as int init 0;
    while ($i < yaml.length($doc, $ptr)) {
        $out[] = docString($doc, $ptr + "/" + convert.toString($i));
        $i = $i + 1;
    }
    return $out;
}

/**
 * The keys of a map node.
 *
 * @param doc {yaml.Value} the document
 * @param ptr {string} the node
 * @return {list of string} its keys, in document order
 */
func docMap(doc as yaml.Value, ptr as string) {
    if (yaml.typeOf($doc, $ptr) != "map") {
        docFail($ptr, "expected a map, found " + yaml.typeOf($doc, $ptr));
    }
    return yaml.keys($doc, $ptr);
}

/**
 * Refuse keys a node should not have: a typo would otherwise be ignored.
 *
 * @param doc {yaml.Value} the document
 * @param ptr {string} the node, which must be a map
 * @param allowed {list of string} the keys it may have
 */
func docKeys(doc as yaml.Value, ptr as string, allowed as list of string) {
    for (def k in docMap($doc, $ptr)) {
        if (not lists.contains($allowed, $k)) {
            docFail($ptr, "unknown key " + json.encode($k));
        }
    }
}

/**
 * A function named in the document.
 *
 * @param doc {yaml.Value} the document
 * @param ptr {string} the node naming it
 * @param funcs {map of string to func} the functions the document may name
 * @return {func} the function
 */
func docFunc(doc as yaml.Value, ptr as string, funcs as map of string to func) {
    def name as string init docString($doc, $ptr);
    if (not maps.has($funcs, $name)) {
        docFail($ptr, "no function " + json.encode($name) + " was given");
    }
    return $funcs[$name];
}

/**
 * Read a machine from a document.
 *
 * @param doc {yaml.Value} the document
 * @param funcs {map of string to func} the functions it may name
 * @return {Machine} the machine
 */
func fromDoc(doc as yaml.Value, funcs as map of string to func) {
    docKeys($doc, "", DOC_KEYS);
    for (def key in ["name", "initial", "transitions"]) {
        if (not yaml.has($doc, "/" + $key)) {
            fail("load: no " + json.encode($key));
        }
    }
    def initial as string init docString($doc, "/initial");
    def m as Machine init machine(docString($doc, "/name"), $initial);
    if (yaml.has($doc, "/states")) {
        def rest as list of string init [];
        def listed as bool init false;
        for (def s in docStrings($doc, "/states", MAX_STATES, "more than MAX_STATES states")) {
            if ($s == $initial and not $listed) {
                $listed = true;
            } else {
                $rest[] = $s;
            }
        }
        $m = addStates($m, $rest);
    }
    if (yaml.has($doc, "/final")) {
        $m = addFinals($m, docStrings($doc, "/final", MAX_STATES, "more than MAX_STATES states"));
    }
    if (yaml.typeOf($doc, "/transitions") != "list") {
        docFail("/transitions", "expected a list, found " + yaml.typeOf($doc, "/transitions"));
    }
    def edges as int init 0;
    def i as int init 0;
    while ($i < yaml.length($doc, "/transitions")) {
        def at as string init "/transitions/" + convert.toString($i);
        docKeys($doc, $at, TRANSITION_KEYS);
        for (def key in ["event", "from", "to"]) {
            if (not yaml.has($doc, $at + "/" + $key)) {
                docFail($at, "no " + json.encode($key));
            }
        }
        def event as string init docString($doc, $at + "/event");
        def sources as list of string init docStrings(
            $doc,
            $at + "/from",
            MAX_EDGES - $edges,
            "the transitions name more than MAX_EDGES source states in all");
        $edges = $edges + len($sources);
        def target as string init docString($doc, $at + "/to");
        if (yaml.has($doc, $at + "/guard")) {
            $m = addGuarded($m, $event, $sources, $target, docFunc($doc, $at + "/guard", $funcs));
        } else {
            $m = addTransition($m, $event, $sources, $target);
        }
        $i = $i + 1;
    }
    if (yaml.has($doc, "/enter")) {
        for (def s in docMap($doc, "/enter")) {
            $m = onEnter($m, $s, docFunc($doc, "/enter/" + token($s), $funcs));
        }
    }
    if (yaml.has($doc, "/leave")) {
        for (def s in docMap($doc, "/leave")) {
            $m = onLeave($m, $s, docFunc($doc, "/leave/" + token($s), $funcs));
        }
    }
    return $m;
}

/**
 * Read a machine from a TOML, YAML or JSON document. Guards and hooks are
 * named; `funcs` maps each name the document may use to the function, so a
 * document reaches only the functions the caller lists.
 *
 * ```toml
 * name = "order"
 * initial = "draft"
 * states = ["draft", "review", "approved"]
 * final = ["approved"]
 *
 * [[transitions]]
 * event = "submit"
 * from = "draft"            # a state or a list of states
 * to = "review"
 *
 * [[transitions]]
 * event = "approve"
 * from = ["review"]
 * to = "approved"
 * guard = "isManager"       # optional
 *
 * [enter]
 * approved = "notify"       # optional, also [leave]
 * ```
 *
 * @param text {string} the document
 * @param format {string} `"toml"`, `"yaml"` or `"json"`
 * @param funcs {map of string to func} the guards and hooks by name; `{}`
 *   when the document names none
 * @return {Machine} the machine, built as the `add*` functions would
 * @throws {Error} on a parse error, a missing or unknown key, a wrong type,
 *   a function not in `funcs`, or anything the `add*` functions refuse
 * @example
 *   def m as fsm.Machine init fsm.load(fs.readString("order.toml"), "toml", {
 *       "isManager": isManager,
 *       "notify": notify
 *   });
 */
export func load(text as string, format as string, funcs as map of string to func) {
    def doc as yaml.Value;
    try {
        if ($format == "toml") {
            $doc = yaml.decode(tomlJson(toml.decode($text), ""));
        } elseif ($format == "json") {
            $doc = yaml.decode(json.encode(json.decode($text)));
        } elseif ($format == "yaml") {
            $doc = yaml.decode($text);
        } else {
            fail("load: format must be toml, yaml or json, not " + json.encode($format));
        }
    } catch (e) {
        if ($e.kind == ERROR_KIND) {
            throw $e;
        }
        fail("load: not valid " + $format + ": " + $e.message);
    }
    return fromDoc($doc, $funcs);
}
