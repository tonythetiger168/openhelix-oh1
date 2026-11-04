"""pyuvm tests for OH-1 (run through verif/run.py).

Environment knobs:  OH1_N (kernels per CRV test, default 40), RANDOM_SEED (cocotb).
"""
import os
import random
import zlib

import cocotb
import pyuvm
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb_coverage.coverage import coverage_db
from pyuvm import uvm_test, ConfigDB

from oh1_env import Oh1Env
from oh1_progen import Knobs, Program
from oh1_seqs import (KernelSeq, RegAccessSeq, MidRunResetSeq, DmemSweepSeq, BaseSeq, REG,
                      IMEM, DMEM, RegStrobeSweepSeq, IdleResetSeq)
from oh1_isa import enc_i, enc_c3, enc_csrr, enc_sw, enc_lw, enc_r, K, F3_TEXIT, CSR_TID

N = int(os.environ.get("OH1_N", "40"))
COV_FILE = os.environ.get("OH1_FCOV", "fcov.yml")


class Oh1BaseTest(uvm_test):
    def build_phase(self):
        self.env = Oh1Env("env", self)
        # str hash() is randomised per process; crc32 keeps every test reproducible per seed
        self.rng = random.Random(cocotb.RANDOM_SEED ^ zlib.crc32(type(self).__name__.encode()))

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
        dut.rst_n.value = 0
        seqr = ConfigDB().get(None, "", "SEQR")
        self.seqr = seqr
        for _ in range(3):
            await RisingEdge(dut.clk)
        dut.rst_n.value = 1
        await self.body()
        for _ in range(5):
            await RisingEdge(dut.clk)
        self.drop_objection()

    async def kernels(self, n, knobs_fn, side=0.4):
        for _ in range(n):
            await KernelSeq("k", knobs=knobs_fn(), side=side, rng=self.rng).start(self.seqr)

    def report_phase(self):
        coverage_db.export_to_yaml(COV_FILE)


@pyuvm.test()
class Oh1SmokeTest(Oh1BaseTest):
    """Directed: one kernel that stores per-lane values, then read them back."""

    async def body(self):
        w = [enc_csrr(1, CSR_TID), enc_i(K.SLLI, 6, 1, 2), enc_i(K.ADDI, 3, 1, 100),
             enc_r(K.MUL, 4, 3, 3), enc_sw(4, 6, 0x40), enc_lw(5, 6, 0x40), enc_c3(F3_TEXIT)]
        await KernelSeq("smoke", prog=Program(w, 0, {}, "texit"), side=0, rng=self.rng).start(self.seqr)
        await DmemSweepSeq("sweep", lo=16, hi=20, rng=self.rng).start(self.seqr)


@pyuvm.test()
class Oh1CrvTest(Oh1BaseTest):
    """Default constrained-random kernels with AXI side traffic."""

    async def body(self):
        await self.kernels(N, Knobs)


