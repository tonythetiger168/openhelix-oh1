"""Constrained-random OH-1 kernel generator.

Programs are built from weighted random constructs. Structural constraints keep
most programs terminating (forward branches, balanced split/join, bounded loops),
while knobs deliberately produce the corner cases needed for coverage closure:
deep nesting (stack overflow), illegal encodings, divergent JALR, TMC clamping,
same-address stores, address aliasing and programs that never exit (watchdog).
"""
import random

from oh1_isa import (K, R_OPS, I_OPS, BR_OPS, enc_r, enc_i, enc_lw, enc_sw, enc_csrr, enc_b,
                     enc_u, enc_jal, enc_jalr, enc_split, enc_c3, enc_vdot4, decode,
                     F3_JOIN, F3_TMC, F3_BAR, F3_WEXIT, F3_TEXIT, F3_VDOT, F3_WSPAWN,
                     CSR_TID, CSR_LANEID, OPC_CUSTOM0)

# Register conventions (soft; "chaos" mode ignores them)
X_TID, X_TID4, X_TMC, X_LOOP, X_TMP = 1, 6, 2, 10, 11
DATA_REGS = [3, 4, 5, 7, 8, 9, 12, 13, 14, 15, 16, 17, 20, 24, 28, 31]


class Knobs:
    def __init__(self, **kw):
        self.max_len = 96
        self.n_constructs = (4, 14)
        self.w = dict(alu=10, const=4, lane=4, split=5, branch=4, loop=1, lsu=5, tmc=2,
                      jump=3, csr=2, vdot=2, illegal=1, bar=1, jalr_div=0, deep=1, fill=2)
        self.max_nest = 3
        self.chaos = 0.05            # probability of using any register as rd
        self.exit_mix = dict(texit=8, wexit=3, none=0)
        self.big_imm = 0.3
        self.base_mode = "mixed"     # mixed | random32
        self.__dict__.update(kw)


class Program:
    def __init__(self, words, base, dinit, desc):
        self.words, self.base, self.dinit, self.desc = words, base, dinit, desc


