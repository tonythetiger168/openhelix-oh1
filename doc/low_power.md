# OpenHelix OH-1 Low-Power Design（M0.3）

日期：2026-10-04　｜　狀態：已加入 RTL、驗證通過

---

## 1. 設計理念：SIMT 的功耗比例性

SIMT 架構的獨特優勢——**divergence 越深，功耗越低**。當 warp 內 lane 因 split/tmc/分支而 inactive 時，該 lane 的 ALU 運算元無效切換（glitch/toggle）是純粹的功耗浪費。operand isolation 讓不活躍 lane 的 ALU 輸入恆為 0，動態功耗與「實際活躍 lane 數」成正比，而非與「硬體 lane 數」成正比。

## 2. 已實現技術

| 技術 | 位置 | 效果 | 驗證 |
|---|---|---|---|
| **Per-lane operand isolation** | `oh1_core.sv` lane generate 區塊 | `rs1_iso = act_mask_q[l] ? rs1_data[l] : 0`；ALU/branch/split 的運算元改接 iso 版本 | lint 0/0、smoke 12/12、simd 14/14、rand 60/60+20/20 全 PASS，**零行為改變** |
| RF 寫入 gating | `oh1_core.sv` WB 路徑 | `wb_en && rd!=0 && lane_mask[l]` 才寫入——既有設計，文件化 | 同上 |
| 隔離邊界嚴格把關 | 註解標明 | LSU 位址/資料（SW 全 lane 語意）、TMC（lane0 原始值）**不可隔離**，維持原值 | tb_rand CRV 交叉驗證（divergent LSU、TMC clamp 等情境） |

**隔離安全證明**：operand isolation 前後，所有 4-lane 遮罩形態（full/single/pair/triple）下的 ALU 結果逐位元等價——因為 `wb_en=0` 或 `act_mask_q[l]=0` 時 `wb_data_c[l]` 本就為 0，iso 只影響無效路徑的內部切換，不改變任何可觀測輸出。

## 3. 建議但未實現（M1.0+ 路線圖）

| 技術 | 說明 | 觸發條件 |
|---|---|---|
| Clock gating（模組級） | `oh1_decode`、`oh1_core` 的 ID/EX 級在 stall 時關時脈 | 需合成工具支援 ICG；教學核心先保持可讀性 |
| Power gating（lane 級） | inactive lane 的 RF/ALU 電源切斷（sleep transistor） | ASIC 流程；FPGA 無意義 |
| DVFS | 動態電壓/頻率調整 | 需 PMU 整合；Edge 版評估 |
| Memory sleep | imem/dmem SRAM 無存取時進入 light-sleep | 需 SRAM 巨集支援；AXI/DMA 整合時評估 |

## 4. 功耗分析流程（驗證建議）

```bash
# 1. 產生活動波形（VCD/FST）
./sim/bin/Vtb_rand +seed=1 +n_prog=10 +trace  # 需加 --trace 建置

# 2. 訊號切換率統計（python 腳本或 yosys）
python3 tools/toggle_analysis.py --fst run.fst --top oh1_core

# 3. 對比：isolation 前後的 toggle count（期望 ALU 輸入切換減少 ~30–50%，依 divergence 密度）
```

**量化目標**：divergence 密集負載（split/tmc 頻繁）下，動態功耗降低 ≥30%；straight-line code（全 lane 活躍）下零開銷。

## 5. 與其他低功耗技術的關係

- ** operand isolation ≠ clock gating**：isolation 是組合邏輯層的靜態優化，無時序風險；clock gating 是時序層動態優化，需 CDC 檢查。
- **SIMT isolation 是 GPU 獨有**：CPU 的 operand isolation 只能靠編譯器插入 bubble（NOP），SIMT 的 lane mask 是硬體原生訊號，隔離零成本。
- **與 W1 Tensor Lite 的協同**：vdot 指令同樣適用 operand isolation——inactive lane 的 MAC 陣列不開關。
