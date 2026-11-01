// =============================================================================
// OpenHelix OH-1 AXI4-Lite wrapper protocol test (tb/tb_axi_smoke.sv)
// - Write channel ordering: AW+W together, AW before W, W before AW
// - Random BREADY / RREADY backpressure
// - WSTRB on registers and memory, SLVERR / DECERR responses, RO registers
// - VERSION / CAP, STATUS.busy, start ignored while busy, imem write rejected while busy
// - IRQ: done event, level irq_o gated by irq_en, W1C clear
// - Memory model is 1-cycle SYNCHRONOUS read (BRAM-like) to prove read timing
// Core is a stub: done rises N cycles after start and clears on the next start.
// =============================================================================
`timescale 1ns/1ps

module tb_axi_smoke;

  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic [31:0] awaddr; logic awvalid; logic awready;
  logic [31:0] wdata;  logic [3:0] wstrb; logic wvalid; logic wready;
  logic [1:0]  bresp;  logic bvalid; logic bready;
  logic [31:0] araddr; logic arvalid; logic arready;
  logic [31:0] rdata;  logic [1:0] rresp; logic rvalid; logic rready;

  logic        core_start; logic [31:0] core_start_pc;
  logic        core_done, core_illegal, core_stk_ovf;
  logic        irq;
  logic        mem_we; logic [3:0] mem_wstrb; logic mem_is_imem;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;

  oh1_axi_lite #(.LANES_P(4), .STK_P(8), .MEM_WORDS(4096)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .awaddr_i(awaddr), .awvalid_i(awvalid), .awready_o(awready),
    .wdata_i(wdata), .wstrb_i(wstrb), .wvalid_i(wvalid), .wready_o(wready),
    .bresp_o(bresp), .bvalid_o(bvalid), .bready_i(bready),
    .araddr_i(araddr), .arvalid_i(arvalid), .arready_o(arready),
    .rdata_o(rdata), .rresp_o(rresp), .rvalid_o(rvalid), .rready_i(rready),
    .core_start_o(core_start), .core_start_pc_o(core_start_pc),
    .core_done_i(core_done), .core_illegal_i(core_illegal), .core_stk_ovf_i(core_stk_ovf),
    .irq_o(irq),
    .mem_we_o(mem_we), .mem_wstrb_o(mem_wstrb), .mem_is_imem_o(mem_is_imem),
    .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata), .mem_rdata_i(mem_rdata));

  // ---- synchronous-read memory model ----
  logic [31:0] imem [4096];
  logic [31:0] dmem [4096];
  always_ff @(posedge clk) begin
    mem_rdata <= mem_is_imem ? imem[mem_addr[11:0]] : dmem[mem_addr[11:0]];
    if (mem_we)
      for (int b = 0; b < 4; b++)
        if (mem_wstrb[b]) begin
          if (mem_is_imem) imem[mem_addr[11:0]][b*8 +: 8] <= mem_wdata[b*8 +: 8];
          else             dmem[mem_addr[11:0]][b*8 +: 8] <= mem_wdata[b*8 +: 8];
        end
  end

  // ---- core stub ----
  int run_len = 300;
  int core_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_done <= 1'b0; core_cnt <= -1;
    end else if (core_start) begin
      core_done <= 1'b0; core_cnt <= 0;
    end else if (core_cnt >= 0) begin
      core_cnt <= core_cnt + 1;
      if (core_cnt == run_len - 1) begin core_done <= 1'b1; core_cnt <= -1; end
    end
  end
  assign core_illegal = 1'b0;
  assign core_stk_ovf = 1'b0;

  int n_start = 0;
  always @(posedge clk) if (core_start) n_start++;

  // ---- random backpressure on B / R ----
  always @(negedge clk) begin
    bready <= ($urandom_range(0, 2) != 0);
    rready <= ($urandom_range(0, 2) != 0);
  end

  // ---- BFM ----
  // mode 0: AW and W together, 1: AW first, 2: W first
  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data,
                           input logic [3:0] strb, input int mode, output logic [1:0] resp);
    bit aw_done = 0, w_done = 0;
    @(negedge clk);
    if (mode != 2) begin awaddr = addr; awvalid = 1; end
    if (mode != 1) begin wdata = data; wstrb = strb; wvalid = 1; end
    while (!(aw_done && w_done)) begin
      @(posedge clk);
      if (awvalid && awready) aw_done = 1;
      if (wvalid && wready)   w_done  = 1;
      @(negedge clk);
      if (aw_done) awvalid = 0;
      if (w_done)  wvalid  = 0;
      // second half goes out only after the first was accepted (with a gap)
      if (mode == 1 && aw_done && !w_done && !wvalid) begin
        repeat ($urandom_range(0, 3)) @(negedge clk);
        wdata = data; wstrb = strb; wvalid = 1;
      end
      if (mode == 2 && w_done && !aw_done && !awvalid) begin
        repeat ($urandom_range(0, 3)) @(negedge clk);
        awaddr = addr; awvalid = 1;
      end
    end
    do @(posedge clk); while (!(bvalid && bready));
    resp = bresp;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    @(negedge clk);
    araddr = addr; arvalid = 1;
    do @(posedge clk); while (!arready);
    @(negedge clk); arvalid = 0;
    do @(posedge clk); while (!(rvalid && rready));
    data = rdata; resp = rresp;
  endtask

  int errors = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin $display("[TB_AXI] FAIL: %s", what); errors++; end
  endtask

  task automatic wr(input logic [31:0] a, input logic [31:0] d, input logic [1:0] exp_resp = 2'b00,
                    input logic [3:0] strb = 4'hF);
    logic [1:0] r;
    axi_write(a, d, strb, $urandom_range(0, 2), r);
    check(r === exp_resp, $sformatf("write %08x resp=%0d exp=%0d", a, r, exp_resp));
  endtask

  task automatic rd_expect(input logic [31:0] a, input logic [31:0] exp, input logic [1:0] exp_resp = 2'b00);
    logic [31:0] d; logic [1:0] r;
    axi_read(a, d, r);
    check(r === exp_resp, $sformatf("read %08x resp=%0d exp=%0d", a, r, exp_resp));
    if (exp_resp == 2'b00)
      check(d === exp, $sformatf("read %08x data=%08x exp=%08x", a, d, exp));
  endtask

  initial begin
    logic [31:0] d; logic [1:0] r;
    rst_n = 0;
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
    araddr = 0; arvalid = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- 1. each write ordering, many times, on registers ----
    for (int i = 0; i < 30; i++) begin
      logic [31:0] v = $urandom;
      logic [1:0] wr_resp;
      axi_write(32'h08, v, 4'hF, i % 3, wr_resp);
      check(wr_resp === 2'b00, $sformatf("PROG_BASE write mode %0d resp", i % 3));
      rd_expect(32'h08, v);
    end
    $display("[TB_AXI] write ordering AW+W / AW-first / W-first OK");

    // ---- 2. WSTRB on a register ----
    wr(32'h0C, 32'h1122_3344);
    wr(32'h0C, 32'hAABB_CCDD, 2'b00, 4'b0101);
    rd_expect(32'h0C, 32'h11BB_33DD);

    // ---- 3. memory windows (sync-read memory) + WSTRB ----
    for (int i = 0; i < 16; i++) wr(32'h1000_0000 + i*4, 32'hC0DE_0000 + i);
    for (int i = 0; i < 16; i++) rd_expect(32'h1000_0000 + i*4, 32'hC0DE_0000 + i);
    wr(32'h2000_0040, 32'h0000_0000);
    wr(32'h2000_0040, 32'hFFFF_FFFF, 2'b00, 4'b1000);
    rd_expect(32'h2000_0040, 32'hFF00_0000);
    $display("[TB_AXI] memory windows + WSTRB OK");

    // ---- 4. error responses ----
    wr(32'h04, 32'h1, 2'b10);               // STATUS is RO
    wr(32'h18, 32'h1, 2'b10);               // VERSION is RO
    wr(32'h40, 32'h1, 2'b10);               // unmapped register
    wr(32'h1000_4000, 32'h1, 2'b10);        // imem index 4096 out of range
    wr(32'h3000_0000, 32'h1, 2'b11);        // no target -> DECERR
    rd_expect(32'h40, 0, 2'b10);
    rd_expect(32'h2000_4000, 0, 2'b10);
    rd_expect(32'h0001_0000, 0, 2'b11);
    $display("[TB_AXI] SLVERR / DECERR OK");

    // ---- 5. identification ----
    rd_expect(32'h18, 32'h0002_0002);
    rd_expect(32'h1C, {16'd4096, 8'd8, 8'd4});

    // ---- 6. start / busy / IRQ ----
    rd_expect(32'h04, 32'h0);               // idle: not busy, not done
    check(irq === 1'b0, "irq idle");
    wr(32'h08, 32'h0000_0100);
    wr(32'h00, 32'h0000_0003);              // start + irq_en
    check(core_start_pc === 32'h100, "start pc = PROG_BASE");
    axi_read(32'h04, d, r);
    check(d[2] === 1'b1 && d[0] === 1'b0, $sformatf("STATUS busy after start %08x", d));
    wr(32'h1000_0000, 32'h0, 2'b10);        // imem write rejected while busy
    wr(32'h2000_0000, 32'h7);               // dmem write allowed while busy
    wr(32'h00, 32'h0000_0003);              // second start while busy: ignored
    repeat (2) @(posedge clk);
    check(n_start == 1, $sformatf("start while busy ignored (starts=%0d)", n_start));
    wait (irq === 1'b1);
    rd_expect(32'h04, 32'h1);               // done, not busy
    rd_expect(32'h14, 32'h1);               // done event
    wr(32'h14, 32'h1);                      // W1C
    @(posedge clk); #1;
    check(irq === 1'b0, "irq cleared by W1C while core_done stays high");
    rd_expect(32'h14, 32'h0);
    repeat (5) @(posedge clk); #1;
    check(irq === 1'b0, "irq stays low after W1C");

    // ---- 7. relaunch ----
    wr(32'h00, 32'h0000_0001);              // start, irq_en = 0
    repeat (2) @(posedge clk);
    check(n_start == 2, "relaunch after done");
    wait (core_done === 1'b0);
    wait (core_done === 1'b1);
    repeat (3) @(posedge clk);
    check(irq === 1'b0, "irq masked when irq_en=0");
    rd_expect(32'h14, 32'h1);               // event still recorded
    wr(32'h00, 32'h0000_0002);              // irq_en = 1, no start
    @(posedge clk); #1;
    check(irq === 1'b1, "pending event raises irq when enabled");
    wr(32'h14, 32'h3);
    $display("[TB_AXI] start / busy / IRQ W1C / relaunch OK");

    if (errors == 0) $display("[TB_AXI] PASS: all AXI wrapper checks passed");
    else             $fatal(1, "[TB_AXI] FAIL: %0d errors", errors);
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "[TB_AXI] watchdog timeout");
  end

endmodule
