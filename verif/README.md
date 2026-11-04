# OH-1 coverage-driven verification (pyuvm + cocotb + Verilator)

Constrained-random, coverage-driven verification of the OH-1 SoC block
(`oh1_axi_lite` + `oh1_core`) with an open-source flow:

| Piece | Tool | Version (pinned in `requirements.txt`) |
|---|---|---|
| Simulator + code coverage + SVA | Verilator (PyPI wheel, 5.049 dev build) | `verilator==5.48.0` |
| Python co-simulation | cocotb | 2.1.0 |
| UVM class library | pyuvm | 5.0.0 |
| Functional coverage | cocotb-coverage | 2.0 |
| Front-end check, assertion inventory, exclusion analysis | pyslang | 12.1.0 |

Commercial simulators are not needed. The older SystemVerilog-UVM files in `tb/`
(`oh1_env.sv` etc.) need VCS/Xcelium/Questa and are left untouched.

## Run it

```bash
python -m pip install -r verif/requirements.txt
source verif/tools/setup_verilator.sh            # puts a repaired Verilator on PATH
python verif/run.py --seeds 1 2 3 4 5 6 7 8 --n 40 --gate   # sign-off regression, both builds
python verif/run.py --tests Oh1SmokeTest --seeds 1 --sync-mem 1   # quick check, one build
python verif/run.py --seeds 1 2 --close 4                     # add coverage-driven seeds until 100%
python verif/scripts/cdv_compare.py --seeds 1 2 3 4 5 6 7 8   # closure curve: CDV vs plain CRV
python verif/scripts/mutation_check.py                      # does the TB catch RTL bugs?
```

`make uvm` / `make uvm-signoff` wrap the same commands. Results land in `verif/out/`:
`report.md` (all metrics, per-file table, remaining holes, exclusions), `summary.json`,
`merged_coverage.dat` (Verilator format, works with `verilator_coverage --annotate`),
and per-seed `results.xml` / `coverage.dat` / `fcov.yml` (`seed_<s>/` for the SYNC_MEM=0 build,
`seed_<s>_sync/` for SYNC_MEM=1).

## Two memory-timing builds

