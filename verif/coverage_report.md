# OH-1 coverage report

Runs merged: seed_1, seed_2, seed_3, seed_4, seed_5, seed_6, seed_7, seed_8 | tests: 48 | failing tests: 0

| Metric | Points | Excluded | Covered / eligible | Coverage | Raw (no exclusions) |
|---|---:|---:|---:|---:|---:|
| line | 233 | 90 | 143 / 143 | **100.00%** | 61.37% |
| branch | 164 | 7 | 157 / 157 | **100.00%** | 95.73% |
| expression | 179 | 17 | 162 / 162 | **100.00%** | 90.50% |
| toggle | 14256 | 424 | 13832 / 13832 | **100.00%** | 97.03% |
| FSM states+arcs (f_* covers) | 34 | 0 | 34 / 34 | **100.00%** | 100.00% |
| SVA cover properties | 69 | 0 | 69 / 69 | **100.00%** | 100.00% |
| functional bins (cocotb-coverage) | 788 | 0 | 788 / 788 | **100.00%** | 100.00% |

SVA: 51 assertions (51 instances incl. generate copies), 0 failing tests (a failing assertion stops the simulation and fails the test). Vacuous assertions (antecedent cover never hit): none. Assertions without an antecedent cover (unconditional invariants): a_awready, a_fsm_arcs, a_fsm_arcs_run, a_fsm_legal, a_irq_level, a_one_read, a_rd_idle_arcs, a_rd_legal, a_stk_bound, a_wr_arcs, a_wready, a_x0_zero.

FSM: Verilator `--coverage-fsm` extracted 0 points from this RTL (see the exclusions doc); FSM coverage is measured with explicit state/arc cover properties.

## Per file

| Metric | File | Covered / eligible | Excluded | Coverage |
|---|---|---:|---:|---:|
| branch | rtl/oh1_axi_lite.sv | 35 / 35 | 3 | 100.00% |
| branch | rtl/oh1_core.sv | 110 / 110 | 0 | 100.00% |
| branch | rtl/oh1_decode.sv | 12 / 12 | 0 | 100.00% |
| branch | rtl/oh1_pkg.sv | 0 / 0 | 4 | 100.00% |
| expression | rtl/oh1_axi_lite.sv | 66 / 66 | 0 | 100.00% |
| expression | rtl/oh1_core.sv | 96 / 96 | 0 | 100.00% |
| expression | rtl/oh1_pkg.sv | 0 / 0 | 17 | 100.00% |
| line | rtl/oh1_axi_lite.sv | 33 / 33 | 1 | 100.00% |
| line | rtl/oh1_core.sv | 62 / 62 | 0 | 100.00% |
| line | rtl/oh1_decode.sv | 46 / 46 | 1 | 100.00% |
| line | rtl/oh1_pkg.sv | 2 / 2 | 88 | 100.00% |
| toggle | rtl/oh1_axi_lite.sv | 954 / 954 | 40 | 100.00% |
| toggle | rtl/oh1_core.sv | 12540 / 12540 | 332 | 100.00% |
| toggle | rtl/oh1_decode.sv | 338 / 338 | 52 | 100.00% |

## Functional coverage by group

| Group | Covered / bins | Coverage |
|---|---:|---:|
| oh1.exec.alu | 104 / 104 | 100.00% |
| oh1.exec.br | 33 / 33 | 100.00% |
| oh1.exec.cmp | 24 / 24 | 100.00% |
| oh1.exec.csr | 3 / 3 | 100.00% |
| oh1.exec.illegal | 10 / 10 | 100.00% |
| oh1.exec.join | 17 / 17 | 100.00% |
| oh1.exec.jump | 17 / 17 | 100.00% |
| oh1.exec.kind | 39 / 39 | 100.00% |
| oh1.exec.kind_x_lanes | 195 / 195 | 100.00% |
| oh1.exec.lanes | 5 / 5 | 100.00% |
| oh1.exec.lsu | 26 / 26 | 100.00% |
| oh1.exec.mask | 16 / 16 | 100.00% |
| oh1.exec.mul | 4 / 4 | 100.00% |
| oh1.exec.shift | 43 / 43 | 100.00% |
| oh1.exec.split | 38 / 38 | 100.00% |
| oh1.exec.tmc | 41 / 41 | 100.00% |
| oh1.exec.vdot | 7 / 7 | 100.00% |
| oh1.soc.ctrl | 8 / 8 | 100.00% |
| oh1.soc.exit | 19 / 19 | 100.00% |
| oh1.soc.irq | 4 / 4 | 100.00% |
| oh1.soc.launch | 7 / 7 | 100.00% |
| oh1.soc.rd | 29 / 29 | 100.00% |
| oh1.soc.reset | 2 / 2 | 100.00% |
| oh1.soc.start_ignored | 2 / 2 | 100.00% |
| oh1.soc.wr | 95 / 95 | 100.00% |

