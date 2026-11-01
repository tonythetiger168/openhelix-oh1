// =============================================================================
// OpenHelix OH-1 AXI4-Lite Slave Wrapper (M2.0 Phase 0 hardening)
//
// Register page (addr[31:28] == 4'h0, addr[27:8] == 0):
//   0x00 CTRL      [0]=start (W1, self-clearing, ignored while busy), [1]=irq_en
//   0x04 STATUS    RO  [0]=done [1]=illegal [2]=busy [3]=stk_ovf
//   0x08 PROG_BASE RW  start PC (byte address) used on the next start
//   0x0C DATA_BASE RW  reserved for DMA (scratch today)
//   0x10 PROG_LEN  RW  reserved for DMA (scratch today)
//   0x14 IRQ_STAT  R: [0]=done event [1]=fault event (illegal or stk_ovf); W1C
//   0x18 VERSION   RO  OH1_VERSION
//   0x1C CAP       RO  {MEM_WORDS[15:0], STK_P[7:0], LANES_P[7:0]}
// Memory windows (word-indexed, byte address >> 2):
//   0x1xxx_xxxx = imem (writes rejected with SLVERR while busy)
//   0x2xxx_xxxx = dmem
//
// AXI4-Lite compliance:
//   - AW and W are accepted independently, in either order or together
//   - WSTRB honoured for registers (byte lanes) and forwarded to memory (mem_wstrb_o)
//   - BRESP/RRESP: OKAY, SLVERR (unmapped register, RO write, out-of-range index,
//     imem write while busy), DECERR (address outside the register page and windows)
//   - One outstanding transaction per channel; writes have priority over reads
//   - Memory reads tolerate either combinational or 1-cycle synchronous memories
// IRQ: level, irq_o = irq_en & |IRQ_STAT. Events are captured on rising edges of
//   core done / illegal / stk_ovf, and cleared by writing 1s to IRQ_STAT.
// =============================================================================
module oh1_axi_lite #(
  parameter int          LANES_P     = 4,
  parameter int          STK_P       = 8,
  parameter int          MEM_WORDS   = 4096,
  parameter int          ADDR_W      = 32,
  parameter int          DATA_W      = 32,
  parameter logic [31:0] OH1_VERSION = 32'h0002_0002   // M2.0, rev 2 (MUL, JAL/JALR, vdot4.i8)
)(
  input  logic                     clk_i,
  input  logic                     rst_ni,

  input  logic [ADDR_W-1:0]        awaddr_i,
  input  logic                     awvalid_i,
  output logic                     awready_o,
  input  logic [DATA_W-1:0]        wdata_i,
  input  logic [DATA_W/8-1:0]      wstrb_i,
  input  logic                     wvalid_i,
  output logic                     wready_o,
  output logic [1:0]               bresp_o,
  output logic                     bvalid_o,
  input  logic                     bready_i,
  input  logic [ADDR_W-1:0]        araddr_i,
  input  logic                     arvalid_i,
  output logic                     arready_o,
  output logic [DATA_W-1:0]        rdata_o,
  output logic [1:0]               rresp_o,
  output logic                     rvalid_o,
  input  logic                     rready_i,

  output logic                     core_start_o,
  output logic [31:0]              core_start_pc_o,
  input  logic                     core_done_i,
  input  logic                     core_illegal_i,
  input  logic                     core_stk_ovf_i,

  output logic                     irq_o,

  output logic                     mem_we_o,
  output logic [3:0]               mem_wstrb_o,
  output logic                     mem_is_imem_o,
  output logic [31:0]              mem_addr_o,
  output logic [31:0]              mem_wdata_o,
  input  logic [31:0]              mem_rdata_i
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  localparam logic [7:0] REG_CTRL      = 8'h00;
  localparam logic [7:0] REG_STATUS    = 8'h04;
  localparam logic [7:0] REG_PROG_BASE = 8'h08;
  localparam logic [7:0] REG_DATA_BASE = 8'h0C;
  localparam logic [7:0] REG_PROG_LEN  = 8'h10;
  localparam logic [7:0] REG_IRQ_STAT  = 8'h14;
  localparam logic [7:0] REG_VERSION   = 8'h18;
  localparam logic [7:0] REG_CAP       = 8'h1C;

  localparam logic [31:0] CAP_VALUE = {16'(MEM_WORDS), 8'(STK_P), 8'(LANES_P)};

  // ---------------------------------------------------------------------------
  // Address decode helpers
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {T_REG, T_IMEM, T_DMEM, T_NONE} target_e;

  function automatic target_e decode_target(input logic [31:8] a);
    if (a[31:28] == 4'h0 && a[27:8] == '0) return T_REG;
    if (a[31:28] == 4'h1)                  return T_IMEM;
    if (a[31:28] == 4'h2)                  return T_DMEM;
    return T_NONE;
  endfunction

  function automatic logic [31:0] word_index(input logic [27:2] a);
    return {6'b0, a};
  endfunction

  function automatic logic [31:0] apply_strb(input logic [31:0] old_v,
                                             input logic [31:0] new_v,
                                             input logic [3:0]  strb);
    logic [31:0] r;
    for (int b = 0; b < 4; b++) r[b*8 +: 8] = strb[b] ? new_v[b*8 +: 8] : old_v[b*8 +: 8];
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Registers and core status tracking
  // ---------------------------------------------------------------------------
  logic        ctrl_irq_en;
  logic [31:0] prog_base, data_base, prog_len;
  logic        busy_q;
  logic [1:0]  irq_stat_q;           // [0]=done event, [1]=fault event
  logic        done_d1, fault_d1;
  logic        fault_c;
  assign fault_c = core_illegal_i | core_stk_ovf_i;

  // ---------------------------------------------------------------------------
  // Write channel: independent AW / W holding registers
  // ---------------------------------------------------------------------------
  logic        aw_full, w_full;
  logic [31:0] aw_addr_q, w_data_q;
  logic [3:0]  w_strb_q;

  assign awready_o = !aw_full;
  assign wready_o  = !w_full;

  // ---------------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {RD_IDLE, RD_MEM_WAIT, RD_MEM_SAMPLE} rd_state_e;
  rd_state_e   rd_state;
  logic        ar_full;
  logic [31:0] ar_addr_q;

  assign arready_o = !ar_full && !rvalid_o && (rd_state == RD_IDLE);

  // A write executes when both halves are held, B is free, and no read owns the memory port
  logic do_write;
  assign do_write = aw_full && w_full && !bvalid_o && (rd_state == RD_IDLE);
  // A read starts when AR is held, R is free, and no write uses the memory port this cycle
  logic do_read;
  assign do_read  = ar_full && !rvalid_o && (rd_state == RD_IDLE) && !do_write;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_full       <= 1'b0;
      w_full        <= 1'b0;
      aw_addr_q     <= '0;
      w_data_q      <= '0;
      w_strb_q      <= '0;
      ar_full       <= 1'b0;
      ar_addr_q     <= '0;
      rd_state      <= RD_IDLE;
      bvalid_o      <= 1'b0;
      bresp_o       <= RESP_OKAY;
      rvalid_o      <= 1'b0;
      rresp_o       <= RESP_OKAY;
      rdata_o       <= '0;
      mem_we_o      <= 1'b0;
      mem_wstrb_o   <= '0;
      mem_is_imem_o <= 1'b0;
      mem_addr_o    <= '0;
      mem_wdata_o   <= '0;
      core_start_o  <= 1'b0;
      ctrl_irq_en   <= 1'b0;
      prog_base     <= '0;
      data_base     <= '0;
      prog_len      <= '0;
      busy_q        <= 1'b0;
      irq_stat_q    <= '0;
      done_d1       <= 1'b0;
      fault_d1      <= 1'b0;
    end else begin
      core_start_o <= 1'b0;
      mem_we_o     <= 1'b0;

      // ---- capture AW / W independently ----
      if (awvalid_i && awready_o) begin
        aw_full   <= 1'b1;
        aw_addr_q <= awaddr_i;
      end
      if (wvalid_i && wready_o) begin
        w_full   <= 1'b1;
        w_data_q <= wdata_i;
        w_strb_q <= wstrb_i;
      end
      if (arvalid_i && arready_o) begin
        ar_full   <= 1'b1;
        ar_addr_q <= araddr_i;
      end

      // ---- B handshake ----
      if (bvalid_o && bready_i) bvalid_o <= 1'b0;

      // ---- execute a write ----
      if (do_write) begin
        aw_full  <= 1'b0;
        w_full   <= 1'b0;
        bvalid_o <= 1'b1;
        bresp_o  <= RESP_OKAY;
        unique case (decode_target(aw_addr_q[31:8]))
          T_IMEM, T_DMEM: begin
            if (word_index(aw_addr_q[27:2]) >= MEM_WORDS) begin
              bresp_o <= RESP_SLVERR;
            end else if (decode_target(aw_addr_q[31:8]) == T_IMEM && busy_q) begin
              bresp_o <= RESP_SLVERR;      // do not rewrite code under a running kernel
            end else begin
              mem_we_o      <= 1'b1;
              mem_wstrb_o   <= w_strb_q;
              mem_is_imem_o <= (decode_target(aw_addr_q[31:8]) == T_IMEM);
              mem_addr_o    <= word_index(aw_addr_q[27:2]);
              mem_wdata_o   <= w_data_q;
            end
          end
          T_REG: begin
            unique case (aw_addr_q[7:0])
              REG_CTRL: begin
                if (w_strb_q[0]) begin
                  ctrl_irq_en <= w_data_q[1];
                  if (w_data_q[0] && !busy_q) begin
                    core_start_o <= 1'b1;
                    busy_q       <= 1'b1;
                  end
                end
              end
              REG_PROG_BASE: prog_base <= apply_strb(prog_base, w_data_q, w_strb_q);
              REG_DATA_BASE: data_base <= apply_strb(data_base, w_data_q, w_strb_q);
              REG_PROG_LEN:  prog_len  <= apply_strb(prog_len,  w_data_q, w_strb_q);
              REG_IRQ_STAT:  if (w_strb_q[0]) irq_stat_q <= irq_stat_q & ~w_data_q[1:0];
              REG_STATUS, REG_VERSION, REG_CAP: bresp_o <= RESP_SLVERR;  // read-only
              default:       bresp_o <= RESP_SLVERR;
            endcase
          end
          default: bresp_o <= RESP_DECERR;
        endcase
      end

      // ---- R handshake ----
      if (rvalid_o && rready_i) rvalid_o <= 1'b0;

      // ---- execute a read ----
      unique case (rd_state)
        RD_IDLE: begin
          if (do_read) begin
            ar_full <= 1'b0;
            rresp_o <= RESP_OKAY;
            unique case (decode_target(ar_addr_q[31:8]))
              T_IMEM, T_DMEM: begin
                if (word_index(ar_addr_q[27:2]) >= MEM_WORDS) begin
                  rresp_o  <= RESP_SLVERR;
                  rdata_o  <= '0;
                  rvalid_o <= 1'b1;
                end else begin
                  mem_is_imem_o <= (decode_target(ar_addr_q[31:8]) == T_IMEM);
                  mem_addr_o    <= word_index(ar_addr_q[27:2]);
                  rd_state      <= RD_MEM_WAIT;
                end
              end
              T_REG: begin
                rvalid_o <= 1'b1;
                unique case (ar_addr_q[7:0])
                  REG_CTRL:      rdata_o <= {30'b0, ctrl_irq_en, 1'b0};
                  REG_STATUS:    rdata_o <= {28'b0, core_stk_ovf_i, busy_q, core_illegal_i,
                                             core_done_i && !busy_q};
                  REG_PROG_BASE: rdata_o <= prog_base;
                  REG_DATA_BASE: rdata_o <= data_base;
                  REG_PROG_LEN:  rdata_o <= prog_len;
                  REG_IRQ_STAT:  rdata_o <= {30'b0, irq_stat_q};
                  REG_VERSION:   rdata_o <= OH1_VERSION;
                  REG_CAP:       rdata_o <= CAP_VALUE;
                  default: begin
                    rdata_o <= '0;
                    rresp_o <= RESP_SLVERR;
                  end
                endcase
              end
              default: begin
                rdata_o  <= '0;
                rresp_o  <= RESP_DECERR;
                rvalid_o <= 1'b1;
              end
            endcase
          end
        end
        // mem_addr_o became valid at the end of RD_IDLE; a synchronous memory
        // registers its output at the end of this cycle
        RD_MEM_WAIT:   rd_state <= RD_MEM_SAMPLE;
        RD_MEM_SAMPLE: begin
          rdata_o  <= mem_rdata_i;
          rvalid_o <= 1'b1;
          rd_state <= RD_IDLE;
        end
        default: rd_state <= RD_IDLE;
      endcase

      // ---- core status tracking and IRQ events ----
      done_d1  <= core_done_i;
      fault_d1 <= fault_c;
      if (busy_q && !core_start_o && core_done_i && !done_d1) busy_q <= 1'b0;
      if (core_done_i && !done_d1) irq_stat_q[0] <= 1'b1;
      if (fault_c && !fault_d1)    irq_stat_q[1] <= 1'b1;
    end
  end

  assign irq_o           = ctrl_irq_en && (irq_stat_q != '0);
  assign core_start_pc_o = prog_base;

endmodule
