# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

/**
 * White-box tests for the entry module: jennifer test src/fsm_test.j
 *
 * The overlay is compiled with its module, so it reaches unexported helpers.
 */
use testing;

/**
 * The message a call fails with.
 *
 * @param f {func} a function taking nothing
 * @return {string} the message of the deck's error; "" when it passes
 */
func failure(f as func) {
    try {
        $f();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        return $e.message;
    }
    return "";
}

/**
 * The order machine most tests use: draft, review, approved, rejected.
 *
 * @return {Machine} the machine
 */
func order() {
    def m as Machine init machine("order", "draft");
    $m = addStates($m, ["review", "approved", "rejected"]);
    $m = addFinals($m, ["approved", "rejected"]);
    $m = addTransition($m, "submit", ["draft"], "review");
    $m = addGuarded($m, "approve", ["review"], "approved", isManager);
    $m = addTransition($m, "reject", ["review"], "rejected");
    $m = addTransition($m, "edit", ["review"], "draft");
    return $m;
}

func isManager(s as Step) {
    return maps.has($s.ctx, "role") and $s.ctx["role"] == "manager";
}

func isAdmin(s as Step) {
    return maps.has($s.ctx, "role") and $s.ctx["role"] == "admin";
}

func trace(s as Step) {
    def c as map of string to string init $s.ctx;
    def before as string init "";
    if (maps.has($c, "trace")) {
        $before = $c["trace"] + ",";
    }
    $c["trace"] = $before + $s.event + ":" + $s.source + ">" + $s.target;
    return $c;
}

func traceLeave(s as Step) {
    def c as map of string to string init trace($s);
    $c["trace"] = $c["trace"] + "(leave)";
    return $c;
}

func refuseHook(s as Step) {
    throw Error{kind: "mine", message: "the hook said no"};
}

func testBuilding() {
    def m as Machine init order();
    testing.assertEqual([$m.name, $m.initial], ["order", "draft"]);
    testing.assertEqual($m.states, ["draft", "review", "approved", "rejected"]);
    testing.assertEqual($m.finals, ["approved", "rejected"]);
    testing.assertEqual(len($m.transitions), 4);
    testing.assertEqual($m.transitions[1].guard == isManager, true);
    testing.assertEqual(isSet($m.transitions[0].guard), false);
    testing.assertEqual([isState($m, "review"), isState($m, "nope")], [true, false]);
    testing.assertEqual([isFinal($m, "approved"), isFinal($m, "draft")], [true, false]);
    testing.assertEqual(addFinals($m, ["approved"]).finals, ["approved", "rejected"]);
}

func longName() {
    machine(strings.replicate("a", MAX_NAME + 1), "x");
}

func testNamesAreChecked() {
    for (def good in ["in-review", "v1.2", "_x", "1st", strings.replicate("a", MAX_NAME)]) {
        testing.assertEqual(checkName($good, "state"), $good);
    }
    for (def bad in [
        "",
        "a b",
        "-x",
        ".x",
        "a\"b",
        "a\nb",
        "caf" + convert.fromCodepoint(233),
        "a/b"
    ]) {
        try {
            checkName($bad, "state");
            testing.assertTrue(false);
        } catch (e) {
            testing.assertTrue(strings.contains($e.message, "not a valid state name"));
        }
    }
    testing.assertTrue(strings.contains(failure(longName), "longer than 100"));
}

func duplicateState() {
    addStates(order(), ["review"]);
}

func unknownFinal() {
    addFinals(order(), ["done"]);
}

func unknownTarget() {
    addTransition(order(), "go", ["draft"], "done");
}

func unknownSource() {
    addTransition(order(), "go", ["drfat"], "review");
}

func noSources() {
    addTransition(order(), "go", [], "review");
}

func repeatedSource() {
    addTransition(order(), "go", ["draft", "draft"], "review");
}

func nullGuard() {
    def none as func;
    addGuarded(order(), "go", ["draft"], "review", $none);
}

func shadowedGuard() {
    addGuarded(order(), "reject", ["review"], "draft", isAdmin);
}

