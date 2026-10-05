# OpenHelix OH-1 覆蓋率計畫（UVM CRV）

日期：2026-10-01
平台：`tb/oh1_{if,seq_lib,agent,scoreboard,env,tests}.sv`＋`tb/tb_top.sv`（filelist.f 已就緒）
執行：**需商業模擬器**（VCS/Xcelium/Questa）——本環境僅有 verilator/iverilog，
verilator 不支援完整 UVM class 語法，**無法在本機簽核**，以下為可複現流程。

## 1. 覆蓋模型清單

### 1.1 工具自動收集（line / toggle / FSM / assert）

| 覆蓋 | 來源 | 收集方式 |
|---|---|---|
| line | RTL 語句 | 模擬器 code coverage |
| toggle | RTL 訊號 0/1 | 模擬器 code coverage |
| FSM | `active_q/done_q` 狀態機 | 模擬器 FSM 自動抽取（VCS `-cm fsm`）＋`cg_fsm` 交叉驗證 |
| assert | 15 條 SVA | VCS `-cm assert`（pass/fail/vacuous 計數） |

### 1.2 TB 功能覆蓋（covergroup）

| covergroup | 位置 | 覆蓋點 |
|---|---|---|
| cg_exec | oh1_if | 指令 kind（10+9+2+2+4+7 bins）× 遮罩形態（full/single×4/pair×6/triple×4）cross |
| cg_redirect | oh1_if | redirect 來源（branch/split/join）× 方向（fwd/bwd）cross |
| cg_lsu | oh1_if | rd/wr × divergent × 活躍 lane 數 cross |
| cg_fsm | tb_top | IDLE/RUN/DONE ＋ 4 種轉移（idle→run、run→done、reset 路徑） |
| cg_stack | tb_top | 堆疊深度 0–8 × 遮罩 lane 數 0–4 cross |
| cg_wb | oh1_if | WB rd（1–7/8–31）× lane_mask × lane0 資料值類別（0/1/小值/負數/全1/other）cross |
| cg_mem | oh1_if | SW 資料值類別（首/尾 lane）× divergent cross |
| cg_csr | oh1_if | CSRR 位址（TID/LANEID/非既定） |
| cg_tmc | tb_top(XMR) | tmc_n（0/1–3/clamp）× lane0 是否活躍 cross；遮罩 delta（shrink/same/grow） |
| cg_nest | tb_top(XMR) | split 時即時堆疊深度 × 當前遮罩 lane 數 cross |

### 1.3 情境覆蓋（cover property，11 條）

branch taken / fallthrough、split 混合（push_two）/ 全假直跳 / 全真不推、
join 彈 else（redirect）/ 彈 tag（restore）、tmc 縮小遮罩、lw/sw divergent、**tmc zero/grow/equal/clamp、深層 split
（stk≥4）、堆疊縮小轉移**。
另加 **15 條** assert property（done 靜默/done 保持/堆疊邊界×3/對齊×2/
空遮罩不執行/split 子集/**tmc ones-mask 連續/push·pop 遮罩非空×2/
start→active/active·done 互斥/done 時 x0 全 lane 為 0（generate）**）。

## 2. 執行流程（closure）

```bash
source tools/env.sh          # 僅 iverilog/yosys/verilator 需要
make sim SIM=vcs TEST=oh1_smoke_test          # directed 基線
make cov                                       # = smoke+rand+stress 三 test 後 urg 合併
# 未達標時：調整 CRV knobs（+ntb_random_seed 多 seed）→ 重跑 → 再合併
```

```bash
# Xcelium 等價：xrun -coverage all -covoverwrite ...；Questa：vlog/vsim -coverage
```

## 3. 簽核標準（100%）

1. line/toggle：**100%**，未覆蓋點逐條審查 → 合理不可達（如 case default 防護、
   tmc 值 ≥LANES 的 clamp 路徑）才允許 exclusion，並記錄於
   `doc/coverage_exclusions.md`（簽核時建立）。
2. FSM：所有狀態與轉移 100%（cg_fsm 與工具 FSM coverage 互相佐證）。
3. assert：10 條全 pass、無 vacuous（每條至少 1 次有效匹配）；
   11 條 cover property 全命中 ≥1 次。
4. 功能覆蓋：cg_exec/cg_redirect/cg_lsu/cg_fsm/cg_stack 全部 100%，
   cross bin 未命中者需新增 directed sequence 補洞。

## 4. 已知風險

- **cg_stack d7/d8 bin**：巢狀上限 3（6 entry）由產生器保證不溢位；深度 7–8 需
  產生器放寬並確認 RTL 堆疊溢位保護行為（`ast_stk_push_room` 會攔截非法程式）。
- UVM 程式庫未在本環境編譯驗證：首次於 VCS 編譯時可能有語法修正迭代。
