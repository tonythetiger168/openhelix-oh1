// =============================================================================
// OH-1 pyuvm testbench top (verif/hdl/oh1_tb_top.sv)
//
// SoC-level harness: oh1_axi_lite + oh1_core + 16 KB imem + 16 KB dmem.
// The pyuvm environment drives only the AXI4-Lite slave port (plus reset and one
// test-only start-injection pin) and observes the core trace ports, which are
// re-exported here so cocotb never needs hierarchical (public) access.
//
// tb_start_inj_i is OR-ed onto the core start pin. The AXI wrapper never issues a
// start while busy, so this is the only way to drive start_i into a running core
// (the core must ignore it). Sequences only pulse it while a kernel is running.
// =============================================================================

module oh1_tb_top import oh1_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  // AXI4-Lite slave
  input  logic [31:0] awaddr,
  input  logic        awvalid,
  output logic        awready,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  input  logic        wvalid,
  output logic        wready,
  output logic [1:0]  bresp,
  output logic        bvalid,
  input  logic        bready,
  input  logic [31:0] araddr,
  input  logic        arvalid,
  output logic        arready,
  output logic [31:0] rdata,
  output logic [1:0]  rresp,
  output logic        rvalid,
  input  logic        rready,
  output logic        irq,
  // test-only
  input  logic        tb_start_inj_i,
  // observation: wrapper <-> core / memory side
  output logic        core_start,
  output logic [31:0] core_start_pc,
  output logic        core_done,
  output logic        core_illegal,
  output logic        core_stk_ovf,
  output logic        mem_we,
  output logic [3:0]  mem_wstrb,
  output logic        mem_is_imem,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  output logic [31:0] mem_rdata,
  // observation: core execution trace (lanes flattened, lane l = [32*l +: 32])
  output logic        exec_valid,
  output logic [31:0] exec_pc,
  output logic [3:0]  exec_mask,
  output logic        wb_valid,
  output logic [4:0]  wb_rd,
  output logic [3:0]  wb_lane_mask,
  output logic [127:0] wb_data,
  output logic        dmem_wen,
  output logic [3:0]  dmem_wmask,
  output logic [127:0] dmem_waddr,
  output logic [127:0] dmem_wdata
);

  localparam int MEM_W = 4096;

  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_ren;
  logic [31:0] dmem_raddr_a [LANES], dmem_rdata_a [LANES];
  logic [31:0] dmem_waddr_a [LANES], dmem_wdata_a [LANES];
  logic [31:0] wb_data_a [LANES];
  logic        core_start_axi;

  assign core_start = core_start_axi | tb_start_inj_i;

  // ---- memories: combinational read, write at posedge (core first, AXI last) ----
  logic [31:0] pmem [MEM_W];
  logic [31:0] dmem [MEM_W];

  assign imem_rdata = pmem[imem_addr[13:2]];
  for (genvar g = 0; g < LANES; g++) begin : g_lane_io
    assign dmem_rdata_a[g]       = dmem[dmem_raddr_a[g][13:2]];
    assign wb_data[32*g +: 32]    = wb_data_a[g];
    assign dmem_waddr[32*g +: 32] = dmem_waddr_a[g];
    assign dmem_wdata[32*g +: 32] = dmem_wdata_a[g];
  end

  always_ff @(posedge clk) begin
    if (dmem_wen)
      for (int l = 0; l < LANES; l++)
        if (dmem_wmask[l]) dmem[dmem_waddr_a[l][13:2]] <= dmem_wdata_a[l];
    if (mem_we)
      for (int b = 0; b < 4; b++)
        if (mem_wstrb[b]) begin
          if (mem_is_imem) pmem[mem_addr[11:0]][b*8 +: 8] <= mem_wdata[b*8 +: 8];
          else             dmem[mem_addr[11:0]][b*8 +: 8] <= mem_wdata[b*8 +: 8];
        end
  end
  assign mem_rdata = mem_is_imem ? pmem[mem_addr[11:0]] : dmem[mem_addr[11:0]];

  oh1_axi_lite #(.LANES_P(LANES)) u_axi (
    .clk_i(clk), .rst_ni(rst_n),
    .awaddr_i(awaddr), .awvalid_i(awvalid), .awready_o(awready),
    .wdata_i(wdata), .wstrb_i(wstrb), .wvalid_i(wvalid), .wready_o(wready),
    .bresp_o(bresp), .bvalid_o(bvalid), .bready_i(bready),
    .araddr_i(araddr), .arvalid_i(arvalid), .arready_o(arready),
    .rdata_o(rdata), .rresp_o(rresp), .rvalid_o(rvalid), .rready_i(rready),
    .core_start_o(core_start_axi), .core_start_pc_o(core_start_pc),
    .core_done_i(core_done), .core_illegal_i(core_illegal), .core_stk_ovf_i(core_stk_ovf),
    .irq_o(irq),
    .mem_we_o(mem_we), .mem_wstrb_o(mem_wstrb), .mem_is_imem_o(mem_is_imem),
    .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata), .mem_rdata_i(mem_rdata));

  oh1_core #(.LANES_P(LANES)) u_core (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(core_start), .start_pc_i(core_start_pc),
    .imem_addr_o(imem_addr), .imem_rdata_i(imem_rdata),
    .dmem_ren_o(dmem_ren), .dmem_raddr_o(dmem_raddr_a), .dmem_rdata_i(dmem_rdata_a),
    .dmem_wen_o(dmem_wen), .dmem_wmask_o(dmem_wmask),
    .dmem_waddr_o(dmem_waddr_a), .dmem_wdata_o(dmem_wdata_a),
    .exec_valid_o(exec_valid), .exec_pc_o(exec_pc), .exec_mask_o(exec_mask),
    .wb_valid_o(wb_valid), .wb_rd_o(wb_rd), .wb_lane_mask_o(wb_lane_mask),
    .wb_data_o(wb_data_a), .done_o(core_done), .illegal_o(core_illegal),
    .stk_ovf_o(core_stk_ovf));

endmodule