`oh1_core` has a `SYNC_MEM` parameter (PR #5). With `SYNC_MEM=1` it expects BRAM-style
registered reads: it drives `imem_addr` one fetch ahead (`if_pc_next_c`) and stalls every LW
for one cycle (`lw_stall_c` / `lw_wait_q`). The harness takes the same parameter and then
registers all its read ports (imem, the four dmem lanes and the wrapper's `mem_rdata`,
read-before-write). `run.py` builds the harness twice and runs every seed on both; the report
merges the two (Verilator renames the specialised module `oh1_core__S…`, which
`cov_report.py` normalises so the points line up). Without the SYNC_MEM=1 build the new RTL
lines are unreachable, which is what dropped line coverage to 98.67% after #5 merged.

The scoreboard knows the mode (`OH1_SYNC_MEM`): it checks `dmem_ren` against the next
instruction, requires exactly one non-retiring stall cycle before each LW, and takes the LW
data that the registered memory latched in the stall cycle (so an AXI write to the same word
in that cycle is modelled correctly). `mem_rdata` is compared one cycle late. Assertions in
`oh1_core_sva.sv` (`g_sync`) pin the fetch-ahead address and the stall/resume protocol. Running
the SYNC_MEM=1 build against the combinational model fails immediately, so the mode check is
not vacuous.

Why the setup script: Ubuntu's Verilator (5.020) is older than cocotb 2.x accepts
(5.036+). The PyPI wheel is new enough but ships `verilated.mk` with its configure
results blank (no `-std=gnu++20`, `-fcoroutines`, PCH `-include`, thread libs);
the script copies the wheel into `verif/.tools/` and fills them in.

## Architecture

```
            pyuvm test (Oh1*Test)  ── sequences: KernelSeq, RegAccessSeq, MidRunResetSeq, ...
                    │
   Oh1Env ──────────┼───────────────────────────────────────────────────────────────
     BusAgent       │  sequencer → BusDriver: AXI4-Lite master with random AW/W skew,
                    │  B/R back-pressure, overlapped write pairs, write+read collisions,
                    │  reset (also mid-read) and a test-only start-inject pin
     CycleScoreboard│  samples every harness pin each clock and steps SocModel:
                    │    CoreISS   instruction-level OH-1 model, lock-stepped on exec_valid
                    │              (pc, mask, every WB lane, every store lane, done/illegal/ovf)
                    │    AxiModel  cycle-accurate AXI4-Lite slave model (all outputs every cycle)
                    │    imem/dmem mirrors, committed in the same order as the harness
     Oh1Coverage    │  cocotb-coverage covergroups fed by the scoreboard
                    ▼
   hdl/oh1_tb_top.sv  oh1_axi_lite + oh1_core + 16 KB imem + 16 KB dmem (DUT = rtl/ unchanged),
                    #(SYNC_MEM) selects combinational or registered memory reads
   hdl/oh1_core_sva.sv, hdl/oh1_axi_sva.sv  bound with `bind`: assertions, antecedent covers,
                    scenario covers, FSM state/arc covers
```

The program generator (`tb/oh1_progen.py`) builds random kernels from weighted constructs:
ALU/MUL/vdot4, lane-dependent data, nested split/join with arbitrary per-lane predicates,
long split chains that overflow the 8-entry divergence stack, TMC (including 0 and clamp),
uniform/divergent forward and backward branches, bounded loops, JAL/JALR (including
divergent JALR → illegal), LW/SW with same-address conflicts, aliasing and misalignment,
illegal encodings of every class, exits from divergent paths and kernels that never exit.
`PROG_BASE` is randomised over the full 32-bit range (including odd values).

Tests: `Oh1SmokeTest` (directed), `Oh1CrvTest`, `Oh1SimtStressTest`, `Oh1FaultTest`,
`Oh1AxiTest`, `Oh1StackClosureTest` (directed-random closure for deep stack entries),
`Oh1CdvTest` (coverage-driven closure loop, below). `Oh1CdvBaselineTest` is the same loop
with feedback off and is only used by `scripts/cdv_compare.py`.

## Coverage-driven closure (CDV)

Plain CRV draws every kernel from fixed weights and waits for rare bins to come up; the
earlier closure work here was done by hand (re-weighting knobs, writing
`Oh1StackClosureTest`). `tb/oh1_cdv.py` closes that loop inside the simulation:

```
ClosureLoop (Oh1CdvTest)
  every batch of 4 kernels:
    holes  <- uncovered bins, read live from the cocotb-coverage DB
              (bins tagged for the other SYNC_MEM build are skipped: unreachable here)
    plan   <- per hole, one of
              * a directed construct ProgGen.c_<name>(*args) that produces exactly that bin
                (target_for(): hazard(prod, cons, gap), memord(pair, dist), redir(kind, next),
                 masked(kind, lanes), mask_to(m), stack_at(tail, depth), tmc_at(arg, before),
                 alu_vals(kind, a, b), br_cond(kind, cond), alu_to(kind, rd), fault_exit(how, fault), ...)
              * a weight boost on the generator knobs of that cover group (saturating)
              * a bus-level action for SoC groups (register sweep, mid-run / idle reset,
                more side traffic, fault exit mix)
    run    <- kernels drawn from the re-weighted knobs; ~half of the constructs are targets
    credit <- every emitted target counts as one try for its holes; a hole still open after
              4 tries is demoted ("stubborn") so it cannot starve the rest, and retried
              once everything else is closed
  stop at local closure or after OH1_CDV_BUDGET kernels (default 2 x OH1_N)
```

Targets are still random inside (registers, data, addresses, PROG_BASE, handshake timing,
side traffic) and every kernel is checked cycle by cycle by the scoreboard; the loop only
moves probability toward what is not covered. `cdv_curve.json` in each run directory has
the per-batch curve and the holes left.

`run.py --close N` is the outer loop across simulations: if the merged report misses the
gate, it runs `Oh1CdvTest` on two more seeds per round (both builds) and re-reports, up to
N rounds.

### Sequence coverage added with it (`oh1.exec.seq.*`, 179 bins)

The pairwise/temporal behaviour of the IF/EX pipeline was not in the functional model:

| Cover item | Bins | What |
|---|---:|---|
| `raw.prod_x_cons` (+ `raw.prod`, `raw.cons`) | 74 (+18) | instruction N+1 reads the register instruction N wrote: producer {alu, mul, vdot, lui/auipc, lw, csr, jal/jalr link} x consumer operand {alu rs1, alu rs2, mul, vdot (incl. accumulator), lw base, sw base, sw data, branch, split predicate, tmc, jalr base}; lw/vdot/csr -> jalr ignored (base would not be uniform or in the program) |
| `lw_use.dist` | 6 | first use of a loaded register 1 / 2 / 3 instructions later, per build |
| `mem.order` | 12 | store->load, store->store, load->store to the same word (some lane), distance 1 / 2, per build (SYNC_MEM=1 issues the LW read in the stall cycle) |
| `redir.type_x_next` (+ `type`, `next`) | 45 (+14) | control transfer {taken branch, jal, jalr, all-false split, join to else} x class of the instruction at the target (IF flush / fetch-ahead) |
| `redir.lw_mode` | 10 | LW right after each kind of transfer, per build |

New SVA (in `oh1_core_sva.sv`): scenario covers `s_raw_rs1`, `s_raw_rs2`, `s_raw_lw_use`,
`s_st_then_ld`, `s_st_then_st`, `s_ld_then_st`, and per-lane assertion `a_rf_write` (every
register write lands in exactly the written lanes' RF, with antecedent cover `c_rf_write`).

## Metrics and how each is measured

| Metric | Source | Scope |
|---|---|---|
| line | Verilator `--coverage-line` | `rtl/*.sv` only |
| branch | Verilator `--coverage-line` branch points (if/else arms, case items) | `rtl/*.sv` |
| expression (condition) | Verilator `--coverage-expr` | `rtl/*.sv` |
| toggle | Verilator `--coverage-toggle`, every bit of every RTL signal incl. RF and stack arrays, both directions | `rtl/*.sv` |
| FSM | `f_*` cover properties: every state and legal arc of the core control FSM `{active_q,done_q}`, the AXI read FSM `rd_state`, the AW/W holding FSM and `busy_q`, including reset arcs; illegal states/arcs are assertions | bind modules |
| SVA | 58 assertions (any failure fails the test) + 84 cover properties; every conditional assertion has a `c_*` cover on its antecedent so vacuity is visible | bind modules |
| functional | 967 bins in `tb/oh1_coverage.py` (instruction × active lanes, operand classes, branch outcome × divergence, split type × stack depth, join type, TMC, LSU patterns, jumps, illegal classes, AXI window × response × busy, register × strobe, CTRL, launch, reset, IRQ, exit × fault, and the `seq.*` pipeline sequences: RAW producer × consumer, load-use distance, same-word memory ordering, redirect × next) | scoreboard |

FSM note: Verilator's `--coverage-fsm` is enabled but extracts 0 points from this RTL.
`oh1_core` has no enum state register, and in `oh1_axi_lite` Verilator instruments only the
first enum-typed `case` of an always block, which is the address decoder, not `rd_state`.
Adding `/*verilator fsm_state*/` to `rd_state` in the RTL would enable the tool path; it was
not done here to keep `rtl/` unchanged.

## Results (8 seeds × 7 tests × 2 builds, `--n 40`)

See `verif/out/report.md` after a run; CI uploads it as the `oh1-coverage` artifact.
At the time of the PR:

| Metric | Covered / eligible | Coverage | Raw, no exclusions |
|---|---:|---:|---:|
| line | 150 / 150 | 100% | 62.50% (90 points are unused `oh1_pkg` helper functions) |
| branch | 161 / 161 | 100% | 95.83% |
| expression | 184 / 184 | 100% | 91.54% |
| toggle | 13900 / 13900 | 100% | 97.04% |
| FSM states + arcs | 34 / 34 | 100% | 100% |
| SVA covers | 84 / 84 | 100% | 100% (58 assertions, 0 failures, 0 vacuous) |
| functional | 967 / 967 | 100% | 100% (788 + 179 sequence bins) |

## Does it catch bugs? (mutation check)

`scripts/mutation_check.py` applies 12 one-line RTL bugs (SLTU signedness, branch
uniformity, stack-full off-by-one, store mask, vdot4 accumulator, IRQ W1C, imem write
protection, STATUS.done masking, SRAI decode, JALR divergence, TMC argument masked by lane 0's
active bit, SYNC_MEM fetch-ahead ignoring the LW stall) to a copy of `rtl/` and runs the
sign-off regression on each. Result: **12/12 killed** (`verif/mutation_report.md`), by the
cycle scoreboard or by assertions (`a_stk_bound`, `a_fetch_next`).

## Exclusions

All exclusions are in `coverage_exclusions.yml` with their reasons and are listed (with
point counts, and how many of the excluded points were hit anyway) in every report:

- `oh1_pkg` functions that no RTL module calls (`enc_*`, `dec_kind`, `enc_vdot`): found by a
  pyslang reference scan, so the list updates itself if the RTL starts using one. `dot4_i8`
  is used by the core and stays in scope.
- Two unreachable `default` arms (fully enumerated OP-IMM funct3 case, 3-state `rd_state`).
- A Verilator artefact: branch counters of `if (...) return ...;` in `decode_target` never
  increment; expression and functional coverage show those arms are taken.
- Constant bits: x0 of the register file, upper bits of the int-based `ikind_e` enum,
  `mem_addr_o[31:12]` (indices are range-checked), JALR target bit 0, and stack entry 0
  (always a tag entry). Each is backed by an assertion where one can be written
  (`a_x0_zero`, `a_mem_range`, `a_stk0_tag`, `a_rd_legal`).

## Findings while building this

- A start pulse that arrives in the same cycle as `WEXIT`/`TEXIT` is dropped (the core is
  not yet `done`). It cannot happen through the AXI wrapper (busy blocks it), only on the bare
  core `start_i` pin. Now pinned down by `a_start_at_exit`.
- `tb/tb_rand.sv` sign-extends B-type immediates from bit 11 instead of bit 12
  (`{{19{b_imm[11]}}, ...}` with `b_imm` declared `[12:1]`). Harmless today because it only
  generates small forward branches; it would mispredict branches of ±2 KB or more.
- Coverage closure is not proof: an early mutation run with a shorter regression let a
  `SRAI → SRLI` decode mutant survive. The coverage model now has a bin for arithmetic
  shifts of negative values by a non-zero amount, and `mutation_check.py` uses the full
  sign-off regression.

## Limits worth knowing

- The AXI model is cycle-accurate and was written from the register map and the RTL, so a
  misunderstanding shared by both would not be caught. The core ISS is instruction-level
  and independent of the RTL structure.
- "100%" means 100% of the bins and points defined here, with the exclusions above. The
  functional model is only as complete as its bins.
- Toggle coverage counts each 32-bit stacked PC bit separately, which is why the closure
  test randomises `PROG_BASE` over 32 bits.
