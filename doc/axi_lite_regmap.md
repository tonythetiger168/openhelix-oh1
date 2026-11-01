# OH-1 AXI4-Lite register map

Applies to `rtl/oh1_axi_lite.sv` (VERSION `0x0002_0002`). All registers are 32-bit.

## Address windows

| Address | Target | Notes |
| --- | --- | --- |
| `0x0000_0000`–`0x0000_00FF` | Registers | Unmapped offsets return SLVERR |
| `0x1xxx_xxxx` | imem, word index = `addr[27:2]` | Index ≥ MEM_WORDS → SLVERR; writes while busy → SLVERR |
| `0x2xxx_xxxx` | dmem, word index = `addr[27:2]` | Index ≥ MEM_WORDS → SLVERR |
| anything else | — | DECERR |

## Registers

| Offset | Name | Access | Bits |
| --- | --- | --- | --- |
| `0x00` | CTRL | RW | `[0]` start (write 1; ignored while busy), `[1]` irq_en |
| `0x04` | STATUS | RO | `[0]` done, `[1]` illegal, `[2]` busy, `[3]` stk_ovf |
| `0x08` | PROG_BASE | RW | Start PC (byte address) used by the next start |
| `0x0C` | DATA_BASE | RW | Reserved for DMA (scratch) |
| `0x10` | PROG_LEN | RW | Reserved for DMA (scratch) |
| `0x14` | IRQ_STAT | R/W1C | `[0]` done event, `[1]` fault event (illegal or stk_ovf) |
| `0x18` | VERSION | RO | `0x0002_0002` (rev 2 adds MUL, JAL/JALR, vdot4.i8) |
| `0x1C` | CAP | RO | `{MEM_WORDS[15:0], STK_P[7:0], LANES_P[7:0]}` |

Writes to RO registers return SLVERR. WSTRB is honoured on RW registers and forwarded to memory as `mem_wstrb_o`.

## Behaviour

- AW and W are accepted independently, in any order. One write and one read can be outstanding.
- `irq_o = irq_en & |IRQ_STAT`. Events are latched on the rising edge of core done / fault, so clearing IRQ_STAT drops the line even while the core still reports done.
- A start after done relaunches the core without reset: control state, done, illegal and stk_ovf are cleared; the register files keep their contents.
- Memory reads wait two cycles after driving `mem_addr_o`, so both combinational and 1-cycle synchronous (BRAM) memories work.

## Typical driver sequence

1. Write the program into the imem window, data into the dmem window.
2. Write PROG_BASE, then CTRL = `0x3` (start + irq_en).
3. On IRQ: read STATUS (check illegal / stk_ovf), write IRQ_STAT = `0x3`, read results from dmem.
