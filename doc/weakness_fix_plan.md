# OH-1 弱點補強方案（對應 SWOT 劣勢 W1–W4）

日期：2026-10-02　｜　原則：每項補強都錨定現有驗證資產（ISS/CRV/SVA 可沿用），
不依賴深流水線、不改 ISA 凍結區（僅 additive 擴展）

---

## W1. 無 FP/Tensor 單元

### 方案：OH-1 Tensor Lite（M1.0，4–6 週）

**設計**：不新增獨立 tensor core，而是在既有 4-lane ALU 旁並一個 **2×2 FP16/BF16 MAC 陣列**（每 lane 一個 MAC），執行「4-lane 並列 dot-product」：

| 項目 | 內容 |
|---|---|
| ISA | Custom-0 新 F3 編碼：`vdot vd, vs1, vs2, imm`（imm=向量長度 2/4/8） |
| 語意 | 每 lane 獨立：`vd[l] += Σ vs1[l][k] * vs2[l][k]`（k<imm）——SIMT 一致性：每 lane 處理自己的 2×2 小塊，結果是每 lane 一個 scalar 累加值 |
| 硬體 | 4× FP16 乘法器（可共用現有 ALU 的 32b 乘法器路徑，時脈不變）＋ 4× FP32 累加器＋1 個共享 FP32→FP16 捨入單元 |
| 不做的 | 不支援 FP32 全精度（面積×2，邊緣 AI 用不到）、不做 4×4 以上（lane 數限制，擴充留 M2） |
| 功耗 | 複用 operand isolation：vdot 只在 act_mask_q 的 lane 上開關 MAC |
| 驗證 | tb_rand generator 加 `vdot` 隨機指令（golden model FP16 用 bit-accurate reference——Python struct 打包計算期望值）；covergroup 加 `cg_tensor`（向量長度×lane 活躍度 cross） |

**量化目標**：INT8 8 TOPS→ FP16 2 TFLOPS（4 lane × 2 MAC × 500MHz）——足夠邊緣 AI 前處理（感測器融合、特徵提取），不夠 LLM 推理（非目標）。

**KPI**：`tb_rand` 含 vdot 後 100 programs × 3 seeds 全 PASS；FP16 精度誤差 < 1 ULP（相對于 IEEE 754 half）。

---

## W2. 無 cache/DMA/匯流排

### 方案：AXI4-Lite 周邊 + 區塊搬移 DMA（M1.0，與 W1 並行 6–8 週）

**設計**：把 OH-1 從「TB 餵程式」變成「可掛系統匯流排的加速器周邊」：

```
┌─────────────────────────────────────┐
│  AXI4-Lite Slave（控制面）          │
│  · 0x00: CTRL (start/done/irq_en)   │
│  · 0x04: STATUS (done/illegal/busy) │
│  · 0x08: PROG_BASE (imem 載入位址)  │
│  · 0x0C: DATA_BASE (dmem 基址)      │
│  · 0x10: PROG_LEN (指令數)          │
│  · 0x14: IRQ_STATUS / clear         │
└──────────┬──────────────────────────┘
           │
┌──────────▼──────────────────────────┐
│  DMA Engine（AXI4 Master）          │
│  · 描述符環：{src, dst, len} × 8    │
│  · 搬移方向：host→imem、dmem→host   │
│  · 與核心並發：核心 RUN 時 DMA idle │
│    （單 warp 無 context switch，    │
│     不需要同時搬）                  │
└──────────┬──────────────────────────┘
           │
    ┌──────▼──────┐        ┌──────────┐
    │  OH-1 Core  │◄──────►│  SRAM    │
    │  (existing) │  native│  imem/   │
    └─────────────┘  ports │  dmem    │
                           └──────────┘
```

| 項目 | 內容 |
|---|---|
| 匯流排 | AXI4-Lite slave（控制）＋ AXI4 master（DMA），不支援 burst > 8（簡化） |
| 記憶體 | imem/dmem 改為 **dual-port SRAM**（port A：core native，port B：DMA/host）——不影響核心時序 |
| cache | **不做**（明確決策）：MCU 級加速器用 SRAM 直通 + DMA 預取已足夠，cache 一致性複雜度不值得 |
| 中斷 | done/illegal 可 maskable IRQ，優先級由系統整合者定 |
| 功耗 | DMA idle 時 clock-gate（`cg_dma`），AXI 介面無活動自動掉電 |
| 驗證 | 新增 `tb_axi`（AXI VIP 或簡易 master BFM）：DMA 搬移正確性（random length/alignment）、IRQ 時序、控制面讀寫；`tb_rand` 不變（核心語意不受周邊影響） |

