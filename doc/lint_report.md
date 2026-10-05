# OpenHelix OH-1 Lint 報告

日期：2026-10-01（更新）
工具鏈：verilator **5.052**（原始碼編譯，預設）、iverilog 11.0、yosys 0.65（原始碼編譯，`source tools/env.sh`）

## 指令

```bash
make lint-verilator     # verilator --lint-only -sv -Wall（已移除 -Wno-fatal，恢復權威性）
make iv-lint            # iverilog -g2012（容忍已知 sorry，無 error）
make lint-yosys         # yosys hierarchy/proc/check
```

## 現況：**verilator -Wall CLEAN（0 error 0 warning, RC=0）** ✅

| 檢查 | 結果 |
|---|---|
| verilator -Wall | **0 warning 0 error**（2026-10-01 達成，RTL 修正後 smoke/simd/rand 全數回歸通過） |
| iverilog -g2012 | 0 error（34 條已知 sorry 屬工具能力限制） |
| yosys check | 0 error（0.65 版，見 tools/yosys-0.65） |

## 已完成的 lint 修正（全部 grep 驗證落盤）

1. `gen_tmc_rs1` 命名（line 93，GENUNNAMED）
2. `gen_wb_data` 命名（wb_data_o generate）
3. `stk_ptr_q + 2'd2` → `4'd2`（WIDTHEXPAND）
4. `next_pc_c` 未用訊號移除（宣告＋賦值）
5. `redirect_en_c && ex_vld_q` 閘控（**功能性 deadlock bug**，非 lint 項；有 monitor trace 證據鏈）

## 注意事項

- RTL 修正後必須回歸：smoke 12/12、simd 14/14、rand（seed 1,2,3 × 20 programs 60/60）全 PASS。
- 工作區為共享環境：曾觀察到外部對 `tb_smoke.sv` 的平行修改（split imm 修正為半字組），
  修改前請先 `git diff`（若已建 git）或重新 `grep` 確認現況。
