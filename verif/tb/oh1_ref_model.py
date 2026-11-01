"""OH-1 reference models used by the scoreboard.

CoreISS     instruction-level model of oh1_core (independent re-implementation of
            the ISS in tb/tb_rand.sv, extended with launch/relaunch, the sticky
            illegal / stack-overflow flags and exact overflow behaviour).
AxiModel    cycle-accurate model of the oh1_axi_lite slave, written from the
            register map in doc/axi_lite_regmap.md and the header of the RTL.
SocModel    both models plus the 16 KB imem / dmem of the harness, stepped once
            per clock with the sampled bus inputs; it predicts every output of
            the harness for the current cycle.
"""
from dataclasses import dataclass, field

from oh1_isa import (K, LANES, STK_DEPTH, MEM_WORDS, MASK32, CSR_TID, CSR_LANEID,
                     decode, dot4_i8, s32)

IDX = MEM_WORDS - 1


@dataclass
class ExecRecord:
    """What the core does in one EX cycle (also fed to functional coverage)."""
    pc: int
    ins: int
    kind: K
    rd: int
    rs1: int
    rs2: int
    imm: int
    mask: int
    a: list
    b: list
    wb_en: bool = False
    wb_mask: int = 0
    wb_data: list = field(default_factory=lambda: [0] * LANES)
    st_en: bool = False
    st_mask: int = 0
    st_addr: list = field(default_factory=lambda: [0] * LANES)
    st_data: list = field(default_factory=lambda: [0] * LANES)
    ld_addr: list = field(default_factory=lambda: [0] * LANES)
    next_pc: int = 0
    next_mask: int = 0
    redirect: bool = False
    taken: bool = False          # branch taken
    cond: int = 0                # per-lane branch condition
    pred: int = 0                # per-lane split predicate
    split_type: str = ""         # all_true / all_false / mixed / empty
    join_type: str = ""          # else / tag / empty
    stk_before: int = 0
    stk_after: int = 0
    ovf: bool = False            # this push overflowed
    illegal: bool = False        # this instruction raised illegal
    jalr_div: bool = False
    tmc_arg: int = 0


