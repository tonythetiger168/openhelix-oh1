"""Coverage-driven closure loop for OH-1 (used by Oh1CdvTest in test_oh1.py).

Plain CRV draws every kernel from fixed constraint weights and hopes the rare bins
come up. This loop closes the feedback path inside one simulation:

    while holes and budget left:
        holes   = uncovered functional bins (read live from cocotb-coverage)
        plan    = for each hole: a directed construct (ProgGen.c_<name>(*args)) that
                  produces exactly that bin, or a weight boost on the generator knobs,
                  or a bus-level sequence (register sweep, mid-run reset, ...)
        run a batch of kernels drawn from the re-weighted constraints + targets
        record which holes closed; holes that stay open after several targeted
        attempts are demoted ("stubborn") so they cannot starve the rest

Every kernel is still constrained-random (random registers, data, addresses, PROG_BASE,
handshake timing, side traffic) and still checked cycle by cycle by the scoreboard;
the loop only moves probability mass toward what is not covered yet.

Bins that belong to the other memory-timing build (".. 'sync'" in a comb run and
vice versa) are not reachable in this process and are left out of the local metric.
"""
import collections
import json

from cocotb_coverage.coverage import coverage_db, CoverPoint, CoverCross

from oh1_coverage import MODE, MODES, P, E, S
from oh1_progen import Knobs

ILL_IDX = {"fp16_vdot": 0, "wspawn": 1, "bad_r_funct7": 2, "bad_branch_f3": 3,
           "bad_load_f3": 4, "bad_jalr_f3": 5, "bad_store_f3": 6, "bad_system_f3": 6,
           "bad_opcode": 7}

# coverage group prefix -> generator knobs to boost when it has holes
BOOST = [
    (P + "alu", dict(alu=1.0, const=0.5, lane=0.5)), (P + "shift", dict(alu=1.0, const=0.5)),
    (P + "cmp", dict(alu=1.0, const=0.5)), (P + "mul", dict(alu=0.5, hazard=0.5)),
    (P + "vdot", dict(vdot=1.5)), (P + "br", dict(branch=1.0, loop=0.5)),
    (P + "split", dict(split=1.0, deep=1.0)), (P + "join", dict(split=1.0, deep=1.0)),
    (P + "tmc", dict(tmc=1.5)), (P + "lsu", dict(lsu=1.0, memord=0.5)),
    (P + "jump", dict(jump=1.0, jalr_div=0.5)), (P + "csr", dict(csr=1.5)),
    (P + "mask", dict(split=1.0, tmc=0.5)), (P + "lanes", dict(tmc=1.0)),
    (P + "illegal", dict(illegal=1.0)),
    (S + "raw", dict(hazard=1.0)), (S + "lw_use", dict(hazard=1.0)),
    (S + "mem", dict(memord=1.0)), (S + "redir", dict(redir=1.0)),
    (E + "exit", dict(illegal=0.5, deep=0.5)),
]
# soc group prefix -> bus-level action
ACTIONS = [(E + "wr", "regs"), (E + "rd", "regs"), (E + "ctrl", "side"),
           (E + "reset", "reset"), (E + "start_ignored", "side"), (E + "irq", "side"),
           (E + "launch", "fault"), (E + "exit", "fault")]


DEPTH_OF = {"0": 0, "1-3": 2, "4-6": 5, "7": 7, "8": 8}


def _bin_mode(b):
    """'comb'/'sync' if the bin is specific to one memory-timing build."""
    if isinstance(b, tuple):
        for x in b:
            if x in MODES:
                return x
    return None


def holes():
    """[(cover item name, bin)] of every uncovered bin reachable in this build."""
    out = []
    for name, item in coverage_db.items():
        if not isinstance(item, (CoverPoint, CoverCross)):
            continue
        need = item.at_least
        for b, h in item.detailed_coverage.items():
            if h < need and _bin_mode(b) in (None, MODE):
                out.append((name, b))
    return out


def local_size():
    n = 0
    for _, item in coverage_db.items():
        if isinstance(item, (CoverPoint, CoverCross)):
            n += sum(1 for b in item.detailed_coverage if _bin_mode(b) in (None, MODE))
    return n


