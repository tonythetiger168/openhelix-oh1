# OpenHelix OH-1 產品線與 Features

版本：2026-10-01　｜　狀態標註：✅ 已驗證（RTL＋測試通過）｜🔧 已交付工具｜🗺️ 路線圖

---

## 一、OH-1 Base——SIMT 微型核心（現況 Milestone 0.2）

**定位**：4-lane SIMT（單 warp）嵌入式/教學/加速器前置核心。IEEE 1800 完整驗證資產。

### ISA（✅ 21 條指令，凍結）

| 類別 | 指令 |
|---|---|
| R-type | add, sub, and, or, xor, sll, srl, sra, slt, sltu |
| I-type | addi, andi, ori, xori, slti, sltiu, slli, srli, srai, lw |
| S-type | sw |
| B-type | beq, bne, blt, bge |
| U-type | lui, auipc |
| **Custom-0（SIMT 靈魂）** | **split / join / tmc / bar / wexit / texit** |
| CSR | tid（lane id）、laneid |

### 微架構 Features（✅）

- **IF/EX 二級流水線**：redirect 懲罰僅 **1 個 bubble**（smoke trace 實測），SIMT 分歧密集型負載的最優級數選擇
- **每 lane 獨立資料通路**：RF 32×32b ×4、ALU ×4、LSU ×4（`tb_simd` 14 項逐 lane 檢查 PASS）
- **標記式雙 entry 分歧堆疊**：8-deep × {tag, mask[3:0], pc}；split 全假只推 1 entry、join 先彈 else 再彈 tag（✅ 修復 redirect 未閘控 deadlock bug，有 monitor trace 證據鏈）
- **warp-uniform 分支 AND 語意**：所有 active lane 條件一致才跳轉
- **TMC 動態遮罩**：lane0 取值、超界 clamp、結果必為低位連續 ones-mask（SVA `ast_tmc_ones_mask` 保證）
- **參數化 LANES_P**：4 為基準組態
- 16KB imem（組合讀）＋16KB dmem（同步寫、word-indexed）

### 驗證資產（✅ 完整交付）

| 資產 | 規格 |
|---|---|
| Directed 測試 | smoke 12 項 ✅ ＋ **SIMD engine 14 項逐 lane 檢查** ✅（`make smoke` / `make simd`） |
| UVM CRV 平台 | 7 檔案：CRV 程式產生器（split/join 靜態配平）、指令級 ISS scoreboard（逐步＋終態比對）、3 sequences / 4 tests |
| Functional coverage | **8 covergroups**：指令×遮罩、redirect、LSU divergent、WB 資料類別、SW 資料類別、CSR、TMC、巢狀深度（含 cross） |
| SVA | **15 assertions** ＋ **17 cover properties**（done 靜默、堆疊邊界、對齊、互斥、x0 保護…） |
| 覆蓋率閉環 | `make cov`（三 test＋urg 合併）＋簽核標準（doc/coverage_plan.md） |

### 工具鏈（🔧 全部 source 固化、離線可重現）

- verilator **5.052**（原始碼編譯）｜iverilog 11.0｜yosys **0.65**（原始碼編譯＋ABC 釘選）
- `tools/manifest.txt` SHA256 全登錄；`env.sh` 一鍵環境（新舊版可切換回退）

---

## 二、產品線藍圖（🗺️ 依依賴關係排序）

| 型號 | 目標市場 | 與 Base 的差異 | 關鍵里程碑 |
|---|---|---|---|
| **OH-1 Nano**（教育版） | 教學、研究、開源社群 | ＝Base，文件/教材加強；block-diagram＋21 指令參考卡 | M0.2 ✅ ＋教材包 |
| **OH-1 Edge**（嵌入式） | MCU  offload、FPGA SoC 周邊 | ＋同步讀記憶體（block RAM）、**3 級流水線選項**、AHB/APB 從介面、中斷/DONE 訊號、yosys 合成參考流程（Fmax 報告） | M0.3 |
| **OH-1 Pro**（加速器） | 邊緣 AI 前處理、圖形化工作負載 | **多 warp**（wspawn 已由 ISA 預留 F3＝001）、LANES 16/32、DMA/AXI4、banked dmem 解決 divergent LSU 衝突、scoreboard 記憶體排序 | M1.0 |
| **OH-1 Safety**（車規/工控衍生） | 功能安全 | ＋lockstep 影子核、ECC/parity、SVA 100% 無 vacuous 簽核、FMEDA 資料包 | M1.5 |

### 路線圖設計理由（與微架構主張一致）

- **不加深流水線換效能**：SIMT 的延遲隱藏靠 **TLP（多 warp）**而非 ILP（深流水）——OH-1 Pro 走多 warp 路線，與「2–3 級甜蜜點」分析一致，redirect 懲罰不被放大
- **每級差異都是參數/介面層**：LANES_P、流水線選項、bus wrapper 均不改 ISA 與驗證語意，ISS scoreboard 可沿用

---

## 三、Features 總表（checklist 形式）

**核心**
- [x] 21 條指令 SIMT ISA（custom-0：split/join/tmc/bar/wexit/texit）
- [x] warp-uniform 分支 AND 語意
- [x] 標記式雙 entry 分歧堆疊（8-deep）
- [x] TMC 動態遮罩（clamp＋連續 ones-mask 保證）
- [x] 每 lane 獨立 RF/ALU/LSU
- [x] LANES_P 參數化
- [ ] wspawn 多 warp（ISA 已預留）
- [ ] BAR 記憶體屏障語意強化（現為單 warp nop）

**驗證**
- [x] directed smoke 12 項 / SIMD 14 項（verilator 可跑）
- [x] UVM CRV＋指令級 ISS scoreboard
- [x] 8 covergroups / 15 assertions / 17 cover properties
- [x] 覆蓋率閉環計畫與簽核標準
- [ ] VCS 上實跑 100% 覆蓋簽核（待商業模擬器環境）
- [ ] 隨機 seed 回歸矩陣（50+ seeds）

**工具與流程**
- [x] verilator 5.052 / iverilog 11 / yosys 0.65 全部 source 固化
- [x] manifest＋離線重現
- [x] lint 權威檢查（剩 3 個已知 warning，diff 已備）
- [ ] yosys 合成 Fmax/面積基線報告（M0.3）
- [ ] FPGA reference design（Edge）

**文件**
- [x] 架構圖（doc/oh1_architecture.svg/png）
- [x] lint/coverage/產品線文件
- [ ] ISA 參考卡、教材（Nano）

---

## 四、一句話賣點

> **OH-1：把 GPU 的 warp 分歧語意（split/join/tmc）做進一顆 2 級流水線、可完整形式化驗證的微型 SIMT 核心——14 項逐 lane 定向檢查＋指令級 ISS 隨機驗證，教學、嵌入式 offload、加速器原型三者通吃。**
