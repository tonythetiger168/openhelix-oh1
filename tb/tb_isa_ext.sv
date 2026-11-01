// =============================================================================
// OpenHelix OH-1 ISA extension directed test (tb/tb_isa_ext.sv)
// - MUL with signed operands
// - vdot4.i8: INT8x4 dot product accumulated twice, including -128 and 127
// - JAL call + JALR return, JAL skip, backward BNE loop (5 iterations)
// - Program B: JALR whose active lanes disagree on the target -> illegal_o
// Programs run back to back without reset (relaunch).
// =============================================================================
`timescale 1ns/1ps

module tb_isa_ext #(parameter int SYNC_MEM = 0);
  import oh1_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n, start, done, illegal, stk_ovf;
  logic [31:0] start_pc;

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] pmem [128];
  if (SYNC_MEM != 0) begin : g_imem_sync
    always_ff @(posedge clk) imem_rdata <= pmem[imem_addr[8:2]];
  end else begin : g_imem_comb
    always_comb imem_rdata = pmem[imem_addr[8:2]];
  end

  logic        dmem_ren, dmem_wen;
  lane_mask_t  dmem_wmask, exec_mask, wb_lane_mask;
  logic [31:0] dmem_raddr [LANES], dmem_rdata [LANES], dmem_waddr [LANES], dmem_wdata [LANES];
  logic [31:0] wb_data [LANES], exec_pc;
  logic        exec_valid, wb_valid;
  logic [4:0]  wb_rd;
  for (genvar g = 0; g < LANES; g++) begin : g_rd
    assign dmem_rdata[g] = 32'b0;
  end

  oh1_core #(.LANES_P(LANES), .SYNC_MEM(SYNC_MEM)) dut (
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .start_pc_i(start_pc),
    .imem_addr_o(imem_addr), .imem_rdata_i(imem_rdata),
    .dmem_ren_o(dmem_ren), .dmem_raddr_o(dmem_raddr), .dmem_rdata_i(dmem_rdata),
    .dmem_wen_o(dmem_wen), .dmem_wmask_o(dmem_wmask), .dmem_waddr_o(dmem_waddr), .dmem_wdata_o(dmem_wdata),
    .exec_valid_o(exec_valid), .exec_pc_o(exec_pc), .exec_mask_o(exec_mask),
    .wb_valid_o(wb_valid), .wb_rd_o(wb_rd), .wb_lane_mask_o(wb_lane_mask), .wb_data_o(wb_data),
    .done_o(done), .illegal_o(illegal), .stk_ovf_o(stk_ovf));

  task automatic launch(input logic [31:0] pc);
    @(negedge clk); start_pc = pc; start = 1'b1;
    @(negedge clk); start = 1'b0;
    wait (done === 1'b0);
    wait (done === 1'b1);
  endtask

  int errors = 0;
  task automatic expect_rf(input int l, input int r, input logic [31:0] exp, input string what);
    if (dut.rf_q[l][r] !== exp) begin
      $display("[TB_ISA] FAIL: lane%0d x%0d (%s) = %08x exp %08x", l, r, what, dut.rf_q[l][r], exp);
      errors++;
    end
  endtask

  localparam logic [31:0] VEC = 32'h807F_02FE;   // bytes: -2, 2, 127, -128

  initial begin
    for (int i = 0; i < 128; i++) pmem[i] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);
    // ---------------- program A @ 0x000 ----------------
    pmem[0]  = enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID);        // x1 = tid
    pmem[1]  = enc_itype(I_ADDI, 5'd2, 5'd1, 12'hFFE);        // x2 = tid - 2
    pmem[2]  = enc_itype(I_ADDI, 5'd5, 5'd0, 12'hFF9);        // x5 = -7
    pmem[3]  = enc_rtype(I_MUL,  5'd3, 5'd2, 5'd5);           // x3 = (tid-2) * -7
    pmem[4]  = enc_lui(I_LUI,    5'd7, VEC[31:12]);           // x7 = 0x807F0000
    pmem[5]  = enc_itype(I_ADDI, 5'd7, 5'd7, VEC[11:0]);      // x7 = 0x807F02FE
    pmem[6]  = enc_rtype(I_XOR,  5'd8, 5'd7, 5'd1);           // x8 = x7 ^ tid
    pmem[7]  = enc_itype(I_ADDI, 5'd9, 5'd0, 12'd100);        // x9 = 100
    pmem[8]  = enc_vdot4(5'd9, 5'd7, 5'd8);                   // x9 += dot(x7, x8)
    pmem[9]  = enc_vdot4(5'd9, 5'd7, 5'd8);                   // x9 += dot(x7, x8)
    pmem[10] = enc_jal(5'd10, 20'd8);                         // call idx 14 (+16 bytes), x10 = 44
    pmem[11] = enc_itype(I_ADDI, 5'd12, 5'd12, 12'd55);       // after return: x12 = 11 + 55
    pmem[12] = enc_jal(5'd0, 20'd8);                          // skip to idx 16
    pmem[13] = enc_itype(I_ADDI, 5'd13, 5'd0, 12'd999);       // never executed
    pmem[14] = enc_itype(I_ADDI, 5'd12, 5'd0, 12'd11);        // subroutine body
    pmem[15] = enc_jalr(5'd0, 5'd10, 12'd0);                  // return
    pmem[16] = enc_itype(I_ADDI, 5'd14, 5'd0, 12'd0);         // i = 0
    pmem[17] = enc_itype(I_ADDI, 5'd14, 5'd14, 12'd1);        // loop: i++
    pmem[18] = enc_itype(I_ADDI, 5'd15, 5'd0, 12'd5);
    pmem[19] = enc_btype(I_BNE,  5'd14, 5'd15, 12'hFFC);      // bne -8 bytes -> idx 17
    pmem[20] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);
    // ---------------- program B @ 0x100 ----------------
    pmem[64] = enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID);
    pmem[65] = enc_itype(I_SLLI, 5'd16, 5'd1, 12'd2);         // x16 = tid*4
    pmem[66] = enc_jalr(5'd0, 5'd16, 12'h10C);                // lane targets 0x10C + 4*tid: divergent
    pmem[67] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);             // 0x10C: lane 0's target

    rst_n = 1'b0; start = 1'b0; start_pc = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    launch(32'h000);
    if (illegal !== 1'b0) begin $display("[TB_ISA] FAIL: program A raised illegal"); errors++; end
    for (int l = 0; l < LANES; l++) begin
      expect_rf(l, 3,  32'((l - 2) * -7), "mul");
      expect_rf(l, 9,  32'd100 + 2 * dot4_i8(VEC, VEC ^ 32'(l)), "vdot4 x2");
      expect_rf(l, 10, 32'd44, "jal link");
      expect_rf(l, 12, 32'd66, "call/return");
      expect_rf(l, 13, 32'd0,  "skipped by jal");
      expect_rf(l, 14, 32'd5,  "loop count");
    end
    // spot-check the reference itself: lane 0 dot = 4 + 4 + 16129 + 16384
    if (dot4_i8(VEC, VEC) !== 32'd32521) begin $display("[TB_ISA] FAIL: dot4_i8 reference"); errors++; end

    launch(32'h100);
    if (illegal !== 1'b1) begin $display("[TB_ISA] FAIL: divergent JALR not flagged illegal"); errors++; end

    if (errors == 0) $display("[TB_ISA] PASS: MUL, vdot4.i8, JAL/JALR call-return, loop, divergent JALR verified");
    else             $fatal(1, "[TB_ISA] FAIL: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "[TB_ISA] watchdog timeout");
  end
endmodule
