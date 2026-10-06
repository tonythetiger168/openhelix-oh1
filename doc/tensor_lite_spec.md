# OH-1 Tensor Lite 設計規格（M1.0 W1）

日期：2026-10-05　｜　狀態：ISA 編碼已凍結（pkg），RTL 實作規劃中

---

## 1. 指令語意

`vdot rd, rs1, len`——4-lane 並列 FP16 dot-product，每 lane 獨立：

```
for l in 0..LANES-1:
  if act_mask_q[l]:
    acc = 0
    for k in 0..len-1:
      acc += fp16_to_fp32(mem[rs1[l] + k*4]) * fp16_to_fp32(mem[rs1[l] + k*4 + 2])
    rf[l][rd] = fp32_to_fp16(acc)   // 或保持 FP32 累加，視精度需求
```

| 欄位 | 說明 |
|---|---|
| `rd` | 目標累加器暫存器（每 lane 獨立） |
| `rs1` | 向量基址暫存器（每 lane 各自指向自己的 FP16 向量） |
| `len` | 向量長度（2/4/8，imm[11:0] 儲存，0→2） |
| `rs2` | 保留（未來擴展：第二運算元或 stride） |

**SIMT 一致性**：每 lane 處理自己的 2×2 小塊，結果是每 lane 一個 scalar——與現有 ALU 語意完全對齊，divergence 語意不變。

## 2. 微架構

```
Lane l:
  rs1_data[l] → addr_gen → dmem_raddr[l]（len 次讀取，或 burst）
                    ↓
              FP16 pair → FP16_MUL → FP32_ACC（累加器暫存器）
                    ↓
              FP32→FP16 捨入 → wb_data_c[l]
```

| 元件 | 規格 |
|---|---|
| FP16 乘法器 | 4×（每 lane 一個），IEEE 754 half，支援 subnormal |
| FP32 累加器 | 4×（每 lane 一個），中間精度不捨入 |
| 捨入 | 最終一步 FP32→FP16（RN——round-to-nearest-even） |
| operand isolation | 沿用 M0.3 的 `rs1_iso`——inactive lane 的 MAC 不開關 |

**時脈影響**：FP16 乘法器關鍵路徑 ~3ns（28nm），不改變 2 級流水線的時脈目標。

## 3. 記憶體介面

`vdot` 需要從 dmem 讀取 `len` 個 FP16 pair——與現有 `I_LW` 的單字讀取不同：

| 方案 | 說明 | 選擇 |
|---|---|---|
| A. 多週期讀取 | `vdot` 佔用 EX 級 `len/2` 個週期（每週期讀 2 個 FP16） | ✅ **M1.0 採用**——簡單，不破壞流水線，divergent lane 可提前完成 |
| B. burst 讀取 | 一次發起 burst，dmem 改雙埠 | M2.0（配合 banked dmem） |
| C. 向量暫存器檔 | 類似 RVV 的向量暫存器 | 不做（面積複雜度） |

**多週期語意**：`vdot` 執行時 `exec_valid` 保持 1，但 `wb_valid` 延後到最後一個 lane 完成——需要新增 `vdot_busy` 狀態位。

## 4. 精度與驗證

| 項目 | 規格 |
|---|---|
| 中間精度 | FP32 累加（不捨入） |
| 最終精度 | FP16（RN），誤差 < 1 ULP（相對於 FP32 參考） |
| 特殊值 | Inf/NaN 傳播、subnormal 支援 |
| 驗證 | `tb_rand` generator 加 `vdot`（隨機 len/lane mask/資料）；golden model 用 Python `struct` 打包 FP16 計算期望值 |
| covergroup | `cg_tensor`：len（2/4/8）× lane 活躍度（1/2/3/4）× 資料類別（normal/subnormal/Inf/NaN）cross |

## 5. 與現有設計的整合點

| 檔案 | 改動 |
|---|---|
| `oh1_pkg.sv` | ✅ 已完成：`I_VDOT`、`F3_VDOT`、`enc_vdot` |
| `oh1_core.sv` | 新增 `vdot_busy` 狀態、FP16 MAC 陣列、多週期控制 |
| `oh1_decode.sv` | 無（vdot 用現有 imm_d） |
| `tb_rand` | generator 加 `vdot`、ISS 加 FP16 dot-product 語意 |
| `tb_simd` | 新增 vdot 定向測試（每 lane 獨立向量） |

## 6. 量化目標

| 指標 | M0.3（無 tensor） | M1.0（Tensor Lite） |
|---|---|---|
| INT 運算 | 4×32b ALU | 4×32b ALU + 4×FP16 MAC |
| FP16 吞吐 | 0 | 8 GFLOPS（4 lane × 2 MAC × 1GHz） |
| 面積 | 基準 | +15~20%（FP16 乘法器 + 累加器） |
| 功耗 | 基準 | +10%（operand isolation 限制在 active lane） |

**定位**：邊緣 AI 前處理（感測器融合、特徵提取），非 LLM 推理。
