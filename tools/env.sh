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

echo "[OpenHelix] toolchain ready: iverilog 11.0 / yosys 0.23 / verilator $OH1_VERILATOR"
