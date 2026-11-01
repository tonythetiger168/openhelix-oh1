// =============================================================================
// OpenHelix OH-1 divergence-stack overflow + core relaunch test (tb/tb_stk_ovf.sv)
// - Program A at 0x000: 8 all-false splits (1 push each) fill the 8-deep stack
//   exactly -> stk_ovf_o must stay 0
// - Program B at 0x100: 9 all-false splits -> 9th push is dropped, stk_ovf_o = 1
// - B is launched by pulsing start_i after A finished (no reset), which also
//   checks that the core relaunches and clears done / stk_ovf on start
// =============================================================================
`timescale 1ns/1ps

module tb_stk_ovf #(parameter int SYNC_MEM = 0);
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

  initial begin
    for (int i = 0; i < 128; i++) pmem[i] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);
    // split x0 (predicate all-false) with else = next instruction: pushes one tag entry
    for (int i = 0; i < 8; i++) pmem[i]      = enc_split(5'd0, 12'd2);   // A @ 0x000
    for (int i = 0; i < 9; i++) pmem[64 + i] = enc_split(5'd0, 12'd2);   // B @ 0x100

    rst_n = 1'b0; start = 1'b0; start_pc = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    launch(32'h000);
    if (stk_ovf !== 1'b0) begin $display("[TB_STK] FAIL: overflow flagged at exactly 8 entries"); errors++; end
    if (dut.stk_ptr_q !== 4'd8) begin $display("[TB_STK] FAIL: stk_ptr=%0d exp 8", dut.stk_ptr_q); errors++; end

    launch(32'h100);   // relaunch without reset
    if (stk_ovf !== 1'b1) begin $display("[TB_STK] FAIL: 9th push did not flag overflow"); errors++; end
    if (dut.stk_ptr_q !== 4'd8) begin $display("[TB_STK] FAIL: stk_ptr=%0d exp 8 (push dropped)", dut.stk_ptr_q); errors++; end

    launch(32'h000);   // relaunch clears the sticky flag
    if (stk_ovf !== 1'b0) begin $display("[TB_STK] FAIL: stk_ovf not cleared by start"); errors++; end

    if (errors == 0) $display("[TB_STK] PASS: stack overflow flag + relaunch verified");
    else             $fatal(1, "[TB_STK] FAIL: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "[TB_STK] watchdog timeout");
  end
endmodule
