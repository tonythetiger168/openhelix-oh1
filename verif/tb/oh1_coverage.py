"""Functional coverage model (cocotb-coverage), fed by the cycle scoreboard.

Every bin listed here is reachable; impossible combinations are removed with
ign_bins and listed in verif/doc/coverage_exclusions.md.
"""
import os

from cocotb_coverage.coverage import CoverPoint, CoverCross, coverage_db
from pyuvm import uvm_component, uvm_subscriber

from oh1_isa import K, R_OPS, I_OPS, BR_OPS, LANES, s32, CSR_TID, CSR_LANEID, OPC_CUSTOM0

ALL_K = [k.name for k in K]
ALU_K = {k.name for k in R_OPS + I_OPS}
SHIFT_K = {"SLL", "SRL", "SRA", "SLLI", "SRLI", "SRAI"}
CMP_K = {"SLT", "SLTU", "SLTI", "SLTIU"}
VAL_BINS = ["zero", "one", "all_ones", "min_neg", "max_pos", "neg", "pos"]


def vclass(v):
    if v == 0:
        return "zero"
    if v == 1:
        return "one"
    if v == 0xFFFFFFFF:
        return "all_ones"
    if v == 0x80000000:
        return "min_neg"
    if v == 0x7FFFFFFF:
        return "max_pos"
    return "neg" if v >> 31 else "pos"


def lanes(m):
    return bin(m & 0xF).count("1")


def illegal_class(r):
    ins = r.ins
    opc, f3, f7 = ins & 0x7F, (ins >> 12) & 7, ins >> 25
    if r.jalr_div:
        return "jalr_divergent"
    if opc == OPC_CUSTOM0:
        return "fp16_vdot" if f3 == 6 else "wspawn"
    return {0b0110011: "bad_r_funct7", 0b0010011: "bad_i", 0b1100011: "bad_branch_f3",
            0b0000011: "bad_load_f3", 0b0100011: "bad_store_f3", 0b1100111: "bad_jalr_f3",
            0b1110011: "bad_system_f3"}.get(opc, "bad_opcode")


ILL_BINS = ["jalr_divergent", "fp16_vdot", "wspawn", "bad_r_funct7", "bad_branch_f3",
            "bad_load_f3", "bad_store_f3", "bad_jalr_f3", "bad_system_f3", "bad_opcode"]


def lsu_pattern(r):
    act = [l for l in range(LANES) if (r.mask >> l) & 1]
    idx = [(r.ld_addr[l] >> 2) & 0xFFF for l in act]
    if len(act) <= 1:
        return "single" if act else "none"
    if len(set(idx)) == 1:
        return "same_addr"
    if len(set(idx)) < len(idx):
        return "partial_conflict"
    return "distinct"


def lsu_alias(r):
    act = [l for l in range(LANES) if (r.mask >> l) & 1] or [0]
    a = r.ld_addr[act[0]]
    if a & 3:
        return "misaligned"
    if a >> 14:
        return "aliased_high"
    return "in_range"


# ----------------------------------------------------------------------------- exec
P = "oh1.exec."


@CoverPoint(P + "kind", xf=lambda r: r.kind.name, bins=ALL_K)
@CoverPoint(P + "lanes", xf=lambda r: lanes(r.mask), bins=list(range(LANES + 1)))
@CoverCross(P + "kind_x_lanes", items=[P + "kind", P + "lanes"])
@CoverPoint(P + "mask", xf=lambda r: r.mask, bins=list(range(16)))
def cov_exec(r):
    pass


@CoverPoint(P + "alu.kind", xf=lambda r: r.kind.name, bins=sorted(ALU_K))
@CoverPoint(P + "alu.a", xf=lambda r: vclass(r.a[0]), bins=VAL_BINS)
@CoverPoint(P + "alu.b", xf=lambda r: vclass(r.b[0] if r.kind in R_OPS else r.imm), bins=VAL_BINS)
@CoverPoint(P + "alu.rd", xf=lambda r: "x0" if r.rd == 0 else ("lo" if r.rd < 16 else "hi"),
            bins=["x0", "lo", "hi"])
@CoverCross(P + "alu.kind_x_rd", items=[P + "alu.kind", P + "alu.rd"])
@CoverPoint(P + "alu.res", xf=lambda r: vclass(r.wb_data[(r.mask & -r.mask).bit_length() - 1]
                                              if r.mask else 0), bins=VAL_BINS)
