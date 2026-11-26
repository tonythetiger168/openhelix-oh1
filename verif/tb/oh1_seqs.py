"""OH-1 sequences: AXI register/memory access, kernel launch, side traffic, faults."""
import random

import cocotb
from pyuvm import uvm_sequence, ConfigDB

from oh1_env import BusItem
from oh1_isa import MEM_WORDS, enc_i, enc_c3, enc_csrr, enc_sw, K, F3_TEXIT, CSR_TID
from oh1_progen import ProgGen, Knobs

REG = dict(CTRL=0x00, STATUS=0x04, PROG_BASE=0x08, DATA_BASE=0x0C, PROG_LEN=0x10,
           IRQ_STAT=0x14, VERSION=0x18, CAP=0x1C)
IMEM, DMEM = 0x1000_0000, 0x2000_0000


class BaseSeq(uvm_sequence):
    def __init__(self, name="base", rng=None, timing=0.3):
        super().__init__(name)
        self.rng = rng or random.Random(cocotb.RANDOM_SEED)
        self.timing = timing          # probability of random handshake delays

    def _t(self):
        r = self.rng
        if r.random() < self.timing:
            return dict(aw_dly=r.randint(0, 3), w_dly=r.randint(0, 3), resp_dly=r.randint(0, 3))
        return {}

    async def item(self, **kw):
        it = BusItem(**kw)
        await self.start_item(it)
        await self.finish_item(it)
        return it

    async def write(self, addr, data, strb=0xF):
        return await self.item(op="write", addr=addr, data=data, strb=strb, **self._t())

    async def read(self, addr):
        return await self.item(op="read", addr=addr, **self._t())

    async def write_read(self, waddr, data, raddr, strb=0xF):
        return await self.item(op="write_read", addr=waddr, data=data, strb=strb, raddr=raddr,
                               **self._t())

    async def idle(self, n):
        return await self.item(op="idle", cycles=n)

    async def reset(self, n=3):
        return await self.item(op="reset", cycles=n)

    async def inject(self):
        return await self.item(op="inject")

    def sb(self):
        return ConfigDB().get(None, "", "SCOREBOARD")


class RegAccessSeq(BaseSeq):
    """Random register-page and window accesses, including error responses."""

    def __init__(self, name="reg_access", n=60, **kw):
        super().__init__(name, **kw)
        self.n = n

    def rand_addr(self):
        r = self.rng
        c = r.randrange(8)
        if c < 3:
            return r.choice(list(REG.values()))
        if c == 3:
            return r.choice([0x20, 0x24, 0x3C, 0x80, 0xFC, 0x02, 0x05])   # unmapped / unaligned
        if c == 4:
            return r.choice([IMEM, DMEM]) | (r.randrange(MEM_WORDS) << 2)
        if c == 5:
            return r.choice([IMEM, DMEM]) | (r.randrange(MEM_WORDS, 1 << 26) << 2)   # out of range
        if c == 6:
            return r.choice([0x100, 0x0100_0000, 0x3000_0000, 0xF000_0000, r.getrandbits(32)])
        return r.choice([REG["PROG_BASE"], REG["DATA_BASE"], REG["PROG_LEN"]])

    async def body(self):
        r = self.rng
        for _ in range(self.n):
            a = self.rand_addr()
            if a == REG["CTRL"]:
                d = r.getrandbits(32) & ~1        # never start a kernel from here
            elif a == REG["IRQ_STAT"]:
                d = r.getrandbits(32)
            else:
                d = r.getrandbits(32)
            if (a >> 28) == 1 and r.random() < 0.8:
                continue                          # keep imem mostly intact
            op = r.randrange(5)
            strb = r.choice([0xF, 0xF, 0x0, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC, 0x5, 0xA, 0x7, 0xE])
            if op < 2:
                await self.write(a, d, strb)
            elif op < 4:
                await self.read(a)
            else:
                await self.write_read(a, d, self.rand_addr(), strb)


class RegStrobeSweepSeq(BaseSeq):
    """Every register offset (and an unmapped one) written with every strobe class."""

    async def body(self):
        r = self.rng
        for off in list(REG.values()) + [0x40]:
            for strb in (0xF, 0x0, 0x1, 0x3, 0x5):
                d = r.getrandbits(32)
                if off == REG["CTRL"]:
                    d &= ~1                       # do not start a kernel
                await self.write(off, d, strb)
                await self.read(off)


