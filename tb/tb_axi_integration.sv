// =============================================================================
// OpenHelix OH-1 AXI4-Lite + Core 整合驗證（tb/tb_axi_integration.sv）
// - AXI wrapper 連接真實 oh1_core（非 stub）
// - 流程：AXI 載入程式到 imem → 寫 CTRL start → 輪詢 STATUS done →
//         驗證 RF/dmem 結果與 tb_smoke 期望值一致
// =============================================================================
`timescale 1ns/1ps

module tb_axi_integration;
  import oh1_pkg::*;

  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  // AXI
  logic [31:0] awaddr; logic awvalid; logic awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wvalid; logic wready;
  logic [1:0] bresp; logic bvalid; logic bready;
  logic [31:0] araddr; logic arvalid; logic arready;
  logic [31:0] rdata; logic [1:0] rresp; logic rvalid; logic rready;

  // Core
  logic        core_start; logic [31:0] core_start_pc;
  logic        core_done, core_illegal;
  logic        irq;
  logic        mem_we; logic mem_is_imem; logic [31:0] mem_addr, mem_wdata, mem_rdata;

  // Core native memory interface
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_ren, dmem_wen;
  logic [31:0] dmem_raddr [LANES], dmem_rdata [LANES];
  logic [31:0] dmem_waddr [LANES], dmem_wdata [LANES];
  logic        exec_valid; logic [31:0] exec_pc; lane_mask_t exec_mask, wb_lane_mask;
  logic        wb_valid; logic [4:0] wb_rd; logic [31:0] wb_data [LANES];

  // Memory model（與 tb_smoke 相同）
  logic [31:0] pmem [4096];
  logic [31:0] dmem [4096];

  always_comb imem_rdata = pmem[imem_addr[31:2] & 32'hFFF];
  for (genvar g = 0; g < LANES; g++) begin : g_dmem_rd
    always_comb dmem_rdata[g] = dmem[dmem_raddr[g][13:2] & 32'hFFF];
  end
  always_ff @(posedge clk) begin
    if (dmem_wen)
      for (int l = 0; l < LANES; l++)
        dmem[dmem_waddr[l][13:2] & 32'hFFF] <= dmem_wdata[l];
    // AXI backdoor 寫入（mem_addr 已是 word index，與 core 的 [31:2] 一致）
    if (mem_we) begin
      if (mem_is_imem) pmem[mem_addr & 32'hFFF] <= mem_wdata;
      else             dmem[mem_addr & 32'hFFF] <= mem_wdata;
    end
  end
  assign mem_rdata = mem_is_imem ? pmem[mem_addr & 32'hFFF] : dmem[mem_addr & 32'hFFF];

  // DUTs
  oh1_axi_lite #(.LANES_P(LANES)) axi (
    .clk_i(clk), .rst_ni(rst_n),
    .awaddr_i(awaddr), .awvalid_i(awvalid), .awready_o(awready),
    .wdata_i(wdata), .wstrb_i(wstrb), .wvalid_i(wvalid), .wready_o(wready),
    .bresp_o(bresp), .bvalid_o(bvalid), .bready_i(bready),
    .araddr_i(araddr), .arvalid_i(arvalid), .arready_o(arready),
    .rdata_o(rdata), .rresp_o(rresp), .rvalid_o(rvalid), .rready_i(rready),
    .core_start_o(core_start), .core_start_pc_o(core_start_pc),
    .core_done_i(core_done), .core_illegal_i(core_illegal),
    .irq_o(irq),
    .mem_we_o(mem_we), .mem_is_imem_o(mem_is_imem),
    .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata), .mem_rdata_i(mem_rdata));

  oh1_core #(.LANES_P(LANES)) core (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(core_start), .start_pc_i(core_start_pc),
    .imem_addr_o(imem_addr), .imem_rdata_i(imem_rdata),
    .dmem_ren_o(dmem_ren), .dmem_raddr_o(dmem_raddr), .dmem_rdata_i(dmem_rdata),
    .dmem_wen_o(dmem_wen), .dmem_waddr_o(dmem_waddr), .dmem_wdata_o(dmem_wdata),
    .exec_valid_o(exec_valid), .exec_pc_o(exec_pc), .exec_mask_o(exec_mask),
    .wb_valid_o(wb_valid), .wb_rd_o(wb_rd), .wb_lane_mask_o(wb_lane_mask),
    .wb_data_o(wb_data), .done_o(core_done), .illegal_o(core_illegal));

  // start 脈衝觀察旗標（non-blocking，不干擾任何握手）
  logic start_seen = 1'b0;
  always @(posedge clk) begin
    if (core_start) begin
      start_seen <= 1'b1;
      $display("[DBG] core_start RISE at t=%0t", $time);
    end
  end

  // Debug：core 執行觀測（三合一判死 monitor）
  logic done_d = 1'b0;
  int dbg_cyc = 0;
  always @(posedge clk) begin
    done_d <= core_done;
    dbg_cyc++;
    if (core.active_q && !core.done_q && dbg_cyc < 60)
      $display("[DBG] ACTIVE exec pc=%08x mask=%04b vld=%b", exec_pc, exec_mask, exec_valid);
    if (core_done && !done_d)
      $display("[DBG] core_done RISE at t=%0t", $time);
  end

  // AXI BFM（與 tb_axi_smoke 相同，修正版）
  task axi_write(input [31:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      awaddr = addr; awvalid = 1;
      wdata = data; wstrb = 4'hF; wvalid = 1;
      @(posedge clk);
      @(negedge clk);
      awvalid = 0; wvalid = 0;
      wait (bvalid === 1'b1);
      @(negedge clk); bready = 1;
      @(posedge clk); #1;
      @(negedge clk); bready = 0;
      wait (awready === 1'b1);
    end
  endtask

  task axi_read(input [31:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      araddr = addr; arvalid = 1;
      @(posedge clk);
      @(negedge clk);
      arvalid = 0;
      wait (rvalid === 1'b1);
      @(posedge clk); #2 data = rdata;
      @(negedge clk); rready = 1;
      @(posedge clk); #1;
      @(negedge clk); rready = 0;
      wait (arready === 1'b1);
    end
  endtask

  // Smoke program（與 tb_smoke 相同）
  logic [31:0] smoke_prog [15];
  function automatic void load_smoke();
    smoke_prog[0]  = enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID);
    smoke_prog[1]  = enc_split(5'd1, 12'd6);
    smoke_prog[2]  = enc_itype(I_ADDI, 5'd2, 5'd0, 12'd99);
    smoke_prog[3]  = enc_custom3(F3_JOIN, 5'd0, 5'd0);
    smoke_prog[4]  = enc_itype(I_ADDI, 5'd2, 5'd0, 12'd20);
    smoke_prog[5]  = enc_custom3(F3_JOIN, 5'd0, 5'd0);
    smoke_prog[6]  = enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2);
    smoke_prog[7]  = enc_sw(5'd1, 5'd6, 12'd64);
    smoke_prog[8]  = enc_itype(I_LW, 5'd3, 5'd6, 12'd64);
    smoke_prog[9]  = enc_btype(I_BEQ, 5'd1, 5'd0, 12'd4);
    smoke_prog[10] = enc_itype(I_ADDI, 5'd4, 5'd0, 12'd7);
    smoke_prog[11] = enc_btype(I_BEQ, 5'd0, 5'd0, 12'd4);
    smoke_prog[12] = enc_itype(I_ADDI, 5'd5, 5'd0, 12'd111);
    smoke_prog[13] = enc_itype(I_ADDI, 5'd5, 5'd0, 12'd99);
    smoke_prog[14] = enc_custom3(F3_TEXIT, 5'd0, 5'd0);
  endfunction

  int errors = 0;
  logic [31:0] rd;

  initial begin
    // Reset
    rst_n = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // 準備程式陣列
    load_smoke();
    for (int i = 0; i < 4096; i++) begin pmem[i] = '0; dmem[i] = '0; end

    // 透過 AXI 載入程式到 imem
    for (int i = 0; i < 15; i++) begin
      $display("[DBG] loading pmem[%0d] = %08x", i, smoke_prog[i]);
      axi_write(32'h1000_0000 + i*4, smoke_prog[i]);
    end

    // 驗證 imem 載入正確（讀回第一個和最後一個）
    axi_read(32'h1000_0000, rd);
    $display("[DBG] readback imem[0] = %08x", rd);
    if (rd !== smoke_prog[0]) begin $display("[TB_AXI_INT] FAIL: imem[0] rd=%08x exp=%08x", rd, smoke_prog[0]); errors++; end
    axi_read(32'h1000_0038, rd);
    if (rd !== smoke_prog[14]) begin $display("[TB_AXI_INT] FAIL: imem[14] rd=%08x exp=%08x", rd, smoke_prog[14]); errors++; end

    // Start（non-blocking 觀察，不干擾握手）
    begin
      automatic logic saw_start = 0;
      // 觀察區塊：每 posedge 檢查（獨立 always 不行在 task 內，用旗標+延後檢查）
      axi_write(32'h00, 32'h0000_0001);   // CTRL: start=1, irq_en=0
      saw_start = start_seen;
      if (!saw_start) begin
        $display("[TB_AXI_INT] FAIL: no core_start pulse"); errors++;
      end
    end

    // 等 core 完成（wire 等待已證明 done 會升起），再驗 STATUS register 正確反映
    wait (core_done === 1'b1);
    $display("[TB_AXI_INT] core done (wire) at t=%0t", $time);
    axi_read(32'h04, rd);
    if (rd[0] !== 1'b1) begin
      $display("[TB_AXI_INT] FAIL: STATUS done bit not set, rd=%08x", rd); errors++;
    end else begin
      $display("[TB_AXI_INT] STATUS done bit verified");
    end

    // 驗證核心結果（與 tb_smoke 相同期望值）
    for (int l = 0; l < LANES; l++) begin
      if (core.rf_q[l][2] !== ((l == 0) ? 32'd20 : 32'd99)) begin
        $display("[TB_AXI_INT] FAIL: rf[%0d][2]=%0d exp=%0d", l, core.rf_q[l][2], (l==0)?20:99);
        errors++;
      end
      if (dmem[16+l] !== 32'(l)) begin
        $display("[TB_AXI_INT] FAIL: dmem[%0d]=%0d exp=%0d", 16+l, dmem[16+l], l);
        errors++;
      end
    end

    if (errors == 0) $display("[TB_AXI_INT] PASS: AXI + core integration verified");
    else             $fatal(1, "[TB_AXI_INT] FAIL: %0d errors", errors);
    $finish;
  end

  initial begin
    #50000;
    $fatal(1, "[TB_AXI_INT] watchdog timeout");
  end

endmodule