def cov_alu(r):
    pass


@CoverPoint(P + "shift.amt", xf=lambda r: (lambda s: "0" if s == 0 else "31" if s == 31 else "mid")(
    (r.b[0] if r.kind.name in ("SLL", "SRL", "SRA") else r.imm) & 31), bins=["0", "31", "mid"])
@CoverPoint(P + "shift.kind", xf=lambda r: r.kind.name, bins=sorted(SHIFT_K))
@CoverPoint(P + "shift.neg", xf=lambda r: bool(r.a[0] >> 31), bins=[True, False])
@CoverPoint(P + "shift.arith_effect",
            xf=lambda r: (lambda amt: any((r.mask >> l) & 1 and r.a[l] >> 31 for l in range(LANES))
                          and amt != 0)((r.b[0] if r.kind.name == "SRA" else r.imm) & 31)
            if r.kind.name in ("SRA", "SRAI") else None, bins=[True, False])
@CoverCross(P + "shift.kind_x_amt", items=[P + "shift.kind", P + "shift.amt"])
@CoverCross(P + "shift.kind_x_neg", items=[P + "shift.kind", P + "shift.neg"])
def cov_shift(r):
    pass


def _cmp_b(r):
    return r.b[0] if r.kind.name in ("SLT", "SLTU") else r.imm


@CoverPoint(P + "cmp.kind", xf=lambda r: r.kind.name, bins=sorted(CMP_K))
@CoverPoint(P + "cmp.res", xf=lambda r: r.wb_data[0] if r.mask & 1 else None, bins=[0, 1])
@CoverPoint(P + "cmp.sign_split", xf=lambda r: (s32(r.a[0]) < s32(_cmp_b(r))) != (r.a[0] < _cmp_b(r)),
            bins=[True, False])
@CoverCross(P + "cmp.kind_x_res", items=[P + "cmp.kind", P + "cmp.res"])
@CoverCross(P + "cmp.kind_x_sign_split", items=[P + "cmp.kind", P + "cmp.sign_split"])
def cov_cmp(r):
    pass


@CoverPoint(P + "mul.overflow", xf=lambda r: r.a[0] * r.b[0] > 0xFFFFFFFF, bins=[True, False])
@CoverPoint(P + "mul.zero", xf=lambda r: r.a[0] == 0 or r.b[0] == 0, bins=[True, False])
def cov_mul(r):
    pass


@CoverPoint(P + "vdot.res", xf=lambda r: (lambda v: "neg" if v >> 31 else "zero" if v == 0 else "pos")(
    r.wb_data[(r.mask & -r.mask).bit_length() - 1] if r.mask else 0), bins=["neg", "zero", "pos"])
@CoverPoint(P + "vdot.acc_x0", xf=lambda r: r.rd == 0, bins=[True, False])
@CoverPoint(P + "vdot.alias", xf=lambda r: r.rd in (r.rs1, r.rs2) and r.rd != 0, bins=[True, False])
def cov_vdot(r):
    pass


@CoverPoint(P + "br.kind", xf=lambda r: r.kind.name, bins=[k.name for k in BR_OPS])
@CoverPoint(P + "br.taken", xf=lambda r: r.taken, bins=[True, False])
@CoverPoint(P + "br.cond", xf=lambda r: (lambda c: "all" if c == r.mask else "none" if c == 0 else "some")(
    r.cond & r.mask), bins=["all", "none", "some"])
@CoverPoint(P + "br.dir", xf=lambda r: "bwd" if r.imm >> 31 else "fwd", bins=["fwd", "bwd"])
@CoverCross(P + "br.kind_x_taken", items=[P + "br.kind", P + "br.taken"])
@CoverCross(P + "br.kind_x_cond", items=[P + "br.kind", P + "br.cond"])
@CoverPoint(P + "br.empty_mask", xf=lambda r: r.mask == 0, bins=[True, False])
def cov_branch(r):
    pass


def depth_bucket(d):
    return "0" if d == 0 else "1-3" if d <= 3 else "4-6" if d <= 6 else str(d)


DEPTHS = ["0", "1-3", "4-6", "7", "8"]


@CoverPoint(P + "split.type", xf=lambda r: r.split_type, bins=["all_true", "all_false", "mixed", "empty"])
@CoverPoint(P + "split.depth", xf=lambda r: depth_bucket(r.stk_before), bins=DEPTHS)
@CoverCross(P + "split.type_x_depth", items=[P + "split.type", P + "split.depth"])
@CoverPoint(P + "split.ovf", xf=lambda r: (r.ovf, r.split_type),
            bins=[(True, "mixed"), (True, "all_false"), (False, "mixed"), (False, "all_false")])