func shadowedPlain() {
    addTransition(order(), "submit", ["review", "draft"], "rejected");
}

func secondEnter() {
    onEnter(onEnter(order(), "review", trace), "review", trace);
}

func secondLeave() {
    onLeave(onLeave(order(), "review", trace), "review", trace);
}

func hookOnNothing() {
    onEnter(order(), "nope", trace);
}

func testDefinitionsAreChecked() {
    testing.assertTrue(strings.contains(failure(duplicateState), "already a state: review"));
    testing.assertTrue(strings.contains(failure(unknownFinal), "not a state: \"done\""));
    testing.assertTrue(strings.contains(failure(unknownTarget), "not a state: \"done\""));
    testing.assertTrue(strings.contains(failure(unknownSource), "not a state: \"drfat\""));
    testing.assertTrue(strings.contains(failure(noSources), "no source states"));
    testing.assertTrue(strings.contains(failure(repeatedSource), "draft is listed twice"));
    testing.assertTrue(strings.contains(failure(nullGuard), "null function"));
    testing.assertTrue(strings.contains(failure(shadowedGuard), "could never be taken"));
    testing.assertTrue(strings.contains(failure(shadowedPlain), "submit from draft already"));
    testing.assertTrue(strings.contains(failure(secondEnter), "already has an enter hook"));
    testing.assertTrue(strings.contains(failure(secondLeave), "already has a leave hook"));
    testing.assertTrue(strings.contains(failure(hookOnNothing), "not a state"));
    # A guarded transition before an unguarded one is a fallback, not a shadow.
    def m as Machine init addGuarded(order(), "edit", ["draft"], "review", isAdmin);
    $m = addTransition($m, "edit", ["draft"], "rejected");
    testing.assertEqual(len($m.transitions), 6);
}

func fireFromNowhere() {
    fire(order(), "nope", "submit", {});
}

func fireUnknownEvent() {
    fire(order(), "draft", "approve", {});
}

func fireRefused() {
    fire(order(), "review", "approve", {"role": "clerk"});
}

func testFire() {
    def m as Machine init order();
    def s as Step init fire($m, "draft", "submit", {"id": "7"});
    testing.assertEqual(
        $s,
        Step{event: "submit", source: "draft", target: "review", ctx: {"id": "7"}});
    testing.assertEqual(fire($m, "review", "approve", {"role": "manager"}).target, "approved");
    testing.assertEqual(failure(fireFromNowhere), "fsm: order: not a state: \"nope\"");
    testing.assertEqual(
        failure(fireUnknownEvent),
        "fsm: order: no \"approve\" transition from draft");
    testing.assertEqual(
        failure(fireRefused),
        "fsm: order: \"approve\" from review refused by its guard");
}

func testTheFirstPassingGuardWins() {
    def m as Machine init machine("ticket", "open");
    $m = addStates($m, ["escalated", "closed", "queued"]);
    $m = addGuarded($m, "triage", ["open"], "escalated", isAdmin);
    $m = addGuarded($m, "triage", ["open"], "closed", isManager);
    $m = addTransition($m, "triage", ["open"], "queued");
    testing.assertEqual(fire($m, "open", "triage", {"role": "admin"}).target, "escalated");
    testing.assertEqual(fire($m, "open", "triage", {"role": "manager"}).target, "closed");
    testing.assertEqual(fire($m, "open", "triage", {}).target, "queued");
}

func testHooksThreadTheContext() {
    def m as Machine init order();
    $m = onLeave($m, "draft", traceLeave);
    $m = onEnter($m, "review", trace);
    $m = onEnter($m, "draft", trace);
    def s as Step init fire($m, "draft", "submit", {"id": "7"});
    testing.assertEqual(
        $s.ctx,
        {"id": "7", "trace": "submit:draft>review(leave),submit:draft>review"});
    def back as Step init fire($m, "review", "edit", $s.ctx);
    testing.assertTrue(strings.endsWith($back.ctx["trace"], ",edit:review>draft"));
    # Guards and can() run no hooks.
    testing.assertEqual(can($m, "draft", "submit", {}), true);
    def loop as Machine init addTransition(machine("loop", "on"), "tick", ["on"], "on");
    $loop = onEnter(onLeave($loop, "on", traceLeave), "on", trace);
    testing.assertEqual(fire($loop, "on", "tick", {}).ctx["trace"], "tick:on>on(leave),tick:on>on");
}

