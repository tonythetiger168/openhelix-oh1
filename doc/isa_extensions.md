# OH-1 ISA extensions (M2.0 deepening)

Four instructions were added on top of the original 21. All are single-cycle in the existing 2-stage pipeline, honour the active-lane mask, and are covered by the random ISS comparison (`tb_rand`) and the directed `tb_isa_ext` test.

| Instruction | Encoding | Per active lane | Notes |
| --- | --- | --- | --- |
| `mul rd, rs1, rs2` | RV32M MUL (`0000001`, f3 `000`, opcode `0110011`) | `rd = (rs1 * rs2)[31:0]` | Low 32 bits only; operands go through operand isolation |
| `jal rd, off` | RV32I JAL | `rd = pc + 4` | Warp-uniform redirect to `pc + off` (1 bubble, like a taken branch) |
| `jalr rd, off(rs1)` | RV32I JALR (f3 `000`) | `rd = pc + 4` | Target `(rs1 + off) & ~1` of the lowest active lane (lane 0 if none). If active lanes disagree, the jump still goes to that target and `illegal` is set: divergent indirect jumps are not supported |
| `vdot4.i8 rd, rs1, rs2` | custom-0, f3 `110` (F3_VDOT), funct7 `0000001` | `rd += Σk s8(rs1.byte[k]) × s8(rs2.byte[k])`, k = 0..3 | Register form, reads `rd` as the accumulator (third RF read port). The FP16 memory form in `tensor_lite_spec.md` keeps funct7 `0000000` and is still illegal in RTL |

Other changes in the same step:

- `wb_valid_o` is now low for writes to `x0` (they were never architectural).
- `enc_vdot` in `oh1_pkg.sv` had a truncated 5-bit opcode field; it now emits a full 7-bit custom-0 opcode.
- `dot4_i8()` in `oh1_pkg.sv` is the shared reference model used by both ISS copies and the directed test.

Typical use, a 4-lane INT8 dot product over 16 bytes per lane:

```
addi  x9, x0, 0          # accumulator
lw    x7, 0(x6)          # 4 activations
lw    x8, 64(x6)         # 4 weights
vdot4.i8 x9, x7, x8
lw    x7, 4(x6)
lw    x8, 68(x6)
vdot4.i8 x9, x7, x8      # ... and so on
```
