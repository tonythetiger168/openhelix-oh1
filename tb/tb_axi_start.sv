// 最小探針：CTRL write → core_start 鏈路觀察
`timescale 1ns/1ps
module tb_axi_start;
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

  oh1_axi_lite #(.LANES_P(4)) dut (
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

  assign core_done = 1'b0;
  assign core_illegal = 1'b0;
  assign mem_rdata = 32'h0;

  int cyc = 0;
  always @(posedge clk) begin
    cyc++;
    $display("cyc=%0d st=%0d awv=%b awr=%b wv=%b wr=%d bv=%b start=%b wdata=%08x awaddr=%08x",
             cyc, dut.axi_state, awvalid, awready, wvalid, wready, bvalid, core_start, wdata, awaddr);
  end

  initial begin
    rst_n=0; awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    awaddr=0; wdata=0; wstrb=4'hF; araddr=0;
    repeat(4) @(posedge clk);
    rst_n=1;
    repeat(2) @(posedge clk);
    $display("--- reset done, writing CTRL=1 ---");
    // inline write CTRL=1
    @(negedge clk);
    awaddr=32'h00; awvalid=1;
    wdata=32'h01; wvalid=1;
    @(posedge clk);
    @(negedge clk);
    awvalid=0; wvalid=0;
    repeat(4) @(posedge clk);
    $display("--- done observing ---");
    $finish;
  end
endmodule