func badHook(s as Step) {
    return 1;
}

func silentHook(s as Step) {
    testing.assertTrue(isSet(silentHook));
}

func badGuard(s as Step) {
    return "yes";
}

func badHookFired() {
    fire(onEnter(order(), "review", badHook), "draft", "submit", {});
}

func silentHookFired() {
    fire(onLeave(order(), "draft", silentHook), "draft", "submit", {});
}

func badGuardFired() {
    fire(addGuarded(order(), "go", ["draft"], "review", badGuard), "draft", "go", {});
}

func testWrongResultsNameTheFunction() {
    testing.assertEqual(
        failure(badHookFired),
        "fsm: order: the enter hook of review (badHook) must return the context map");
    testing.assertEqual(
        failure(silentHookFired),
        "fsm: order: the leave hook of draft (silentHook) must return the context map");
    testing.assertEqual(
        failure(badGuardFired),
        "fsm: order: the guard (badGuard) must return a bool");
}

# A bad event name is reported as one before anything is said about the guard,
# which a message would otherwise name the unchecked event in.
func testAddGuardedChecksTheEventFirst() {
    testing.assertContains(failure(guardedWithBadEvent), "event");
    testing.assertFalse(strings.contains(failure(guardedWithBadEvent), "null function"));
}

func guardedWithBadEvent() {
    def none as func;
    addGuarded(order(), "", ["draft"], "review", $none);
}

# A guard or hook whose own code fails on a typed local keeps its error: the
# deck tells a wrong result from the function's own failure by the error's
# position, not its text, so even a local named as the deck's once were is
# not mistaken for a wrong result.
func echo(s as string) {
    return $s;
}

func faultyGuard(s as Step) {
    def guardAnswer as bool init echo($s.event);
    return $guardAnswer;
}

func faultyHook(s as Step) {
    def hookContext as map of string to string init echo($s.event);
    return $hookContext;
}

func faultyGuardFired() {
    fire(addGuarded(order(), "go", ["draft"], "review", faultyGuard), "draft", "go", {});
}

func faultyHookFired() {
    fire(onEnter(order(), "review", faultyHook), "draft", "submit", {});
}

func testAFaultInsideAGuardOrHookPassesThrough() {
    testing.assertThrows("faultyGuardFired", "runtime");
    testing.assertThrows("faultyHookFired", "runtime");
}

func hookThrows() {
    fire(onEnter(order(), "review", refuseHook), "draft", "submit", {});
}

func testHookErrorsPassThrough() {
    try {
        hookThrows();
        testing.assertTrue(false);
    } catch (e) {
        testing.assertEqual([$e.kind, $e.message], ["mine", "the hook said no"]);
    }
}

func canFromNowhere() {
    can(order(), "nope", "submit", {});
}

func eventsFromNowhere() {
    events(order(), "nope", {});
}

func testCanAndEvents() {
    def m as Machine init order();
    testing.assertEqual(can($m, "draft", "submit", {}), true);
    testing.assertEqual(can($m, "draft", "approve", {}), false);
    testing.assertEqual(can($m, "draft", "no-such-event", {}), false);
    testing.assertEqual(can($m, "review", "approve", {"role": "manager"}), true);
    testing.assertEqual(events($m, "review", {}), ["reject", "edit"]);
    testing.assertEqual(events($m, "review", {"role": "manager"}), ["approve", "reject", "edit"]);
    testing.assertEqual(events($m, "approved", {}), []);
    testing.assertTrue(strings.contains(failure(canFromNowhere), "not a state"));
    testing.assertTrue(strings.contains(failure(eventsFromNowhere), "not a state"));
}

