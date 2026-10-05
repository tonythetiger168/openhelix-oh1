# OH-1 產品線 vs NVIDIA 產品線：優劣對比與改進計劃

日期：2026-10-01　｜　基準：OH-1（M0.2/0.3）vs NVIDIA 全產品線（GeForce / RTX Pro / Data Center H·B 系列 / Jetson / Drive）

---

## 一、誠實定位：不在同一量級，找的是「NVIDIA 沒覆盖到的位」

| | OH-1 | NVIDIA |
|---|---|---|
| 本質 | 4-lane SIMT **微核心 IP**（教學/嵌入式 offload） | 萬億級 **全棧 GPU 運算平台** |
| 計算 | 4×32b 整數 ALU，單 warp | 數千 CUDA core + Tensor Core + RT Core |
| 記憶體 | 16KB comb imem + 16KB sync dmem，無 cache/TLB | HBM3e 數百 GB～數 TB/s，完整階層 |
| 軟體 | 自定義 21 指令 ISA，無生態 | CUDA 20 年生態，百萬開發者 |
| 功耗 | 微瓦～毫瓦級 | 700W～1200W（B200） |

**可比較維度**：NVIDIA 產品線最底端是 Jetson（Orin SoM，100TOPS 級）——**毫無覆蓋「Jetson 以下」的 MCU-adjacent SIMT 市場**。這是 OH-1 的生存位。

---

## 二、優缺對比（按 NVIDIA 產品線分段）

### vs GeForce/RTX Pro（消費/工作站）——**不可比，列為非競爭區**
- NVIDIA 優：絕對效能、驅動成熟度、AI 生產力工具（TensorRT/NGC）
- OH-1 不進入此市場。**非目標**。

### vs Data Center（H100/B200/GB200）——**不可比，列為非競爭區**
- 非目標。但借鑑其驗證方法學（coverage-driven DV、formal、emulation）——OH-1 的 UVM+ISS+CRV 平台正是同源做法，只是規模迷你。

### vs Jetson（邊緣 AI SoM）——**OH-1 Edge 的假想對手**
| 維度 | OH-1 Edge（規劃） | Jetson Orin Nano |
|---|---|---|
| 功耗 | <1W 目標 | 7～15W |
| 算力 | 整數 4-lane（FP16 待 M1.0） | 20～40 TOPS（INT8/FP16，含 Tensor） |
| 開放度 | **RTL+驗證全開源**，可改可驗 | 黑盒 SoM |
| 確定性 | 完全確定（WCET 可分析） | 複雜 OS+驅動，非硬即時 |
| 軟體 | 需自建（LLVM backend） | Ubuntu/CUDA/DeepStream 现成 |
| 成本 | 授權-free IP | $200+（模組） |

**OH-1 優點**：開放可驗、極低功耗、硬即時確定性、可深度客製（安全關鍵、教學可解剖）
**OH-1 缺點**：無現成軟體棧、無 tensor 單元、單 warp 延遲隱藏能力弱、記憶體子系統過於原始

### vs Drive（車規）——**OH-1 Safety 的長期對標**
- NVIDIA 優：量產車規記錄、ISO 26262 全套、生態
- OH-1 潛在優勢：小型化後 **FMEDA/鎖步驗證成本遠低**，適合 L2 以下輔助系統的輔助加速器（而非主腦）

---

## 三、SWOT 收斂

**優勢（S）**：開源全棧（RTL/驗證/工具鏈可離線重現）、SIMT 語意在 MCU 級功耗落地、驗證資產工程紀律（ISS+CRV+SVA）、ISA 預留擴展位（wspawn）
**劣勢（W）**：無 FP/tensor、無 cache/DMA/匯流排、單 warp、零軟體生態、無實體晶片/FPGA reference
**機會（O）**：邊緣 AI 前處理（感測器融合、前處理管線 offloading）、RISC-V 生態的開放加速器插槽、教育/科研（可解剖的真 SIMT）、功能安全小型化需求
**威脅（T）**：NVIDIA 下放 Jetson 價格、RISC-V 向量擴展（RVV）擠壓「開放 SIMD」定位、ARM Ethos 系列在 MCU-AI 的先發

