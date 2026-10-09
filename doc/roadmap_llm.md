# OH-1 與 LLM：能力邊界與 demo 路線圖（M3.0）

日期：2026-10-10　｜　狀態：戰略決策記錄

---

## 決策一句話

> **讓 OH-1 能跑最小 LLM（證明基礎完備），但絕不為 LLM 造 OH-1（守住架構主張）。**

## 三層邊界

| 層級 | 定義 | 決策 |
|---|---|---|
| 微型 LLM（TinyStories 15M、量化 ≤30M 參數） | 教學/demo 級 | ✅ M3.0 demo 目標（非產品承諾） |
| 邊緣 LLM（0.5B–3B：Qwen-0.5B、Llama-3.2-1B） | 實用級 | ❌ 明確不做——架構不對口 |
| 真實 MCU-AI（關鍵詞喚醒、感測器融合、<10M encoder） | OH-1 本業 | ✅ 這才是 AI 定位 |

## 為什麼 0.5B+ 是結構性不可能（三道牆）

1. **記憶體容量牆**：1B 參數 INT8 = 1GB + KV cache；OH-1 內建 32KB，差 3 萬倍。
2. **記憶體頻寬牆（致命）**：LLM decode 是 memory-bound——每 token 掃全部權重。
   1B INT8 ≈ 2GB/token；即使 600MB/s SDRAM 也只有 0.3 tok/s。
   **SIMT lane 再多沒用——權重餵不進來。** OH-1 的價值（SIMT 分歧語意）與 LLM decode 的需求（bandwidth）正好錯位。
3. **資源詛咒**：記憶體子系統→算子庫→量化工具鏈→runtime，全是 LLVM backend（W4）10 倍的工作量；MCU-AI 正面戰場（Ethos-U55、Tensilica、各家 NPU）已有 100+ TOPS 與成熟生態。

## M3.0 demo 的可行數字（假設 M2.0 完成）

| 項目 | 數字 |
|---|---|
| 模型 | TinyStories-15M，INT4 量化 |
| 權重 | 7.5MB → FPGA 外接 SDRAM 綽綽有餘 |
| 頻寬上限 | 7.5MB/token ÷ 600MB/s = 80 tok/s |
| 算力上限 | 30M ops/token ÷ 400M ops/s（4-lane INT8 @100MHz）≈ 13 tok/s |
| **目標** | **≥5 tok/s on FPGA reference**（compute-bound，可達） |

## M3.0 倒逼出的硬體（本來就在 roadmap）

| 需求 | 對應工作 |
|---|---|
| INT8/INT4 MAC | W1 Tensor Lite 擴充（現規格僅 FP16，需加 INT 點積） |
| AXI DMA + 外接記憶體 | W2（AXI wrapper 已驗證 4/4＋整合測試 PASS） |
| banked dmem | W3 multi-warp 的配套 |
| 載入/執行 runtime | W4 LLVM backend（`.ohx` + `oh1-sim`） |

## 紅線（寫死，防資源漂移）

- ❌ >100M 參數的模型支持——memory-bandwidth wall 不可跨越
- ❌ 為 LLM 加深流水線 / 堆 MAC 陣列——違背 2 級流水線甜蜜點主張
- ❌ cache / MMU / DDR 控制器——OH-1 保持加速器周邊定位，記憶體由 host SoC 提供

## AI 正定位（產品語言）

keyword spotting、感測器融合前處理、tiny vision encoder——**記憶體 footprint 與 4-lane SIMT 匹配、需要確定性延遲**的場景。這是 NVIDIA（Jetson 7W+）與 TinyML ASIC（黑盒）之間的空位：開放 RTL + 可驗證 + 微瓦功耗。