def target_for(name, b):
    """Directed construct (name, args) that produces bin b of item `name`, or None."""
    if name == S + "raw.prod_x_cons":
        return ("hazard", (b[0], b[1], 0))
    if name == S + "raw.prod":
        return ("hazard", (b, None, 0))
    if name == S + "raw.cons":
        return ("hazard", (None, b, 0))
    if name == S + "lw_use.dist":
        return ("hazard", ("lw", None, b[0] - 1))
    if name == S + "mem.order":
        return ("memord", (b[0], b[1]))
    if name == S + "redir.type_x_next":
        return ("redir", (b[0], b[1]))
    if name == S + "redir.type":
        return ("redir", (b, None))
    if name == S + "redir.next":
        return ("redir", (None, b))
    if name == S + "redir.lw_mode":
        return ("redir", (b[0], "lw"))
    if name == P + "kind_x_lanes":
        return ("masked", (b[0], b[1]))
    if name == P + "kind":
        return ("masked", (b, None))
    if name in (P + "lanes", P + "jump.lanes", P + "tmc.lanes_before"):
        return ("masked", (None, b))
    if name == P + "illegal.class" and b in ILL_IDX:
        return ("illegal", (ILL_IDX[b],))
    if name in (P + "jump.jalr_div", P + "illegal.class") and b in (True, "jalr_divergent"):
        return ("jalr_div", ())
    if name == P + "alu.a":
        return ("alu_vals", (None, b, None))
    if name == P + "alu.b":
        return ("alu_vals", (None, None, b))
    if name in (P + "shift.kind_x_amt",):
        return ("alu_vals", (b[0], None, b[1]))
    if name == P + "shift.kind_x_neg":
        return ("alu_vals", (b[0], "neg" if b[1] else "pos", None))
    if name == P + "shift.arith_effect" and b:
        return ("alu_vals", ("SRAI", "neg", None))
    if name == P + "br.kind_x_cond":
        return ("br_cond", b)
    if name == P + "mask":
        return ("mask_to", (b,))
    if name == P + "alu.kind_x_rd":
        return ("alu_to", (b[0], b[1]))
    if name in (P + "split.type_x_depth", P + "join.type_x_depth"):
        typ, d = b[0], DEPTH_OF[b[1]]
        if name.startswith(P + "join"):
            if typ == "empty":
                return ("masked", ("JOIN", 4))
            typ, d = ("join_else", d) if typ == "else" else ("all_false", d - 1)
        return ("stack_at", (typ, d))
    if name == P + "split.ovf":
        ovf, typ = b
        return ("stack_at", (typ, (7 if typ == "mixed" else 8) if ovf else 2))
    if name == P + "tmc.arg_x_before":
        return ("tmc_at", b)
    if name == P + "tmc.arg":
        return ("tmc_at", (b, 4))
    if name == E + "exit.kind_x_fault":
        return ("fault_exit", b)
    if name == E + "exit.fault":
        return ("fault_exit", ("TEXIT", b))
    if name == E + "exit.kind":
        return ("fault_exit", (b, "clean"))
    return None


class ClosureLoop:
    def __init__(self, rng, base_knobs=None, feedback=True, batch=4, stubborn_after=4):
        self.r = rng
        self.base = base_knobs or Knobs
        self.feedback = feedback
        self.batch = batch
        self.stubborn_after = stubborn_after
        self.tries = collections.Counter()      # (item, bin) -> times its construct was emitted
        self.tmap = {}                          # target -> holes it aims at
        self.stubborn = set()
        self.curve = []
        self.size = local_size()

    def plan(self):
        """Knobs for the next batch, the targeted holes and the bus actions."""
        k = self.base()
        if not self.feedback:
            return k, [], set()
        hs = holes()
        live = [h for h in hs if h not in self.stubborn]
        pool = live or hs                         # retry stubborn holes once the rest closed
        boost = collections.Counter()
        actions = set()
        targets = []
        for name, b in pool:
            for pre, kn in BOOST:
                if name.startswith(pre):
                    for kk, f in kn.items():
                        boost[kk] += f
            for pre, act in ACTIONS:
                if name.startswith(pre):
                    actions.add(act)
            t = target_for(name, b)
            if t:
                targets.append(((name, b), t))
        # weight boost saturates so one big group cannot drown the others
        for kk, f in boost.items():
            k.w[kk] = k.w.get(kk, 0) * (1 + min(f, 8) / 2) + min(f, 4)
        self.r.shuffle(targets)
        targets = targets[:24]
        self.tmap = collections.defaultdict(list)
        for h, t in targets:
            self.tmap[t].append(h)
        k.targets = list(self.tmap)
        if targets:
            k.w["target"] = sum(k.w.values()) + 2                # ~50% of constructs
            k.n_constructs = (6, 16)
        if "fault" in actions:
            k.exit_mix = dict(texit=5, wexit=3, none=1, hang=1)
        return k, [h for h, _ in targets], actions

    def credit(self, knobs):
        """Count real attempts: every emitted target construct is one try for its holes.
        A hole still open after `stubborn_after` tries is demoted below the others."""
        open_ = set(holes())
        for t in knobs.emitted:
            for h in self.tmap.get(t, ()):
                if h in open_:
                    self.tries[h] += 1
                    if self.tries[h] >= self.stubborn_after:
                        self.stubborn.add(h)

    def record(self, kernels, cycles):
        open_ = holes()
        self.curve.append(dict(kernels=kernels, cycles=cycles, covered=self.size - len(open_),
                               size=self.size))
        return open_

    def dump(self, path, extra=None):
        d = dict(mode=MODE, feedback=self.feedback, curve=self.curve,
                 open=[[n, str(b)] for n, b in holes()],
                 stubborn=[[n, str(b)] for n, b in self.stubborn if (n, b) in set(holes())])
        d.update(extra or {})
        with open(path, "w") as f:
            json.dump(d, f, indent=1)