## Remaining holes

None.

## Exclusions applied

| ID | Type | Location | Points | Of which hit anyway | Reason |
|---|---|---|---:|---:|---|
| DEC-1 | line | rtl/oh1_decode.sv:59 | 1 | 0 | `default` of the OP-IMM funct3 case. All 8 funct3 values have explicit items, so the default is unreachable. |
| AXI-1 | line | rtl/oh1_axi_lite.sv:298 | 1 | 0 | `default` of the rd_state case. rd_state_e has 3 values in 2 bits; the 4th encoding never occurs (assertion a_rd_legal). |
| AXI-2 | branch | rtl/oh1_axi_lite.sv:93-95 `^if$` | 3 | 0 | Tool artefact: the `if (...) return T_x;` arms of function decode_target never increment Verilator's branch counter because the `return` leaves the function before it. The same conditions are hit thousands of times in expression coverage (line 93) and the T_REG/T_IMEM/T_DMEM results are covered by functional bins oh1.soc.wr.window / rd.window. |
| TGL-X0 | toggle | rtl/oh1_core.sv `^rf_q\[\d\]\[0\]\[` | 256 | 0 | x0 of every lane is never written (writes to rd=0 are suppressed); proven by assertion g_x0[*].a_x0_zero. |
| TGL-ENUM | toggle | rtl/oh1_decode.sv `^kind(_o)?\[([6-9]|[12][0-9]|3[01])\]` | 52 | 0 | oh1_pkg::ikind_e is an int-based enum with 41 values; bits 31:6 are constant 0 by type. |
| TGL-ENUM-CORE | toggle | rtl/oh1_core.sv `^kind\[([6-9]|[12][0-9]|3[01])\]` | 0 | 0 | Same int-based enum (ikind_e) bits 31:6, constant 0 by type. |
| TGL-MEMADDR | toggle | rtl/oh1_axi_lite.sv `^mem_addr_o\[(1[2-9]|2[0-9]|3[01])\]` | 40 | 0 | mem_addr_o is only loaded with in-range word indices (< MEM_WORDS = 4096), so bits 31:12 stay 0 (assertion a_mem_range). |
| TGL-JALR-BIT0 | toggle | rtl/oh1_core.sv `^(g_lane\[\d\]\.)?(jtgt\[\d\]|jalr_pc_c)\[0\]` | 10 | 0 | JALR targets are (rs1 + imm) & ~1 by ISA definition, so bit 0 is constant 0. |
| TGL-STK0 | toggle | rtl/oh1_core.sv `^(stk_tag_q\[0\]:1->0|stk_pc_q\[0\]\[|stk_mask_q\[0\]\[0\]:1->0)` | 66 | 0 | Stack entry 0 is only written by the tag half of a push at depth 0: tag=1, pc=0, mask = the depth-0 active mask, which is always a launch/TMC mask containing lane 0 (a push needs a non-empty mask). Proven by assertion a_stk0_tag. |
| PKG-enc_rtype | any | rtl/oh1_pkg.sv:56-73 | 13 | 0 | oh1_pkg::enc_rtype is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_itype | any | rtl/oh1_pkg.sv:75-95 | 20 | 0 | oh1_pkg::enc_itype is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_btype | any | rtl/oh1_pkg.sv:97-105 | 6 | 0 | oh1_pkg::enc_btype is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_lui | any | rtl/oh1_pkg.sv:107-109 | 3 | 0 | oh1_pkg::enc_lui is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_split | any | rtl/oh1_pkg.sv:112-114 | 1 | 0 | oh1_pkg::enc_split is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_custom3 | any | rtl/oh1_pkg.sv:117-119 | 1 | 0 | oh1_pkg::enc_custom3 is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_sw | any | rtl/oh1_pkg.sv:122-124 | 1 | 0 | oh1_pkg::enc_sw is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_jal | any | rtl/oh1_pkg.sv:127-129 | 1 | 0 | oh1_pkg::enc_jal is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_jalr | any | rtl/oh1_pkg.sv:132-134 | 1 | 0 | oh1_pkg::enc_jalr is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_vdot4 | any | rtl/oh1_pkg.sv:137-139 | 1 | 0 | oh1_pkg::enc_vdot4 is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-dec_kind | any | rtl/oh1_pkg.sv:151-192 | 60 | 0 | oh1_pkg::dec_kind is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
| PKG-enc_vdot | any | rtl/oh1_pkg.sv:197-201 | 1 | 0 | oh1_pkg::enc_vdot is a generator/ISS helper; no RTL module calls it (pyslang reference scan), so it is never synthesised. |
