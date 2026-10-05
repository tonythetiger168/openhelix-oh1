// =============================================================================
// OpenHelix OH-1 Random ISA Generator ＋ Golden Model（tb/tb_rand.sv）
// Standalone CRV co-verification（verilator --binary 直接執行，無需 VCS）：
//   1. 隨機程式產生器：結構合法（split/join 配平＋索引回填、分支界內對齊、
//      LW/SW 字對齊、tmc 0..LANES、巢狀≤3），規則與 UVM oh1_seq_lib 相同
//   2. Golden model（指令級 ISS）：語意獨立實作，與 UVM scoreboard ISS 互相對照
//   3. 逐步比對：每個 exec_valid 週期比 pc/遮罩，WB 逐 lane 比資料
//      終態比對：RF 全暫存器 ×4 lane、dmem 前 512 字、illegal 旗標
// 執行：./Vtb_rand +seed=7 +n_prog=50   （make rand）
// =============================================================================
`timescale 1ns/1ps

module tb_rand;
  import oh1_pkg::*;

  localparam int PMEM_W = 4096;
  localparam int DMEM_W = 4096;
  localparam int CHK_DMEM_W = 512;

  // ---- plusarg knobs ----
  int seed = 1, n_prog = 20, max_prog_len = 64, dbg = 0;

  // ---- DUT 訊號與記憶體 ----
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic        rst_n, start;
  logic [31:0] start_pc;
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_ren, dmem_wen;
  logic [31:0] dmem_raddr [LANES], dmem_rdata [LANES];
  logic [31:0] dmem_waddr [LANES], dmem_wdata [LANES];
  logic        exec_valid;
  logic [31:0] exec_pc;
  lane_mask_t  exec_mask, wb_lane_mask;
  logic        wb_valid;
  logic [4:0]  wb_rd;
  logic [31:0] wb_data [LANES];
  logic        done, illegal;

  logic [31:0] pmem [PMEM_W];
  logic [31:0] dmem [DMEM_W];

  always_comb imem_rdata = pmem[imem_addr[31:2] & 32'hFFF];
  for (genvar gi = 0; gi < LANES; gi++) begin : g_dmem_rd
    always_comb dmem_rdata[gi] = dmem[dmem_raddr[gi][13:2] & 32'hFFF];
  end
  always_ff @(posedge clk) begin
    if (dmem_wen)
      for (int l = 0; l < LANES; l++)
        dmem[dmem_waddr[l][13:2] & 32'hFFF] <= dmem_wdata[l];
  end

  oh1_core #(.LANES_P(LANES)) dut (
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .start_pc_i(start_pc),
    .imem_addr_o(imem_addr), .imem_rdata_i(imem_rdata),
    .dmem_ren_o(dmem_ren), .dmem_raddr_o(dmem_raddr), .dmem_rdata_i(dmem_rdata),
    .dmem_wen_o(dmem_wen), .dmem_waddr_o(dmem_waddr), .dmem_wdata_o(dmem_wdata),
    .exec_valid_o(exec_valid), .exec_pc_o(exec_pc), .exec_mask_o(exec_mask),
    .wb_valid_o(wb_valid), .wb_rd_o(wb_rd), .wb_lane_mask_o(wb_lane_mask),
    .wb_data_o(wb_data), .done_o(done), .illegal_o(illegal));

  // =========================================================================
  // Golden model（ISS）狀態
  // =========================================================================
  logic [31:0] iss_rf   [LANES][32];
  logic [31:0] iss_dmem [DMEM_W];
  logic [31:0] iss_pc;
  lane_mask_t  iss_act;
  bit          iss_stk_tag [DIV_STK_DEPTH];
  lane_mask_t  iss_stk_m   [DIV_STK_DEPTH];
  logic [31:0] iss_stk_p   [DIV_STK_DEPTH];
  int          iss_sp;
  bit          iss_done, iss_ill;

  function automatic void iss_reset();
    for (int l = 0; l < LANES; l++)
      for (int r = 0; r < 32; r++) iss_rf[l][r] = '0;
    for (int i = 0; i < DMEM_W; i++) iss_dmem[i] = '0;
    iss_pc = '0; iss_act = '1; iss_sp = 0;
    iss_done = 0; iss_ill = 0;
  endfunction

  function automatic logic [31:0] iss_imm(input logic [31:0] ins, input ikind_e k);
    logic [11:0] i_imm = ins[31:20];
    logic [11:0] s_imm = {ins[31:25], ins[11:7]};
    logic [12:1] b_imm = {ins[31], ins[7], ins[30:25], ins[11:8]};
    case (k)
      I_ADDI, I_ANDI, I_ORI, I_XORI, I_SLTI, I_SLTIU, I_LW, I_CSRR:
        return {{20{i_imm[11]}}, i_imm};
      I_SLLI, I_SRLI, I_SRAI: return {27'b0, i_imm[4:0]};
      I_SW:            return {{20{s_imm[11]}}, s_imm};
      I_BEQ, I_BNE, I_BLT, I_BGE: return {{19{b_imm[11]}}, b_imm, 1'b0};
      I_LUI, I_AUIPC:  return {ins[31:12], 12'b0};
      // custom-0（split 等）：imm_d = sext(i_imm) << 1（oh1_decode L84，半字組）
      default:         return {{19{i_imm[11]}}, i_imm, 1'b0};
    endcase
  endfunction

  // 執行一步；輸出預測 WB（wb_en=0 表示無寫回）
  function automatic void iss_step(
      output bit wb_en, output logic [4:0] rd,
      output lane_mask_t wb_mask, output logic [31:0] wdata [LANES]);
    logic [31:0] ins = iss_dmem_i0();
    ikind_e      k   = dec_kind(ins);
    logic [4:0]  rs1 = ins[19:15], rs2 = ins[24:20];
    logic [31:0] imm = iss_imm(ins, k);
    logic [31:0] a [LANES], b [LANES];
    lane_mask_t  pred, false_m, cond;
    logic [31:0] pc_n = iss_pc + 32'd4;
    int unsigned tmc_n;

    wb_en = 0; rd = ins[11:7]; wb_mask = '0;
    for (int l = 0; l < LANES; l++) wdata[l] = '0;
    for (int l = 0; l < LANES; l++) begin
      a[l] = (rs1 == 0) ? 0 : iss_rf[l][rs1];
      b[l] = (rs2 == 0) ? 0 : iss_rf[l][rs2];
    end

    case (k)
      I_ADD, I_SUB, I_AND, I_OR, I_XOR, I_SLL, I_SRL, I_SRA, I_SLT, I_SLTU,
      I_ADDI, I_ANDI, I_ORI, I_XORI, I_SLTI, I_SLTIU, I_SLLI, I_SRLI, I_SRAI,
      I_LUI, I_AUIPC, I_CSRR: begin
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
        // 全 lane（含 inactive）依序寫入，後者覆蓋——與 TB 記憶體模型一致
        for (int l = 0; l < LANES; l++)
          iss_dmem[((a[l] + imm) >> 2) & 32'hFFF] = b[l];
      end

      I_BEQ, I_BNE, I_BLT, I_BGE: begin
        cond = '0;
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
          iss_stk_tag[iss_sp] = 1'b1; iss_stk_m[iss_sp] = iss_act; iss_stk_p[iss_sp] = '0; iss_sp++;
          if ((iss_act & pred) != '0) begin
            iss_stk_tag[iss_sp] = 1'b0; iss_stk_m[iss_sp] = false_m; iss_stk_p[iss_sp] = iss_pc + imm; iss_sp++;
            iss_act = iss_act & pred;
          end else begin
            iss_act = false_m; pc_n = iss_pc + imm;
          end
        end
      end

      I_JOIN: begin
        if (iss_sp != 0) begin
          iss_sp--;
          iss_act = iss_stk_m[iss_sp];
          if (!iss_stk_tag[iss_sp]) pc_n = iss_stk_p[iss_sp];
        end
      end

      I_TMC: begin
        tmc_n = (a[0] >= LANES) ? LANES : a[0];
        iss_act = lane_mask_t'((32'd1 << tmc_n) - 32'd1);
      end

      I_BAR: ;

      I_WEXIT, I_TEXIT: iss_done = 1;

      default: iss_ill = 1;
    endcase

    if (wb_en && (rd != 0))
      for (int l = 0; l < LANES; l++)
        if (wb_mask[l]) iss_rf[l][rd] = wdata[l];

    iss_pc = pc_n;
  endfunction

  // 取指（ISS 的 imem 即 TB pmem）
  function automatic logic [31:0] iss_dmem_i0();
    return pmem[(iss_pc >> 2) & 32'hFFF];
  endfunction

  // =========================================================================
  // 隨機程式產生器
  // =========================================================================
  logic [31:0] g_pmem [$];
  int          g_dinit_idx [$];
  logic [31:0] g_dinit_val [$];
  int          g_nest_limit, g_regions_left, g_br_left, g_lsu_left, g_tmc_left;

  function automatic int g_pick_src();   // 2..5,7（避開 x1=tid、x6=tid*4）
    int v = $urandom_range(0, 4);
    return (v >= 4) ? 7 : v + 2;
  endfunction

  function automatic void g_filler();
    case ($urandom_range(0, 9))
      0,1,2,3: g_pmem.push_back(enc_rtype(ikind_e'($urandom_range(I_ADD, I_SLTU)),
                          $urandom_range(2, 7), g_pick_src(), g_pick_src()));
      4,5,6,7: g_pmem.push_back(enc_itype(ikind_e'($urandom_range(I_ADDI, I_SRAI)),
                          g_pick_src(), g_pick_src(), $urandom_range(0, 63)));
      8:       g_pmem.push_back(enc_lui(I_LUI,   g_pick_src(), $urandom_range(0, 16'hFFFF)));
      default: g_pmem.push_back(enc_lui(I_AUIPC, g_pick_src(), $urandom_range(0, 16'hFFFF)));
    endcase
  endfunction

  function automatic void g_region(int depth);
    int then_len, else_len, split_idx, else_idx;
    then_len = $urandom_range(1, 4);
    else_len = $urandom_range(1, 4);
    split_idx = g_pmem.size();
    g_pmem.push_back(enc_split(5'd1, 12'd0));
    for (int i = 0; i < then_len; i++) begin
      if (depth < g_nest_limit && i == 0 && $urandom_range(0, 1))
        g_region(depth + 1);
      else
        g_filler();
    end
    g_pmem.push_back(enc_custom3(F3_JOIN, 5'd0, 5'd0));
    else_idx = g_pmem.size();
    for (int i = 0; i < else_len; i++) g_filler();
    g_pmem.push_back(enc_custom3(F3_JOIN, 5'd0, 5'd0));
    g_pmem[split_idx] = enc_split(5'd1, 12'((else_idx - split_idx) * 2));
  endfunction

  function automatic void g_branch();
    int off = $urandom_range(1, 3);
    case ($urandom_range(0, 4))
      0: g_pmem.push_back(enc_btype(I_BEQ, 5'd0, 5'd0, 12'(off * 2)));
      1: g_pmem.push_back(enc_btype(I_BNE, 5'd0, 5'd0, 12'(off * 2)));
      2: g_pmem.push_back(enc_btype(I_BEQ, 5'd1, 5'd0, 12'(off * 2)));
      3: g_pmem.push_back(enc_btype(I_BGE, 5'd0, 5'd0, 12'(off * 2)));
      4: g_pmem.push_back(enc_btype(I_BLT, 5'd0, 5'd0, 12'(off * 2)));
    endcase
    repeat (off) g_filler();
  endfunction

  function automatic void g_lsu();
    int imm = $urandom_range(0, 15) * 4;
    if ($urandom_range(0, 1)) begin
      g_pmem.push_back(enc_itype(I_ADDI, 5'd5, 5'd0, $urandom_range(1, 127)));
      g_pmem.push_back(enc_sw(5'd5, 5'd6, 12'(imm)));
    end else begin
      g_pmem.push_back(enc_itype(I_LW, 5'd7, 5'd6, 12'(imm)));
    end
  endfunction

  function automatic void g_tmc();
    g_pmem.push_back(enc_itype(I_ADDI, 5'd2, 5'd0, $urandom_range(0, LANES)));
    g_pmem.push_back(enc_custom3(F3_TMC, 5'd2, 5'd0));
    repeat ($urandom_range(1, 3)) g_filler();
  endfunction

  function automatic void gen_program();
    int budget;
    g_pmem.delete(); g_dinit_idx.delete(); g_dinit_val.delete();
    g_nest_limit   = $urandom_range(0, 3);
    g_regions_left = $urandom_range(0, 4);
    g_br_left      = $urandom_range(0, 6);
    g_lsu_left     = $urandom_range(0, 6);
    g_tmc_left     = $urandom_range(0, 3);

    g_pmem.push_back(enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID));   // x1 = tid
    g_pmem.push_back(enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2));     // x6 = tid*4
    g_pmem.push_back(enc_itype(I_ADDI, 5'd2, 5'd0, $urandom_range(1, 31)));

    budget = g_regions_left + g_br_left + g_lsu_left + g_tmc_left;
    while (budget > 0 && g_pmem.size() < max_prog_len - 8) begin
      case ($urandom_range(0, 3))
        0: if (g_regions_left > 0) begin g_region(0); g_regions_left--; budget--; end
        1: if (g_br_left      > 0) begin g_branch();   g_br_left--;      budget--; end
        2: if (g_lsu_left     > 0) begin g_lsu();      g_lsu_left--;     budget--; end
        3: if (g_tmc_left     > 0) begin g_tmc();      g_tmc_left--;     budget--; end
      endcase
      repeat ($urandom_range(0, 3)) g_filler();
    end
    g_pmem.push_back(enc_custom3(F3_TEXIT, 5'd0, 5'd0));

    repeat ($urandom_range(4, 12)) begin
      g_dinit_idx.push_back($urandom_range(0, CHK_DMEM_W - 1));
      g_dinit_val.push_back($urandom());
    end
  endfunction

  // =========================================================================
  // 逐週期 monitor：exec 比 pc/遮罩、WB 逐 lane 比（每次 exec_valid 步進 ISS）
  // =========================================================================
  bit   mon_en = 0;
  int   mon_err = 0, cyc = 0, wd_hit = 0, cur_prog = 0;
  logic [4:0]  p_rd; lane_mask_t p_mask; logic [31:0] p_data [LANES];
  bit p_wb;

  always @(posedge clk) begin
    if (rst_n && mon_en) begin
      cyc++;
      if (cyc > 5000 && !wd_hit) begin
        wd_hit = 1;
        $display("[TB_RAND] ERROR: watchdog timeout (pc=%08x)", exec_pc);
        mon_err++;
      end
      if (exec_valid && !wd_hit) begin
        bit wb_en; logic [4:0] rd; lane_mask_t m; logic [31:0] d [LANES];
        if (dbg && cur_prog == 0)
          $display("[TRC] cyc=%0d dut=%08x/%04b iss=%08x/%04b sp=%0d ins=%08x",
                   cyc, exec_pc, exec_mask, iss_pc, iss_act, iss_sp, pmem[exec_pc>>2]);
        if (dbg && (exec_pc !== iss_pc || exec_mask !== iss_act)) begin
          $display("[DBG] first divergence: cyc=%0d dut_pc=%08x iss_pc=%08x dut_mask=%04b iss_mask=%04b",
                   cyc, exec_pc, iss_pc, exec_mask, iss_act);
          $display("[DBG] prog dump (%0d instrs):", g_pmem.size());
          foreach (g_pmem[i]) $display("[DBG] %3d: %08x  kind=%0d", i, g_pmem[i], dec_kind(g_pmem[i]));
          $display("[DBG] iss_rf snapshot:");
          for (int l = 0; l < LANES; l++)
            $display("[DBG] lane%0d: x1=%08x x2=%08x x3=%08x x4=%08x x5=%08x x6=%08x x7=%08x",
                     l, iss_rf[l][1], iss_rf[l][2], iss_rf[l][3], iss_rf[l][4],
                     iss_rf[l][5], iss_rf[l][6], iss_rf[l][7]);
          $finish;
        end
        if (exec_pc !== iss_pc) begin
          $display("[TB_RAND] ERROR: pc dut=%08x iss=%08x", exec_pc, iss_pc);
          mon_err++;
        end
        if (exec_mask !== iss_act) begin
          $display("[TB_RAND] ERROR: mask @%08x dut=%04b iss=%04b", exec_pc, exec_mask, iss_act);
          mon_err++;
        end
        iss_step(wb_en, rd, m, d);
        p_wb = wb_en && (rd != 0); p_rd = rd; p_mask = m;
        for (int l = 0; l < LANES; l++) p_data[l] = d[l];
        if (wb_valid && p_wb) begin
          if (wb_rd !== p_rd) begin
            $display("[TB_RAND] ERROR: wb_rd dut=%0d iss=%0d @%08x", wb_rd, p_rd, exec_pc);
            mon_err++;
          end
          if (wb_lane_mask !== p_mask) begin
            $display("[TB_RAND] ERROR: wb_mask dut=%04b iss=%04b @%08x", wb_lane_mask, p_mask, exec_pc);
            mon_err++;
          end
          for (int l = 0; l < LANES; l++)
            if (p_mask[l] && (wb_data[l] !== p_data[l])) begin
              $display("[TB_RAND] ERROR: wb_data lane=%0d dut=%08x iss=%08x rd=%0d @%08x",
                       l, wb_data[l], p_data[l], wb_rd, exec_pc);
              mon_err++;
            end
        end else if (wb_valid != (wb_en && (rd != 0))) begin
          $display("[TB_RAND] ERROR: wb_valid mismatch @%08x", exec_pc);
          mon_err++;
        end
      end
    end
  end

  // =========================================================================
  // 主流程
  // =========================================================================
  int total_err = 0;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("n_prog=%d", n_prog));
    void'($value$plusargs("dbg=%d", dbg));
    $urandom(seed);
    rst_n = 0; start = 0; start_pc = '0;

    for (int p = 0; p < n_prog; p++) begin
      int perr;
      run_one(p, perr);
      total_err += perr;
      $display("[TB_RAND] prog %0d: %s", p, (perr == 0) ? "PASS" : "FAIL");
    end

    if (total_err == 0)
      $display("[TB_RAND] PASS: %0d programs verified OK (seed=%0d)", n_prog, seed);
    else
      $fatal(1, "[TB_RAND] FAIL: %0d errors", total_err);
    $finish;
  end

  task automatic run_one(input int prog_i, output int perr);
    perr = 0; wd_hit = 0; cyc = 0; mon_err = 0;

    // 1) 產生並載入
    gen_program();
    for (int i = 0; i < PMEM_W; i++) pmem[i] = '0;
    for (int i = 0; i < DMEM_W; i++) dmem[i] = '0;
    foreach (g_pmem[i]) pmem[i] = g_pmem[i];
    foreach (g_dinit_idx[i]) dmem[g_dinit_idx[i]] = g_dinit_val[i];

    // 2) ISS 載入
    iss_reset();
    foreach (g_dinit_idx[i]) iss_dmem[g_dinit_idx[i]] = g_dinit_val[i];

    // 3) reset → start
    rst_n = 0; start = 0;
    repeat (4) @(posedge clk);
    rst_n <= 1;
    @(posedge clk);
    start <= 1;
    @(posedge clk);
    start <= 0;

    // 4) 執行（monitor 同步比對）
    mon_en = 1;
    wait (done === 1'b1 || wd_hit);
    @(posedge clk);
    mon_en = 0;
    perr = mon_err;

    // 5) 終態檢查
    if (!wd_hit) begin
      if (illegal !== 1'b0) begin
        $display("[TB_RAND] ERROR: illegal flag"); perr++;
      end
      if (!iss_done) begin
        $display("[TB_RAND] ERROR: ISS not done"); perr++;
      end
      for (int l = 0; l < LANES; l++)
        for (int r = 1; r < 32; r++)
          if (dut.rf_q[l][r] !== iss_rf[l][r]) begin
            if (perr < 8)
              $display("[TB_RAND] ERROR: rf[%0d][%0d] dut=%08x iss=%08x", l, r, dut.rf_q[l][r], iss_rf[l][r]);
            perr++;
          end
      for (int i = 0; i < CHK_DMEM_W; i++)
        if (dmem[i] !== iss_dmem[i]) begin
          if (perr < 8)
            $display("[TB_RAND] ERROR: dmem[%0d] dut=%08x iss=%08x", i, dmem[i], iss_dmem[i]);
          perr++;
        end
    end

    // 6) 復位準備下一輪
    rst_n <= 0;
    repeat (4) @(posedge clk);
  endtask

endmodule
