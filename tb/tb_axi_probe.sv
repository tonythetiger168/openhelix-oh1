
`timescale 1ns/1ps
module tb_axi_probe;
  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic [31:0] awaddr; logic awvalid; logic awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wvalid; logic wready;
  logic [1:0] bresp; logic bvalid; logic bready;
  logic [31:0] araddr; logic arvalid; logic arready;
  logic [31:0] rdata; logic [1:0] rresp; logic rvalid; logic rready;
  logic core_start; logic [31:0] core_start_pc;
  logic core_done, core_illegal;
  logic irq;
  logic mem_we; logic mem_is_imem; logic [31:0] mem_addr, mem_wdata, mem_rdata;

  oh1_axi_lite #(.LANES_P(4), .ADDR_W(32), .DATA_W(32)) dut (
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

  assign core_illegal = 1'b0;
  assign mem_rdata = 32'h0;

  int cyc = 0;
  always @(posedge clk) begin
    cyc++;
    $display("cyc=%0d state=%0d awv=%b awr=%b wv=%b wr=%b bv=%b br=%b", cyc, dut.axi_state, awvalid, awready, wvalid, wready, bvalid, bready);
  end

  initial begin
    rst_n=0; awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    awaddr=0; wdata=0; wstrb=4'hF; araddr=0;
    core_done=0;
    repeat(4) @(posedge clk);
    rst_n=1;
    @(posedge clk);
    $display("--- after reset, state=%0d ---", dut.axi_state);
    // inline write PROG_BASE = 0x10
    @(negedge clk);
    awaddr=32'h08; awvalid=1;
    wdata=32'h10; wvalid=1;
    @(posedge clk);  // DUT samples awvalid && awready
    @(negedge clk);
    awvalid=0; wvalid=0;
    // 先等 bvalid 升起（DUT 在 WR_RESP 拉起）
    wait (bvalid === 1'b1);
    $display("[PROBE] WRITE OK, bvalid received at cyc=%0d", cyc);
    // 再拉 bready 完成握手
    @(negedge clk); bready = 1;
    @(posedge clk); #1;
    if (bvalid === 1'b0) $display("[PROBE] bvalid cleared correctly");
    else $display("[PROBE] ERROR: bvalid not cleared");
    @(negedge clk); bready = 0;
    $finish;
  end
endmodule
