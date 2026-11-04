#!/usr/bin/env python3
"""Closure-curve comparison: coverage-driven CRV vs plain constrained-random.

Runs Oh1CdvTest (feedback on) and Oh1CdvBaselineTest (same loop, feedback off) alone,
each in its own simulation, on every seed and both memory-timing builds, with the same
kernel budget. Each run logs functional coverage after every batch of 4 kernels
(cdv_curve.json). The report gives kernels / cycles needed to reach 90 / 95 / 99 / 100 %
of the functional bins reachable in that build, and the holes left at the budget.

  python verif/scripts/cdv_compare.py --seeds 1 2 3 4 5 6 7 8 --budget 160
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "tb"))
import run as R   # noqa: E402  (verif/run.py: build args and file lists)

TESTS = ["Oh1CdvBaselineTest", "Oh1CdvTest"]
LABEL = {"Oh1CdvBaselineTest": "plain CRV", "Oh1CdvTest": "coverage-driven"}
LEVELS = [90, 95, 99, 100]


def reach(curve, lvl, key):
    for p in curve:
        if 100.0 * p["covered"] / p["size"] >= lvl - 1e-9:
            return p[key]
    return None


def fmt(vals):
    hit = [v for v in vals if v is not None]
    if not hit:
        return f"not reached (0/{len(vals)})"
    med = statistics.median(hit)
    s = f"{med:,.0f}"
    if len(hit) < len(vals):
        s += f" ({len(hit)}/{len(vals)} runs)"
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, nargs="+", default=list(range(1, 9)))
    ap.add_argument("--budget", type=int, default=160)
    ap.add_argument("--sync-mem", type=int, nargs="+", default=[0, 1], choices=[0, 1])
    ap.add_argument("--out", default=str(HERE / "out" / "cdv"))
    ap.add_argument("--rtl-dir", default=str(R.ROOT / "rtl"))
    ap.add_argument("--report-only", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    rtl = [Path(a.rtl_dir) / f for f in R.RTL_FILES]

    if not a.report_only:
        from cocotb_tools.runner import get_runner
        runner = get_runner("verilator")
        for sm in a.sync_mem:
            build = out / ("build_sync" if sm else "build")
            runner.build(sources=rtl + R.HDL, hdl_toplevel="oh1_tb_top", build_args=R.BUILD_ARGS,
                         parameters={"SYNC_MEM": sm}, build_dir=build, timescale=("1ns", "1ps"))
            for t in TESTS:
                for s in a.seeds:
                    d = out / f"{t}_s{s}_{'sync' if sm else 'comb'}"
                    d.mkdir(parents=True, exist_ok=True)
                    runner.test(test_module="test_oh1", hdl_toplevel="oh1_tb_top", testcase=[t],
                                seed=s, build_dir=build, test_dir=d,
                                extra_env={"OH1_CDV_BUDGET": str(a.budget),
                                           "OH1_FCOV": str(d / "fcov.yml"),
                                           "OH1_SYNC_MEM": str(sm),
                                           "OH1_CURVE": str(d / "cdv_curve.json")},
                                results_xml="results.xml")

    runs = {}
    for p in sorted(out.glob("*/cdv_curve.json")):
        d = json.loads(p.read_text())
        runs.setdefault((d["test"], d["mode"]), []).append(d)
    if not runs:
        sys.exit("no cdv_curve.json found")

    md = ["# Coverage-driven vs plain constrained-random: functional closure\n",
          f"Seeds {a.seeds}, budget {a.budget} kernels per run, batches of 4 kernels, every run "
          "in its own simulation. Bins are the functional bins reachable in that build "
          "(bins tagged with the other memory-timing build are left out). Medians over seeds; "
          "\"(k/n runs)\" means only k of n runs got there within the budget.\n"]
    for mode in ("comb", "sync"):
        rows = [(t, runs.get((t, mode), [])) for t in TESTS]
        if not any(r for _, r in rows):
            continue
        size = rows[0][1][0]["curve"][0]["size"] if rows[0][1] else rows[1][1][0]["curve"][0]["size"]
        md.append(f"\n## SYNC_MEM={1 if mode == 'sync' else 0} build ({size} bins)\n")
        md.append("| Generator | " + " | ".join(f"kernels to {l}%" for l in LEVELS)
                  + " | cycles to 100% | covered at budget (median, min) |")
        md.append("|---|" + "---:|" * (len(LEVELS) + 2))
        for t, rs in rows:
            if not rs:
                continue
            ks = [fmt([reach(r["curve"], l, "kernels") for r in rs]) for l in LEVELS]
            cyc = fmt([reach(r["curve"], 100, "cycles") for r in rs])
            fin = [r["curve"][-1]["covered"] for r in rs]
            md.append(f"| {LABEL[t]} | " + " | ".join(ks)
                      + f" | {cyc} | {statistics.median(fin):.0f} / {size}, min {min(fin)} |")
        base = runs.get(("Oh1CdvBaselineTest", mode), [])
        if base:
            from collections import Counter
            c = Counter(n for r in base for n, _ in r["open"])
            md.append("\nHoles plain CRV leaves at the budget, by cover item (summed over seeds): "
                      + ", ".join(f"`{n}` {k}" for n, k in c.most_common(12)) + ".")
        cdv = runs.get(("Oh1CdvTest", mode), [])
        left = sorted({f"{n} {b}" for r in cdv for n, b in r["open"]})
        if cdv:
            md.append("\nHoles coverage-driven runs still had at the budget: "
                      + (", ".join(f"`{x}`" for x in left) if left else "none") + ".")
    text = "\n".join(md) + "\n"
    (out / "cdv_compare.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