class ProgGen:
    def __init__(self, rng: random.Random, knobs: Knobs = None):
        self.r = rng
        self.k = knobs or Knobs()

    # ---------------------------------------------------------------- helpers
    def rd(self):
        if self.r.random() < self.k.chaos:
            return self.r.randrange(32)
        return self.r.choice(DATA_REGS)

    def src(self):
        p = self.r.random()
        if p < 0.08:
            return 0
        if p < 0.2:
            return self.r.choice([X_TID, X_TID4])
        if p < 0.25:
            return self.r.randrange(32)
        return self.r.choice(DATA_REGS)

    def imm12(self):
        r = self.r
        if r.random() < self.k.big_imm:
            return r.choice([0, 1, -1, 0x7FF, -0x800, r.randrange(-2048, 2048)])
        return r.randrange(-64, 64)

    def emit(self, w):
        self.p.append(w & 0xFFFFFFFF)

    # ---------------------------------------------------------------- constructs
    def c_alu(self):
        r = self.r
        rd = 0 if r.random() < 0.06 else self.rd()
        if r.random() < 0.5:
            k = r.choice(R_OPS)
            if k in (K.SLL, K.SRL, K.SRA) and r.random() < 0.4:
                self.emit(enc_i(K.ADDI, X_TMP, 0, r.choice([0, 31, 31, r.randrange(32)])))
                self.emit(enc_r(k, rd, self.src(), X_TMP))
            else:
                self.emit(enc_r(k, rd, self.src(), self.src()))
        else:
            k = r.choice(I_OPS)
            imm = r.choice([0, 31, r.randrange(32)]) if k in (K.SLLI, K.SRLI, K.SRAI) else self.imm12()
            self.emit(enc_i(k, rd, self.src(), imm))

    def c_const(self):
        r = self.r
        d = self.rd()
        v = r.choice([0, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 1, r.getrandbits(32)])
        hi = ((v + 0x800) >> 12) & 0xFFFFF
        self.emit(enc_u(K.LUI, d, hi))
        self.emit(enc_i(K.ADDI, d, d, ((v & 0xFFF) ^ 0x800) - 0x800))
        if r.random() < 0.2:
            self.emit(enc_u(K.AUIPC, self.rd(), r.getrandbits(20)))

    def c_lane(self):
        """Lane-dependent values (drive divergence and per-lane data)."""
        r = self.r
        d = self.rd()
        op = r.choice([K.ADD, K.MUL, K.XOR, K.SLL, K.SUB, K.SLT])
        self.emit(enc_r(op, d, r.choice([X_TID, X_TID4]), self.src()))

    def c_csr(self):
        r = self.r
        csr = r.choice([CSR_TID, CSR_LANEID, CSR_LANEID, r.randrange(4096)])
        self.emit(enc_csrr(self.rd(), csr, r.choice([0, 0, r.randrange(32)])))

    def c_vdot(self):
        self.emit(enc_vdot4(0 if self.r.random() < 0.1 else self.rd(), self.src(), self.src()))

    def c_bar(self):
        self.emit(enc_c3(F3_BAR))

    def filler(self, n):
        for _ in range(n):
            self.r.choice([self.c_alu, self.c_alu, self.c_lane, self.c_csr, self.c_vdot])()

    def body(self, depth):
        """One construct inside a divergent region (anything except loops)."""
        r = self.r
        c = r.randrange(20)
        if c < 9:
            self.filler(1)
        elif c < 11:
            self.c_lsu()
        elif c == 11:
            self.c_branch()
        elif c == 12:
            self.c_jump()
        elif c == 13:
            self.c_bar()
        elif c == 14:
            self.c_const()
        elif c == 15 and self.k.w.get("illegal", 0):
            self.c_illegal()
        elif c == 16:
            self.c_tmc(restore=r.random() < 0.5)
        elif c == 17 and r.random() < 0.15:
            self.emit(enc_c3(r.choice([F3_TEXIT, F3_WEXIT])))   # exit from a divergent path
        elif c == 18 and depth < self.k.max_nest:
            self.c_split(depth + 1)
        else:
            self.filler(1)

    def pred_reg(self):
        """Emit a predicate computation; return its register."""
        r = self.r
        c = r.randrange(8)
        if c >= 6:                            # arbitrary per-lane pattern: bit tid of a constant
            self.emit(enc_i(K.ADDI, X_TMP, 0, r.randrange(16)))
            self.emit(enc_r(K.SRL, X_TMP, X_TMP, X_TID))
            self.emit(enc_i(K.ANDI, X_TMP, X_TMP, 1))
            return X_TMP
        if c == 0:
            return X_TID                      # lanes 1..3 true
        if c == 1:
            return 0                          # all false
        if c == 2:
            self.emit(enc_i(K.ADDI, X_TMP, 0, r.randrange(1, 100)))
            return X_TMP                      # all true
        if c == 3:
            self.emit(enc_i(K.ANDI, X_TMP, X_TID, r.choice([1, 2, 3])))
            return X_TMP
        if c == 4:
            self.emit(enc_i(K.SLTI, X_TMP, X_TID, r.randrange(0, 5)))
            return X_TMP
        return self.src()                     # random data

    def c_split(self, depth=0):
        r = self.r
        pr = self.pred_reg()
        sidx = len(self.p)
        self.emit(0)
        then_n = r.randint(0, 4)
        for i in range(max(then_n, 1)):
            if depth < self.k.max_nest and r.random() < 0.6 and i == 0:
                self.c_split(depth + 1)
            else:
                self.body(depth)
        self.emit(enc_c3(F3_JOIN))
        eidx = len(self.p)
        for _ in range(r.randint(0, 3)):
            if depth < self.k.max_nest and r.random() < 0.25:
                self.c_split(depth + 1)
            else:
                self.body(depth)
        self.emit(enc_c3(F3_JOIN))
        self.p[sidx] = enc_split(pr, (eidx - sidx) * 2)
        if r.random() < 0.1:
            self.emit(enc_c3(F3_JOIN))        # extra join: pops an outer entry / empty stack

    def c_deep(self):
        """Chain of splits nested in their else paths. x0 predicates are all-false and
        push one tag entry each, so a long chain overflows the 8-entry divergence stack;
        the innermost region then exercises mixed / empty splits at depth 6..8."""
        r = self.r
        n = r.choice([4, 5, 6, 6, 7, 7, 8, 9, r.randint(3, 11)])
        for _ in range(n):
            sidx = len(self.p)
            self.emit(0)                       # split -> (else) next link of the chain
            self.emit(enc_c3(F3_JOIN))         # then path: pops back into the chain
            self.p[sidx] = enc_split(r.choice([0, 0, 0, X_TID, 3, 4, 5]), 2 * 2)
        c = r.randrange(4)
        if c == 0:                            # empty split (no active lane) at depth
            self.emit(enc_i(K.ADDI, X_TMC, 0, 0))
            self.emit(enc_c3(F3_TMC, X_TMC))
            self.c_split(self.k.max_nest)
        elif c == 1:                          # mixed split at depth
            sidx = len(self.p)
            self.emit(enc_split(X_TID, 0))
            self.filler(1)
            self.emit(enc_c3(F3_JOIN))
            eidx = len(self.p)
            self.filler(1)
            self.emit(enc_c3(F3_JOIN))
            self.p[sidx] = enc_split(X_TID, (eidx - sidx) * 2)
        elif c == 2:
            self.c_split(self.k.max_nest)
        else:
            self.body(self.k.max_nest)
        for _ in range(n):
            self.emit(enc_c3(F3_JOIN))

    def c_fill(self):
        """Load per-lane random words into arbitrary registers (RF toggle coverage)."""
        r = self.r
        regs = list(range(1, 32)) if r.random() < 0.3 else r.sample(range(2, 32), r.randint(1, 4))
        regs = [x for x in regs if x != X_TID4] + ([X_TID4] if X_TID4 in regs else [])
        for d in regs:
            self.emit(enc_lw(d, X_TID4, 16 * r.randrange(16)))
        if X_TID in regs or X_TID4 in regs:   # restore the lane-id conventions
            self.emit(enc_csrr(X_TID, CSR_TID))
            self.emit(enc_i(K.SLLI, X_TID4, X_TID, 2))

    def c_branch(self):
        r = self.r
        n = r.randint(0, 4)
        c = r.randrange(5)
        if c == 0:
            a, b = 0, 0                      # uniform
        elif c == 1:
            a, b = X_TID, 0                  # divergent
        elif c == 2:
            a, b = X_TID, X_TID
        else:
            a, b = self.src(), self.src()
        k = r.choice(BR_OPS)
        off = (n + 1) * 4
        if r.random() < 0.05:
            off = r.choice([2, 6]) if r.random() < 0.5 else off   # half-word (misaligned) target
        self.emit(enc_b(k, a, b, off))
        self.filler(n)

    def c_loop(self):
        """Bounded backward loop on a warp-uniform counter."""
        r = self.r
        if self.mask_maybe_zero:
            return self.c_alu()
        self.emit(enc_i(K.ADDI, X_LOOP, 0, r.randint(1, 4)))
        top = len(self.p)
        self.filler(r.randint(1, 3))
        self.emit(enc_i(K.ADDI, X_LOOP, X_LOOP, -1))
        self.emit(enc_b(K.BNE, X_LOOP, 0, (top - len(self.p)) * 4))

    def c_lsu(self):
        r = self.r
        c = r.randrange(6)
        imm = r.randrange(0, 64) * 4
        if c == 0:
            base = 0                          # all lanes same address
        elif c == 1:
            base = self.src()                 # random address (aliasing, misaligned)
            imm = self.imm12()
        else:
            base = X_TID4
        if r.random() < 0.5:
            self.emit(enc_sw(self.src(), base, imm))
        else:
            self.emit(enc_lw(self.rd(), base, imm))

    def c_tmc(self, restore=None):
        r = self.r
        if r.random() < 0.3:                  # TMC from an already-reduced mask
            self.emit(enc_i(K.ADDI, X_TMC, 0, r.choice([0, 0, 1, 2, 3])))
            self.emit(enc_c3(F3_TMC, X_TMC))
        n = r.choice([0, 1, 2, 3, 4, 4, 5, 7, 1000])
        reg = X_TMC
        if r.random() < 0.2:
            reg = self.src()                  # lane-0 value of an arbitrary register
            self.mask_maybe_zero = True
        else:
            self.emit(enc_i(K.ADDI, X_TMC, 0, n))
            if n == 0:
                self.mask_maybe_zero = True
        self.emit(enc_c3(F3_TMC, reg))
        for _ in range(r.randint(1, 3)):
            self.body(self.k.max_nest) if r.random() < 0.5 else self.filler(1)
        if (r.random() < 0.7) if restore is None else restore:   # restore the full warp
            self.emit(enc_i(K.ADDI, X_TMC, 0, 4))
            self.emit(enc_c3(F3_TMC, X_TMC))
            self.mask_maybe_zero = False

    def c_jump(self):
        r = self.r
        n = r.randint(0, 3)
        link = r.choice([0, 3, 5, r.randrange(32)])
        if r.random() < 0.5:
            self.emit(enc_jal(link, (n + 1) * 4))
        else:
            self.emit(enc_u(K.AUIPC, X_TMP, 0))
            self.emit(enc_jalr(link, X_TMP, (n + 2) * 4 + r.choice([0, 0, 1])))
        self.filler(n)

    def c_jalr_div(self):
        """JALR whose target differs per lane -> illegal; lands on a TEXIT pad."""
        self.emit(enc_u(K.AUIPC, X_TMP, 0))
        self.emit(enc_r(K.ADD, X_TMP, X_TMP, X_TID4))
        self.emit(enc_jalr(0, X_TMP, 4 * 4))
        self.emit(enc_c3(F3_TEXIT))
        for _ in range(4):
            self.emit(enc_c3(F3_TEXIT))

    def c_illegal(self):
        r = self.r
        c = r.randrange(8)
        if c == 0:
            w = enc_c3(F3_VDOT, self.src(), self.src(), 0, self.rd())         # FP16 vdot form
        elif c == 1:
            w = enc_c3(F3_WSPAWN, self.src(), self.src())
        elif c == 2:
            w = enc_r(K.ADD, 3, 4, 5) | (r.choice([0x10, 0x02, 0x7F]) << 25)  # bad funct7
        elif c == 3:
            w = (enc_b(K.BEQ, 0, 0, 8) & ~(7 << 12)) | (r.choice([2, 3, 6, 7]) << 12)
        elif c == 4:
            w = (enc_lw(3, 0, 0) & ~(7 << 12)) | (r.choice([0, 1, 4, 5]) << 12)
        elif c == 5:
            w = (enc_jalr(0, 0, 0) & ~(7 << 12)) | (r.randrange(1, 8) << 12)
        elif c == 6 and r.random() < 0.5:
            w = (enc_sw(3, 0, 0) & ~(7 << 12)) | (r.choice([0, 1, 3, 4, 5, 6, 7]) << 12)
        elif c == 6:
            w = (enc_csrr(3, CSR_TID) & ~(7 << 12)) | (r.choice([0, 1, 3, 4, 5, 6, 7]) << 12)
        else:
            while True:
                w = r.getrandbits(32)
                if decode(w)[0] == K.ILL:
                    break
        self.emit(w)

    # ---------------------------------------------------------------- top
    def gen(self):
        r, k = self.r, self.k
        self.p = []
        self.mask_maybe_zero = False
        self.emit(enc_csrr(X_TID, CSR_TID))
        self.emit(enc_i(K.SLLI, X_TID4, X_TID, 2))
        for reg in r.sample(DATA_REGS, 4):
            self.emit(enc_i(K.ADDI, reg, X_TID, r.randrange(-50, 50)))
        names = list(k.w)
        weights = [k.w[n] for n in names]
        for _ in range(r.randint(*k.n_constructs)):
            if len(self.p) > k.max_len - 12:
                break
            getattr(self, "c_" + r.choices(names, weights)[0])()
        ex = r.choices(list(k.exit_mix), list(k.exit_mix.values()))[0]
        if ex == "texit":
            self.emit(enc_c3(F3_TEXIT))
        elif ex == "wexit":
            self.emit(enc_c3(F3_WEXIT))
        elif ex == "hang":
            self.emit(enc_jal(0, 0))           # spin until the watchdog resets the core
        base = r.choice([0, r.randrange(4096) * 4, r.getrandbits(32) & ~3, r.getrandbits(32)])
        if k.base_mode == "random32":
            base = r.getrandbits(32)
        elif r.random() < 0.5:
            base &= 0x3FFC
        dinit = {r.randrange(4096) if r.random() < 0.3 else r.randrange(256):
                 r.getrandbits(32) for _ in range(r.randint(0, 24))}
        return Program(self.p, base & 0xFFFFFFFF, dinit, ex)
