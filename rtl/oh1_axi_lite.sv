// =============================================================================
// OpenHelix OH-1 AXI4-Lite Slave Wrapper（M1.0 W2）
// - 把 OH-1 核心包裝為可掛系統匯流排的周邊
// - 暫存器：
//     0x00 CTRL      [0]=start (W1S, self-clear), [1]=irq_en
//     0x04 STATUS    [0]=done (RO), [1]=illegal (RO), [2]=busy (RO)
//     0x08 PROG_BASE imem 載入位址（word index）
//     0x0C DATA_BASE dmem 基址（word index）
//     0x10 PROG_LEN  指令數
//     0x14 IRQ_ACK   W1C 中斷清除
// - 記憶體窗口：0x1xxx_xxxx = imem, 0x2xxx_xxxx = dmem（word index）
// - 簡化 AXI-Lite：AW+W 同拍完成（不支援分開握手），無 burst
// =============================================================================
module oh1_axi_lite #(
  parameter int LANES_P = 4,
  parameter int ADDR_W  = 32,
  parameter int DATA_W  = 32
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

  output logic                     irq_o,

  output logic                     mem_we_o,
  output logic                     mem_is_imem_o,
  output logic [31:0]              mem_addr_o,
  output logic [31:0]              mem_wdata_o,
  input  logic [31:0]              mem_rdata_i
);

  logic        ctrl_irq_en;
  logic        status_done, status_illegal, status_busy;
  logic [31:0] prog_base, data_base, prog_len;

  typedef enum logic [2:0] {IDLE, WR_DATA, WR_RESP, RD_ADDR, RD_DATA} axi_state_t;
  axi_state_t axi_state;

  logic [ADDR_W-1:0] waddr_q, raddr_q;

  assign awready_o = (axi_state == IDLE);
  assign wready_o  = (axi_state == IDLE) || (axi_state == WR_DATA);
  assign arready_o = (axi_state == IDLE);
  assign bresp_o   = 2'b00;
  assign rresp_o   = 2'b00;

  localparam logic [7:0] REG_CTRL      = 8'h00;
  localparam logic [7:0] REG_STATUS    = 8'h04;
  localparam logic [7:0] REG_PROG_BASE = 8'h08;
  localparam logic [7:0] REG_DATA_BASE = 8'h0C;
  localparam logic [7:0] REG_PROG_LEN  = 8'h10;
  localparam logic [7:0] REG_IRQ_ACK   = 8'h14;

  wire [7:0] wreg = waddr_q[7:0];
  wire [7:0] rreg = raddr_q[7:0];

  wire mem_wr_window = (waddr_q[31:28] == 4'h1) || (waddr_q[31:28] == 4'h2);
  wire mem_rd_window = (raddr_q[31:28] == 4'h1) || (raddr_q[31:28] == 4'h2);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      axi_state     <= IDLE;
      ctrl_irq_en   <= 1'b0;
      bvalid_o      <= 1'b0;
      rvalid_o      <= 1'b0;
      rdata_o       <= '0;
      mem_we_o      <= 1'b0;
      mem_is_imem_o <= 1'b0;
      core_start_o  <= 1'b0;
      irq_o         <= 1'b0;
    end else begin
      // ---- 每週期脈衝訊號（default，case 內可覆蓋）----
      core_start_o <= 1'b0;
      mem_we_o     <= 1'b0;

      case (axi_state)
        // ---- 寫通道：AW+W 同拍（簡化 AXI-Lite）----
        IDLE: begin
          if (awvalid_i && awready_o && wvalid_i && wready_o) begin
            waddr_q <= awaddr_i;
            if (awaddr_i[31:28] == 4'h1 || awaddr_i[31:28] == 4'h2) begin
              mem_we_o      <= 1'b1;
              mem_addr_o    <= awaddr_i[27:0] >> 2;
              mem_wdata_o   <= wdata_i;
              mem_is_imem_o <= (awaddr_i[31:28] == 4'h1);
            end else begin
              case (awaddr_i[7:0])
                REG_CTRL:      ctrl_irq_en <= wdata_i[1];
                REG_PROG_BASE: prog_base   <= wdata_i;
                REG_DATA_BASE: data_base   <= wdata_i;
                REG_PROG_LEN:  prog_len    <= wdata_i;
                REG_IRQ_ACK:   irq_o       <= 1'b0;
                default: ;
              endcase
              if (awaddr_i[7:0] == REG_CTRL && wdata_i[0])
                core_start_o <= 1'b1;   // 覆蓋 default
            end
            axi_state <= WR_RESP;
          end else if (arvalid_i && arready_o) begin
            raddr_q   <= araddr_i;
            axi_state <= RD_ADDR;
          end
        end

        // ---- 相容分開握手：AW 先、W 後 ----
        WR_DATA: begin
          if (wvalid_i && wready_o) begin
            if (mem_wr_window) begin
              mem_we_o    <= 1'b1;    // 覆蓋 default
              mem_addr_o  <= waddr_q[27:0] >> 2;
              mem_wdata_o <= wdata_i;
            end else begin
              case (wreg)
                REG_CTRL:      ctrl_irq_en <= wdata_i[1];
                REG_PROG_BASE: prog_base   <= wdata_i;
                REG_DATA_BASE: data_base   <= wdata_i;
                REG_PROG_LEN:  prog_len    <= wdata_i;
                REG_IRQ_ACK:   irq_o       <= 1'b0;
                default: ;
              endcase
              if (wreg == REG_CTRL && wdata_i[0])
                core_start_o <= 1'b1;   // 覆蓋 default
            end
            axi_state <= WR_RESP;
          end
        end

        // ---- 寫回應：bvalid 保持到 bready ----
        WR_RESP: begin
          if (!bvalid_o) begin
            bvalid_o <= 1'b1;
          end else if (bready_i) begin
            bvalid_o  <= 1'b0;
            axi_state <= IDLE;
          end
        end

        // ---- 讀通道：先設位址 ----
        RD_ADDR: begin
          if (mem_rd_window) begin
            mem_addr_o    <= raddr_q[27:0] >> 2;
            mem_is_imem_o <= (raddr_q[31:28] == 4'h1);
          end
          axi_state <= RD_DATA;
        end

        // RD_DATA：組合讀取（mem_rdata 已是當前位址的資料）
        RD_DATA: begin
          if (!rvalid_o) begin
            if (mem_rd_window) begin
              rdata_o <= mem_rdata_i;   // mem_addr 已在 RD_ADDR 設好，此時穩定
            end else begin
              case (rreg)
                REG_CTRL:      rdata_o <= {30'b0, ctrl_irq_en, 1'b0};
                REG_STATUS:    rdata_o <= {29'b0, status_busy, status_illegal, status_done};
                REG_PROG_BASE: rdata_o <= prog_base;
                REG_DATA_BASE: rdata_o <= data_base;
                REG_PROG_LEN:  rdata_o <= prog_len;
                default:       rdata_o <= '0;
              endcase
            end
            rvalid_o <= 1'b1;
          end else if (rready_i) begin
            rvalid_o  <= 1'b0;
            axi_state <= IDLE;
          end
        end

        RD_DATA: begin
          if (!rvalid_o) begin
            rvalid_o <= 1'b1;
          end else if (rready_i) begin
            rvalid_o  <= 1'b0;
            axi_state <= IDLE;
          end
        end
      endcase

      // done 中斷（irq_en 時）
      if (core_done_i && ctrl_irq_en) begin
        irq_o <= 1'b1;
      end
    end
  end

  assign status_done    = core_done_i;
  assign status_illegal = core_illegal_i;
  assign status_busy    = !core_done_i && !core_illegal_i;

  assign core_start_pc_o = prog_base;

endmodule