class CoreISS:
    def __init__(self, dmem, imem):
        self.dmem = dmem
        self.imem = imem
        self.reset()

    def reset(self):
        self.rf = [[0] * 32 for _ in range(LANES)]
        self.active = False
        self.done = False
        self.ill = False
        self.ovf = False
        self.pc = 0
        self.act = 0xF
        self.stk_tag = [0] * STK_DEPTH
        self.stk_mask = [0] * STK_DEPTH
        self.stk_pc = [0] * STK_DEPTH
        self.sp = 0
        self.lw_snap = None      # SYNC_MEM: per-lane data latched in the LW stall cycle

    def can_launch(self):
        return (not self.active) or self.done

    def launch(self, pc):
        self.active, self.done, self.ill, self.ovf = True, False, False, False
        self.pc, self.act, self.sp = pc & MASK32, 0xF, 0
        self.lw_snap = None

    def next_kind(self):
        """Kind of the instruction the core executes next (at self.pc)."""
        return decode(self.imem[(self.pc >> 2) & IDX])[0]

    def latch_lw(self):
        """SYNC_MEM stall cycle of an LW: a registered memory captures every lane's word
        now (before this cycle's writes commit); the LW retires next cycle with it."""
        _, _, rs1, _, imm = decode(self.imem[(self.pc >> 2) & IDX])
        self.lw_snap = [self.dmem[((((0 if rs1 == 0 else self.rf[l][rs1]) + imm) & MASK32) >> 2) & IDX]
                        for l in range(LANES)]

    def step(self):
        """Execute the instruction at self.pc; returns an ExecRecord.

        Register-file and stack updates are applied immediately; stores are only
        returned (the SoC model commits them at the end of the cycle)."""
        ins = self.imem[(self.pc >> 2) & IDX]
        k, rd, rs1, rs2, imm = decode(ins)
        act = self.act
        a = [0 if rs1 == 0 else self.rf[l][rs1] for l in range(LANES)]
        b = [0 if rs2 == 0 else self.rf[l][rs2] for l in range(LANES)]
        r = ExecRecord(pc=self.pc, ins=ins, kind=k, rd=rd, rs1=rs1, rs2=rs2, imm=imm,
                       mask=act, a=a, b=b, stk_before=self.sp)
        pc_n = (self.pc + 4) & MASK32
        new_act = act
        on = [bool((act >> l) & 1) for l in range(LANES)]

        def alu(l):
            x, y = a[l], b[l]
            sh = y & 31
            return {
                K.ADD: x + y, K.SUB: x - y, K.AND: x & y, K.OR: x | y, K.XOR: x ^ y,
                K.SLL: x << sh, K.SRL: x >> sh, K.SRA: s32(x) >> sh,
                K.SLT: int(s32(x) < s32(y)), K.SLTU: int(x < y), K.MUL: x * y,
                K.ADDI: x + imm, K.ANDI: x & imm, K.ORI: x | imm, K.XORI: x ^ imm,
                K.SLTI: int(s32(x) < s32(imm)), K.SLTIU: int(x < imm),
                K.SLLI: x << (imm & 31), K.SRLI: x >> (imm & 31), K.SRAI: s32(x) >> (imm & 31),
                K.LUI: imm, K.AUIPC: self.pc + imm,
                K.CSRR: l if imm in (CSR_TID, CSR_LANEID) else 0,
                K.VDOT4: (0 if rd == 0 else self.rf[l][rd]) + dot4_i8(x, y),
                K.JAL: self.pc + 4, K.JALR: self.pc + 4,
            }[k] & MASK32

        if k in (K.LW, K.SW):
            for l in range(LANES):
                r.ld_addr[l] = (a[l] + imm) & MASK32
        if k in (
                K.ADD, K.SUB, K.AND, K.OR, K.XOR, K.SLL, K.SRL, K.SRA, K.SLT, K.SLTU, K.MUL,
                K.ADDI, K.ANDI, K.ORI, K.XORI, K.SLTI, K.SLTIU, K.SLLI, K.SRLI, K.SRAI,
                K.LUI, K.AUIPC, K.CSRR, K.VDOT4, K.JAL, K.JALR):
            r.wb_en, r.wb_mask = True, act
            for l in range(LANES):
                if on[l]:
                    r.wb_data[l] = alu(l)
            if k == K.JAL:
                pc_n, r.redirect = (self.pc + imm) & MASK32, True
            elif k == K.JALR:
                tg = [(a[l] + imm) & MASK32 & ~1 for l in range(LANES)]
                act_l = [l for l in range(LANES) if on[l]]
                tgt = tg[act_l[0]] if act_l else tg[0]
                r.jalr_div = any(tg[l] != tgt for l in act_l)
                pc_n, r.redirect = tgt, True
        elif k == K.LW:
            r.wb_en, r.wb_mask = True, act
            for l in range(LANES):
                if on[l]:
                    r.wb_data[l] = (self.lw_snap[l] if self.lw_snap is not None
                                    else self.dmem[(r.ld_addr[l] >> 2) & IDX])
            self.lw_snap = None
        elif k == K.SW:
            if act:
                r.st_en, r.st_mask = True, act
                for l in range(LANES):
                    r.st_addr[l] = r.ld_addr[l]
                    r.st_data[l] = b[l]
        elif k in (K.BEQ, K.BNE, K.BLT, K.BGE):
            for l in range(LANES):
                c = {K.BEQ: a[l] == b[l], K.BNE: a[l] != b[l],
                     K.BLT: s32(a[l]) < s32(b[l]), K.BGE: s32(a[l]) >= s32(b[l])}[k]
                r.cond |= int(c) << l
            if (act & ~r.cond & 0xF) == 0:
                pc_n, r.redirect, r.taken = (self.pc + imm) & MASK32, True, True
        elif k == K.SPLIT:
            for l in range(LANES):
                r.pred |= int(on[l] and a[l] != 0) << l
            false_m = act & ~r.pred & 0xF
            if act == 0:
                r.split_type = "empty"
            elif false_m == 0:
                r.split_type = "all_true"
            elif act & r.pred:
                r.split_type = "mixed"
            else:
                r.split_type = "all_false"
            if false_m:
                two = bool(act & r.pred)
                if self.sp + (2 if two else 1) > STK_DEPTH:
                    r.ovf = True
                    self.ovf = True
                else:
                    p = self.sp & 7
                    self.stk_tag[p], self.stk_mask[p], self.stk_pc[p] = 1, act, 0
                    if two:
                        q = (p + 1) & 7
                        self.stk_tag[q], self.stk_mask[q] = 0, false_m
                        self.stk_pc[q] = (self.pc + imm) & MASK32
                        self.sp += 2
                    else:
                        self.sp += 1
                if two:
                    new_act = act & r.pred
                else:
                    new_act = false_m
                    pc_n, r.redirect = (self.pc + imm) & MASK32, True
        elif k == K.JOIN:
            if self.sp:
                t = (self.sp - 1) & 7
                self.sp -= 1
                new_act = self.stk_mask[t]
                if not self.stk_tag[t]:
                    r.join_type = "else"
                    pc_n, r.redirect = self.stk_pc[t], True
                else:
                    r.join_type = "tag"
            else:
                r.join_type = "empty"
        elif k == K.TMC:
            r.tmc_arg = a[0]
            n = min(a[0], LANES)
            new_act = (1 << n) - 1
        elif k in (K.WEXIT, K.TEXIT):
            self.done = True
        elif k == K.BAR:
            pass
        else:
            r.illegal = True

        if r.jalr_div:
            r.illegal = True
        if r.illegal:
            self.ill = True
        if r.wb_en and rd != 0:
            for l in range(LANES):
                if (r.wb_mask >> l) & 1:
                    self.rf[l][rd] = r.wb_data[l]
        self.act = new_act
        self.pc = pc_n
        r.next_pc, r.next_mask, r.stk_after = pc_n, new_act, self.sp
        return r