@CoverPoint(P + "split.lanes_true", xf=lambda r: lanes(r.pred), bins=list(range(LANES + 1)))
def cov_split(r):
    pass


@CoverPoint(P + "join.type", xf=lambda r: r.join_type, bins=["else", "tag", "empty"])
@CoverPoint(P + "join.depth", xf=lambda r: depth_bucket(r.stk_before), bins=DEPTHS)
@CoverCross(P + "join.type_x_depth", items=[P + "join.type", P + "join.depth"],
            ign_bins=[("empty", d) for d in DEPTHS[1:]] + [("else", "0"), ("tag", "0")])
def cov_join(r):
    pass


@CoverPoint(P + "tmc.arg", xf=lambda r: min(r.tmc_arg, 5) if r.tmc_arg < 2 ** 31 else 5, bins=[0, 1, 2, 3, 4, 5])
@CoverPoint(P + "tmc.lanes_before", xf=lambda r: lanes(r.mask), bins=list(range(LANES + 1)))
@CoverCross(P + "tmc.arg_x_before", items=[P + "tmc.arg", P + "tmc.lanes_before"])
def cov_tmc(r):
    pass


@CoverPoint(P + "lsu.kind", xf=lambda r: r.kind.name, bins=["LW", "SW"])
@CoverPoint(P + "lsu.pattern", xf=lsu_pattern,
            bins=["none", "single", "same_addr", "partial_conflict", "distinct"])
@CoverPoint(P + "lsu.alias", xf=lsu_alias, bins=["in_range", "aliased_high", "misaligned"])
@CoverCross(P + "lsu.kind_x_pattern", items=[P + "lsu.kind", P + "lsu.pattern"])
@CoverCross(P + "lsu.kind_x_alias", items=[P + "lsu.kind", P + "lsu.alias"])
def cov_lsu(r):
    pass


@CoverPoint(P + "jump.kind", xf=lambda r: r.kind.name, bins=["JAL", "JALR"])
@CoverPoint(P + "jump.link", xf=lambda r: r.rd != 0, bins=[True, False])
@CoverCross(P + "jump.kind_x_link", items=[P + "jump.kind", P + "jump.link"])
@CoverPoint(P + "jump.jalr_div", xf=lambda r: r.jalr_div if r.kind == K.JALR else None, bins=[True, False])
@CoverPoint(P + "jump.jalr_bit0", xf=lambda r: bool((r.a[0] + r.imm) & 1) if r.kind == K.JALR else None,
            bins=[True, False])
@CoverPoint(P + "jump.lanes", xf=lambda r: lanes(r.mask), bins=list(range(LANES + 1)))
def cov_jump(r):
    pass


@CoverPoint(P + "csr.addr", xf=lambda r: {CSR_TID: "tid", CSR_LANEID: "laneid"}.get(r.imm, "other"),
            bins=["tid", "laneid", "other"])
def cov_csr(r):
    pass


@CoverPoint(P + "illegal.class", xf=illegal_class, bins=ILL_BINS)
def cov_illegal(r):
    pass


# ----------------------------------------------------------------------------- sequences
# Temporal coverage over the executed instruction stream: read-after-write between
# neighbours, load-use distance, same-address memory ordering and what follows a
# control transfer (IF flush; SYNC_MEM fetch-ahead). The memory-timing build is part of
# the bin where the RTL behaves differently (registered LW read, one stall cycle), so
# closure needs both builds; cov_report merges them.
S = "oh1.exec.seq."
MODE = "sync" if os.environ.get("OH1_SYNC_MEM", "0") == "1" else "comb"
MODES = ["comb", "sync"]


def kclass(k):
    if k in (K.MUL,):
        return "mul"
    if k.name in ALU_K:
        return "alu"
    return {K.VDOT4: "vdot", K.LUI: "upper", K.AUIPC: "upper", K.LW: "lw", K.SW: "sw",
            K.BEQ: "br", K.BNE: "br", K.BLT: "br", K.BGE: "br", K.JAL: "jump", K.JALR: "jump",
            K.SPLIT: "split", K.JOIN: "join", K.TMC: "tmc", K.CSRR: "csr", K.BAR: "bar",
            K.WEXIT: "exit", K.TEXIT: "exit"}.get(k, "ill")


