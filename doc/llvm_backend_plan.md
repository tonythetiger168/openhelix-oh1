# OH-1 LLVM Backend 實作計畫（M1.0 W4）

日期：2026-10-08　｜　狀態：規格凍結，實作 M1.0 收尾後啟動

---

## 1. 戰略定位

**W4 是四項弱點中最關鍵的**——沒有編譯器，硬體就是死的（NVIDIA 的護城河是 CUDA 不是矽）。LLVM backend 讓 OH-1 從「手寫 assembly 的教學玩具」變成「可跑 C 程式的加速器」。

## 2. 技術路線（LLVM 19，TableGen 定義）

### 2.1 Target 描述（`lib/Target/OH1/`）

| 檔案 | 內容 |
|---|---|
| `OH1.td` | Target 定義：位元組序（little）、字長（32）、暫存器類別（GPR32、SPR） |
| `OH1RegisterInfo.td` | 32 個 GPR（x0–x31）、x0 硬接零、特殊暫存器（PC、act_mask） |
| `OH1InstrInfo.td` | 21 條指令模式匹配：R-type（add/sub/…）、I-type（addi/…）、B-type（beq/…）、Custom-0（split/join/tmc/vdot/wspawn） |
| `OH1CallingConv.td` | C 函數 → warp 映射：引數 → lane 暫存器，回傳值 → lane 0 |

### 2.2 關鍵設計決策

| 決策 | 說明 |
|---|---|
| **向量型別 `v4i32`** | LLVM 原生 4-element vector → OH-1 的 4-lane SIMD；`v4i32 add` → 4× `add`（SISD）或 `vdot`（若為 dot-product pattern） |
| **SIMT 語意的 C 暴露** | `__builtin_oh1_split(pred)` / `__builtin_oh1_join()` / `__builtin_oh1_tmc(n)`——intrinsic 直接映射 custom-0 指令，不經pattern matching |
| **分歧的 C 語法** | `if (__builtin_oh1_laneid() != 0)` → split/join 對；自動由編譯器插入，非手寫 |
| **執行檔格式 `.ohx`** | ELF 子集：`.text`（imem 映像）、`.data`（dmem 初始化）、`.entry`（start_pc） |

### 2.3 編譯流程

```
hello.c
  ↓ clang -target oh1-unknown-elf
LLVM IR（含 v4i32、intrinsics）
  ↓ opt（O2）
機器無關優化
  ↓ llc -march=oh1
OH1 machine code（.s）
  ↓ oh1-as（自製 assembler，或 LLVM MC）
.o
  ↓ oh1-ld（自製 linker，或 lld 擴展）
.ohx
  ↓ oh1-sim（ISS 移植）或 RTL co-sim
執行結果
```

## 3. 實作里程碑（W4 內部拆分）

| 階段 | 內容 | 時程 | 驗收 |
|---|---|---|---|
| W4.1 | `OH1.td` + `OH1RegisterInfo.td` + 最小 `llc`（可編譯 `return 42`） | 2 週 | `llc` 產生正確 assembly |
| W4.2 | `OH1InstrInfo.td` 全 21 指令 + `oh1-as` assembler | 2 週 | `add/addi/beq` 手工 assembly 跑通 RTL |
| W4.3 | Calling convention + `clang` 整合（C → OH1） | 3 週 | `hello_vector.c`（v4i32 加法）編譯執行正確 |
| W4.4 | Intrinsics（split/join/tmc）+ divergent codegen | 3 週 | `if (laneid != 0)` 自動產生 split/join，CRV 驗證 |
| W4.5 | `vdot` 自動向量化（pattern matching） | 2 週 | `dot_product.c`（FP16 陣列內積）編譯 → vdot，精度 <1 ULP |
| W4.6 | `.ohx` linker + `oh1-sim`（ISS 移植）+ co-sim 流程 | 2 週 | CI 跑 `make check-llvm`（編譯→模擬→RTL co-sim 全鏈路） |

## 4. 與現有驗證資產的整合

| 資產 | 用法 |
|---|---|
| `tb_rand` ISS | 直接作為 `oh1-sim` 的 C++ 核心（已驗證語意正確） |
| `tb_rand` generator | 用於 CRV 測試 LLVM 產生的 code（隨機 C 程式 → 編譯 → co-sim） |
| `doc/tensor_lite_spec.md` | `vdot` 的 LLVM pattern matching 規格來源 |
| `doc/multiwarp_spec.md` | `wspawn` 的 LLVM intrinsic 語義來源 |

## 5. 風險與對策

| 風險 | 對策 |
|---|---|
| LLVM TableGen 學習曲線陡峭 | 參考 RISCV backend（最成熟的开源參考）；W4.1 先最小化 |
| `v4i32` 的 divergent 語意與 LLVM vector 語義不完全對齊 | 在 `OH1ISelLowering.cpp` 自定義 lowering，不強求通用 vector 支援 |
| 自動 split/join 插入的演算法複雜 | M1.0 先支援手動 intrinsic（`__builtin_oh1_split`），自動插入 M2.0 |
| `.ohx` 格式無現成工具 | 用 Python 寫 `oh1-ld`（簡單段合併），不擴展 lld |

## 6. 一句話

> **W4 把 OH-1 從「驗證過的 RTL」變成「可用的加速器」——LLVM backend 是軟體生態的根，也是與 NVIDIA CUDA 護城河對位的唯一長期路徑。**
