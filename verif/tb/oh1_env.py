"""pyuvm environment for the OH-1 SoC harness (verif/hdl/oh1_tb_top.sv).

  Oh1Env
   +-- BusAgent        sequencer + driver for AXI4-Lite, reset and start-inject
   +-- CycleScoreboard samples every harness pin each clock, steps SocModel,
   |                   compares all predicted outputs, publishes events
   +-- Oh1Coverage     functional covergroups (cocotb-coverage), fed by the scoreboard
"""
import random

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, Timer
from pyuvm import (uvm_sequence_item, uvm_sequencer, uvm_driver, uvm_component, uvm_env,
                   uvm_analysis_port, ConfigDB)

from oh1_isa import LANES, MASK32
from oh1_ref_model import SocModel, AxiModel, decode_target, word_index, MEM_WORDS

AXI_IN = ("awaddr", "awvalid", "wdata", "wstrb", "wvalid", "bready",
          "araddr", "arvalid", "rready")


# =============================================================================
# Sequence item
# =============================================================================
class BusItem(uvm_sequence_item):
    """op: write | read | write_read | reset | inject | idle"""

    def __init__(self, name="bus_item", op="write", addr=0, data=0, strb=0xF,
                 raddr=0, cycles=1, aw_dly=0, w_dly=0, resp_dly=0):
        super().__init__(name)
        self.op, self.addr, self.data, self.strb = op, addr & MASK32, data & MASK32, strb
        self.raddr, self.cycles = raddr & MASK32, cycles
        self.aw_dly, self.w_dly, self.resp_dly = aw_dly, w_dly, resp_dly
        self.bresp = self.rresp = self.rdata = None

    def __str__(self):
        return f"{self.op} a={self.addr:08x} d={self.data:08x} s={self.strb:x}"


# =============================================================================
# Driver
# =============================================================================
class BusDriver(uvm_driver):
    def build_phase(self):
        self.dut = cocotb.top

    async def run_phase(self):
        d = self.dut
        for s in AXI_IN:
            getattr(d, s).value = 0
        d.tb_start_inj_i.value = 0
        while True:
            it = await self.seq_item_port.get_next_item()
            if it.op == "reset":
                await RisingEdge(d.clk)
                d.rst_n.value = 0
                for s in AXI_IN:
                    getattr(d, s).value = 0
                for _ in range(it.cycles):
                    await RisingEdge(d.clk)
                d.rst_n.value = 1
                await RisingEdge(d.clk)
            elif it.op == "idle":
                for _ in range(it.cycles):
                    await RisingEdge(d.clk)
            elif it.op == "inject":
                await RisingEdge(d.clk)
                d.tb_start_inj_i.value = 1
                await RisingEdge(d.clk)
                d.tb_start_inj_i.value = 0
            elif it.op == "write":
                await self.do_write(it)
            elif it.op == "read":
                await self.do_read(it)
            elif it.op == "read_reset":
                # reset while a memory read is in flight (wrapper in RD_MEM_WAIT)
                t = cocotb.start_soon(self.do_read(it))
                for _ in range(2 + it.cycles):
                    await RisingEdge(d.clk)
                t.cancel()
                d.rst_n.value = 0
                for s in AXI_IN:
                    getattr(d, s).value = 0
                for _ in range(2):
                    await RisingEdge(d.clk)
                d.rst_n.value = 1
                await RisingEdge(d.clk)
            elif it.op == "write_pair":
                await self.do_write_pair(it)
            elif it.op == "write_read":
                w = cocotb.start_soon(self.do_write(it))
                await self.do_read(it)
                await w
            self.seq_item_port.item_done()

    async def _hs(self, valid, ready, dly, setup):
        d = self.dut
        for _ in range(dly):
            await RisingEdge(d.clk)
        setup()
        valid.value = 1
        while True:
            await ReadOnly()
            ok = int(ready.value)
            await RisingEdge(d.clk)
            if ok:
                break
        valid.value = 0

    async def _resp(self, valid, ready, dly):
        d = self.dut
        while True:
            await ReadOnly()
            if int(valid.value):
                break
            await RisingEdge(d.clk)
        await RisingEdge(d.clk)
        for _ in range(dly):
            await RisingEdge(d.clk)
        ready.value = 1
        while True:
            await ReadOnly()
            v = int(valid.value)
            got = (int(d.rdata.value), int(d.rresp.value), int(d.bresp.value))
            await RisingEdge(d.clk)
            if v:
                break
        ready.value = 0
        return got

    async def do_write(self, it):
        d = self.dut
        await RisingEdge(d.clk)

        def aw():
            d.awaddr.value = it.addr

        def w():
            d.wdata.value, d.wstrb.value = it.data, it.strb

        ta = cocotb.start_soon(self._hs(d.awvalid, d.awready, it.aw_dly, aw))
        tw = cocotb.start_soon(self._hs(d.wvalid, d.wready, it.w_dly, w))
        await ta
        await tw
        it.bresp = (await self._resp(d.bvalid, d.bready, it.resp_dly))[2]

    async def do_write_pair(self, it):
        """Two writes, the second AW/W presented while the first B is still held."""
        d = self.dut
        await RisingEdge(d.clk)
        for addr in (it.addr, it.raddr):
            def setup(a=addr):
                d.awaddr.value, d.wdata.value, d.wstrb.value = a, it.data, 0xF
            ta = cocotb.start_soon(self._hs(d.awvalid, d.awready, 0, setup))
            tw = cocotb.start_soon(self._hs(d.wvalid, d.wready, 0, lambda: None))
            await ta
            await tw
        for _ in range(it.resp_dly):
            await RisingEdge(d.clk)
        it.bresp = (await self._resp(d.bvalid, d.bready, 0))[2]
        await self._resp(d.bvalid, d.bready, 0)

    async def do_read(self, it):
        d = self.dut
        await RisingEdge(d.clk)

        def ar():
            d.araddr.value = it.raddr if it.op == "write_read" else it.addr

        await self._hs(d.arvalid, d.arready, it.aw_dly if it.op == "read" else 0, ar)
        it.rdata, it.rresp, _ = await self._resp(d.rvalid, d.rready, it.resp_dly)