def producer(r):
    """Class of the value r writes, or None if it writes no register."""
    if not (r.wb_en and r.rd and r.wb_mask) or r.illegal:
        return None
    if r.kind in (K.JAL, K.JALR):
        return "link"
    return kclass(r.kind)


def reads(r):
    """(register, consumer role) pairs an instruction actually reads."""
    k = r.kind
    if r.illegal and not r.jalr_div:
        return []
    if k == K.MUL:
        return [(r.rs1, "mul"), (r.rs2, "mul")]
    if k in R_OPS:
        return [(r.rs1, "alu_a"), (r.rs2, "alu_b")]
    if k in I_OPS:
        return [(r.rs1, "alu_a")]
    return {K.LW: [(r.rs1, "lw_base")], K.SW: [(r.rs1, "sw_base"), (r.rs2, "sw_data")],
            K.JALR: [(r.rs1, "jalr")], K.SPLIT: [(r.rs1, "split")], K.TMC: [(r.rs1, "tmc")],
            K.VDOT4: [(r.rs1, "vdot"), (r.rs2, "vdot"), (r.rd, "vdot")],
            K.BEQ: [(r.rs1, "br"), (r.rs2, "br")], K.BNE: [(r.rs1, "br"), (r.rs2, "br")],
            K.BLT: [(r.rs1, "br"), (r.rs2, "br")], K.BGE: [(r.rs1, "br"), (r.rs2, "br")]}.get(k, [])


PRODUCERS = ["alu", "mul", "vdot", "upper", "lw", "csr", "link"]
CONSUMERS = ["alu_a", "alu_b", "mul", "vdot", "lw_base", "sw_base", "sw_data", "br", "split",
             "tmc", "jalr"]
# a JALR base must be warp-uniform and point into the program; loaded, vdot and lane-id
# values are neither (a divergent JALR is covered by oh1.exec.jump.jalr_div)
RAW_IGN = [("lw", "jalr"), ("vdot", "jalr"), ("csr", "jalr")]
REDIRS = ["br_taken", "jal", "jalr", "split_else", "join_else"]
NEXTS = ["alu", "lw", "sw", "br", "jump", "split", "join", "tmc", "exit"]
MEMPAIRS = ["sw_lw", "sw_sw", "lw_sw"]


@CoverPoint(S + "raw.prod", xf=lambda p, c: p, bins=PRODUCERS)
@CoverPoint(S + "raw.cons", xf=lambda p, c: c, bins=CONSUMERS)
@CoverCross(S + "raw.prod_x_cons", items=[S + "raw.prod", S + "raw.cons"], ign_bins=RAW_IGN)
def cov_raw(p, c):
    pass


@CoverPoint(S + "lw_use.dist", xf=lambda d: (d, MODE), bins=[(d, m) for d in (1, 2, 3) for m in MODES])
def cov_lw_use(d):
    pass


@CoverPoint(S + "mem.order", xf=lambda pair, d: (pair, d, MODE),
            bins=[(p, d, m) for p in MEMPAIRS for d in (1, 2) for m in MODES])
def cov_mem_order(pair, d):
    pass


@CoverPoint(S + "redir.type", xf=lambda t, n: t, bins=REDIRS)
@CoverPoint(S + "redir.next", xf=lambda t, n: n, bins=NEXTS)
@CoverCross(S + "redir.type_x_next", items=[S + "redir.type", S + "redir.next"])
@CoverPoint(S + "redir.lw_mode", xf=lambda t, n: (t, MODE) if n == "lw" else None,
            bins=[(t, m) for t in REDIRS for m in MODES])
def cov_redir(t, n):
    pass


def redir_type(r):
    if not r.redirect or r.illegal:
        return None
    if r.kind in BR_OPS:
        return "br_taken"
    return {K.JAL: "jal", K.JALR: "jalr", K.SPLIT: "split_else", K.JOIN: "join_else"}.get(r.kind)


