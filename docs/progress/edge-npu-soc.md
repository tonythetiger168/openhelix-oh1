# Edge NPU／CPU／OS／SKU 工作進度

更新：2026-10-26 10:40（Asia/Taipei）。
本工作獨立進度檔，依使用者指示不寫共用 PROGRESS_TV_STB_IPCAM.md。

## 來源基線
- orca-v63: `3d66ab0c9b16a4a35907d7729cafe3abebec379a`
- orca-ai-accelerators: `8059f10d6f1f54e3afbe676f71a71ba998172ade`
- openhelix-oh1: `8905c6d635372bab22be76524f4a58e28e9c850d`

## 完成與待驗收

- design：完成來源比較、唯一來源建議、NPU架構與ABI草案、
  CPU/OS/SKU/QoS、安全/恢復設計、OH1小型pre/post評估。
- RTL：本輪未修改；現有RTL僅盤點，不視為首代實作完成。
- verified：來源SHA與17項離線算術已執行；RTL/模型/OS未跑。
- physical：未合成、未STA、未板級DDR驗證，沒有PPA承諾。
- 待驗收：G1跨consumer合約、模型/資料集/精度門檻、CPU修正PR與OS gate。
- 阻塞：DMA stub、數學/排程正確性、軟體棧未交付、
  application CPU與真實DDR PHY、OH1 wrapper整合缺陷。

## 真實執行命令與結果

- python work/audit_design.py（Python3.14.8）：exit0。
- 38檔聯集：31不同、1相同、v63-only3、ai-only3。
- 抽樣10檔git blob SHA匹配；17項算力/頻寬算術檢查完成。
- 環境未找到verilator/iverilog；本輪未執行RTL lint/regression。
- CPU PR #1 的104/104等數字僅為PR既有報告，本輪未重跑。
- 文檔QA與PR commit：見後續更新；不填造RTL PASS。

## 下一步

先審唯一來源與ABI；建立獨立GEMM/quant golden，
修正NPU DMA/handshake/有效MAC計數與OH1 wrapper，
再選固定模型/資料集跑CPU→quant→RTL。
CPU/OS與DDR gate另列驗收，OH1無優勢即保留研究線。
不自動合併、不付費、不直接改main、不跨聊天發訊息。
