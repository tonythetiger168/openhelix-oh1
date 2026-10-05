// =============================================================================
// OpenHelix OH-1 SIMD engine 定向驗證（tb/tb_simd.sv）
// 目的：逐 lane 檢測 SIMD 資料通路——同一指令在多 lane 上以各自運算元
//       lockstep 執行，結果逐 lane 獨立寫回。
// 覆蓋情境：
//   1. 每 lane 相異 ALU 結果（tid 驅動運算元）→ 逐 lane RF 期望值檢查
//   2. divergent LSU：每 lane 獨立字位址 sw/lw，dmem 逐字檢查
//   3. TMC 子集執行：只寫入指定 lane，其餘 lane 保持歸零值
//   4. split/join 分歧下 SIMD：不同 lane 群執行不同指令路徑
// 執行：verilator --binary --timing（見 Makefile simd target）
// =============================================================================
`timescale 1ns/1ps

module tb_simd;
  import oh1_pkg::*;

  localparam int N_CHK = 14;

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

  // ---- 記憶體模型（與 tb_smoke / UVM if 相同行為）----
  logic [31:0] pmem [4096];
  logic [31:0] dmem [4096];

  always_comb imem_rdata = pmem[imem_addr[31:2] & 32'hFFF];
  for (genvar gl = 0; gl < LANES; gl++) begin : g_dmem_rd
    always_comb dmem_rdata[gl] = dmem[dmem_raddr[gl][13:2] & 32'hFFF];
  end
  always_ff @(posedge clk) begin
    if (dmem_wen)
      for (int l = 0; l < LANES; l++)
        dmem[dmem_waddr[l][13:2] & 32'hFFF] <= dmem_wdata[l];
  end

  // ---- DUT ----
  oh1_core #(.LANES_P(LANES)) dut (
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .start_pc_i(start_pc),
    .imem_addr_o(imem_addr), .imem_rdata_i(imem_rdata),
    .dmem_ren_o(dmem_ren), .dmem_raddr_o(dmem_raddr), .dmem_rdata_i(dmem_rdata),
    .dmem_wen_o(dmem_wen), .dmem_waddr_o(dmem_waddr), .dmem_wdata_o(dmem_wdata),
    .exec_valid_o(exec_valid), .exec_pc_o(exec_pc), .exec_mask_o(exec_mask),
    .wb_valid_o(wb_valid), .wb_rd_o(wb_rd), .wb_lane_mask_o(wb_lane_mask),
    .wb_data_o(wb_data), .done_o(done), .illegal_o(illegal));

  // ---- 測試程式 ----
  // x1[l]=l; x2=2l; x3=3l; x4=3l+7; x6=4l;
  // dmem[32+l]=3l+7; x5=3l+7;
  // tmc 2 → lanes{0,1}: x8=3l+8, x9=l；tmc 4 → 全 lane: x10=6l+14;
  // split x1: lanes{1,3?1..3} 走 sub（x11=3l+7），lane0 走 xor（x11=9）
  initial begin
    for (int i = 0; i < 4096; i++) begin pmem[i] = '0; dmem[i] = '0; end

    pmem[0]  = enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID);      // csrr x1, tid
    pmem[1]  = enc_itype(I_SLLI, 5'd2, 5'd1, 12'd1);        // slli x2, x1, 1
    pmem[2]  = enc_rtype(I_ADD,  5'd3, 5'd2, 5'd1);         // add  x3, x2, x1
    pmem[3]  = enc_itype(I_ADDI, 5'd4, 5'd3, 12'd7);        // addi x4, x3, 7
    pmem[4]  = enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2);        // slli x6, x1, 2
    pmem[5]  = enc_sw(5'd4, 5'd6, 12'd128);                 // sw   x4, 128(x6)
    pmem[6]  = enc_itype(I_LW, 5'd5, 5'd6, 12'd128);        // lw   x5, 128(x6)
    pmem[7]  = enc_itype(I_ADDI, 5'd7, 5'd0, 12'd2);        // x7 = 2
    pmem[8]  = enc_custom3(F3_TMC, 5'd7, 5'd0);             // tmc 2 → mask 0011
    pmem[9]  = enc_itype(I_ADDI, 5'd8, 5'd4, 12'd1);        // addi x8, x4, 1（lanes0,1）
    pmem[10] = enc_itype(I_CSRR, 5'd9, 5'd0, CSR_TID);      // csrr x9（lanes0,1）
    pmem[11] = enc_itype(I_ADDI, 5'd7, 5'd0, 12'd4);        // x7 = 4
    pmem[12] = enc_custom3(F3_TMC, 5'd7, 5'd0);             // tmc 4 → 全 lane
    pmem[13] = enc_rtype(I_ADD, 5'd10, 5'd4, 5'd5);         // add  x10, x4, x5
    pmem[14] = enc_split(5'd1, 12'd6);                      // split x1, else@pc76
    pmem[15] = enc_rtype(I_SUB, 5'd11, 5'd10, 5'd4);        // then: x11=3l+7（lanes1-3）
    pmem[16] = enc_custom3(F3_JOIN, 5'd0, 5'd0);            // join#1
    pmem[17] = enc_rtype(I_XOR, 5'd11, 5'd10, 5'd4);        // else: lane0 x11=9
    pmem[18] = enc_custom3(F3_JOIN, 5'd0, 5'd0);            // join#2
    pmem[19] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);           // texit

    // ---- reset / start ----
    rst_n = 0; start = 0; start_pc = 32'h0;
    repeat (4) @(posedge clk);
    rst_n <= 1;
    @(posedge clk);
    start <= 1;
    @(posedge clk);
    start <= 0;

    // ---- watchdog ----
    fork : wd
      begin
        wait (done === 1'b1);
        disable wd;
      end
      begin
        repeat (2000) @(posedge clk);
        $display("[TB_SIMD] FAIL: watchdog timeout");
        $fatal(1);
      end
    join_any

    // ---- 逐 lane 檢查 ----
    begin
      int errors = 0;
      if (illegal !== 1'b0) begin
        $display("[TB_SIMD] FAIL: illegal"); errors++;
      end

      // 1) 每 lane 相異 ALU 結果：x4[l] = 3l+7
      // 2) divergent LSU：x5[l] = 3l+7、dmem[32+l] = 3l+7
      // 3) TMC 子集：x8/x9 僅 lanes0,1，其餘歸零
      // 4) 全 lane 恢復：x10[l] = 6l+14
      // 5) 分歧 SIMD：x11[0]=9（xor），x11[1..3]=3l+7（sub）
      for (int l = 0; l < LANES; l++) begin
        automatic int e3l7 = 3*l + 7;
        automatic int e6l14 = 6*l + 14;
        if (dut.rf_q[l][4]  !== 32'(e3l7))  begin
          $display("[TB_SIMD] FAIL: rf[%0d][4]=%08x expect %0d", l, dut.rf_q[l][4], e3l7); errors++; end
        if (dut.rf_q[l][5]  !== 32'(e3l7))  begin
          $display("[TB_SIMD] FAIL: rf[%0d][5]=%08x expect %0d", l, dut.rf_q[l][5], e3l7); errors++; end
        if (dmem[32+l] !== 32'(e3l7)) begin
          $display("[TB_SIMD] FAIL: dmem[%0d]=%08x expect %0d", 32+l, dmem[32+l], e3l7); errors++; end
        if (dut.rf_q[l][10] !== 32'(e6l14)) begin
          $display("[TB_SIMD] FAIL: rf[%0d][10]=%08x expect %0d", l, dut.rf_q[l][10], e6l14); errors++; end
        if (l == 0) begin
          if (dut.rf_q[l][11] !== 32'd9) begin
            $display("[TB_SIMD] FAIL: rf[0][11]=%08x expect 9", dut.rf_q[0][11]); errors++; end
        end else begin
          if (dut.rf_q[l][11] !== 32'(e3l7)) begin
            $display("[TB_SIMD] FAIL: rf[%0d][11]=%08x expect %0d", l, dut.rf_q[l][11], e3l7); errors++; end
        end
      end
      // TMC 子集：lanes0,1 有值；lanes2,3 歸零
      for (int l = 0; l < 2; l++) begin
        if (dut.rf_q[l][8] !== 32'(3*l+8)) begin
          $display("[TB_SIMD] FAIL: rf[%0d][8]=%08x expect %0d", l, dut.rf_q[l][8], 3*l+8); errors++; end
        if (dut.rf_q[l][9] !== 32'(l)) begin
          $display("[TB_SIMD] FAIL: rf[%0d][9]=%08x expect %0d", l, dut.rf_q[l][9], l); errors++; end
      end
      for (int l = 2; l < LANES; l++) begin
        if (dut.rf_q[l][8] !== 32'd0 || dut.rf_q[l][9] !== 32'd0) begin
          $display("[TB_SIMD] FAIL: rf[%0d][8/9] not zero (tmc subset leak)", l); errors++; end
      end

      if (errors == 0) $display("[TB_SIMD] PASS: all %0d SIMD checks passed (done@%0t)", N_CHK, $time);
      else             $fatal(1, "[TB_SIMD] FAIL: %0d errors", errors);
    end

    $finish;
  end

endmodule
