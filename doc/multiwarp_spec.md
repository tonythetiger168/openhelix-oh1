# OH-1 多 warp 設計規格（M1.0 W3 → M2.0）

日期：2026-10-05　｜　狀態：ISA 編碼凍結，RTL 實作 M2.0

---

## 1. 指令語意

`wspawn rd, rs1`——產生新 warp：

| 欄位 | 說明 |
|---|---|
| `rd` | 新 warp 的入口 PC（word index） |
| `rs1` | 初始 lane mask（通常全 1） |
| 效果 | 若硬體 warp slot 有空閒，啟動新 warp；否則 stall 直到有空閒 |

`wexit`——當前 warp 退出，釋放 slot。

**與現有分歧堆疊的關係**：每 warp 獨立堆疊——warp 數 × DIV_STK_DEPTH。

## 2. 微架構（2-warp round-robin）

```
IF:  warp0_pc → imem → warp0_ir ─┐
     warp1_pc → imem → warp1_ir  │ 2-to-1 mux（round-robin 選擇）
                                ↓
ID:  decode + RF read（warp0 或 warp1 的 RF bank）
                                ↓
EX:  ALU/LSU/Stack（warp0 或 warp1 的狀態）
                                ↓
WB:  寫回對應 warp 的 RF
```

| 元件 | 規格 |
|---|---|
| warp 狀態 | PC ×2、act_mask ×2、div stack ×2、done ×2 |
| RF | **複製** ×2（非 banking——時脈不變，面積 +30%） |
| imem | dual-port 或 2 週期輪詢（M1.0 用輪詢，M2.0 dual-port） |
| dmem | banked ×2（warp0 用 bank0/1，warp1 用 bank2/3）——同時解決 divergent LSU 衝突 |
| 排程 | round-robin：IF 給 warp A 時 EX 給 warp B，**零氣泡** |

## 3. 與「不深流水線」主張的關係

GPU 延遲隱藏靠 **TLP（多 warp）** 而非 ILP（深流水線）——本方案是架構主張的直接落地：
- 單 warp 分歧等待時，另一 warp 填補 EX 級——**等效吞吐 ×1.8**（非 ×2，因切換開銷）
- 每 warp 的 redirect 懲罰仍維持 1 bubble（2 級流水線不變）

## 4. 驗證

| 項目 | 內容 |
|---|---|
| ISS 擴充 | warp 交錯執行模型：每步輪流 step warp0/warp1，各自獨立堆疊/遮罩 |
| `tb_rand` | generator 加 `wspawn`/`wexit`，隨機 warp 數（1/2）、隨機入口 PC |
| covergroup | `cg_multiwarp`：warp 數×活躍度×分歧深度 cross |
| 功耗 | warp 切換時 operand isolation 沿用——inactive warp 的 lane 不開關 |

## 5. 時脈影響

RF 複製（非 banking）→ 關鍵路徑不變。warp 切換 mux（2-to-1）增加 ~0.5ns——在 2 級流水線的時序預算內（FPGA 目標 ≥80MHz 有餘量）。