---

## W3. 單 warp（無 TLP 延遲隱藏）

### 方案：多 warp 基礎（M1.0 後段，8–10 週）

**設計**：啟用 ISA 預留的 `wspawn`（F3=001），支援 **2 warp**（M2 再擴 4/8）：

| 項目 | 內容 |
|---|---|
| 硬體 | warp 狀態複製 ×2：PC/imem 埠（imem 改 dual-port 或 2 週期輪詢）、act_mask、分歧堆疊、RF 改 **banked 2×**（每 warp 獨立 32×32b） |
| 排程 | round-robin，每個 warp 執行 1 條指令後切換（與 2 級流水線自然對齊：IF 給 warp A 時 EX 給 warp B，零氣泡） |
| 關鍵路徑 | RF banking 需 2R1W 埠或複製——選 **複製**（面積 +30%，時脈不變）|
| dmem | 雙 warp 並發存取衝突 → **banked dmem**（warp 0 用 bank0/1，warp 1 用 bank2/3，LSU 位址 bit[3:2] 選 bank）——divergent LSU 衝突順便解決（W2 的 banked dmem 為此鋪路） |
| 驗證 | ISS 擴充：warp 交錯執行模型（每步輪流 step warp0/warp1）；`tb_rand` 加 `wspawn` 指令（隨機 warp 數 1/2）；divergent LSU cross-warp 衝突 covergroup |
| 功耗 | warp 數 2 但同一時間只 1 個活躍（round-robin）→ 動態功耗 ×1.3（RF 複製），但 **TLP 延遲隱藏讓等效吞吐 ×1.8**（分歧等待被另一 warp 填滿） |

**與「不深流水線」主張的關係**：GPU 的延遲隱藏靠 TLP（多 warp）而非 ILP（深流水）——本方案是架構主張的直接落地，不是矛盾。

---

## W4. 零軟體生態

### 方案：LLVM 後端 + intrinsics（M1.0 全程，10–12 週，最優先啟動）

**設計**：沒有編譯器，硬體就是死的——這是四項弱點中**最關鍵**的（NVIDIA 的護城河是 CUDA，不是矽）。

| 項目 | 內容 |
|---|---|
| 路徑 | 基於 LLVM 19（TableGen 定義 OH-1 backend）：`clang → LLVM IR → OH-1 machine code` |
| 呼叫約定 | C 函數 → 自動映射到 warp：函數引數 → lane 暫存器，回傳值 → lane 0 |
| intrinsics | `__builtin_oh1_split(pred)`, `__builtin_oh1_join()`, `__builtin_oh1_tmc(n)`, `__builtin_oh1_vdot(vs1, vs2, len)`（W1 聯動） |
| 向量型別 | `v4i32`（4-lane 整數向量）→ `vdot` 自動向量化（`#pragma omp simd` 或手動 intrinsic） |
| 執行檔格式 | 自定義 `.ohx`（ELF 子集：段 = imem 映像 + dmem 初始化 + 進入點） |
| 模擬器 | `oh1-sim`（基於現有 ISS，C++ 移植）——與 RTL co-simulation 對照 |
| 驗證 | `tests/` 目錄：C 程式 → LLVM → oh1-sim → 期望值；CI 跑 `make check-llvm`（對照 RTL 模擬結果） |

**KPI**：`hello_vector.c`（4-lane 向量加法）編譯 → 模擬 → RTL co-sim 全鏈路通；`matrix_2x2.c`（vdot）正確。

---

## 補強路線圖總覽

| 弱點 | 方案 | 里程碑 | 週期 | 與現有資產的複用 |
|---|---|---|---|---|
| W1 無 FP/tensor | Tensor Lite（2×2 FP16 MAC） | M1.0 | 4–6 週 | tb_rand generator/ISS 擴充；operand isolation 複用 |
| W2 無 DMA/匯流排 | AXI4-Lite + DMA | M1.0 | 6–8 週 | 與 W3 banked dmem 共用；tb_axi 新增 |
| W3 單 warp | 2-warp round-robin | M1.0→M2 | 8–10 週 | ISS warp 模型；tb_rand 擴充 |
| W4 零軟體 | LLVM backend + intrinsics | M1.0（最優先） | 10–12 週 | 現有 ISS 作為 oh1-sim 基礎 |

**驗證不債務原則**：每項補強落地時，`tb_rand`/`tb_simd`/`tb_smoke` 必須同步更新（新增指令/情境），確保 CRV 覆蓋率不隨硬體複雜度稀釋。
