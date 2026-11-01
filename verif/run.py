#!/usr/bin/env python3
"""Build the OH-1 harness with Verilator coverage and run the pyuvm regression.

  python verif/run.py --seeds 1 2 3 4 5 6 7 8 --gate   # sign-off regression (CI)
  python verif/run.py                       # quick regression (seeds 1..4)
  python verif/run.py --seeds 1 2 3 --n 60  # custom
  python verif/run.py --tests Oh1SmokeTest --seeds 7 --sync-mem 1

Every seed runs on two builds of the harness: SYNC_MEM=0 (combinational memory reads)
and SYNC_MEM=1 (registered reads, BRAM timing). --sync-mem picks one of them.

Outputs (verif/out/):
  seed_<s>/coverage.dat   Verilator code coverage of that run (SYNC_MEM=0)
  seed_<s>_sync/...       the same seed on the SYNC_MEM=1 build
  seed_<s>/fcov.yml       functional coverage of that run
  report.md               merged coverage report (scripts/cov_report.py)
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "out"

RTL_FILES = ("oh1_pkg.sv", "oh1_decode.sv", "oh1_core.sv", "oh1_axi_lite.sv")
HDL = [HERE / "hdl" / f for f in ("oh1_core_sva.sv", "oh1_axi_sva.sv", "oh1_tb_top.sv")]
TESTS = ["Oh1SmokeTest", "Oh1CrvTest", "Oh1SimtStressTest", "Oh1FaultTest", "Oh1AxiTest",
         "Oh1StackClosureTest"]

BUILD_ARGS = [
    "--assert", "--timing",
    "--coverage-line", "--coverage-toggle", "--coverage-user", "--coverage-fsm", "--coverage-expr",
    "--coverage-max-width", "4096",
    "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-TIMESCALEMOD",
    "-O2", "-j", "4",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, nargs="+", default=[1, 2, 3, 4])
    ap.add_argument("--n", type=int, default=40, help="kernels per CRV test")
    ap.add_argument("--tests", nargs="+", default=TESTS)
    ap.add_argument("--no-report", action="store_true")
    ap.add_argument("--gate", action="store_true", help="fail unless every metric is 100%%")
    ap.add_argument("--fail-fast", action="store_true", help="stop at the first failing seed")
    ap.add_argument("--rtl-dir", default=str(ROOT / "rtl"), help="alternative RTL (mutation runs)")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--sync-mem", type=int, nargs="+", default=[0, 1], choices=[0, 1],
                    help="memory read timing builds to run (default: both)")
    a = ap.parse_args()
    out = Path(a.out)
    rtl = [Path(a.rtl_dir) / f for f in RTL_FILES]

    sys.path.insert(0, str(HERE / "tb"))     # the runner passes sys.path on as PYTHONPATH
    runner = get_runner("verilator")
    from cocotb_tools.check_results import get_results
    failed = []
    for sm in a.sync_mem:
        build = out / ("build_sync" if sm else "build")
        runner.build(sources=rtl + HDL, hdl_toplevel="oh1_tb_top", build_args=BUILD_ARGS,
                     parameters={"SYNC_MEM": sm}, build_dir=build, timescale=("1ns", "1ps"))
        for s in a.seeds:
            d = out / (f"seed_{s}_sync" if sm else f"seed_{s}")
            d.mkdir(parents=True, exist_ok=True)
            for f in ("coverage.dat", "fcov.yml"):
                (d / f).unlink(missing_ok=True)
            res = runner.test(test_module="test_oh1", hdl_toplevel="oh1_tb_top", testcase=a.tests,
                              seed=s, build_dir=build, test_dir=d,
                              extra_env={"OH1_N": str(a.n), "OH1_FCOV": str(d / "fcov.yml"),
                                         "OH1_SYNC_MEM": str(sm)},
                              results_xml="results.xml")
            _, nfail = get_results(res)
            if nfail:
                failed.append(d.name)
                if a.fail_fast:
                    break
        if failed and a.fail_fast:
            break
    if not a.no_report:
        subprocess.run([sys.executable, str(HERE / "scripts" / "sv_check.py")], check=True)
        subprocess.run([sys.executable, str(HERE / "scripts" / "cov_report.py"), str(out)]
                       + (["--gate"] if a.gate else []), check=True)
    if failed:
        print(f"FAILED seeds: {failed}")
        sys.exit(1)


if __name__ == "__main__":
    main()
