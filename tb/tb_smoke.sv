// =============================================================================
// OH-1 開源煙霧測試（非 UVM，iverilog 可執行）
// 功能：csrr tid、split/join 分歧、texit 前 WB、beq/bne（AND 語義）、
//       divergent sw/lw（每 lane 獨立位址）
// 期望值（LANES=4）：
//   x1[l] = l                    (csrr tid)
//   x2[0] = 20, x2[1..3] = 10    (split/join：lane0 走 else 路徑)
//   x3[l] = l                    (lw x3, 64(x6) — divergent load, x6=tid*4)
//   x4 = 7                       (beq x1,x0 → AND 語義不跳)
//   x5 = 99                      (beq x0,x0 → 必跳過 x5=111)
//   dmem[16+l] = l               (sw x1, 64(x6) — divergent store, 字對齊獨立位址)
// =============================================================================
`timescale 1ns/1ps

module tb_smoke;
  import oh1_pkg::*;

  localparam int N = oh1_pkg::LANES;

  logic clk, rst_n, start;
  logic [31:0] start_pc;
  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_raddr [N], dmem_rdata [N];
  logic [31:0] dmem_waddr [N], dmem_wdata [N];
  logic dmem_ren, dmem_wen;
  logic exec_valid;
  logic [31:0] exec_pc;
  lane_mask_t exec_mask, wb_lane_mask;
  logic wb_valid;
  logic [4:0] wb_rd;
  logic [31:0] wb_data [N];
  logic done, illegal;

  // ---- DUT ----
  oh1_core dut (
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .start_pc_i(start_pc),
    .imem_addr_o(imem_addr), .imem_rdata_i(imem_rdata),
    .dmem_ren_o(dmem_ren), .dmem_raddr_o(dmem_raddr), .dmem_rdata_i(dmem_rdata),
    .dmem_wen_o(dmem_wen), .dmem_waddr_o(dmem_waddr), .dmem_wdata_o(dmem_wdata),
    .exec_valid_o(exec_valid), .exec_pc_o(exec_pc), .exec_mask_o(exec_mask),
    .wb_valid_o(wb_valid), .wb_rd_o(wb_rd), .wb_lane_mask_o(wb_lane_mask),
    .wb_data_o(wb_data), .done_o(done), .illegal_o(illegal)
  );

  // ---- 指令記憶體（comb）----
  logic [31:0] pmem [64];
  always_comb imem_rdata = pmem[imem_addr[31:2] & 32'h3F];

  // ---- 資料記憶體（comb read / sync write，每 lane 獨立位址）----
  logic [31:0] dmem [1024];
  genvar gl;
  generate
    for (gl = 0; gl < N; gl++) begin : g_dmem
      assign dmem_rdata[gl] = dmem[dmem_raddr[gl][13:2]];
    end
  endgenerate
  always_ff @(posedge clk) begin
    if (dmem_wen) begin
      for (int l = 0; l < N; l++)
        dmem[dmem_waddr[l][13:2]] <= dmem_wdata[l];
    end
  end

  // ---- 時脈 ----
  initial clk = 0;
  always #5 clk = ~clk;

  // ---- 測試主流程 ----
  int errors = 0;
  task automatic check32(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL [%s]: got 0x%08x, expect 0x%08x", name, got, exp);
      errors++;
    end else $display("PASS [%s] = 0x%08x", name, got);
  endtask

  // ---- watchdog（獨立 initial；timeout 時強制結束並報 FAIL）----
  initial begin : watchdog
    repeat (2000) @(posedge clk);
    if (!done) begin
      $display("FAIL: watchdog timeout (done 未拉起)");
      errors++;
      $display("==== SMOKE TEST FAIL (watchdog) ====");
      $finish;
    end
  end

  initial begin : main
    // 程式（使用 oh1_pkg 編碼函數，與 generator/ISS 同源）
    pmem[0]  = enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID);        // x1 = tid (lane id)
    pmem[1]  = enc_split(5'd1, 12'd6);                        // split x1, +12B → else@pc16（推 tag+else 兩 entry）
    pmem[2]  = enc_itype(I_ADDI, 5'd2, 5'd0, 12'd10);         // then: x2 = 10
    pmem[3]  = enc_custom3(F3_JOIN, 5'd0, 5'd0);              // join #1 → else 路徑
    pmem[4]  = enc_itype(I_ADDI, 5'd2, 5'd0, 12'd20);         // else: x2 = 20
    pmem[5]  = enc_custom3(F3_JOIN, 5'd0, 5'd0);              // join #2 → 恢復全遮罩
    pmem[6]  = enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2);          // x6 = tid*4（每 lane 字對齊獨立位址）
    pmem[7]  = enc_sw(5'd1, 5'd6, 12'd64);                    // sw x1, 64(x6)（enc_sw 參數序為 rs2, rs1, imm）
    pmem[8]  = enc_itype(I_LW, 5'd3, 5'd6, 12'd64);           // lw x3, 64(x6)
    pmem[9]  = enc_btype(I_BEQ, 5'd1, 5'd0, 12'd4);           // beq x1,x0,+8B (AND語義→不跳; imm 為半字組)
    pmem[10] = enc_itype(I_ADDI, 5'd4, 5'd0, 12'd7);          // x4 = 7
    pmem[11] = enc_btype(I_BEQ, 5'd0, 5'd0, 12'd4);           // beq x0,x0,+8B (必跳→pc52/0x34; imm 為半字組)
    pmem[12] = enc_itype(I_ADDI, 5'd5, 5'd0, 12'd111);        // (跳過) x5 = 111
    pmem[13] = enc_itype(I_ADDI, 5'd5, 5'd0, 12'd99);         // x5 = 99
    pmem[14] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);
    for (int i = 15; i < 64; i++) pmem[i] = 32'h0;

    for (int i = 0; i < 1024; i++) dmem[i] = 32'h0;

    rst_n = 0; start = 0; start_pc = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    start <= 1; start_pc <= 0;
    @(posedge clk);
    start <= 0;

    wait (done);
    begin : settle
      int n = 0;
      forever begin
        @(posedge clk);
        n++;
        if (n >= 4) disable settle;
      end
    end

    if (illegal) begin $display("FAIL: illegal 指令被執行"); errors++; end

    // ---- 期望檢查 ----
    check32("x1[0] (tid lane0)", dut.rf_q[0][1], 32'd0);
    check32("x1[3] (tid lane3)", dut.rf_q[3][1], 32'd3);
    check32("x2[0] (else 路徑)", dut.rf_q[0][2], 32'd20);
    check32("x2[1] (then 路徑)", dut.rf_q[1][2], 32'd10);
    check32("x2[3] (then 路徑)", dut.rf_q[3][2], 32'd10);
    check32("x3[2] (divergent lw)", dut.rf_q[2][3], 32'd2);
    check32("x4 (beq AND 不跳)", dut.rf_q[0][4], 32'd7);
    check32("x5 (beq 必跳)", dut.rf_q[0][5], 32'd99);
    check32("dmem[16] (divergent sw)", dmem[16], 32'd0);
    check32("dmem[17] (divergent sw)", dmem[17], 32'd1);
    check32("dmem[18] (divergent sw)", dmem[18], 32'd2);
    check32("dmem[19] (divergent sw)", dmem[19], 32'd3);

    if (errors == 0) $display("\n==== SMOKE TEST PASS: 12/12 checks ====");
    else             $display("\n==== SMOKE TEST FAIL: %0d errors ====", errors);
    $finish;
  end

endmodule
