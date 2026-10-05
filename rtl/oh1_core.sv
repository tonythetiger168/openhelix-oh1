// =============================================================================
// OH-1 最小核心（Milestone 0.2：IF/EX 二級流水線）
//  - 單 warp、LANES=4
//  - IF stage：連續取指（imem comb read）；EX 控制轉移時 flush 誤取指令
//    （branch taken / split 全假 / join→else），代價 1-cycle bubble
//  - EX stage：lane 私有 RF（32 x 32b）、活動遮罩、標記式分歧堆疊
//  - 每 lane 獨立 LSU 埠（divergent LW/SW 由 TB dmem_if 逐 lane 處理）
//  - 每 lane 運算以 genvar 產生（per-lane 區塊對 synthesis/iverilog 皆友善；
//    iverilog 不支援 always_* 內對 unpacked array 的變數索引）
// =============================================================================
module oh1_core import oh1_pkg::*; #(
  parameter int LANES_P  = 4,
  parameter int STK_P    = 8
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic                      start_i,        // 脈波：離開 IDLE 開始執行
  input  logic [31:0]               start_pc_i,

  output logic [31:0]               imem_addr_o,
  input  logic [31:0]               imem_rdata_i,

  output logic                      dmem_ren_o,
  output logic [31:0]               dmem_raddr_o  [LANES_P],
  input  logic [31:0]               dmem_rdata_i  [LANES_P],
  output logic                      dmem_wen_o,
  output logic [31:0]               dmem_waddr_o  [LANES_P],
  output logic [31:0]               dmem_wdata_o  [LANES_P],

  output logic                      exec_valid_o,
  output logic [31:0]               exec_pc_o,
  output lane_mask_t                exec_mask_o,
  output logic                      wb_valid_o,
  output logic [4:0]                wb_rd_o,
  output lane_mask_t                wb_lane_mask_o,
  output logic [31:0]               wb_data_o     [LANES_P],
  output logic                      done_o,
  output logic                      illegal_o
);

  // ===========================================================================
  // IF stage
  // ===========================================================================
  logic        active_q;
  logic [31:0] if_pc_q;
  logic        ex_vld_q;
  logic [31:0] ir_q;
  logic [31:0] ex_pc_q;

  assign imem_addr_o = if_pc_q;

  // ---- 解碼（EX 階段）----
  ikind_e      kind;
  logic [4:0]  rd_d, rs1_d, rs2_d;
  logic [31:0] imm_d;
  logic        ill_d;
  oh1_decode u_dec (
    .instr_i (ir_q),
    .kind_o  (kind), .rd_o(rd_d), .rs1_o(rs1_d), .rs2_o(rs2_d),
    .imm_o   (imm_d), .illegal_o(ill_d)
  );

  // ---- RF（per-lane 讀口；寫口在 always_ff）----
  logic [31:0] rf_q [LANES_P][32];
  logic [31:0] rs1_data [LANES_P], rs2_data [LANES_P];

  // ---- 分歧堆疊（標記式雙 entry 模型）----
  lane_mask_t     act_mask_q;
  logic           stk_tag_q  [STK_P];
  lane_mask_t     stk_mask_q [STK_P];
  logic [31:0]    stk_pc_q   [STK_P];
  logic [$clog2(STK_P+1)-1:0] stk_ptr_q;
  logic [2:0]     sptr_w;
  assign sptr_w = stk_ptr_q[2:0];

  logic        done_q, ill_q;

  // ===========================================================================
  // Per-lane 組合邏輯（genvar：每 lane 獨立區塊，無變數索引）
  // ===========================================================================
  logic [LANES_P-1:0] pred_vec, cond_vec;   // 每 lane 謂詞/條件位元
  logic [31:0]        tmc_rs1_w;            // lane0 之 rs1（tmc 用）
  lane_mask_t         wb_lane_mask_c;
  logic [31:0]        wb_data_c [LANES_P];
  logic               wb_en_c;

  for (genvar l = 0; l < LANES_P; l++) begin : g_lane
    // RF 讀口
    always_comb begin
      rs1_data[l] = (rs1_d == 5'd0) ? 32'b0 : rf_q[l][rs1_d];
      rs2_data[l] = (rs2_d == 5'd0) ? 32'b0 : rf_q[l][rs2_d];
    end
    if (l == 0) begin : gen_tmc_rs1
      assign tmc_rs1_w = rs1_data[0];
    end

    // ---- Low-power：operand isolation（僅 ALU/branch/split 用；LSU 位址資料與
    //      TMC（取 lane0 原始值）維持 rs*_data 原值，保證 SW 全 lane 語意不變）----
    //      不活躍 lane 的 ALU 輸入恆為 0 → 動態功耗與「活躍 lane 數」成正比，
    //      這是 SIMT 天然的功耗比例性（power scales with divergence）。
    logic [31:0] rs1_iso, rs2_iso;
    assign rs1_iso = act_mask_q[l] ? rs1_data[l] : 32'b0;
    assign rs2_iso = act_mask_q[l] ? rs2_data[l] : 32'b0;

    always_comb begin
      wb_data_c[l]    = 32'b0;
      dmem_raddr_o[l] = 32'b0;
      dmem_waddr_o[l] = 32'b0;
      dmem_wdata_o[l] = 32'b0;
      pred_vec[l]     = 1'b0;
      cond_vec[l]     = 1'b1;
      unique case (kind)
        I_ADD : if (act_mask_q[l]) wb_data_c[l] = rs1_iso +  rs2_iso;
        I_SUB : if (act_mask_q[l]) wb_data_c[l] = rs1_iso -  rs2_iso;
        I_AND : if (act_mask_q[l]) wb_data_c[l] = rs1_iso &  rs2_iso;
        I_OR  : if (act_mask_q[l]) wb_data_c[l] = rs1_iso |  rs2_iso;
        I_XOR : if (act_mask_q[l]) wb_data_c[l] = rs1_iso ^  rs2_iso;
        I_SLL : if (act_mask_q[l]) wb_data_c[l] = rs1_iso << rs2_iso[4:0];
        I_SRL : if (act_mask_q[l]) wb_data_c[l] = rs1_iso >> rs2_iso[4:0];
        I_SRA : if (act_mask_q[l]) wb_data_c[l] = $signed(rs1_iso) >>> rs2_iso[4:0];
        I_SLT : if (act_mask_q[l]) wb_data_c[l] = ($signed(rs1_iso) <  $signed(rs2_iso)) ? 32'd1 : 32'd0;
        I_SLTU: if (act_mask_q[l]) wb_data_c[l] = (rs1_iso <  rs2_iso) ? 32'd1 : 32'd0;
        I_ADDI: if (act_mask_q[l]) wb_data_c[l] = rs1_iso +  imm_d;
        I_ANDI: if (act_mask_q[l]) wb_data_c[l] = rs1_iso &  imm_d;
        I_ORI : if (act_mask_q[l]) wb_data_c[l] = rs1_iso |  imm_d;
        I_XORI: if (act_mask_q[l]) wb_data_c[l] = rs1_iso ^  imm_d;
        I_SLTI: if (act_mask_q[l]) wb_data_c[l] = ($signed(rs1_iso) <  $signed(imm_d)) ? 32'd1 : 32'd0;
        I_SLTIU:if (act_mask_q[l]) wb_data_c[l] = (rs1_iso <  imm_d) ? 32'd1 : 32'd0;
        I_SLLI: if (act_mask_q[l]) wb_data_c[l] = rs1_iso << imm_d[4:0];
        I_SRLI: if (act_mask_q[l]) wb_data_c[l] = rs1_iso >> imm_d[4:0];
        I_SRAI: if (act_mask_q[l]) wb_data_c[l] = $signed(rs1_iso) >>> imm_d[4:0];
        I_LUI : if (act_mask_q[l]) wb_data_c[l] = imm_d;
        I_AUIPC:if (act_mask_q[l]) wb_data_c[l] = ex_pc_q + imm_d;
        I_LW  : begin
          dmem_raddr_o[l] = rs1_data[l] + imm_d;   // LSU：不可隔離（inactive lane 仍參與）
          if (act_mask_q[l]) wb_data_c[l] = dmem_rdata_i[l];
        end
        I_SW  : begin
          dmem_waddr_o[l] = rs1_data[l] + imm_d;
          dmem_wdata_o[l] = rs2_data[l];
        end
        I_CSRR: if (act_mask_q[l])
                  wb_data_c[l] = ((imm_d[11:0]==CSR_TID) || (imm_d[11:0]==CSR_LANEID))
                                 ? 32'(l) : 32'b0;
        // 分支條件位元（AND 語義由主控區歸約；inactive lane cond=1 被 act 屏蔽，等價）
        I_BEQ : cond_vec[l] = (rs1_iso == rs2_iso);
        I_BNE : cond_vec[l] = (rs1_iso != rs2_iso);
        I_BLT : cond_vec[l] = ($signed(rs1_iso) <  $signed(rs2_iso));
        I_BGE : cond_vec[l] = ($signed(rs1_iso) >= $signed(rs2_iso));
        // split 謂詞位元（inactive lane iso=0 → pred=0，與 act 屏蔽等價）
        I_SPLIT: pred_vec[l] = act_mask_q[l] & (rs1_iso != 32'b0);
        default: ;
      endcase
    end
  end

  // ===========================================================================
  // 主控組合邏輯（遮罩/堆疊/redirect/WB 控制——皆為 packed/純量運算）
  // ===========================================================================
  lane_mask_t  next_act_c;
  lane_mask_t  push_mask_c;
  logic [31:0] push_pc_c;
  logic        push_en_c, push_two_c, pop_en_c;
  logic        stk_top_tag;
  lane_mask_t  stk_top_mask;
  logic [31:0] stk_top_pc;
  assign stk_top_tag  = stk_tag_q [sptr_w - 3'd1];
  assign stk_top_mask = stk_mask_q[sptr_w - 3'd1];
  assign stk_top_pc   = stk_pc_q  [sptr_w - 3'd1];

  logic        redirect_en_c;
  logic [31:0] redirect_pc_c;
  int unsigned tmc_n;

  always_comb begin
    next_act_c     = act_mask_q;
    push_en_c      = 1'b0;
    push_two_c     = 1'b0;
    pop_en_c       = 1'b0;
    push_mask_c    = act_mask_q & ~pred_vec;   // false_m
    push_pc_c      = ex_pc_q + imm_d;          // SPLIT 時 = else_pc
    redirect_en_c  = 1'b0;
    redirect_pc_c  = 32'b0;
    wb_en_c        = 1'b0;
    wb_lane_mask_c = '0;
    tmc_n          = LANES_P;
    dmem_ren_o     = 1'b0;
    dmem_wen_o     = 1'b0;

    unique case (kind)
      I_ADD, I_SUB, I_AND, I_OR, I_XOR, I_SLL, I_SRL, I_SRA, I_SLT, I_SLTU,
      I_ADDI, I_ANDI, I_ORI, I_XORI, I_SLTI, I_SLTIU, I_SLLI, I_SRLI, I_SRAI,
      I_LUI, I_AUIPC, I_CSRR: begin
        wb_en_c        = 1'b1;
        wb_lane_mask_c = act_mask_q;
      end
      I_LW: begin
        dmem_ren_o     = 1'b1;
        wb_en_c        = 1'b1;
        wb_lane_mask_c = act_mask_q;
      end
      I_SW: dmem_wen_o = 1'b1;
      // ---- 分支：active lanes 全部滿足才跳（warp-uniform AND）----
      I_BEQ, I_BNE, I_BLT, I_BGE: begin
        if ((act_mask_q & ~cond_vec) == '0) begin
          redirect_en_c = 1'b1;
          redirect_pc_c = ex_pc_q + imm_d;
        end
      end
      // ---- SIMT 控制（標記式雙 entry 分歧堆疊；else 目標 = pc + imm）----
      I_SPLIT: begin
        if (push_mask_c != '0) begin            // 存在 false lanes
          push_en_c = 1'b1;                     // 至少推 tag entry
          if ((act_mask_q & pred_vec) != '0) begin
            push_two_c = 1'b1;                  // 再推 else entry
            next_act_c = act_mask_q & pred_vec; // then-path
          end else begin
            next_act_c    = push_mask_c;        // 全假：直接跳 else
            redirect_en_c = 1'b1;
            redirect_pc_c = ex_pc_q + imm_d;
          end
        end // 全真或無分歧：遮罩不變
      end
      I_JOIN: begin
        if (stk_ptr_q != '0) begin
          pop_en_c = 1'b1;
          if (!stk_top_tag) begin               // else entry：redirect
            redirect_en_c = 1'b1;
            redirect_pc_c = stk_top_pc;
          end                                   // tag entry：恢復遮罩、pc+4
        end
      end
      I_TMC: begin
        tmc_n      = (tmc_rs1_w >= LANES_P) ? LANES_P : tmc_rs1_w[31:0];
        next_act_c = lane_mask_t'((32'd1 << tmc_n) - 32'd1);
      end
      I_BAR: ; // 單 warp 語義：nop
      I_WEXIT, I_TEXIT: ;
      default: ;
    endcase
  end

  // ===========================================================================
  // 時序：IF 連續取指 + EX 寫回/堆疊/redirect
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q   <= 1'b0;
      if_pc_q    <= 32'b0;
      ir_q       <= 32'b0;
      ex_pc_q    <= 32'b0;
      ex_vld_q   <= 1'b0;
      act_mask_q <= lane_mask_t'({LANES_P{1'b1}});
      stk_ptr_q  <= '0;
      done_q     <= 1'b0;
      ill_q      <= 1'b0;
      for (int l = 0; l < LANES_P; l++)
        for (int r = 0; r < 32; r++) rf_q[l][r] <= 32'b0;
    end else begin
      // ---- IF stage ----
      if (!active_q) begin
        if (start_i) begin
          active_q   <= 1'b1;
          if_pc_q    <= start_pc_i;
          ex_vld_q   <= 1'b0;
          act_mask_q <= lane_mask_t'({LANES_P{1'b1}});
          stk_ptr_q  <= '0;
        end
      end else if (done_q) begin
        ex_vld_q <= 1'b0;
      end else if (redirect_en_c && ex_vld_q) begin
        // 必須以 ex_vld_q 閘控：bubble 週期 ir_q 為舊指令，redirect_en_c
        // 仍為 1（來源條件未被清除），不閘控會讓 IF/EX 永遠凍結（deadlock）
        if_pc_q  <= redirect_pc_c;
        ex_vld_q <= 1'b0;                        // flush 誤取指令（bubble）
      end else begin
        ir_q     <= imem_rdata_i;
        ex_pc_q  <= if_pc_q;
        ex_vld_q <= 1'b1;
        if_pc_q  <= if_pc_q + 32'd4;
      end

      // ---- EX stage ----
      if (ex_vld_q && !done_q) begin
        if (wb_en_c && (rd_d != 5'd0)) begin
          for (int l = 0; l < LANES_P; l++)
            if (wb_lane_mask_c[l]) rf_q[l][rd_d] <= wb_data_c[l];
        end
        if (push_en_c) begin
          stk_tag_q [sptr_w]      <= 1'b1;
          stk_mask_q[sptr_w]      <= act_mask_q;
          stk_pc_q  [sptr_w]      <= 32'b0;
          if (push_two_c) begin
            stk_tag_q [sptr_w + 3'd1] <= 1'b0;
            stk_mask_q[sptr_w + 3'd1] <= push_mask_c;
            stk_pc_q  [sptr_w + 3'd1] <= push_pc_c;
            stk_ptr_q <= stk_ptr_q + 4'd2;
          end else begin
            stk_ptr_q <= stk_ptr_q + 1'b1;
          end
        end else if (pop_en_c) begin
          stk_ptr_q <= stk_ptr_q - 1'b1;
        end
        act_mask_q <= pop_en_c ? stk_top_mask : next_act_c;
        if (ill_d) ill_q <= 1'b1;
        if ((kind == I_WEXIT) || (kind == I_TEXIT)) done_q <= 1'b1;
      end
    end
  end

  assign exec_valid_o   = ex_vld_q && !done_q;
  assign exec_pc_o      = ex_pc_q;
  assign exec_mask_o    = act_mask_q;
  assign wb_valid_o     = wb_en_c && ex_vld_q && !done_q;
  assign wb_rd_o        = rd_d;
  assign wb_lane_mask_o = wb_lane_mask_c;
  assign done_o         = done_q;
  assign illegal_o      = ill_q;

  for (genvar g = 0; g < LANES_P; g++) begin : gen_wb_data
    assign wb_data_o[g] = wb_data_c[g];
  end

endmodule