func testCheck() {
    testing.assertEqual(check(order()), []);
    def m as Machine init addStates(order(), ["archived", "limbo"]);
    $m = addFinals($m, ["archived"]);
    $m = addTransition($m, "archive", ["approved", "rejected"], "archived");
    $m = addTransition($m, "drop", ["draft"], "limbo");
    def kinds as list of string init [];
    for (def p in check($m)) {
        $kinds[] = $p.kind + " " + $p.state;
    }
    testing.assertEqual($kinds, ["final-exit approved", "final-exit rejected", "dead-end limbo"]);
    def lone as Machine init addStates(machine("m", "a"), ["b"]);
    $lone = addFinals($lone, ["a"]);
    def ps as list of Problem init check($lone);
    testing.assertEqual(len($ps), 2);
    testing.assertEqual($ps[0].message, "m: b cannot be reached from a");
    testing.assertEqual($ps[1].message, "m: b is not final and has no transition out");
    testing.assertEqual(
        check($m)[0].message,
        "order: approved is final but has transitions out (archive)");
}

func testDiagrams() {
    def m as Machine init machine("door", "closed");
    $m = addStates($m, ["open", "gone"]);
    $m = addFinals($m, ["gone"]);
    $m = addTransition($m, "open", ["closed"], "open");
    $m = addGuarded($m, "remove", ["open", "closed"], "gone", isAdmin);
    testing.assertEqual(
        mermaid($m),
        "stateDiagram-v2\n" +
            "    state \"closed\" as s0\n" +
            "    state \"open\" as s1\n" +
            "    state \"gone\" as s2\n" +
            "    [*] --> s0\n" +
            "    s0 --> s1 : open\n" +
            "    s1 --> s2 : remove [isAdmin]\n" +
            "    s0 --> s2 : remove [isAdmin]\n" +
            "    s2 --> [*]\n");
    testing.assertEqual(
        dot($m),
        "digraph \"door\" \{\n" +
            "    rankdir=LR;\n" +
            "    node [shape=box, style=rounded];\n" +
            "    \"[*]\" [shape=point, label=\"\"];\n" +
            "    \"closed\";\n" +
            "    \"open\";\n" +
            "    \"gone\" [peripheries=2];\n" +
            "    \"[*]\" -> \"closed\";\n" +
            "    \"closed\" -> \"open\" [label=\"open\"];\n" +
            "    \"open\" -> \"gone\" [label=\"remove [isAdmin]\"];\n" +
            "    \"closed\" -> \"gone\" [label=\"remove [isAdmin]\"];\n" +
            "\}\n");
    testing.assertEqual(funcName(isAdmin), "isAdmin");
}

# The order machine as each format writes it, with an enter hook.
def const ORDER_TOML as string init "name = \"order\"\ninitial = \"draft\"\n" +
    "states = [\"review\", \"approved\", \"rejected\"]\nfinal = [\"approved\", \"rejected\"]\n\n" +
    "[[transitions]]\nevent = \"submit\"\nfrom = \"draft\"\nto = \"review\"\n\n" +
    "[[transitions]]\nevent = \"approve\"\nfrom = [\"review\"]\nto = \"approved\"\n" +
    "guard = \"isManager\"\n\n" +
    "[[transitions]]\nevent = \"reject\"\nfrom = \"review\"\nto = \"rejected\"\n\n" +
    "[[transitions]]\nevent = \"edit\"\nfrom = \"review\"\nto = \"draft\"\n\n" +
    "[enter]\nreview = \"trace\"\n";

def const ORDER_YAML as string init "name: order\ninitial: draft\n" +
    "states: [draft, review, approved, rejected]\nfinal: [approved, rejected]\n" +
    "transitions:\n" +
    "  - \{event: submit, from: draft, to: review\}\n" +
    "  - \{event: approve, from: [review], to: approved, guard: isManager\}\n" +
    "  - \{event: reject, from: review, to: rejected\}\n" +
    "  - \{event: edit, from: review, to: draft\}\n" +
    "enter:\n  review: trace\n";

