# Edge NPU／CPU／OS／SKU 工作進度

更新：2026-11-01 05:09（Asia/Taipei）。
本工作獨立進度檔，依使用者指示不寫共用 PROGRESS_TV_STB_IPCAM.md。

## 2026-11-01 本次跟進

三個設計PR仍draft、尚無審查留言，三個main未變；
CPU PR #1新head為`c1db39aa2ba58d7be23be66912d9051042369c60`。
相對前次CPU head新增21個commits（含merge），已盤點APB/NPU/SoC來源。

- design：新增backend候選與CSR／命令／完成／地址／counter相容性決策。
- reference：獨立repo新增INT8 GEMM／INT32 rescale host golden。
- verified：Python3.14.8，12個unittest通過；4635個精確rounding比較點。
- RTL：本工作未改RTL；CPU PR作者的regression/coverage未重跑。
- physical／模型／OS：未做，沒有新增性能或量產主張。
- 阻塞：G1尚未同意；PR內SoC NPU外部DMA grant接0；
  CPU/APB/DDR/firewall/abort與OH1 wrapper仍需獨立驗收。
- 下一步：先評估X1-Nano重用與64B packing，再接RTL scoreboard；
  本輪golden沒有command generator、driver或DMA功能。
- 本repo更新前head：`02f4885b05a8665905955b7dd426a0f1e1057eb6`。
- 本次更新commit由本檔所在commit/PR head識別。

詳情與證據：
- [總repo跟進PR](https://github.com/tonythetiger168/orca-v63/pull/9)
- [host reference PR](https://github.com/tonythetiger168/orca-ai-accelerators/pull/1)

以下2026-10-26條目保留為歷史紀錄，本次狀態以上方日期段落為準。

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
- 文檔QA：9份Markdown行長/圍欄、2份JSON格式檢查完成。
- GitHub compare：僅新增設計／進度／稽核證據，沒有RTL更動。

## 下一步

先審唯一來源與ABI；建立獨立GEMM/quant golden，
修正NPU DMA/handshake/有效MAC計數與OH1 wrapper，
再選固定模型/資料集跑CPU→quant→RTL。
CPU/OS與DDR gate另列驗收，OH1無優勢即保留研究線。
不自動合併、不付費、不直接改main、不跨聊天發訊息。

## 設計提交與本檔版本

本repo設計commit：`42d7672b801a828e0824b2e2b6143ac7163c78fb`。
本檔的進度提交SHA由所在commit與PR head識別，避免自引用。

## 跨 repo 審查連結

- [SoC／來源合約 PR #9](https://github.com/tonythetiger168/orca-v63/pull/9)
- [NPU 架構 PR #1](https://github.com/tonythetiger168/orca-ai-accelerators/pull/1)
- [OH1 評估 PR #1](https://github.com/tonythetiger168/openhelix-oh1/pull/1)

這些均為 draft；設計尚未合併，不表示consumer已同意。
