#!/usr/bin/env python3
"""Mutation sanity check: does the environment catch real RTL bugs?

Each mutant is a one-line change applied to a temporary copy of rtl/. The
sign-off regression (8 seeds, stopping at the first failing seed) must FAIL for every mutant. Results are
written to verif/out/mutation.md.

  python verif/scripts/mutation_check.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent

SEEDS = [str(s) for s in range(1, 9)]     # the sign-off regression, stopping at the first failure

MUTANTS = [
    ("M1 SLTU compares signed", "oh1_core.sv",
     "I_SLTU: if (act_mask_q[l]) wb_data_c[l] = (rs1_iso <  rs2_iso) ? 32'd1 : 32'd0;",
     "I_SLTU: if (act_mask_q[l]) wb_data_c[l] = ($signed(rs1_iso) <  $signed(rs2_iso)) ? 32'd1 : 32'd0;"),
    ("M2 branch taken if ANY active lane agrees", "oh1_core.sv",
     "if ((act_mask_q & ~cond_vec) == '0) begin",
     "if ((act_mask_q & cond_vec) != '0) begin"),
    ("M3 stack-full check off by one", "oh1_core.sv",
     "(32'(stk_ptr_q) + 2 > STK_P)", "(32'(stk_ptr_q) + 2 > STK_P + 1)"),
    ("M4 masked-off lanes also store", "oh1_core.sv",
     "dmem_wmask_o = ex_live_c ? act_mask_q : '0;", "dmem_wmask_o = ex_live_c ? '1 : '0;"),
    ("M5 vdot4 drops the accumulator", "oh1_core.sv",
     "wb_data_c[l] = rd_data[l] + dot4_i8(rs1_iso, rs2_iso);",
     "wb_data_c[l] = dot4_i8(rs1_iso, rs2_iso);"),
    ("M6 IRQ_STAT write-1-to-clear inverted", "oh1_axi_lite.sv",
     "irq_stat_q <= irq_stat_q & ~w_data_q[1:0];", "irq_stat_q <= irq_stat_q & w_data_q[1:0];"),
    ("M7 imem writable while busy", "oh1_axi_lite.sv",
     "== T_IMEM && busy_q) begin", "== T_IMEM && 1'b0) begin"),
    ("M8 STATUS.done not masked by busy", "oh1_axi_lite.sv",
     "core_done_i && !busy_q};", "core_done_i};"),
    ("M9 SRAI decoded as SRLI", "oh1_decode.sv",
     "if (instr_i[31:25]==7'b0100000) begin kind = I_SRAI;",
     "if (instr_i[31:25]==7'b0100001) begin kind = I_SRAI;"),
    ("M10 JALR divergence not flagged", "oh1_core.sv",
     "if (ill_d || (kind == I_JALR && jalr_div_c)) ill_q <= 1'b1;",
     "if (ill_d) ill_q <= 1'b1;"),
]


def main():
    rows = []
    for name, f, old, new in MUTANTS:
        with tempfile.TemporaryDirectory() as td:
            rtl = Path(td) / "rtl"
            shutil.copytree(ROOT / "rtl", rtl)
            src = (rtl / f).read_text()
            assert src.count(old) == 1, f"{name}: pattern not unique in {f}"
            (rtl / f).write_text(src.replace(old, new))
            out = Path(td) / "out"
            r = subprocess.run([sys.executable, str(HERE / "run.py"), "--seeds", *SEEDS, "--n", "40",
                                "--no-report", "--fail-fast", "--rtl-dir", str(rtl), "--out", str(out)],
                               capture_output=True, text=True)
            log = r.stdout + r.stderr
            killed = r.returncode != 0
            first = next((ln.strip() for ln in log.splitlines()
                          if "ERROR" in ln and ("dut=" in ln or "Assertion" in ln)
                          or "Assertion failed" in ln), "")
            rows.append((name, f, "killed" if killed else "SURVIVED", first[:160]))
            print(rows[-1][:3], flush=True)
    md = ["# Mutation sanity check\n", "| Mutant | File | Result | First detection |",
          "|---|---|---|---|"]
    md += [f"| {n} | {f} | {res} | `{d}` |" for n, f, res, d in rows]
    (HERE / "out").mkdir(exist_ok=True)
    (HERE / "out" / "mutation.md").write_text("\n".join(md) + "\n")
    survived = [r for r in rows if r[2] != "killed"]
    print(f"{len(rows) - len(survived)}/{len(rows)} mutants killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