class SeqTracker:
    """Keeps the last few executed instructions of the running kernel."""
    DEPTH = 3

    def __init__(self):
        self.clear()

    def clear(self):
        self.hist = []           # newest last
        self.lw_pend = None      # (rd, lanes written, distance so far)

    def sample(self, r):
        h = self.hist
        if h:
            p = h[-1]
            pc = producer(p)
            if pc:
                for reg, role in reads(r):
                    if reg == p.rd and (r.mask & p.wb_mask or role == "tmc"):
                        cov_raw(pc, role)
            t = redir_type(p)
            if t:
                n = kclass(r.kind)
                if n in NEXTS:
                    cov_redir(t, n)
        # load-use distance (first reader of a loaded register within 3 instructions)
        if self.lw_pend:
            rd, lanes_w, d = self.lw_pend
            d += 1
            if any(reg == rd for reg, _ in reads(r)) and (r.mask & lanes_w):
                cov_lw_use(d)
                self.lw_pend = None
            elif d >= 3 or (r.wb_en and r.rd == rd):
                self.lw_pend = None
            else:
                self.lw_pend = (rd, lanes_w, d)
        if r.kind == K.LW and r.rd and r.mask and not r.illegal:
            self.lw_pend = (r.rd, r.mask, 0)
        # same-word memory ordering at distance 1 and 2
        if r.kind in (K.LW, K.SW) and r.mask:
            for d, q in enumerate(reversed(h[-2:]), 1):
                pair = {(K.SW, K.LW): "sw_lw", (K.SW, K.SW): "sw_sw",
                        (K.LW, K.SW): "lw_sw"}.get((q.kind, r.kind))
                if pair and q.mask and not q.illegal:
                    if any((r.mask >> l) & (q.mask >> l) & 1 and
                                    (r.ld_addr[l] >> 2) & 0xFFF == (q.ld_addr[l] >> 2) & 0xFFF
                                    for l in range(LANES)):
                        cov_mem_order(pair, d)
        h.append(r)
        if len(h) > self.DEPTH:
            h.pop(0)


# ----------------------------------------------------------------------------- events
E = "oh1.soc."
REG_BINS = ["CTRL", "STATUS", "PROG_BASE", "DATA_BASE", "PROG_LEN", "IRQ_STAT", "VERSION", "CAP",
            "unmapped"]
_REG = {0x00: "CTRL", 0x04: "STATUS", 0x08: "PROG_BASE", 0x0C: "DATA_BASE", 0x10: "PROG_LEN",
        0x14: "IRQ_STAT", 0x18: "VERSION", 0x1C: "CAP"}


def strb_class(s):
    return {0xF: "full", 0: "none", 1: "byte", 2: "byte", 4: "byte", 8: "byte",
            3: "half", 0xC: "half"}.get(s, "other")


def win_class(e):
    if e.target in ("imem", "dmem"):
        return e.target + ("_oob" if (e.addr >> 2) & 0x3FFFFFF >= 4096 else "")
    return e.target


WIN_BINS = ["reg", "imem", "dmem", "imem_oob", "dmem_oob", "none"]


@CoverPoint(E + "wr.window", xf=win_class, bins=WIN_BINS)
@CoverPoint(E + "wr.resp", xf=lambda e: e.resp, bins=[0, 2, 3])
@CoverCross(E + "wr.window_x_resp", items=[E + "wr.window", E + "wr.resp"],
            ign_bins=[("reg", 3), ("imem", 3), ("dmem", 3), ("imem_oob", 3), ("dmem_oob", 3),
                      ("imem_oob", 0), ("dmem_oob", 0), ("dmem", 2), ("none", 0), ("none", 2)])
@CoverPoint(E + "wr.strb", xf=lambda e: strb_class(e.strb), bins=["full", "none", "byte", "half", "other"])
@CoverPoint(E + "wr.busy", xf=lambda e: e.busy, bins=[True, False])
@CoverCross(E + "wr.window_x_busy", items=[E + "wr.window", E + "wr.busy"])
def cov_axi_write(e):
    pass


@CoverPoint(E + "wr.reg", xf=lambda e: _REG.get(e.addr & 0xFF, "unmapped"), bins=REG_BINS)
@CoverPoint(E + "wr.reg_strb", xf=lambda e: strb_class(e.strb), bins=["full", "none", "byte", "half", "other"])
@CoverCross(E + "wr.reg_x_strb", items=[E + "wr.reg", E + "wr.reg_strb"])
def cov_axi_wreg(e):
    pass


@CoverPoint(E + "ctrl.write", xf=lambda e: ("start" if e.data & 1 else "nostart",
                                              "irq_en" if e.data & 2 else "irq_dis",
                                              "busy" if e.busy else "idle"),
            bins=[(a, b, c) for a in ("start", "nostart") for b in ("irq_en", "irq_dis")
                  for c in ("busy", "idle")])