# ---------------------------------------------------------------- AXI
OKAY, SLVERR, DECERR = 0, 2, 3
RD_IDLE, RD_MEM_WAIT, RD_MEM_SAMPLE = 0, 1, 2
REG_CTRL, REG_STATUS, REG_PROG_BASE, REG_DATA_BASE = 0x00, 0x04, 0x08, 0x0C
REG_PROG_LEN, REG_IRQ_STAT, REG_VERSION, REG_CAP = 0x10, 0x14, 0x18, 0x1C
OH1_VERSION = 0x0002_0002
CAP_VALUE = (MEM_WORDS << 16) | (STK_DEPTH << 8) | LANES
T_REG, T_IMEM, T_DMEM, T_NONE = "reg", "imem", "dmem", "none"


def decode_target(addr):
    if (addr >> 28) == 0 and ((addr >> 8) & 0xFFFFF) == 0:
        return T_REG
    if (addr >> 28) == 1:
        return T_IMEM
    if (addr >> 28) == 2:
        return T_DMEM
    return T_NONE


def word_index(addr):
    return (addr >> 2) & 0x3FFFFFF


def apply_strb(old, new, strb):
    out = old
    for i in range(4):
        if (strb >> i) & 1:
            out = (out & ~(0xFF << 8 * i)) | (new & (0xFF << 8 * i))
    return out & MASK32


