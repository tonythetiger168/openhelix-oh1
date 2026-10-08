# OpenHelix 工具鏈環境（source 本檔使用）
# 版本與雜湊見 tools/manifest.txt
export OH1_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- verilator：預設 5.052（原始碼編譯），可用 OH1_VERILATOR=5.006 切回 Debian 版 ---
export OH1_VERILATOR="${OH1_VERILATOR:-5.052}"
if [ "$OH1_VERILATOR" = "5.052" ]; then
    export VERILATOR_ROOT="$OH1_TOOLS/verilator-5.052/share/verilator"
    export PATH="$OH1_TOOLS/verilator-5.052/bin:$OH1_TOOLS/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$OH1_TOOLS/flex-2.6.4/lib:$OH1_TOOLS/usr/lib/x86_64-linux-gnu:$OH1_TOOLS/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
    export VERILATOR_ROOT="$OH1_TOOLS/usr"
    export PATH="$OH1_TOOLS/usr/bin:$PATH"
    export LD_LIBRARY_PATH="$OH1_TOOLS/usr/lib/x86_64-linux-gnu:$OH1_TOOLS/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# --- yosys：預設 0.65（原始碼編譯），可用 OH1_YOSYS=0.23 切回 Debian 版 ---
export OH1_YOSYS="${OH1_YOSYS:-0.65}"
if [ "$OH1_YOSYS" = "0.65" ]; then
    export PATH="$OH1_TOOLS/yosys-0.65/bin:$PATH"
fi

# --- iverilog：預設 13.0（原始碼編譯，OH1_IVERILOG=11 切回 Debian 版）---
export OH1_IVERILOG="${OH1_IVERILOG:-13}"
if [ "$OH1_IVERILOG" = "13" ] && [ -x "$OH1_TOOLS/iverilog-13.0/bin/iverilog" ]; then
    export PATH="$OH1_TOOLS/iverilog-13.0/bin:$PATH"
    export LD_LIBRARY_PATH="$OH1_TOOLS/iverilog-13.0/lib:$OH1_TOOLS/iverilog-13.0/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# --- pyslang（slang SystemVerilog 編譯器 Python 綁定，IEEE 1800 嚴格前端）---
# 用法：PYTHONPATH=$OH1_TOOLS/pyslang-12.0.0 python3.11 -c "import pyslang"
if [ -d "$OH1_TOOLS/pyslang-12.0.0" ]; then
    export PYTHONPATH="$OH1_TOOLS/pyslang-12.0.0${PYTHONPATH:+:$PYTHONPATH}"
fi

echo "[OpenHelix] toolchain ready: iverilog $OH1_IVERILOG / yosys $OH1_YOSYS / verilator $OH1_VERILATOR / pyslang 12.0.0"