def const ORDER_JSON as string init "\{\"name\": \"order\", \"initial\": \"draft\",\n" +
    "\"states\": [\"review\", \"approved\", \"rejected\"],\n" +
    "\"final\": [\"approved\", \"rejected\"],\n\"transitions\": [\n" +
    "\{\"event\": \"submit\", \"from\": \"draft\", \"to\": \"review\"\},\n" +
    "\{\"event\": \"approve\", \"from\": [\"review\"], \"to\": \"approved\",\n" +
    "\"guard\": \"isManager\"\},\n" +
    "\{\"event\": \"reject\", \"from\": \"review\", \"to\": \"rejected\"\},\n" +
    "\{\"event\": \"edit\", \"from\": \"review\", \"to\": \"draft\"\}],\n" +
    "\"enter\": \{\"review\": \"trace\"\}\}\n";

func funcs() {
    def out as map of string to func init {"isManager": isManager, "trace": trace};
    return $out;
}

func testLoad() {
    def want as Machine init onEnter(order(), "review", trace);
    testing.assertEqual(load(ORDER_TOML, "toml", funcs()), $want);
    testing.assertEqual(load(ORDER_YAML, "yaml", funcs()), $want);
    testing.assertEqual(load(ORDER_JSON, "json", funcs()), $want);
    def tab as string init convert.fromCodepoint(9);
    testing.assertEqual(
        load(strings.replace(ORDER_JSON, "\n", "\n" + $tab), "json", funcs()),
        $want);
    def tiny as Machine init load(
        "name: t\ninitial: a\ntransitions: [\{event: go, from: a, to: a\}]\n",
        "yaml",
        {});
    testing.assertEqual($tiny.states, ["a"]);
}

/**
 * The message `load` fails with.
 *
 * @param text {string} the document
 * @param format {string} its format
 * @return {string} the message; "" when it loads
 */
func loadFailure(text as string, format as string) {
    try {
        load($text, $format, funcs());
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        return $e.message;
    }
    return "";
}

/**
 * The message `load` fails with on a document past a cap, which must be the
 * generic kind "limit".
 *
 * @param text {string} the document
 * @param format {string} its format
 * @return {string} the message; "" when it loads
 */
func loadLimit(text as string, format as string) {
    try {
        load($text, $format, funcs());
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        return $e.message;
    }
    return "";
}

func testLoadRefusesBadDocuments() {
    def base as string init "name: o\ninitial: a\nstates: [a, b]\n";
    def cases as map of string to string init {
        "name: o\ninitial: a\n": "no \"transitions\"",
        "initial: a\ntransitions: []\n": "no \"name\"",
        $base + "transitions: []\ncolour: red\n": "/: unknown key \"colour\"",
        $base +
            "transitions: [\{event: go, from: a, to: b, when: x\}]\n": "unknown key \"when\"",
        $base + "transitions: [\{event: go, from: a\}]\n": "/transitions/0: no \"to\"",
        $base +
            "transitions: [\{event: go, from: a, to: 3\}]\n": "/0/to: expected a string",
        $base +
            "transitions: [\{event: go, from: \{a: 1\}, to: b\}]\n": "/0/from: expected a list",
        $base +
            "transitions: [\{event: go, from: a, to: b, guard: sh\}]\n": "no function \"sh\"",
        $base + "transitions: [\{event: go, from: a, to: c\}]\n": "not a state: \"c\"",
        $base + "transitions: \{\}\n": "/transitions: expected a list",
        $base + "transitions: []\nenter: [a]\n": "/enter: expected a map",
        $base + "transitions: []\nleave: \{a: nope\}\n": "/leave/a: no function \"nope\"",
        "- a\n- b\n": "/: expected a map",
        "name: o\ninitial: a\nstates: [a, a]\ntransitions: []\n": "already a state: a",
        "name: [o\n": "not valid yaml"
    };
    for (def text in maps.keys($cases)) {
        def got as string init loadFailure($text, "yaml");
        if (not strings.contains($got, $cases[$text])) {
            testing.assertEqual($got, $cases[$text]);
        }
    }
    testing.assertTrue(strings.contains(
        loadFailure("name = 'o'\nwhen = 2026-11-03\n", "toml"),
        "/when: a datetime has no place"));
    testing.assertTrue(strings.contains(loadFailure("name = \n", "toml"), "not valid toml"));
    testing.assertTrue(strings.contains(
        loadFailure("\{\}", "xml"),
        "format must be toml, yaml or json"));
}

