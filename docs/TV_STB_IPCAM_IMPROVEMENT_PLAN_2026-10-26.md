# SIMT 視覺輔助加速器評估計畫

日期：2026-10-26（Asia/Taipei）。狀態：設計立項，未宣稱 RTL、PPA 或量產驗收完成。
本計畫涵蓋 TV／STB／IPCAM 共用平台。實作前重讀最新 main、AGENTS.md／CLAUDE.md、相關 PR 與驗證報告；來源衝突以具體 RTL、較新報告及可重現結果判定。不得把 VIP、行為 PHY、命名或 coverage 百分比等同完整協定或產品成熟度。

## 定位
現有4-lane SIMT micro-core、AXI4-Lite wrapper為可程式化小型加速候選，不等同完整OpenGL/Vulkan GPU，也不是NPU runtime替代品。
## 設計與決策
評估resize/normalize、色彩轉換、ROI/metadata後處理與固定功能VP/NPU的成本比較；不為TV UI另造完整graphics stack。
交付 doc/media_prepost_evaluation.md：ISA/工具鏈、DMA與scratchpad、AXI資料/控制分工、divergence、memory bandwidth、interrupt/isolation。
用相同workload比較CPU/SIMT/fixed function cycles與資源；若無優勢保留研究線，不列首代量產依賴。維持既有SIMT golden/CRV/SVA，新增buffer邊界/abort/backpressure測試。
FP16 vdot、多warp等roadmap只在有RTL與測試後標為實作完成。

## 共通交付與驗收
- 設計交付：block diagram、模組責任、介面／CSR、資料格式、clock/reset/power、吞吐／頻寬估算、錯誤／abort／recovery、安全邊界、依賴及驗證矩陣。
- 依序進行參考模型、RTL、獨立 scoreboard、CRV、SVA、coverage（保留 raw 數據與逐條 waiver）、適用控制形式驗證與 mutation、系統端到端測試。
- 效能以實測 cycles、配置與工具版本記錄；假設頻率與估算 PPA 必須標明，合成／STA／板級驗證未做不得宣稱完成。
- 每次更新 docs/PROGRESS_TV_STB_IPCAM.md：台北時間、commit、完成／待驗收／阻塞、測試命令與結果、下一步。無結果不得填 PASS。
- 設計工作使用 codex/ 分支與 draft PR；不自動合併，不新增付費服務。跨 repo 介面變更須列出所有 consumer 與相容性。
