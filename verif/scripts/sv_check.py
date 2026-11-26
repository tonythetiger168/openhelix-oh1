#!/usr/bin/env python3
"""pyslang front-end check of the RTL + verification HDL.

1. Elaborates rtl/*.sv with verif/hdl/*.sv; any error fails (exit 1).
2. Inventories every concurrent assertion / cover property (kind, label, file, line).
3. Finds oh1_pkg functions that no RTL module calls. Those are generator/ISS
   helpers that are never synthesised; their code-coverage points are excluded
   automatically (they are listed by name in the report).

Writes verif/out/sv_inventory.json.
"""
import json
import os
import re
import sys
from pathlib import Path

import pyslang as ps

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent
RTL = ["rtl/oh1_pkg.sv", "rtl/oh1_decode.sv", "rtl/oh1_core.sv", "rtl/oh1_axi_lite.sv"]
VHDL = ["verif/hdl/oh1_core_sva.sv", "verif/hdl/oh1_axi_sva.sv", "verif/hdl/oh1_tb_top.sv"]
LABEL = re.compile(r"^\s*(\w+)\s*:\s*(assert|cover)\s+property")


def compile_(files):
    c = ps.ast.Compilation()
    for f in files:
        c.addSyntaxTree(ps.syntax.SyntaxTree.fromFile(str(ROOT / f)))
    return c


def main():
    os.chdir(ROOT)
    c = compile_(RTL + VHDL)
    sm = c.sourceManager
    diags = c.getAllDiagnostics()
    errs = [d for d in diags if d.isError()]
    if errs:
        print(ps.DiagnosticEngine.reportAll(sm, errs))
        sys.exit(1)

    props, rtl_calls = [], set()
    rel = lambda f: os.path.relpath(os.path.abspath(f), ROOT)
    rtl_files = set(RTL)

    def visit(obj):
        if isinstance(obj, ps.ast.CallExpression) and not obj.isSystemCall:
            if rel(sm.getFileName(obj.sourceRange.start)) in rtl_files:
                rtl_calls.add(obj.subroutineName)
        if isinstance(obj, ps.ast.ConcurrentAssertionStatement):
            f = rel(sm.getFileName(obj.sourceRange.start))
            ln = sm.getLineNumber(obj.sourceRange.start)
            text = (ROOT / f).read_text().splitlines()[ln - 1]
            m = LABEL.match(text)
            props.append(dict(kind=obj.assertionKind.name, label=m.group(1) if m else f"L{ln}",
                              file=f, line=ln))
        return ps.ast.VisitAction.Advance

    c.getRoot().visit(visit)

    helpers = []
    for m in c.getPackage("oh1_pkg"):
        if isinstance(m, ps.ast.SubroutineSymbol) and m.name not in rtl_calls:
            r = m.syntax.sourceRange
            helpers.append(dict(name=m.name, file="rtl/oh1_pkg.sv",
                                first=sm.getLineNumber(r.start), last=sm.getLineNumber(r.end)))

    # de-duplicate generate copies (same label/file/line)
    uniq = {(p["kind"], p["label"], p["file"], p["line"]): p for p in props}
    out = dict(warnings=len(diags), errors=0, properties=list(uniq.values()),
               property_instances=len(props), rtl_calls=sorted(rtl_calls), pkg_helpers=helpers)
    dst = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "out"
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "sv_inventory.json").write_text(json.dumps(out, indent=1))
    na = sum(p["kind"] == "Assert" for p in uniq.values())
    nc = sum(p["kind"] == "CoverProperty" for p in uniq.values())
    print(f"pyslang: 0 errors, {len(diags)} warnings; {na} assertions, {nc} cover properties; "
          f"pkg helpers not used by RTL: {', '.join(h['name'] for h in helpers)}")


if __name__ == "__main__":
    main()
