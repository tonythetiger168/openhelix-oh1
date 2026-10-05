// =============================================================================
// OpenHelix OH-1 scoreboard（tb/oh1_scoreboard.sv）
// - 內建指令級 ISS（interpreter），語意逐條鏡像 oh1_core：
//   warp-uniform 分支 AND、標記式雙 entry 分歧堆疊、TMC lane0 取值、
//   SW 全 lane 寫入（含 inactive）、WB 僅 active lanes 且 rd!=0
// - 比對策略：
//   1) 逐步：exec transaction ↔ ISS step（pc/遮罩一致 + WB 資料逐 lane 比對）
//   2) 終態：done 後比對 RF（uvm_hdl_read）與 dmem（全空間）
// =============================================================================
`ifndef OH1_SCOREBOARD_SV
`define OH1_SCOREBOARD_SV

class oh1_scoreboard extends uvm_component;
  `uvm_component_utils(oh1_scoreboard)
  import oh1_pkg::*;

  uvm_analysis_imp_exec #(oh1_exec_tr,  oh1_scoreboard) exec_export;
  uvm_analysis_imp_wb   #(oh1_wb_tr,    oh1_scoreboard) wb_export;
  uvm_analysis_imp_item #(oh1_prog_item,oh1_scoreboard) item_export;

  virtual oh1_if vif;

  // ---- ISS 狀態 ----
  localparam int ISS_IMEM = 4096;
  localparam int ISS_DMEM = 4096;

  typedef struct {
    bit        tag;    // 1=reconverge, 0=else
    lane_mask_t mask;
    logic [31:0] pc;
  } stk_entry_t;

  logic [31:0] iss_imem [ISS_IMEM];
  logic [31:0] iss_dmem [ISS_DMEM];
  logic [31:0] iss_rf   [LANES][32];
  lane_mask_t  iss_act;
  stk_entry_t  stk[$];
  logic [31:0] iss_pc;
  bit          iss_done, iss_ill;

  int n_prog, n_exec, n_wb, n_err;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    exec_export = new("exec_export", this);
    wb_export   = new("wb_export", this);
    item_export = new("item_export", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(virtual oh1_if)::get(this, "", "vif", vif));
  endfunction

  // ------------------------------------------------------------------
  // 新程式：載入 ISS
  // ------------------------------------------------------------------
  function void write_item(oh1_prog_item tr);
    n_prog++;
    for (int i = 0; i < ISS_IMEM; i++) begin
      iss_imem[i] = '0;
      iss_dmem[i] = '0;
    end
    foreach (tr.pmem[i]) if (i < ISS_IMEM) iss_imem[i] = tr.pmem[i];
    foreach (tr.dmem_init[i])
      if ((tr.dmem_init[i].idx >> 2) < ISS_DMEM)
        iss_dmem[tr.dmem_init[i].idx >> 2] = tr.dmem_init[i].val;
    for (int l = 0; l < LANES; l++)
      for (int r = 0; r < 32; r++) iss_rf[l][r] = '0;
    iss_act  = '1;
    stk.delete();
    iss_pc   = tr.start_pc;
    iss_done = 0;
    iss_ill  = 0;
  endfunction

  // ------------------------------------------------------------------
  // operand decode（pkg 僅提供 dec_kind，欄位切割依 RISC-V 標準格式）
  // ------------------------------------------------------------------
  local function automatic logic [31:0] dec_imm(input logic [31:0] ins,
                                                input ikind_e k);
    logic [11:0] i_imm = ins[31:20];
    logic [11:0] s_imm = {ins[31:25], ins[11:7]};
    logic [12:1] b_imm = {ins[31], ins[7], ins[30:25], ins[11:8]};
    case (k)
      I_ADDI, I_ANDI, I_ORI, I_XORI, I_SLTI, I_SLTIU, I_LW, I_CSRR:
        return {{20{i_imm[11]}}, i_imm};
      I_SLLI, I_SRLI, I_SRAI:
        return {27'b0, i_imm[4:0]};
      I_SW:            return {{20{s_imm[11]}}, s_imm};
      I_BEQ, I_BNE, I_BLT, I_BGE: return {{19{b_imm[11]}}, b_imm, 1'b0};
      I_LUI, I_AUIPC:  return {ins[31:12], 12'b0};
      // custom-0（split 等）：imm_d = sext(i_imm) << 1（oh1_decode，半字組）
      I_SPLIT, I_TMC, I_BAR, I_WEXIT, I_TEXIT: return {{19{i_imm[11]}}, i_imm, 1'b0};
      default:         return 32'b0;
    endcase
  endfunction

  // ------------------------------------------------------------------
  // ISS step：執行 iss_pc 指令，輸出預測 WB
  // ------------------------------------------------------------------
  local function automatic void iss_step(
      output bit        wb_en,
      output logic [4:0] rd,
      output lane_mask_t wb_mask,
      output logic [31:0] wdata [LANES]);

    logic [31:0] ins = iss_imem[(iss_pc >> 2) & 32'hFFF];
    ikind_e      k   = dec_kind(ins);
    logic [4:0]  rs1 = ins[19:15], rs2 = ins[24:20];
    logic [31:0] imm = dec_imm(ins, k);
    logic [31:0] a [LANES], b [LANES];
    lane_mask_t  pred, false_m;
    logic [31:0] pc_n = iss_pc + 32'd4;
    int unsigned tmc_n;

    wb_en = 0; rd = ins[11:7]; wb_mask = '0;
    for (int l = 0; l < LANES; l++) wdata[l] = '0;
    for (int l = 0; l < LANES; l++) begin
      a[l] = (rs1 == 0) ? 0 : iss_rf[l][rs1];
      b[l] = (rs2 == 0) ? 0 : iss_rf[l][rs2];
    end

    case (k)
      I_ADD , I_SUB , I_AND , I_OR  , I_XOR , I_SLL , I_SRL , I_SRA , I_SLT , I_SLTU,
      I_ADDI, I_ANDI, I_ORI , I_XORI, I_SLTI, I_SLTIU, I_SLLI, I_SRLI, I_SRAI,
      I_LUI , I_AUIPC, I_CSRR: begin
        wb_en = 1; wb_mask = iss_act;
        for (int l = 0; l < LANES; l++) if (iss_act[l]) begin
          case (k)
            I_ADD : wdata[l] = a[l] + b[l];
            I_SUB : wdata[l] = a[l] - b[l];
            I_AND : wdata[l] = a[l] & b[l];
            I_OR  : wdata[l] = a[l] | b[l];
            I_XOR : wdata[l] = a[l] ^ b[l];
            I_SLL : wdata[l] = a[l] << b[l][4:0];
            I_SRL : wdata[l] = a[l] >> b[l][4:0];
            I_SRA : wdata[l] = $signed(a[l]) >>> b[l][4:0];
            I_SLT : wdata[l] = ($signed(a[l]) <  $signed(b[l])) ? 1 : 0;
            I_SLTU: wdata[l] = (a[l] < b[l]) ? 1 : 0;
            I_ADDI: wdata[l] = a[l] + imm;
            I_ANDI: wdata[l] = a[l] & imm;
            I_ORI : wdata[l] = a[l] | imm;
            I_XORI: wdata[l] = a[l] ^ imm;
            I_SLTI: wdata[l] = ($signed(a[l]) <  $signed(imm)) ? 1 : 0;
            I_SLTIU:wdata[l] = (a[l] < imm) ? 1 : 0;
            I_SLLI: wdata[l] = a[l] << imm[4:0];
            I_SRLI: wdata[l] = a[l] >> imm[4:0];
            I_SRAI: wdata[l] = $signed(a[l]) >>> imm[4:0];
            I_LUI : wdata[l] = imm;
            I_AUIPC:wdata[l] = iss_pc + imm;
            default: wdata[l] = ((imm[11:0] == CSR_TID) || (imm[11:0] == CSR_LANEID)) ? 32'(l) : 0;
          endcase
        end
      end

      I_LW: begin
        wb_en = 1; wb_mask = iss_act;
        for (int l = 0; l < LANES; l++)
          if (iss_act[l]) wdata[l] = iss_dmem[((a[l] + imm) >> 2) & 32'hFFF];
      end

      I_SW: begin
        // 注意：DUT/TB 對「所有 lane」（含 inactive）依 l=0..3 順序寫入，後者覆蓋
        for (int l = 0; l < LANES; l++)
          iss_dmem[((a[l] + imm) >> 2) & 32'hFFF] = b[l];
      end

      I_BEQ, I_BNE, I_BLT, I_BGE: begin
        lane_mask_t cond = '0;
        for (int l = 0; l < LANES; l++) begin
          case (k)
            I_BEQ: cond[l] = (a[l] == b[l]);
            I_BNE: cond[l] = (a[l] != b[l]);
            I_BLT: cond[l] = ($signed(a[l]) <  $signed(b[l]));
            default: cond[l] = ($signed(a[l]) >= $signed(b[l]));
          endcase
        end
        if ((iss_act & ~cond) == '0) pc_n = iss_pc + imm;   // warp-uniform AND
      end

      I_SPLIT: begin
        pred = '0;
        for (int l = 0; l < LANES; l++) pred[l] = iss_act[l] && (a[l] != 0);
        false_m = iss_act & ~pred;
        if (false_m != '0) begin
          stk.push_back('{tag: 1'b1, mask: iss_act, pc: 32'b0});      // tag entry 先推
          if ((iss_act & pred) != '0) begin
            stk.push_back('{tag: 1'b0, mask: false_m, pc: iss_pc + imm}); // else entry
            iss_act = iss_act & pred;
          end else begin
            iss_act = false_m;
            pc_n    = iss_pc + imm;                                     // 全假直接跳 else
          end
        end
      end

      I_JOIN: begin
        if (stk.size() != 0) begin
          automatic stk_entry_t e = stk.pop_back();
          iss_act = e.mask;
          if (!e.tag) pc_n = e.pc;
        end
      end

      I_TMC: begin
        tmc_n  = (a[0] >= LANES) ? LANES : a[0];   // tmc_rs1_w = lane0 的 rs1
        iss_act = lane_mask_t'((32'd1 << tmc_n) - 32'd1);
      end

      I_BAR: ;                                     // 單 warp：nop

      I_WEXIT, I_TEXIT: iss_done = 1;

      default: iss_ill = 1;                        // I_ILLEGAL：記錄後繼續
    endcase

    // RF 寫回（rd!=0 才寫；RTL wb 在下一 clk edge，ISS 順序單步等價）
    if (wb_en && (rd != 0))
      for (int l = 0; l < LANES; l++)
        if (wb_mask[l]) iss_rf[l][rd] = wdata[l];

    iss_pc = pc_n;
  endfunction

  // ------------------------------------------------------------------
  // analysis imp 實作
  // ------------------------------------------------------------------
  oh1_wb_tr pred_q[$];

  function void write_exec(oh1_exec_tr et);
    bit wb_en; logic [4:0] rd; lane_mask_t wb_mask;
    logic [31:0] wdata [LANES];
    if (iss_done) begin
      `uvm_error(get_type_name(), "exec after done")
      n_err++; return;
    end
    if (et.pc !== iss_pc) begin
      `uvm_error(get_type_name(),
        $sformatf("PC mismatch: dut=%08x iss=%08x", et.pc, iss_pc))
      n_err++;
    end
    if (et.mask !== iss_act) begin
      `uvm_error(get_type_name(),
        $sformatf("MASK mismatch @%08x: dut=%04b iss=%04b", et.pc, et.mask, iss_act))
      n_err++;
    end
    iss_step(wb_en, rd, wb_mask, wdata);
    if (wb_en && (rd != 0)) begin
      oh1_wb_tr p = oh1_wb_tr::type_id::create("p");
      p.rd = rd; p.lane_mask = wb_mask;
      foreach (wdata[l]) p.data[l] = wdata[l];
      pred_q.push_back(p);
    end
    n_exec++;
  endfunction

  function void write_wb(oh1_wb_tr wt);
    oh1_wb_tr p;
    if (pred_q.size() == 0) begin
      `uvm_error(get_type_name(), $sformatf("unexpected WB: rd=%0d", wt.rd))
      n_err++; return;
    end
    p = pred_q.pop_front();
    if (wt.rd !== p.rd) begin
      `uvm_error(get_type_name(),
        $sformatf("WB rd mismatch: dut=%0d iss=%0d", wt.rd, p.rd))
      n_err++;
    end
    if (wt.lane_mask !== p.lane_mask) begin
      `uvm_error(get_type_name(),
        $sformatf("WB mask mismatch rd=%0d: dut=%04b iss=%04b", wt.rd, wt.lane_mask, p.lane_mask))
      n_err++;
    end
    for (int l = 0; l < LANES; l++)
      if (p.lane_mask[l] && (wt.data[l] !== p.data[l])) begin
        `uvm_error(get_type_name(),
          $sformatf("WB data mismatch rd=%0d lane=%0d: dut=%08x iss=%08x",
                    wt.rd, l, wt.data[l], p.data[l]))
        n_err++;
      end
    n_wb++;
  endfunction

  // ------------------------------------------------------------------
  // 終態檢查（最後一個程式）
  // ------------------------------------------------------------------
  function void check_phase(uvm_phase phase);
    logic [31:0] val;
    int rf_bad, dmem_bad;
    super.check_phase(phase);

    if (n_prog == 0) begin
      `uvm_warning(get_type_name(), "no program ran")
      return;
    end
    if (!iss_done) begin
      `uvm_error(get_type_name(), "ISS not done at check_phase")
      n_err++;
    end
    if (vif.mon_cb.done !== 1'b1) begin
      `uvm_error(get_type_name(), "DUT done not asserted")
      n_err++;
    end
    if (vif.mon_cb.illegal !== iss_ill) begin
      `uvm_error(get_type_name(),
        $sformatf("illegal mismatch: dut=%0b iss=%0b", vif.mon_cb.illegal, iss_ill))
      n_err++;
    end

    // RF 終態（hdl backdoor）
    rf_bad = 0;
    for (int l = 0; l < LANES; l++)
      for (int r = 1; r < 32; r++) begin
        if (!uvm_hdl_read($sformatf("tb_top.dut.rf_q[%0d][%0d]", l, r), val)) begin
          `uvm_warning(get_type_name(), "uvm_hdl_read failed (RF compare skipped)")
          rf_bad = -1; break;
        end
        if (val !== iss_rf[l][r]) begin
          if (rf_bad < 3)
            `uvm_error(get_type_name(),
              $sformatf("RF mismatch [%0d][%0d]: dut=%08x iss=%08x", l, r, val, iss_rf[l][r]))
          rf_bad++; n_err++;
        end
      end

    // dmem 全空間
    dmem_bad = 0;
    for (int i = 0; i < ISS_DMEM; i++) begin
      if (vif.read_dmem(i) !== iss_dmem[i]) begin
        if (dmem_bad < 3)
          `uvm_error(get_type_name(),
            $sformatf("DMEM mismatch word %0d: dut=%08x iss=%08x", i, vif.read_dmem(i), iss_dmem[i]))
        dmem_bad++; n_err++;
      end
    end

    `uvm_info(get_type_name(), $sformatf(
      "SCOREBOARD: progs=%0d exec=%0d wb=%0d rf_bad=%0d dmem_bad=%0d errors=%0d",
      n_prog, n_exec, n_wb, rf_bad, dmem_bad, n_err), UVM_LOW)
    if (n_err != 0)
      `uvm_error(get_type_name(), $sformatf("TOTAL ERRORS = %0d", n_err))
  endfunction

endclass
`endif // OH1_SCOREBOARD_SV