class KernelSeq(BaseSeq):
    """Load a random program over AXI, launch it, generate side traffic while it
    runs, wait for completion (STATUS polling or IRQ) with a watchdog, clean up."""

    def __init__(self, name="kernel", knobs=None, side=0.5, watchdog=4000, prog=None, **kw):
        super().__init__(name, **kw)
        self.knobs = knobs or Knobs()
        self.side = side
        self.wd = watchdog
        self.prog = prog

    async def load(self, p):
        r = self.rng
        for i, w in enumerate(p.words):
            a = IMEM | ((((p.base >> 2) + i) & (MEM_WORDS - 1)) << 2)
            if r.random() < 0.1:                  # split into two half-word strobed writes
                await self.write(a, w, 0x3)
                await self.write(a, w, 0xC)
            else:
                await self.write(a, w)
        for idx, v in p.dinit.items():
            await self.write(DMEM | (idx << 2), v, r.choice([0xF, 0xF, 0xF, 0x1, 0x6, 0x8]))

    async def side_traffic(self):
        r = self.rng
        c = r.randrange(12)
        if c == 9:
            await self.write(r.choice([0x3000_0000, 0x100, IMEM | (5000 << 2), DMEM | (1 << 27)]),
                             r.getrandbits(32))                                      # DECERR / SLVERR
        elif c == 10:
            await self.read(r.choice([0xF000_0000, 0x200, IMEM | (4096 << 2), DMEM | (9999 << 2)]))
        elif c == 11:
            await self.item(op="write_pair", addr=DMEM | (r.randrange(64, 128) << 2),
                            data=r.getrandbits(32), raddr=DMEM | (r.randrange(128, 192) << 2),
                            resp_dly=r.randint(1, 3))
        elif c == 0:
            await self.write(IMEM | (r.randrange(MEM_WORDS) << 2), r.getrandbits(32))  # SLVERR while busy
        elif c == 1:
            await self.write(REG["CTRL"], r.getrandbits(2))                           # start ignored
        elif c == 2:
            await self.inject()                                                       # pin-level start
        elif c == 3:
            await self.read(DMEM | (r.randrange(64) << 2))
        elif c == 4:
            await self.write(DMEM | (r.randrange(64, MEM_WORDS) << 2), r.getrandbits(32))
        elif c == 5:
            await self.read(IMEM | (r.randrange(MEM_WORDS) << 2))
        elif c == 6:
            await self.write_read(REG["PROG_LEN"], r.getrandbits(32), REG["STATUS"])
        else:
            await self.read(REG["STATUS"])

    async def body(self):
        r = self.rng
        sb = self.sb()
        p = self.prog or ProgGen(r, self.knobs).gen()
        await self.load(p)
        if r.random() < 0.2:
            for b in range(4):
                await self.write(REG["PROG_BASE"], p.base, 1 << b)
        else:
            await self.write(REG["PROG_BASE"], p.base)
        irq_en = r.random() < 0.5
        await self.write(REG["CTRL"], 1 | (int(irq_en) << 1))
        top = cocotb.top
        t0 = sb.cycles
        while True:
            if sb.cycles - t0 > self.wd:
                sb.watchdog()
                if r.random() < 0.5:
                    await self.reset(r.randint(1, 4))
                else:
                    # the kernel cannot be stopped from the bus; recover with a reset
                    await self.reset()
                return
            if r.random() < self.side:
                await self.side_traffic()
            if irq_en:
                await self.idle(r.randint(1, 8))
                if not int(top.irq.value):
                    continue
            it = await self.read(REG["STATUS"])
            if not (it.rdata >> 2) & 1:              # STATUS.busy == 0
                break
        if r.random() < 0.05:
            await self.reset()                    # reset straight after completion
            return
        await self.read(REG["STATUS"])
        await self.read(REG["IRQ_STAT"])
        await self.write(REG["IRQ_STAT"], r.choice([1, 2, 3, 3, 0]), r.choice([0xF, 0xF, 0x1, 0x2]))
        await self.read(REG["IRQ_STAT"])
        for _ in range(r.randint(0, 4)):
            await self.read(DMEM | (r.randrange(64) << 2))


class MidRunResetSeq(BaseSeq):
    """Launch a long kernel and reset while it is running."""

    async def body(self):
        r = self.rng
        words = [enc_csrr(1, CSR_TID), enc_i(K.ADDI, 10, 0, 50)]
        loop = len(words)
        words += [enc_i(K.ADDI, 3, 3, 1), enc_sw(3, 0, 0x40), enc_i(K.ADDI, 10, 10, -1)]
        from oh1_isa import enc_b
        words += [enc_b(K.BNE, 10, 0, (loop - len(words)) * 4), enc_c3(F3_TEXIT)]
        base = r.randrange(MEM_WORDS) << 2
        for i, w in enumerate(words):
            await self.write(IMEM | ((((base >> 2) + i) & (MEM_WORDS - 1)) << 2), w)
        await self.write(REG["PROG_BASE"], base)
        await self.write(REG["CTRL"], 1)
        await self.idle(r.randint(5, 60))
        if r.random() < 0.5:
            await self.item(op="read_reset", addr=DMEM | (r.randrange(64) << 2), cycles=r.randint(1, 3))
        else:
            await self.reset(r.randint(1, 3))


class DmemSweepSeq(BaseSeq):
    """Read back a dmem region over AXI (every read is checked by the scoreboard)."""

    def __init__(self, name="dmem_sweep", lo=0, hi=MEM_WORDS, **kw):
        super().__init__(name, **kw)
        self.lo, self.hi = lo, hi

    async def body(self):
        for i in range(self.lo, self.hi):
            await self.read(DMEM | (i << 2))


class IdleResetSeq(BaseSeq):
    """Reset while no kernel is running."""

    async def body(self):
        await self.idle(self.rng.randint(1, 4))
        await self.reset(self.rng.randint(1, 3))