@pyuvm.test()
class Oh1SimtStressTest(Oh1BaseTest):
    """Deep divergence: nesting beyond the 8-entry stack, TMC, branches inside regions."""

    async def body(self):
        def k():
            return Knobs(max_nest=self.rng.choice([2, 3, 4, 5]),
                         w=dict(alu=4, const=1, lane=4, split=10, branch=4, loop=1, lsu=3,
                                tmc=3, jump=2, csr=1, vdot=1, illegal=0, bar=1, jalr_div=0,
                                deep=4, fill=1),
                         exit_mix=dict(texit=8, wexit=3, hang=1))
        await self.kernels(N // 2, k, side=0.2)


@pyuvm.test()
class Oh1FaultTest(Oh1BaseTest):
    """Illegal encodings, divergent JALR, programs without an exit, mid-run reset."""

    async def body(self):
        def k():
            return Knobs(chaos=0.3, w=dict(alu=5, const=2, lane=2, split=3, branch=3, loop=1,
                                           lsu=3, tmc=2, jump=3, csr=1, vdot=1, illegal=4,
                                           bar=1, jalr_div=2, deep=2, fill=2),
                         exit_mix=dict(texit=5, wexit=3, none=1, hang=2))
        for i in range(N // 2):
            await KernelSeq("f", knobs=k(), side=0.5, watchdog=1500, rng=self.rng).start(self.seqr)
            if i % 5 == 0:
                await MidRunResetSeq("mrr", rng=self.rng).start(self.seqr)


@pyuvm.test()
class Oh1AxiTest(Oh1BaseTest):
    """Register page / window / error-response / strobe / ordering stress."""

    async def body(self):
        await RegStrobeSweepSeq("sweep_regs", rng=self.rng).start(self.seqr)
        for _ in range(4):
            await RegAccessSeq("regs", n=max(N, 20), rng=self.rng, timing=0.7).start(self.seqr)
            await KernelSeq("k", knobs=Knobs(), side=0.8, rng=self.rng, timing=0.7).start(self.seqr)
        await DmemSweepSeq("sweep", lo=0, hi=256, rng=self.rng).start(self.seqr)


@pyuvm.test()
class Oh1StackClosureTest(Oh1BaseTest):
    """Coverage closure for the divergence stack: long split chains (depth 6..11),
    random 32-bit (also odd) PROG_BASE so stacked else-PCs toggle every bit, and
    hanging / faulting kernels (watchdog x illegal x overflow)."""

    async def body(self):
        def k():
            return Knobs(base_mode="random32", max_nest=3,
                         w=dict(alu=2, const=1, lane=1, split=2, branch=1, loop=0, lsu=1, tmc=2,
                                jump=1, csr=1, vdot=1, illegal=1, bar=0, jalr_div=0, deep=8, fill=0),
                         exit_mix=dict(texit=4, wexit=2, hang=3))
        await self.kernels(N // 2, k, side=0.2)


@pyuvm.test()
class Oh1CdvTest(Oh1BaseTest):
    """Coverage-driven CRV: after every batch of kernels the uncovered functional bins are
    read back from the coverage DB and turned into constraints for the next batch
    (oh1_cdv.ClosureLoop). Stops at local closure or after OH1_CDV_BUDGET kernels."""
    FEEDBACK = True

    async def body(self):
        from oh1_cdv import ClosureLoop
        budget = int(os.environ.get("OH1_CDV_BUDGET", str(2 * N)))
        sb = ConfigDB().get(None, "", "SCOREBOARD")
        loop = ClosureLoop(self.rng, feedback=self.FEEDBACK)
        done, swept, c0 = 0, False, sb.cycles
        loop.record(0, 0)
        while done < budget:
            knobs, targeted, actions = loop.plan()
            if "regs" in actions:
                if not swept:
                    await RegStrobeSweepSeq("sweep_regs", rng=self.rng).start(self.seqr)
                    swept = True
                await RegAccessSeq("regs", n=20, rng=self.rng, timing=0.7).start(self.seqr)
            if "reset" in actions:
                await MidRunResetSeq("mrr", rng=self.rng).start(self.seqr)
                await IdleResetSeq("idle_rst", rng=self.rng).start(self.seqr)
            side = 0.7 if "side" in actions else 0.4
            for _ in range(min(loop.batch, budget - done)):
                await KernelSeq("k", knobs=knobs, side=side, watchdog=1500,
                                rng=self.rng).start(self.seqr)
                done += 1
            loop.credit(knobs)
            open_ = loop.record(done, sb.cycles - c0)
            self.logger.info(f"CDV batch: {done} kernels, {len(targeted)} targeted, "
                             f"{loop.size - len(open_)}/{loop.size} bins")
            if not open_:
                break
        loop.dump(os.environ.get("OH1_CURVE", "cdv_curve.json"),
                  extra=dict(test=type(self).__name__, seed=cocotb.RANDOM_SEED, budget=budget))


@pyuvm.test()
class Oh1CdvBaselineTest(Oh1CdvTest):
    """Same loop, same budget and batch size, feedback off: pure constrained-random with the
    default constraints. Only used by scripts/cdv_compare.py for the closure curve."""
    FEEDBACK = False
