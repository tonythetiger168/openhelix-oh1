#!/usr/bin/env python3
"""Merge and report OH-1 coverage.

  python verif/scripts/cov_report.py verif/out

Inputs:   <out>/seed_*/coverage.dat   Verilator coverage (line/branch/expr/toggle/user)
          <out>/seed_*/fcov.yml       cocotb-coverage functional coverage
          <out>/seed_*/results.xml    cocotb results (assertion failures fail a test)
          <out>/sv_inventory.json     pyslang inventory (scripts/sv_check.py)
          verif/coverage_exclusions.yml
Outputs:  <out>/report.md, <out>/summary.json, <out>/merged_coverage.dat
          (merged_coverage.dat is in Verilator format, usable with verilator_coverage)

Metric scope: code coverage counts only RTL (rtl/*.sv); the harness top and the
bind modules are testbench code. SVA coverage = cover properties in the bind
modules (FSM state/arc covers, prefixed f_, are reported separately as FSM).
"""
import collections
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent
KV = re.compile("\x01([a-z]+)\x02([^\x01]*)")
TYPES = {"v_line": "line", "v_branch": "branch", "v_expr": "expression", "v_toggle": "toggle",
         "v_user": "user"}


# Verilator suffixes the module name of a parameter-specialised module in the page field
# (oh1_core -> oh1_core__SB1 in the SYNC_MEM=1 build); drop it so both builds merge
PAGE_SPEC = re.compile("(\x01page\x02v_[a-z]+/[^\x01]*?)__S[A-Za-z0-9]+(?=\x01)")


def load_dat(paths):
    merged = collections.OrderedDict()
    for p in paths:
        for ln in open(p, encoding="latin-1"):
            if not ln.startswith("C '"):
                continue
            key, cnt = ln[3:].rstrip("\n").rsplit("' ", 1)
            key = PAGE_SPEC.sub(r"\1", key)
            merged[key] = merged.get(key, 0) + int(cnt)
    return merged


def parse_key(key):
    kv = dict(KV.findall("\x01" + key if not key.startswith("\x01") else key))
    f = kv.get("f", "")
    try:
        f = str(Path(f).resolve().relative_to(ROOT))
    except ValueError:
        pass
    kv["f"] = f
    kv["type"] = TYPES.get(kv.get("page", "").split("/")[0], kv.get("page", "").split("/")[0])
    kv["l"] = int(kv.get("l", 0))
    return kv


class Excl:
    def __init__(self, entries, helpers):
        self.entries = entries
        for h in helpers:
            self.entries.append(dict(
                id=f"PKG-{h['name']}", type="any", file=h["file"], lines=[h["first"], h["last"]],
                reason=f"oh1_pkg::{h['name']} is a generator/ISS helper; no RTL module calls it "
                       f"(pyslang reference scan), so it is never synthesised."))
        for e in self.entries:
            e["hits"] = 0
            e["covered_anyway"] = 0

    def match(self, kv, cnt):
        for e in self.entries:
            if e.get("type", "any") not in ("any", kv["type"]):
                continue
            if e["file"] != kv["f"]:
                continue
            if "line" in e and e["line"] != kv["l"]:
                continue
            if "lines" in e and not (e["lines"][0] <= kv["l"] <= e["lines"][1]):
                continue
            if "match" in e and not re.search(e["match"], kv.get("o", "")):
                continue
            e["hits"] += 1
            if cnt:
                e["covered_anyway"] += 1
            return e
        return None


def pct(h, t):
    return 100.0 * h / t if t else 100.0