func testTomlBecomesJson() {
    def doc as toml.Value init toml.decode(
        "a = 1\nb = true\nc = 1.5\nd = [\"x\", \"y/z\"]\n[e]\n\"k/~\" = \"v\\\"q\"\n");
    testing.assertEqual(
        tomlJson($doc, ""),
        "\{\"a\":1,\"b\":true,\"c\":0.5,\"d\":[\"x\",\"y/z\"],\"e\":\{\"k/~\":\"v\\\"q\"\}\}");
    testing.assertEqual(token("a/b~c"), "a~1b~0c");
    for (def odd in ["nan", "inf", "-inf", "1.5"]) {
        testing.assertTrue(strings.contains(
            loadFailure("name = \"o\"\ninitial = " + $odd + "\ntransitions = []\n", "toml"),
            "/initial: expected a string, found float"));
    }
}

/**
 * Names `s0` to `s<n-1>`.
 *
 * @param n {int} how many
 * @return {list of string} the names
 */
func numbered(n as int) {
    def out as list of string init [];
    def i as int init 0;
    while ($i < $n) {
        $out[] = "s" + convert.toString($i);
        $i = $i + 1;
    }
    return $out;
}

func deepJson() {
    load(strings.replicate("[", 5000) + strings.replicate("]", 5000), "json", {});
}

func deepYaml() {
    load("name: " + strings.replicate("[", 5000) + strings.replicate("]", 5000), "yaml", {});
}

# A document nested past the decoder's caps: the decoder's "limit", passed on.
func testLoadPassesDecoderCapsOn() {
    testing.assertThrows("deepJson", "limit");
    testing.assertThrows("deepYaml", "limit");
}

func testLoadLimitsDocuments() {
    def all as string init strings.join(numbered(1000), ", ");
    def y as string init "name: big\ninitial: s0\nstates: &all [" + $all + "]\ntransitions:\n";
    def i as int init 0;
    while ($i < 11) {
        $y = $y + "  - \{event: e" + convert.toString($i) + ", from: *all, to: s0\}\n";
        $i = $i + 1;
    }
    testing.assertTrue(strings.contains(
        loadLimit($y, "yaml"),
        "/transitions/10/from: the transitions name more than MAX_EDGES"));
    def many as string init strings.join(numbered(MAX_STATES + 1), ", ");
    testing.assertTrue(strings.contains(
        loadLimit("name: big\ninitial: s0\nstates: [" + $many + "]\ntransitions: []\n", "yaml"),
        "/states: more than MAX_STATES states"));
}

func testManyEventsFromOneState() {
    def m as Machine init addStates(machine("fan", "hub"), ["spoke"]);
    def names as list of string init numbered(300);
    for (def e in $names) {
        $m = addTransition($m, "e" + $e, ["hub"], "spoke");
    }
    $m = addGuarded($m, "back", ["spoke"], "hub", isAdmin);
    $m = addTransition($m, "back", ["spoke"], "spoke");
    def evs as list of string init events($m, "hub", {});
    testing.assertEqual([len($evs), $evs[0], $evs[299]], [300, "es0", "es299"]);
    testing.assertEqual(fire($m, "hub", "es299", {}).target, "spoke");
    testing.assertEqual(fire($m, "spoke", "back", {"role": "admin"}).target, "hub");
    testing.assertEqual(fire($m, "spoke", "back", {}).target, "spoke");
    testing.assertEqual($m.exits["spoke"], ["back"]);
    testing.assertEqual($m.routes["spoke back"], [300, 301]);
    testing.assertEqual(hasFallback($m, "spoke back"), true);
    testing.assertEqual(hasFallback($m, "hub es0"), true);
    testing.assertEqual(hasFallback($m, "hub nothing"), false);
    testing.assertEqual(check($m), []);
}
