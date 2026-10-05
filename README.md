# OpenHelix OH-1 — RTL 開發倉庫

> Milestone 0.1：單 warp SIMT 最小核心（功能正確性基線 / golden RTL）
> 設計：SystemVerilog　|　驗證：UVM 1.2 + Constrained-Random（CRV）
> 對應計畫書：Phase 1 之第一個工程交付物

## 本里程碑範圍（v0.1 刻意做少，但做對）

**做：**
- RV32I 核心子集（R/I/B/LUI/AUIPC/LW/SW）+ custom-0 SIMT 擴展：`split/join/tmc/bar/wexit/texit`
- 分歧堆疊採**標記式雙 entry 模型**（v0.1 設計決策）：
  - `split p` 分歧時依序推入 `{tag=1, 原遮罩}` 與 `{tag=0, false_m, else_pc}`，執行 then 路徑
  - 全假（true_m==0）時僅推 tag entry 並直接進 else 路徑（then 路徑的 join 自然被跳過）
  - `join`：彈出 tag=0 → 進 else 路徑；彈出 tag=1 → 恢復原遮罩、pc+4 續行（reconverge）
  - 程式慣例：if-else 結構需兩個 join（then 路徑尾、else 路徑尾各一）
- CSR 唯讀：`0x8C0 (tid)`、`0x8CD (laneid)`（每 lane 回傳自身 lane 編號）
- LANES=4 lane 私有寄存器堆、分歧堆疊（深度 8）、活動遮罩
- **IF/EX 二級流水線**：IF 持續取指；EX 解析控制轉移（branch taken / split 全假 / join→else）時 flush 誤取指令（1-cycle bubble）；無資料旁路需求（v0.1 每指令獨佔 EX）
- UVM CRV：隨機指令流（split/join 配平、branch 目標範圍、對齊約束）、ISS 參考模型 scoreboard、功能覆蓋

**不做（後續里程碑）：**
- wspawn 多 warp、tmma 張量單元、atomics/fence、管線化、多 core/NoC

## 目錄結構

```
openhelix/
├── README.md
├── Makefile / filelist.f
├── rtl/
│   ├── oh1_pkg.sv        # 參數 + ISA 編碼/解碼常數（generator 與 ISS 單一事實來源）
│   ├── oh1_decode.sv     # 組合解碼器
│   └── oh1_core.sv       # DUT：FSM + RF + ALU + 分歧堆疊 + LSU + 可觀測埠
├── tb/
│   ├── oh1_if.sv         # prog_if（指令記憶體在 interface 內）/ dmem_if
│   ├── oh1_agent.sv      # transaction/item/sequencer/driver/monitor
│   ├── oh1_seq_lib.sv    # 隨機程式序列（CRV 約束核心）
│   ├── oh1_scoreboard.sv # ISS 參考模型 + 逐事件比對
│   ├── oh1_env.sv        # env + coverage
│   ├── oh1_tests.sv      # smoke / random / 高分歧測試
│   └── tb_top.sv
├── sim/                  # 模擬工作目錄
└── doc/                  # 驗證計畫（待補 v0.2）
```

## 執行方式（需商業模擬器，本 sandbox 無法執行）

```bash
make sim SIM=vcs    TEST=oh1_smoke_test    # Synopsys VCS
make sim SIM=xrun   TEST=oh1_rand_test    # Cadence Xcelium
make sim SIM=questa TEST=oh1_div_test     # Siemens Questa
make cov SIM=vcs                          # 產生覆蓋率報告
```

> iverilog/verilator 不支援 UVM 類別庫，v0.1 不支援；RTL 部分可另行以 verilator --lint-only 檢查。

## 驗證方法學

| 元件 | 方法 |
|---|---|
| Stimulus | CRV：指令種類/操作數/立即數約束；序列層追蹤分歧深度（split/join 配平）、branch 目標界內、LW/SW 字對齊 |
| Reference | Scoreboard 內 ISS：逐 lane 執行 + 遮罩語義 + 分歧堆疊，與 DUT 逐事件比對 WB/DMEM |
| 比對點 | EXEC 事件：pc / instr / active_mask / WB(rd,data,per-lane) / DMEM write |
| Coverage | opcode bins、funct12、rd/rs1/rs2 區間、分歧深度、branch taken、load/store 位址區間、CSR bins、cross |
| 結束條件 | texit 抵達 + scoreboard final check + watchdog |

## 編碼慣例

- custom-0 = `0001011`，funct12 區分指令（pkg 內定義）
- 所有狀態可觀測：`exec_valid/exec_pc/exec_active_mask/wb_*/dmem_*` 輸出埠
- bar 在單 warp 語義下為 nop（保留計數器介面供多 warp 擴充）
