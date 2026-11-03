# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0

# An order's life cycle: define it, check it, walk one order through it and
# print the diagram. Run with: jennifer run examples/order.j
import "../src/fsm.j" as fsm;
use io;
use maps;

func isManager(s as fsm.Step) {
    return maps.has($s.ctx, "role") and $s.ctx["role"] == "manager";
}

func stamp(s as fsm.Step) {
    def c as map of string to string init $s.ctx;
    $c["approvedBy"] = $c["user"];
    return $c;
}

def m as fsm.Machine init fsm.machine("order", "draft");
$m = fsm.addStates($m, ["review", "approved", "rejected"]);
$m = fsm.addFinals($m, ["approved", "rejected"]);
$m = fsm.addTransition($m, "submit", ["draft"], "review");
$m = fsm.addTransition($m, "edit", ["review"], "draft");
$m = fsm.addGuarded($m, "approve", ["review"], "approved", isManager);
$m = fsm.addTransition($m, "reject", ["review"], "rejected");
$m = fsm.onEnter($m, "approved", stamp);

for (def p in fsm.check($m)) {
    io.printf("problem: %s\n", $p.message);
}

def state as string init $m.initial;
def ctx as map of string to string init {"user": "ada", "role": "clerk"};
$state = fsm.fire($m, $state, "submit", $ctx).target;
io.printf("%s: can do %v\n", $state, fsm.events($m, $state, $ctx));
try {
    fsm.fire($m, $state, "approve", $ctx);
} catch (e) {
    io.printf("%s\n", $e.message);
}
$ctx["role"] = "manager";
def s as fsm.Step init fsm.fire($m, $state, "approve", $ctx);
io.printf(
    "%s, approved by %s, final: %v\n\n",
    $s.target,
    $s.ctx["approvedBy"],
    fsm.isFinal($m, $s.target));
io.printf("%s", fsm.mermaid($m));
