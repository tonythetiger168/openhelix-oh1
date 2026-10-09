// =============================================================================
// OpenHelix OH-1 AXI4-Lite Wrapper 定向驗證（tb/tb_axi_smoke.sv）
// - AXI master BFM：寫 CTRL 觸發 start、輪詢 STATUS、讀寫 memory window
// - 驗證：register map 讀寫、start pulse 觸發 core、done IRQ 產生
// 執行：verilator --binary --timing（見 Makefile axi target）
// =============================================================================
`timescale 1ns/1ps

module tb_axi_smoke;

  localparam int ADDR_W = 32;
  localparam int DATA_W = 32;

  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  // AXI signals
  logic [ADDR_W-1:0] awaddr; logic awvalid; logic awready;
  logic [DATA_W-1:0] wdata;  logic [DATA_W/8-1:0] wstrb; logic wvalid; logic wready;
  logic [1:0] bresp; logic bvalid; logic bready;
  logic [ADDR_W-1:0] araddr; logic arvalid; logic arready;
  logic [DATA_W-1:0] rdata;  logic [1:0] rresp; logic rvalid; logic rready;

  // Core interface
  logic        core_start; logic [31:0] core_start_pc;
  logic        core_done, core_illegal;
  logic        irq;

  // Memory backdoor
  logic        mem_we; logic mem_is_imem; logic [31:0] mem_addr, mem_wdata, mem_rdata;

  // ---- DUT ----
  oh1_axi_lite #(.LANES_P(4), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
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

  // ---- 簡易 AXI BFM（結構化握手，避免 race）----
  task axi_write(input [31:0] addr, input [31:0] data);
    begin
      // 在 negedge 設定，確保 DUT 在下一個 posedge 穩定採樣
      @(negedge clk);
      awaddr = addr; awvalid = 1;
      wdata = data; wstrb = 4'hF; wvalid = 1;
      // 等一個 posedge（DUT 採樣 AW+W，轉 WR_RESP）
      @(posedge clk);
      // 在 negedge 撤掉（此時 DUT 已轉狀態，awready/wready 已變 0）
      @(negedge clk);
      awvalid = 0; wvalid = 0;
      // 等 bvalid 升起，再拉 bready 完成握手（bvalid 同拍會被清）
      wait (bvalid === 1'b1);
      @(negedge clk); bready = 1;
      @(posedge clk); #1;
      @(negedge clk); bready = 0;
      wait (awready === 1'b1);
      // 等一個 posedge 讓 DUT 回 IDLE
      @(posedge clk);
    end
  endtask

  task axi_read(input [31:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      araddr = addr; arvalid = 1;
      @(posedge clk);   // DUT 採樣 AR，轉 RD_ADDR
      @(negedge clk);
      arvalid = 0;
      rready = 1;
      wait (rvalid === 1'b1);
      @(posedge clk); #2 data = rdata;   // 多等一拍確保 rdata 穩定（NBA 更新）
      @(negedge clk); rready = 1;
      @(posedge clk); #1;
      @(negedge clk); rready = 0;
      wait (arready === 1'b1);
    end
  endtask

  // ---- Core stub：start 後 8 週期拉起 done（結構化，不用 always 內 repeat）----
  int core_cnt = -1;
  always @(posedge clk) begin
    if (!rst_n) begin
      core_done <= 1'b0; core_cnt <= -1;
    end else if (core_start) begin
      core_cnt <= 0;
    end else if (core_cnt >= 0 && core_cnt < 8) begin
      core_cnt <= core_cnt + 1;
      if (core_cnt == 7) core_done <= 1'b1;
    end
  end
  assign core_illegal = 1'b0;

  // Memory model（imem/dmem window）
  logic [31:0] imem [256];
  logic [31:0] dmem [256];
  assign mem_rdata = mem_is_imem ? imem[mem_addr & 255] : dmem[mem_addr & 255];
  always @(posedge clk) begin
    if (mem_we) begin
      if (mem_is_imem) imem[mem_addr & 255] <= mem_wdata;
      else             dmem[mem_addr & 255] <= mem_wdata;
    end
  end

  int errors = 0;

  initial begin
    $display("[TB_AXI] clk started, rst_n=%b", rst_n);
    repeat (10) begin
      @(posedge clk);
      $display("[TB_AXI] t=%0t clk=1 rst_n=%b", $time, rst_n);
    end
    $display("[TB_AXI] 10 cycles done, clk toggling OK");
  end

  initial begin
    logic [31:0] rd;
    rst_n = 0;
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
    araddr = 0; arvalid = 0; rready = 0;
    core_done = 0;

    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // Test 1: 寫讀 register
    axi_write(32'h08, 32'h0000_0010);   // PROG_BASE = 0x10
    axi_write(32'h0C, 32'h0000_0020);   // DATA_BASE = 0x20
    axi_write(32'h10, 32'h0000_0008);   // PROG_LEN = 8
    axi_read(32'h08, rd);
    if (rd !== 32'h0000_0010) begin $display("[TB_AXI] FAIL: PROG_BASE rd=%08x", rd); errors++; end
    axi_read(32'h0C, rd);
    $display("[TB_AXI] DBG: DATA_BASE rd=%08x (expect 20)", rd);
    if (rd !== 32'h0000_0020) begin $display("[TB_AXI] FAIL: DATA_BASE rd=%08x", rd); errors++; end

    // Test 2: 寫 memory window（imem @0x1000_0000）
    axi_write(32'h1000_0000, 32'hDEAD_BEEF);
    @(posedge clk);
    if (imem[0] !== 32'hDEAD_BEEF) begin $display("[TB_AXI] FAIL: imem write"); errors++; end

    // Test 3: start pulse（在 axi_write 回來前的 posedge 檢查，因 start 是單週期脈衝）
    @(negedge clk);
    if (core_start !== 1'b0) begin $display("[TB_AXI] FAIL: start not idle"); errors++; end
    begin : test_start
      @(negedge clk);
      awaddr = 32'h00; awvalid = 1;
      wdata = 32'h0000_0003; wstrb = 4'hF; wvalid = 1;   // CTRL: start=1, irq_en=1
      @(posedge clk);   // DUT 採樣，start pulse 在下一拍生效
      #1;
      if (core_start !== 1'b1) begin $display("[TB_AXI] FAIL: start pulse not asserted"); errors++; end
      @(negedge clk);
      awvalid = 0; wvalid = 0;
      wait (bvalid === 1'b1);
      @(negedge clk); bready = 1;
      @(posedge clk); #1;
      @(negedge clk); bready = 0;
      wait (awready === 1'b1);
    end

    // Test 4: done IRQ
    wait (irq === 1'b1);
    if (errors == 0) $display("[TB_AXI] PASS: all AXI wrapper checks passed");
    else             $fatal(1, "[TB_AXI] FAIL: %0d errors", errors);
    $finish;
  end

  // Watchdog
  initial begin
    #5000;
    $fatal(1, "[TB_AXI] watchdog timeout");
  end

endmodule