class BusAgent(uvm_component):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.drv = BusDriver("drv", self)
        ConfigDB().set(None, "*", "SEQR", self.seqr)

    def connect_phase(self):
        self.drv.seq_item_port.connect(self.seqr.seq_item_export)


# =============================================================================
# Cycle scoreboard (monitor + predictor + comparator)
# =============================================================================
class Event:
    def __init__(self, kind, **kw):
        self.kind = kind
        self.__dict__.update(kw)


class CycleScoreboard(uvm_component):
    """Samples all harness pins once per clock (ReadOnly after the rising edge),
    advances the SocModel by one cycle and compares every predicted output.

    Analysis ports:  exec_ap  ExecRecord per executed instruction
                     ev_ap    Event (axi_write / axi_read / launch / start_ignored /
                              reset / irq / watchdog / ...)
    """
    MAX_LOG = 20

    def build_phase(self):
        self.dut = cocotb.top
        self.m = SocModel()
        self.exec_ap = uvm_analysis_port("exec_ap", self)
        self.ev_ap = uvm_analysis_port("ev_ap", self)
        self.errors = 0
        self.checks = 0
        self.n_exec = 0
        self.cycles = 0
        self.run_cycles = 0          # cycles since last launch (watchdog support)
        self.was_reset = True
        ConfigDB().set(None, "*", "SCOREBOARD", self)

    def err(self, msg):
        self.errors += 1
        if self.errors <= self.MAX_LOG:
            self.logger.error(f"[cyc {self.cycles}] {msg}")

    def cmp(self, name, got, exp):
        self.checks += 1
        if got != exp:
            self.err(f"{name}: dut={got:#x} model={exp:#x}")

    def lane(self, v, l):
        return (v >> (32 * l)) & MASK32

    async def run_phase(self):
        d = self.dut
        sig = {}
        names = (AXI_IN + ("rst_n", "tb_start_inj_i") + AxiModel.OUTS
                 + ("core_start", "core_done", "core_illegal", "core_stk_ovf", "mem_rdata",
                    "exec_valid", "exec_pc", "exec_mask", "wb_valid", "wb_rd", "wb_lane_mask",
                    "wb_data", "dmem_wen", "dmem_wmask", "dmem_waddr", "dmem_wdata"))
        for n in names:
            if n == "core_start_axi":
                continue
            sig[n] = getattr(d, n)
        prev_irq = 0
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            s = {n: int(h.value) for n, h in sig.items()}
            self.cycles += 1
            self.step(s)
            if s["irq"] != prev_irq:
                self.ev_ap.write(Event("irq", level=s["irq"], stat=self.m.axi.irq_stat))
                prev_irq = s["irq"]

    def step(self, s):
        m, c, a = self.m, self.m.core, self.m.axi
        if not s["rst_n"]:
            if not self.was_reset:
                self.ev_ap.write(Event("reset", running=c.active and not c.done))
            m.reset()
            self.was_reset = True
        else:
            self.was_reset = False
        po = a.outputs()
        for n, v in po.items():
            if n == "core_start_axi":
                continue
            self.cmp(n, s[n], v)
        co = m.core_outputs()
        for n, v in co.items():
            self.cmp(n, s[n], v)
        mem_rd = m.mem_rdata()
        self.cmp("mem_rdata", s["mem_rdata"], mem_rd)
        start = po["core_start_axi"] | s["tb_start_inj_i"]
        self.cmp("core_start", s["core_start"], start)
        if not s["rst_n"]:
            for n in ("exec_valid", "wb_valid", "dmem_wen"):
                self.cmp(n, s[n], 0)
            return

        flags = (c.done, c.ill, c.ovf)
        launch_ok = c.can_launch()           # decided on this cycle's state, before EX
        stores = []
        # ---------------- core EX stage
        if s["exec_valid"]:
            if not c.active or c.done:
                self.err("exec_valid while model core is idle/done")
            self.cmp("exec_pc", s["exec_pc"], c.pc)
            self.cmp("exec_mask", s["exec_mask"], c.act)
            r = c.step()
            self.n_exec += 1
            wb = r.wb_en and r.rd != 0
            self.cmp("wb_valid", s["wb_valid"], int(wb))
            if wb and s["wb_valid"]:
                self.cmp("wb_rd", s["wb_rd"], r.rd)
                self.cmp("wb_lane_mask", s["wb_lane_mask"], r.wb_mask)
                for l in range(LANES):
                    if (r.wb_mask >> l) & 1:
                        self.cmp(f"wb_data[{l}]", self.lane(s["wb_data"], l), r.wb_data[l])
            self.cmp("dmem_wen", s["dmem_wen"], int(r.st_en))
            if r.st_en and s["dmem_wen"]:
                self.cmp("dmem_wmask", s["dmem_wmask"], r.st_mask)
                for l in range(LANES):
                    if (r.st_mask >> l) & 1:
                        self.cmp(f"dmem_waddr[{l}]", self.lane(s["dmem_waddr"], l), r.st_addr[l])
                        self.cmp(f"dmem_wdata[{l}]", self.lane(s["dmem_wdata"], l), r.st_data[l])
                        stores.append(((r.st_addr[l] >> 2) & (MEM_WORDS - 1), r.st_data[l]))
            self.exec_ap.write(r)
            if r.kind.name in ("WEXIT", "TEXIT"):
                self.ev_ap.write(Event("exit", how=r.kind.name, ill=c.ill, ovf=c.ovf))
        else:
            self.cmp("wb_valid", s["wb_valid"], 0)
            self.cmp("dmem_wen", s["dmem_wen"], 0)

        # ---------------- launch
        if start:
            if launch_ok:
                self.ev_ap.write(Event("launch", relaunch=c.active, after_fault=c.ill or c.ovf,
                                       via_inject=bool(s["tb_start_inj_i"] and not po["core_start_axi"]),
                                       pc=a.prog_base))
                if s["exec_valid"]:
                    self.err("launch in a cycle with a live EX instruction")
                c.launch(a.prog_base)
                self.run_cycles = 0
            else:
                self.ev_ap.write(Event("start_ignored", via_inject=bool(s["tb_start_inj_i"]),
                                       with_exit=bool(s["exec_valid"]) and c.done))
        if c.active and not c.done:
            self.run_cycles += 1

        # ---------------- AXI wrapper
        busy_before = a.busy
        a.step({n: s[n] for n in AXI_IN}, *flags, mem_rd)
        if a.last_write:
            t, addr, resp, strb, data = a.last_write
            self.ev_ap.write(Event("axi_write", target=t, addr=addr, resp=resp, busy=busy_before,
                                   strb=strb, data=data, ctrl_start=a.core_start,
                                   irq_en=a.irq_en))
        if a.last_read:
            t, addr = a.last_read
            self.ev_ap.write(Event("axi_read", target=t, addr=addr, busy=busy_before))

        # ---------------- memory commit: core stores first, then AXI (as in the harness)
        for idx, v in stores:
            m.dmem[idx] = v
        if po["mem_we"]:
            mem = m.imem if po["mem_is_imem"] else m.dmem
            idx = po["mem_addr"] & (MEM_WORDS - 1)
            old = mem[idx]
            for b in range(4):
                if (po["mem_wstrb"] >> b) & 1:
                    old = (old & ~(0xFF << 8 * b)) | (po["mem_wdata"] & (0xFF << 8 * b))
            mem[idx] = old & MASK32

    def watchdog(self):
        c = self.m.core
        self.ev_ap.write(Event("exit", how="watchdog", ill=c.ill, ovf=c.ovf))

    def kernel_running(self):
        c = self.m.core
        return c.active and not c.done

    def check_phase(self):
        self.logger.info(f"scoreboard: {self.cycles} cycles, {self.n_exec} instructions, "
                         f"{self.checks} compares, {self.errors} mismatches")
        assert self.errors == 0, f"{self.errors} scoreboard mismatches"
        assert self.n_exec > 0 or not ConfigDB().get(None, "", "EXPECT_EXEC"), "no instructions executed"


# =============================================================================
# Env
# =============================================================================
class Oh1Env(uvm_env):
    def build_phase(self):
        from oh1_coverage import Oh1Coverage
        self.agent = BusAgent("agent", self)
        self.sb = CycleScoreboard("sb", self)
        self.cov = Oh1Coverage("cov", self)

    def connect_phase(self):
        self.sb.exec_ap.connect(self.cov.exec_sub.analysis_export)
        self.sb.ev_ap.connect(self.cov.ev_sub.analysis_export)
