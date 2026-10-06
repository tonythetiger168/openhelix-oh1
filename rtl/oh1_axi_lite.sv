// =============================================================================
// OpenHelix OH-1 AXI4-Lite Slave Wrapper（M1.0 W2）
// - 把 OH-1 核心包裝為可掛系統匯流排的周邊
// - 記憶體映射：imem/dmem 透過 AXI 讀寫（backdoor），核心執行時 AXI 不可存取
// - 暫存器：
//     0x00 CTRL      [0]=start (W1S, self-clear), [1]=irq_en
//     0x04 STATUS    [0]=done (RO), [1]=illegal (RO), [2]=busy (RO)
//     0x08 PROG_BASE imem 載入位址（word index）
//     0x0C DATA_BASE dmem 基址（word index）
//     0x10 PROG_LEN  指令數
//     0x14 IRQ_ACK   W1C 中斷清除
// - 限制：單一 AXI master，無 burst（M2.0 DMA 處理）
// =============================================================================
module oh1_axi_lite #(
  parameter int LANES_P = 4,
  parameter int ADDR_W  = 32,
  parameter int DATA_W  = 32
)(
  input  logic                     clk_i,
  input  logic                     rst_ni,

  // AXI4-Lite slave
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

  // OH-1 core native interface
  output logic                     core_start_o,
  output logic [31:0]              core_start_pc_o,
  input  logic                     core_done_i,
  input  logic                     core_illegal_i,

  // IRQ
  output logic                     irq_o,

  // Memory backdoor（DMA/host 載入程式/資料）
  output logic                     mem_we_o,
  output logic                     mem_is_imem_o,   // 1=imem, 0=dmem
  output logic [31:0]              mem_addr_o,      // word index
  output logic [31:0]              mem_wdata_o,
  input  logic [31:0]              mem_rdata_i
);

  // ---- 暫存器 ----
  logic        ctrl_start, ctrl_irq_en;
  logic        status_done, status_illegal, status_busy;
  logic [31:0] prog_base, data_base, prog_len;

  // ---- 簡易 AXI 狀態機 ----
  typedef enum logic [2:0] {IDLE, WR_DATA, WR_RESP, RD_ADDR, RD_DATA} axi_state_t;
  axi_state_t axi_state;

  logic [ADDR_W-1:0] waddr_q, raddr_q;

  assign awready_o = (axi_state == IDLE);
  assign wready_o  = (axi_state == WR_DATA);
  assign arready_o = (axi_state == IDLE);
  assign bresp_o   = 2'b00;  // OKAY
  assign rresp_o   = 2'b00;

  // ---- 記憶體映射解碼 ----
  localparam logic [7:0] REG_CTRL      = 8'h00;
  localparam logic [7:0] REG_STATUS    = 8'h04;
  localparam logic [7:0] REG_PROG_BASE = 8'h08;
  localparam logic [7:0] REG_DATA_BASE = 8'h0C;
  localparam logic [7:0] REG_PROG_LEN  = 8'h10;
  localparam logic [7:0] REG_IRQ_ACK   = 8'h14;

  wire [7:0] wreg = waddr_q[7:0];
  wire [7:0] rreg = raddr_q[7:0];

  // 記憶體區域：0x1000_0000+ = imem, 0x2000_0000+ = dmem（word index）
  wire mem_wr_window = (waddr_q[31:28] == 4'h1) || (waddr_q[31:28] == 4'h2);
  wire mem_rd_window = (raddr_q[31:28] == 4'h1) || (raddr_q[31:28] == 4'h2);
  assign mem_is_imem_o = (waddr_q[31:28] == 4'h1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      axi_state    <= IDLE;
      ctrl_start   <= 1'b0;
      ctrl_irq_en  <= 1'b0;
      bvalid_o     <= 1'b0;
      rvalid_o     <= 1'b0;
      rdata_o      <= '0;
      mem_we_o     <= 1'b0;
      core_start_o <= 1'b0;
      irq_o        <= 1'b0;
    end else begin
      // 預設
      core_start_o <= 1'b0;
      mem_we_o     <= 1'b0;
      ctrl_start   <= 1'b0;  // self-clear

      case (axi_state)
        IDLE: begin
          if (awvalid_i && awready_o) begin
            waddr_q   <= awaddr_i;
            axi_state <= WR_DATA;
          end else if (arvalid_i && arready_o) begin
            raddr_q   <= araddr_i;
            axi_state <= RD_ADDR;
          end
        end

        WR_DATA: begin
          if (wvalid_i && wready_o) begin
            if (mem_wr_window) begin
              mem_we_o    <= 1'b1;
              mem_addr_o  <= waddr_q[27:0] >> 2;  // word index
              mem_wdata_o <= wdata_i;
            end else begin
              case (wreg)
                REG_CTRL:      ctrl_irq_en  <= wdata_i[1];
                REG_PROG_BASE: prog_base    <= wdata_i;
                REG_DATA_BASE: data_base    <= wdata_i;
                REG_PROG_LEN:  prog_len     <= wdata_i;
                REG_IRQ_ACK:   irq_o        <= 1'b0;
                default: ;
              endcase
            end
            axi_state <= WR_RESP;
          end
        end

        WR_RESP: begin
          bvalid_o <= 1'b1;
          if (bready_i) begin
            bvalid_o  <= 1'b0;
            axi_state <= IDLE;
          end
        end

        RD_ADDR: begin
          if (mem_rd_window) begin
            rdata_o <= mem_rdata_i;
          end else begin
            case (rreg)
              REG_CTRL:   rdata_o <= {30'b0, ctrl_irq_en, 1'b0};
              REG_STATUS: rdata_o <= {29'b0, status_busy, status_illegal, status_done};
              REG_PROG_BASE: rdata_o <= prog_base;
              REG_DATA_BASE: rdata_o <= data_base;
              REG_PROG_LEN:  rdata_o <= prog_len;
              default: rdata_o <= '0;
            endcase
          end
          axi_state <= RD_DATA;
        end

        RD_DATA: begin
          rvalid_o <= 1'b1;
          if (rready_i) begin
            rvalid_o  <= 1'b0;
            axi_state <= IDLE;
          end
        end
      endcase

      // start pulse：寫 CTRL[0]=1 觸發
      if (axi_state == WR_DATA && wvalid_i && wready_o && wreg == REG_CTRL && wdata_i[0]) begin
        core_start_o <= 1'b1;
      end

      // done 中斷
      if (core_done_i && ctrl_irq_en) begin
        irq_o <= 1'b1;
      end
    end
  end

  // ---- 狀態 ----
  assign status_done    = core_done_i;
  assign status_illegal = core_illegal_i;
  assign status_busy    = !core_done_i && !core_illegal_i;  // 簡化：running = not done

  assign core_start_pc_o = prog_base;  // 直接作為 start_pc

endmodule
