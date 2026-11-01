#!/usr/bin/env bash
# Install a recent Verilator (with --coverage-fsm / --coverage-expr) without building
# from source: use the PyPI "verilator" wheel (pinned in verif/requirements.txt) and
# repair the configure-time settings in its verilated.mk, which ship empty in the
# manylinux wheel (no -std/-fcoroutines/-include for the PCH, no thread libs).
#
# Usage:  source verif/tools/setup_verilator.sh   (after pip install -r verif/requirements.txt)
# (meant to be sourced, so it does not change shell options)
# Result: $VERIF_TOOLS/bin/verilator on PATH, VERILATOR_ROOT pointing at a patched copy.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIF_TOOLS="${VERIF_TOOLS:-$HERE/../.tools}"
PY="${PYTHON:-python3}"
SRC="$("$PY" -c 'import verilator, os; print(os.path.dirname(verilator.__file__))')"
ROOT="$VERIF_TOOLS/verilator"
rm -rf "$ROOT"; mkdir -p "$ROOT" "$VERIF_TOOLS/bin"
cp -r "$SRC/bin" "$SRC/include" "$ROOT/"
MK="$ROOT/include/verilated.mk"
sed -i \
  -e 's|^AR = .*|AR = ar|' \
  -e 's|^CXX = .*|CXX = g++|' \
  -e 's|^LINK = .*|LINK = g++|' \
  -e 's|^PERL = .*|PERL = perl|' \
  -e 's|^PYTHON3 = .*|PYTHON3 = python3|' \
  -e 's|^CFG_CXXFLAGS_STD = .*|CFG_CXXFLAGS_STD = -std=gnu++20|' \
  -e 's|^CFG_CXXFLAGS_COROUTINES = .*|CFG_CXXFLAGS_COROUTINES = -fcoroutines|' \
  -e 's|^CFG_CXXFLAGS_NO_UNUSED = .*|CFG_CXXFLAGS_NO_UNUSED = -Wno-unused|' \
  -e 's|^CFG_CXXFLAGS_PCH_I = .*|CFG_CXXFLAGS_PCH_I = -include|' \
  -e 's|^CFG_LDLIBS_THREADS = .*|CFG_LDLIBS_THREADS = -pthread -lpthread -latomic|' \
  "$MK"
cat > "$VERIF_TOOLS/bin/verilator" <<WRAP
#!/bin/sh
export VERILATOR_ROOT="$ROOT"
exec "$ROOT/bin/verilator" "\$@"
WRAP
chmod +x "$VERIF_TOOLS/bin/verilator"
export VERILATOR_ROOT="$ROOT"
export PATH="$VERIF_TOOLS/bin:$PATH"
echo "verilator: $(command -v verilator)  ($(sed -n 's/^#define VERILATOR_VERSION "\(.*\)"/\1/p' "$ROOT/include/verilated_config.h"))"