def cov_ctrl(e):
    pass


@CoverPoint(E + "rd.window", xf=win_class, bins=WIN_BINS)
@CoverPoint(E + "rd.reg", xf=lambda e: _REG.get(e.addr & 0xFF, "unmapped") if e.target == "reg" else None,
            bins=REG_BINS)
@CoverPoint(E + "rd.busy", xf=lambda e: e.busy, bins=[True, False])
@CoverCross(E + "rd.window_x_busy", items=[E + "rd.window", E + "rd.busy"])
def cov_axi_read(e):
    pass


@CoverPoint(E + "launch.type", xf=lambda e: "after_fault" if e.after_fault else
            ("relaunch" if e.relaunch else "first"), bins=["first", "relaunch", "after_fault"])
@CoverPoint(E + "launch.pc", xf=lambda e: "zero" if e.pc == 0 else "unaligned" if e.pc & 3 else
            ("high" if e.pc >> 14 else "low"), bins=["zero", "low", "high", "unaligned"])
def cov_launch(e):
    pass


@CoverPoint(E + "start_ignored", xf=lambda e: "at_exit" if e.with_exit else "running",
            bins=["running", "at_exit"])
def cov_start_ignored(e):
    pass


@CoverPoint(E + "reset", xf=lambda e: "running" if e.running else "idle", bins=["running", "idle"])
def cov_reset(e):
    pass


@CoverPoint(E + "irq", xf=lambda e: ("rise" if e.level else "fall", e.stat),
            bins=[("rise", 1), ("rise", 2), ("rise", 3), ("fall", 0)])
def cov_irq(e):
    pass


@CoverPoint(E + "exit.kind", xf=lambda e: e.how, bins=["TEXIT", "WEXIT", "watchdog"])
@CoverPoint(E + "exit.fault", xf=lambda e: ("ill" if e.ill else "") + ("ovf" if e.ovf else "") or "clean",
            bins=["clean", "ill", "ovf", "illovf"])
@CoverCross(E + "exit.kind_x_fault", items=[E + "exit.kind", E + "exit.fault"])
def cov_exit(e):
    pass


EXEC_SAMPLERS = [
    (lambda r: True, cov_exec),
    (lambda r: r.kind.name in ALU_K, cov_alu),
    (lambda r: r.kind.name in SHIFT_K, cov_shift),
    (lambda r: r.kind.name in CMP_K, cov_cmp),
    (lambda r: r.kind == K.MUL, cov_mul),
    (lambda r: r.kind == K.VDOT4, cov_vdot),
    (lambda r: r.kind in BR_OPS, cov_branch),
    (lambda r: r.kind == K.SPLIT, cov_split),
    (lambda r: r.kind == K.JOIN, cov_join),
    (lambda r: r.kind == K.TMC, cov_tmc),
    (lambda r: r.kind in (K.LW, K.SW), cov_lsu),
    (lambda r: r.kind in (K.JAL, K.JALR), cov_jump),
    (lambda r: r.kind == K.CSRR, cov_csr),
    (lambda r: r.illegal, cov_illegal),
]


class _Sub(uvm_subscriber):
    def __init__(self, name, parent, fn):
        super().__init__(name, parent)
        self.fn = fn

    def write(self, t):
        self.fn(t)


class Oh1Coverage(uvm_component):
    def build_phase(self):
        self.exec_sub = _Sub("exec_sub", self, self.on_exec)
        self.ev_sub = _Sub("ev_sub", self, self.on_event)
        self.seq = SeqTracker()

    def on_exec(self, r):
        for cond, fn in EXEC_SAMPLERS:
            if cond(r):
                fn(r)
        self.seq.sample(r)

    def on_event(self, e):
        k = e.kind
        if k in ("launch", "reset", "exit"):
            self.seq.clear()
        if k == "axi_write":
            cov_axi_write(e)
            if e.target == "reg":
                cov_axi_wreg(e)
                if (e.addr & 0xFF) == 0 and e.strb & 1:
                    cov_ctrl(e)
        elif k == "axi_read":
            cov_axi_read(e)
        elif k == "launch":
            cov_launch(e)
        elif k == "start_ignored":
            cov_start_ignored(e)
        elif k == "reset":
            cov_reset(e)
        elif k == "irq":
            cov_irq(e)
        elif k == "exit":
            cov_exit(e)