class AxiModel:
    OUTS = ("awready", "wready", "bvalid", "bresp", "arready", "rvalid", "rresp", "rdata",
            "core_start_axi", "core_start_pc", "irq", "mem_we", "mem_wstrb", "mem_is_imem",
            "mem_addr", "mem_wdata")

    def __init__(self):
        self.reset()

    def reset(self):
        self.aw_full = self.w_full = self.ar_full = False
        self.aw_addr = self.w_data = self.w_strb = self.ar_addr = 0
        self.rd_state = RD_IDLE
        self.bvalid, self.bresp, self.rvalid, self.rresp, self.rdata = False, OKAY, False, OKAY, 0
        self.mem_we, self.mem_wstrb, self.mem_is_imem, self.mem_addr, self.mem_wdata = False, 0, False, 0, 0
        self.core_start = False
        self.irq_en = False
        self.prog_base = self.data_base = self.prog_len = 0
        self.busy = False
        self.irq_stat = 0
        self.done_d1 = self.fault_d1 = False
        self.last_write = None   # (target, offset/index, resp) of the write executed this cycle
        self.last_read = None

    # outputs of the current cycle (functions of state only)
    def outputs(self):
        return dict(
            awready=int(not self.aw_full), wready=int(not self.w_full),
            bvalid=int(self.bvalid), bresp=self.bresp,
            arready=int(not self.ar_full and not self.rvalid and self.rd_state == RD_IDLE),
            rvalid=int(self.rvalid), rresp=self.rresp, rdata=self.rdata,
            core_start_axi=int(self.core_start), core_start_pc=self.prog_base,
            irq=int(self.irq_en and self.irq_stat != 0),
            mem_we=int(self.mem_we), mem_wstrb=self.mem_wstrb, mem_is_imem=int(self.mem_is_imem),
            mem_addr=self.mem_addr, mem_wdata=self.mem_wdata)

    def step(self, i, done, ill, ovf, mem_rdata):
        """Advance one clock. i: dict of sampled AXI inputs for this cycle."""
        o = self.outputs()
        do_write = self.aw_full and self.w_full and not self.bvalid and self.rd_state == RD_IDLE
        do_read = (self.ar_full and not self.rvalid and self.rd_state == RD_IDLE and not do_write)
        n = dict(self.__dict__)            # next-state copy (non-blocking semantics)
        n["core_start"] = False
        n["mem_we"] = False
        n["last_write"] = None
        n["last_read"] = None
        if i["awvalid"] and o["awready"]:
            n["aw_full"], n["aw_addr"] = True, i["awaddr"]
        if i["wvalid"] and o["wready"]:
            n["w_full"], n["w_data"], n["w_strb"] = True, i["wdata"], i["wstrb"]
        if i["arvalid"] and o["arready"]:
            n["ar_full"], n["ar_addr"] = True, i["araddr"]
        if self.bvalid and i["bready"]:
            n["bvalid"] = False
        if do_write:
            n["aw_full"] = n["w_full"] = False
            n["bvalid"], resp = True, OKAY
            a, d, s = self.aw_addr, self.w_data, self.w_strb
            t = decode_target(a)
            if t in (T_IMEM, T_DMEM):
                if word_index(a) >= MEM_WORDS:
                    resp = SLVERR
                elif t == T_IMEM and self.busy:
                    resp = SLVERR
                else:
                    n.update(mem_we=True, mem_wstrb=s, mem_is_imem=(t == T_IMEM),
                             mem_addr=word_index(a), mem_wdata=d)
            elif t == T_REG:
                off = a & 0xFF
                if off == REG_CTRL:
                    if s & 1:
                        n["irq_en"] = bool(d & 2)
                        if (d & 1) and not self.busy:
                            n["core_start"] = True
                            n["busy"] = True
                elif off == REG_PROG_BASE:
                    n["prog_base"] = apply_strb(self.prog_base, d, s)
                elif off == REG_DATA_BASE:
                    n["data_base"] = apply_strb(self.data_base, d, s)
                elif off == REG_PROG_LEN:
                    n["prog_len"] = apply_strb(self.prog_len, d, s)
                elif off == REG_IRQ_STAT:
                    if s & 1:
                        n["irq_stat"] = self.irq_stat & ~d & 3
                else:
                    resp = SLVERR
            else:
                resp = DECERR
            n["bresp"] = resp
            n["last_write"] = (t, a, resp, s, d)
        if self.rvalid and i["rready"]:
            n["rvalid"] = False
        if self.rd_state == RD_IDLE:
            if do_read:
                n["ar_full"], n["rresp"] = False, OKAY
                a = self.ar_addr
                t = decode_target(a)
                n["last_read"] = (t, a)
                if t in (T_IMEM, T_DMEM):
                    if word_index(a) >= MEM_WORDS:
                        n.update(rresp=SLVERR, rdata=0, rvalid=True)
                    else:
                        n.update(mem_is_imem=(t == T_IMEM), mem_addr=word_index(a),
                                 rd_state=RD_MEM_WAIT)
                elif t == T_REG:
                    n["rvalid"] = True
                    off = a & 0xFF
                    val = {REG_CTRL: int(self.irq_en) << 1,
                           REG_STATUS: (int(ovf) << 3) | (int(self.busy) << 2) | (int(ill) << 1)
                                       | int(done and not self.busy),
                           REG_PROG_BASE: self.prog_base, REG_DATA_BASE: self.data_base,
                           REG_PROG_LEN: self.prog_len, REG_IRQ_STAT: self.irq_stat,
                           REG_VERSION: OH1_VERSION, REG_CAP: CAP_VALUE}.get(off)
                    if val is None:
                        n.update(rdata=0, rresp=SLVERR)
                    else:
                        n["rdata"] = val
                else:
                    n.update(rdata=0, rresp=DECERR, rvalid=True)
        elif self.rd_state == RD_MEM_WAIT:
            n["rd_state"] = RD_MEM_SAMPLE
        else:
            n.update(rdata=mem_rdata, rvalid=True, rd_state=RD_IDLE)
        fault = ill or ovf
        n["done_d1"], n["fault_d1"] = done, fault
        if self.busy and not self.core_start and done and not self.done_d1:
            n["busy"] = False
        irq_stat = n["irq_stat"]
        if done and not self.done_d1:
            irq_stat |= 1
        if fault and not self.fault_d1:
            irq_stat |= 2
        n["irq_stat"] = irq_stat
        self.__dict__.update(n)


class SocModel:
    """Predicts every harness output, one clock at a time."""

    # The harness memories are not reset and persist across cocotb tests that share
    # one simulation, so the model's copies are shared across SocModel instances too.
    _IMEM = [0] * MEM_WORDS
    _DMEM = [0] * MEM_WORDS

    def __init__(self):
        self.imem = SocModel._IMEM
        self.dmem = SocModel._DMEM
        self.core = CoreISS(self.dmem, self.imem)
        self.axi = AxiModel()
        self.cycle = 0

    def reset(self):
        self.core.reset()
        self.axi.reset()

    def core_outputs(self):
        c = self.core
        return dict(core_done=int(c.done), core_illegal=int(c.ill), core_stk_ovf=int(c.ovf))

    def mem_rdata(self):
        a = self.axi
        return (self.imem if a.mem_is_imem else self.dmem)[a.mem_addr & IDX]