def fcov_merge(paths):
    items = {}
    for p in paths:
        d = yaml.safe_load(open(p)) or {}
        for name, it in d.items():
            if "bins:_hits" not in it:
                continue
            m = items.setdefault(name, dict(at_least=it.get("at_least", 1), bins=collections.Counter(),
                                            weight=it.get("weight", 1)))
            for b, h in it["bins:_hits"].items():
                m["bins"][str(b)] += h
                m["bins"].setdefault(str(b), 0)
    return items


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    gate = "--gate" in sys.argv
    out = Path(args[0] if args else HERE / "out")
    seeds = sorted(out.glob("seed_*"))
    dats = [s / "coverage.dat" for s in seeds if (s / "coverage.dat").exists()]
    inv_p = out / "sv_inventory.json"
    if not inv_p.exists():
        subprocess.run([sys.executable, str(HERE / "scripts" / "sv_check.py"), str(out)], check=True)
    inv = json.loads(inv_p.read_text())
    ex_cfg = yaml.safe_load(open(HERE / "coverage_exclusions.yml")) or []
    excl = Excl(ex_cfg, inv["pkg_helpers"])

    merged = load_dat(dats)
    with open(out / "merged_coverage.dat", "w", encoding="latin-1") as f:
        f.write("# SystemC::Coverage-3\n")
        for k, v in merged.items():
            f.write(f"C '{k}' {v}\n")

    code = collections.defaultdict(lambda: collections.Counter())   # (type, file) -> counts
    holes = collections.defaultdict(list)
    user = []
    for key, cnt in merged.items():
        kv = parse_key(key)
        t, f = kv["type"], kv["f"]
        if t == "user":
            user.append((kv.get("o", "").split(".")[-1], kv["f"], kv["l"], cnt))
            continue
        if not f.startswith("rtl/"):
            continue
        c = code[(t, f)]
        c["total"] += 1
        c["raw_hit"] += bool(cnt)
        e = excl.match(kv, cnt)
        if e:
            c["excluded"] += 1
            continue
        c["eligible"] += 1
        if cnt:
            c["hit"] += 1
        else:
            holes[t].append(f"{f}:{kv['l']} {kv.get('o', '')} [{kv.get('h', '')}]")

    # ---------------------------------------------------------------- SVA / FSM
    props = inv["properties"]
    asserts = [p for p in props if p["kind"] == "Assert"]
    by_label = collections.defaultdict(int)
    for lab, f, l, cnt in user:
        by_label[(lab, f)] += cnt
    covers = [(lab, f, cnt) for (lab, f), cnt in by_label.items()]
    fsm = [c for c in covers if c[0].startswith("f_")]
    sva = [c for c in covers if not c[0].startswith("f_")]
    antecedent = {c[0][2:]: c[2] for c in sva if c[0].startswith("c_")}
    a_labels = sorted({p["label"] for p in asserts})
    vacuous = [a for a in a_labels if a.startswith("a_") and antecedent.get(a[2:], 0) == 0
               and a[2:] in antecedent]
    no_cover = [a for a in a_labels if a.startswith("a_") and a[2:] not in antecedent]

    # ---------------------------------------------------------------- results
    tests = fails = 0
    for s in seeds:
        x = s / "results.xml"
        if x.exists():
            for tc in ET.parse(x).getroot().iter("testcase"):
                tests += 1
                if tc.find("failure") is not None or tc.find("error") is not None:
                    fails += 1

    # ---------------------------------------------------------------- functional
    fitems = fcov_merge([s / "fcov.yml" for s in seeds if (s / "fcov.yml").exists()])
    groups = collections.defaultdict(lambda: [0, 0])
    fholes = []
    ftot = fhit = 0
    for name, it in sorted(fitems.items()):
        n = len(it["bins"])
        h = sum(1 for b, v in it["bins"].items() if v >= it["at_least"])
        g = ".".join(name.split(".")[:3])
        groups[g][0] += h
        groups[g][1] += n
        ftot += n
        fhit += h
        for b, v in it["bins"].items():
            if v < it["at_least"]:
                fholes.append(f"{name} bin {b}")

    # ---------------------------------------------------------------- summary
    def agg(t):
        tot = sum(c["total"] for (tt, _), c in code.items() if tt == t)
        el = sum(c["eligible"] for (tt, _), c in code.items() if tt == t)
        hit = sum(c["hit"] for (tt, _), c in code.items() if tt == t)
        raw_hit = sum(c["raw_hit"] for (tt, _), c in code.items() if tt == t)
        return dict(points=tot, excluded=tot - el, eligible=el, hit=hit,
                    pct=round(pct(hit, el), 2), raw_pct=round(pct(raw_hit, tot), 2))

    fsm_hit = sum(1 for c in fsm if c[2])
    sva_hit = sum(1 for c in sva if c[2])
    summary = dict(
        seeds=[s.name for s in seeds], tests=tests, test_failures=fails,
        line=agg("line"), branch=agg("branch"), expression=agg("expression"), toggle=agg("toggle"),
        fsm=dict(points=len(fsm), hit=fsm_hit, pct=round(pct(fsm_hit, len(fsm)), 2),
                 tool_extracted=sum(1 for k in merged if "v_fsm" in k)),
        sva=dict(assertions=len(a_labels), assertion_instances=sum(1 for p in asserts),
                 failures=fails, vacuous=vacuous, without_antecedent_cover=no_cover,
                 cover_properties=len(sva), covers_hit=sva_hit, pct=round(pct(sva_hit, len(sva)), 2)),
        functional=dict(bins=ftot, hit=fhit, pct=round(pct(fhit, ftot), 2),
                        groups={g: dict(hit=h, bins=n, pct=round(pct(h, n), 2))
                                for g, (h, n) in sorted(groups.items())}),
    )
    (out / "summary.json").write_text(json.dumps(summary, indent=1))

    # ---------------------------------------------------------------- markdown
    L = []
    w = L.append
    w("# OH-1 coverage report\n")
    w(f"Runs merged: {', '.join(summary['seeds'])} | tests: {tests} | failing tests: {fails}\n")
    w("| Metric | Points | Excluded | Covered / eligible | Coverage | Raw (no exclusions) |")
    w("|---|---:|---:|---:|---:|---:|")
    for t in ("line", "branch", "expression", "toggle"):
        a = summary[t]
        w(f"| {t} | {a['points']} | {a['excluded']} | {a['hit']} / {a['eligible']} | "
          f"**{a['pct']:.2f}%** | {a['raw_pct']:.2f}% |")
    s = summary["fsm"]
    w(f"| FSM states+arcs (f_* covers) | {s['points']} | 0 | {s['hit']} / {s['points']} | "
      f"**{s['pct']:.2f}%** | {s['pct']:.2f}% |")
    s = summary["sva"]
    w(f"| SVA cover properties | {s['cover_properties']} | 0 | {s['covers_hit']} / {s['cover_properties']} | "
      f"**{s['pct']:.2f}%** | {s['pct']:.2f}% |")
    s = summary["functional"]
    w(f"| functional bins (cocotb-coverage) | {s['bins']} | 0 | {s['hit']} / {s['bins']} | "
      f"**{s['pct']:.2f}%** | {s['pct']:.2f}% |")
    w("")
    a = summary["sva"]
    w(f"SVA: {a['assertions']} assertions ({a['assertion_instances']} instances incl. generate copies), "
      f"{a['failures']} failing tests (a failing assertion stops the simulation and fails the test). "
      f"Vacuous assertions (antecedent cover never hit): {', '.join(a['vacuous']) or 'none'}. "
      f"Assertions without an antecedent cover (unconditional invariants): "
      f"{', '.join(a['without_antecedent_cover']) or 'none'}.\n")
    w(f"FSM: Verilator `--coverage-fsm` extracted {summary['fsm']['tool_extracted']} points from this RTL "
      "(see the exclusions doc); FSM coverage is measured with explicit state/arc cover properties.\n")
    w("## Per file\n")
    w("| Metric | File | Covered / eligible | Excluded | Coverage |")
    w("|---|---|---:|---:|---:|")
    for (t, f), c in sorted(code.items()):
        w(f"| {t} | {f} | {c['hit']} / {c['eligible']} | {c['excluded']} | {pct(c['hit'], c['eligible']):.2f}% |")
    w("\n## Functional coverage by group\n")
    w("| Group | Covered / bins | Coverage |")
    w("|---|---:|---:|")
    for g, v in summary["functional"]["groups"].items():
        w(f"| {g} | {v['hit']} / {v['bins']} | {v['pct']:.2f}% |")
    w("\n## Remaining holes\n")
    any_hole = False
    for t, hs in sorted(holes.items()):
        for h in hs:
            w(f"- {t}: `{h}`")
            any_hole = True
    for c in fsm + sva:
        if not c[2]:
            w(f"- cover: `{c[0]}` ({c[1]})")
            any_hole = True
    for h in fholes:
        w(f"- functional: `{h}`")
        any_hole = True
    if not any_hole:
        w("None.")
    w("\n## Exclusions applied\n")
    w("| ID | Type | Location | Points | Of which hit anyway | Reason |")
    w("|---|---|---|---:|---:|---|")
    for e in excl.entries:
        loc = e["file"] + (f":{e['line']}" if "line" in e else
                           f":{e['lines'][0]}-{e['lines'][1]}" if "lines" in e else "")
        if "match" in e:
            loc += f" `{e['match']}`"
        w(f"| {e['id']} | {e.get('type', 'any')} | {loc} | {e['hits']} | {e['covered_anyway']} | {e['reason']} |")
    (out / "report.md").write_text("\n".join(L) + "\n")
    print("\n".join(L[:14]))
    if gate:
        low = {k: summary[k]["pct"] for k in ("line", "branch", "expression", "toggle", "fsm", "sva",
                                               "functional") if summary[k]["pct"] < 100.0}
        if low or fails or vacuous:
            print(f"COVERAGE GATE FAILED: below 100%: {low}; failing tests: {fails}; vacuous: {vacuous}")
            sys.exit(1)
        print("COVERAGE GATE PASSED: all metrics 100% (with the listed exclusions), 0 failing tests")


if __name__ == "__main__":
    main()