---

## 四、改進計劃（三階段，錨定現有資產）

### Phase 1（M0.3，0～3 個月）：把「現在的 OH-1」做到可交付
| 項目 | 內容 | 依賴 |
|---|---|---|
| 工具鏈閉環 | yosys 0.65 固化＋synth 基線（Fmax/面積報告）、pyslang 三前端 lint 交叉 | 🔧 進行中 |
| 驗證閉環 | VCS 上跑完 coverage sign-off（100% line/tgl/fsm/assert＋功能覆蓋） | 需商業模擬器 |
| Edge 硬體前置 | 3 級流水線選項、同步讀記憶體（block RAM）、AHB 從介面＋中斷 | RTL 擴充（低風險） |
| 交付物 | FPGA reference bitstream（Xilinx/Intel 各一）、Fmax≥100MHz 目標 | 上列完成 |

### Phase 2（M1.0，3～9 個月）：從「核」變「加速器」
| 項目 | 內容 | 價值 |
|---|---|---|
| 多 warp（2～4 warp） | 啟用 ISA 預留 F3=001 wspawn；warp 排程器＋RF banking | **TLP 延遲隱藏**（對齊 GPU 本質，非加深流水線） |
| banked dmem＋scoreboard | 解 divergent LSU 衝突；lw/sw 亂序完成 | 記憶體級平行度 |
| DMA＋AXI4 主介面 | 脫離「TB 餵程式」模式，接真實系統匯流排 | 可整合性 |
| FP16/BF16 迷你 tensor 單元 | 4-lane 2×2 dot-product，累加器 32b | 邊緣 AI 前處理的最低門檻算力 |
| LLVM backend | custom ISA 的 clang/LLVM 目標＋intrinsic（split/join/tmc） | **軟體生態的根**——無此則無產品 |

### Phase 3（M1.5，9～18 個月）：差異化卡位
| 項目 | 內容 |
|---|---|
| RISC-V SoC 整合示範 | OH-1 作為 RoCC/AXI 協同處理器掛在 RISC-V host（如 CVA6/VexRiscv）——「開放 GPU 配開放 CPU」完整故事 |
| Safety 衍生 | lockstep 影子核＋RF/記憶體 ECC＋SVA 無 vacuous 簽核＋FMEDA 包；目標 ISO 26262 ASIL-B 輔助加速器 |
| 教學生態 | 教材、21 指令參考卡、架構圖（已有）、browser 模擬器（wasm ISS——pyslang/slang 可編 wasm） |

### 明確不做（防資源分散）
- ❌ 消費級圖形/遊戲（GeForce 區）
- ❌ 資料中心訓練/推理（H/B 區）
- ❌ CUDA 語言層相容（改攻「CUDA-like DSL→OH-1 ISA」的開源編譯路徑）
- ❌ 深流水線（>3 級）換時脈——與 SIMT 分歧懲罰的架構主張相悖

---

## 五、KPI（改進計劃的驗收線）

| 階段 | KPI |
|---|---|
| M0.3 末 | lint 三前端 0 error；yosys synth Fmax/面積基線存檔；smoke/simd/rand 納入 CI（git pre-push） |
| M1.0 末 | 2 warp 跑通 rand CRV；LLVM 編譯「hello vector」C 程式；AXI DMA 搬移 verified by CRV |
| M1.5 末 | RISC-V SoC FPGA demo 上板跑感測器前處理 kernel；Safety 包通過第三方審查預演 |

---

## 六、一句話戰略

> **NVIDIA 從上往下打到 Jetson 為止；OH-1 從下往上做「Jetson 之下的開放 SIMT」——用開放 RTL＋完整驗證＋微瓦功耗，吃 NVIDIA 不吃的確定性、可客製、教學與安全小型化市場。**
