// =============================================================================
// OpenHelix OH-1 UVM 驗證介面（tb/oh1_if.sv）
// - DUT 訊號、imem/dmem 記憶體模型（backdoor API，sequence 載入程式用）
// - drv/mon clocking blocks
// - 訊號級 functional covergroups：執行指令種類×遮罩、redirect、LSU divergent
//   （FSM/堆疊深度覆蓋在 tb_top 以 XMR 採樣，需 DUT 階層參考）
// =============================================================================
`ifndef OH1_IF_SV
`define OH1_IF_SV

interface oh1_if (input logic clk);
  import oh1_pkg::*;

  // ---- DUT 訊號 ----
  logic        rst_n, start;
  logic [31:0] start_pc;
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_ren, dmem_wen;
  logic [31:0] dmem_raddr [LANES], dmem_rdata [LANES];
  logic [31:0] dmem_waddr [LANES], dmem_wdata [LANES];
  logic        exec_valid;
  logic [31:0] exec_pc;
  lane_mask_t  exec_mask, wb_lane_mask;
  logic        wb_valid;
  logic [4:0]  wb_rd;
  logic [31:0] wb_data [LANES];
  logic        done, illegal;

  localparam int PMEM_WORDS = 4096;   // 16KB 程式記憶體
  localparam int DMEM_WORDS = 4096;   // 16KB 資料記憶體

  // ---- 記憶體模型（與 tb_smoke 相同行為：imem comb、word-indexed dmem）----
  logic [31:0] pmem [PMEM_WORDS];
  logic [31:0] dmem [DMEM_WORDS];

  always_comb imem_rdata = pmem[imem_addr[31:2] & 32'hFFF];
  for (genvar gi = 0; gi < LANES; gi++) begin : g_dmem_rd
    always_comb dmem_rdata[gi] = dmem[dmem_raddr[gi][13:2] & 32'hFFF];
  end
  always_ff @(posedge clk) begin
    if (dmem_wen)
      for (int l = 0; l < LANES; l++)
        dmem[dmem_waddr[l][13:2] & 32'hFFF] <= dmem_wdata[l];
  end

  // ---- backdoor API ----
  function automatic void mem_clear();
    for (int i = 0; i < PMEM_WORDS; i++) pmem[i] = '0;
    for (int i = 0; i < DMEM_WORDS; i++) dmem[i] = '0;
  endfunction
  function automatic void write_pmem(input int idx, input logic [31:0] v);
    pmem[idx & 32'hFFF] = v;
  endfunction
  function automatic logic [31:0] read_pmem(input int idx);
    return pmem[idx & 32'hFFF];
  endfunction
  function automatic void write_dmem(input int idx, input logic [31:0] v);
    dmem[idx & 32'hFFF] = v;
  endfunction
  function automatic logic [31:0] read_dmem(input int idx);
    return dmem[idx & 32'hFFF];
  endfunction

  // ---- clocking blocks ----
  clocking drv_cb @(posedge clk);
    default input #1step output #2;
    output rst_n, start, start_pc;
    input  done, illegal;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input exec_valid, exec_pc, exec_mask, wb_valid, wb_rd, wb_lane_mask,
          wb_data, dmem_ren, dmem_wen, dmem_raddr, dmem_waddr, dmem_wdata,
          done, illegal, imem_addr;
  endclocking

  // =========================================================================
  // Functional coverage
  // =========================================================================

  // 執行指令種類 × 遮罩狀態（divergence 語意覆蓋核心）
  covergroup cg_exec @(posedge clk iff (rst_n && mon_cb.exec_valid));
    cp_kind: coverpoint dec_kind(read_pmem(mon_cb.exec_pc >> 2)) {
      bins r_type[] = {I_ADD, I_SUB, I_AND, I_OR, I_XOR, I_SLL, I_SRL, I_SRA, I_SLT, I_SLTU};
      bins i_type[] = {I_ADDI, I_ANDI, I_ORI, I_XORI, I_SLTI, I_SLTIU, I_SLLI, I_SRLI, I_SRAI};
      bins u_type[] = {I_LUI, I_AUIPC};
      bins mem[]    = {I_LW, I_SW};
      bins br[]     = {I_BEQ, I_BNE, I_BLT, I_BGE};
      bins ctrl[]   = {I_SPLIT, I_JOIN, I_TMC, I_BAR, I_CSRR, I_WEXIT, I_TEXIT};
    }
    cp_mask: coverpoint mon_cb.exec_mask {
      bins full   = {4'b1111};
      bins single[] = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
      bins pair[]   = {4'b0011, 4'b0101, 4'b0110, 4'b1001, 4'b1010, 4'b1100};
      bins triple[] = {4'b0111, 4'b1011, 4'b1101, 4'b1110};
    }
    cx_kind_mask: cross cp_kind, cp_mask;
  endgroup

  // redirect 偵測：連續有效執行的 PC 不連續 ⇒ 跳轉發生
  logic [31:0] prev_pc = '0;
  logic        prev_valid = 1'b0;
  int unsigned redirect_count = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      prev_valid <= 1'b0; redirect_count <= 0;
    end else if (mon_cb.exec_valid) begin
      if (prev_valid && (mon_cb.exec_pc != prev_pc + 32'd4)) redirect_count <= redirect_count + 1;
      prev_pc    <= mon_cb.exec_pc;
      prev_valid <= 1'b1;
    end
  end

  covergroup cg_redirect @(posedge clk iff (rst_n && mon_cb.exec_valid && prev_valid
                                            && (mon_cb.exec_pc != prev_pc + 32'd4)));
    cp_src_kind: coverpoint dec_kind(read_pmem(prev_pc >> 2)) {
      bins branch[] = {I_BEQ, I_BNE, I_BLT, I_BGE};
      bins split[]  = {I_SPLIT};
      bins join[]   = {I_JOIN};
    }
    cp_dir: coverpoint (mon_cb.exec_pc > prev_pc) {
      bins fwd = {1}; bins bwd = {0};
    }
    cx_src_dir: cross cp_src_kind, cp_dir;
  endgroup

  // 當前執行指令（comb，供 covergroup 取欄位）
  logic [31:0] exec_ins;
  always_comb exec_ins = read_pmem(exec_pc >> 2);

  // ---- 寫回覆蓋：rd × lane_mask × 資料值類別 ----
  covergroup cg_wb @(posedge clk iff (rst_n && wb_valid));
    cp_rd: coverpoint wb_rd {
      bins lo[] = {[1:7]};                 // 產生器實際使用區間
      bins hi   = {[8:31]};                // 其餘暫存器
    }
    cp_mask: coverpoint wb_lane_mask {
      bins full  = {4'b1111};
      bins single[] = {4'b0001, 4'b0010, 4'b0100, 4'b1000};
      bins multi[]  = {[3:14]};            // 2~3 lanes（自動細分）
    }
    cp_data0: coverpoint wb_data[0] {      // lane0 寫回值類別
      bins zero    = {0};
      bins one     = {1};
      bins small   = {[2:255]};
      bins neg     = {32'h8000_0000};
      bins allones = {32'hFFFF_FFFF};
      bins other   = default;
    }
    cx_rd_mask: cross cp_rd, cp_mask;
  endgroup

  // ---- 記憶體寫入覆蓋：資料值類別 × divergent ----
  covergroup cg_mem @(posedge clk iff (rst_n && dmem_wen));
    cp_wd_first: coverpoint dmem_wdata[0] {
      bins zero    = {0};
      bins one     = {1};
      bins small   = {[2:255]};
      bins neg     = {32'h8000_0000};
      bins allones = {32'hFFFF_FFFF};
      bins other   = default;
    }
    cp_wd_last: coverpoint dmem_wdata[LANES-1] {
      bins zero    = {0};
      bins small   = {[2:255]};
      bins other   = default;
    }
    cp_div: coverpoint ls_divergent { bins uni = {0}; bins div = {1}; }
    cx_wd_div: cross cp_wd_first, cp_div;
  endgroup

  // ---- CSR 存取覆蓋 ----
  covergroup cg_csr @(posedge clk iff (rst_n && exec_valid && dec_kind(exec_ins) == I_CSRR));
    cp_addr: coverpoint exec_ins[31:20] {
      bins tid     = {CSR_TID};
      bins laneid  = {CSR_LANEID};
      bins illegal = default;              // 監控：非既定 CSR 位址
    }
  endgroup

  // LSU divergent 位址偵測（任兩 lane 位址不同）
  logic ls_divergent;
  always_comb begin
    ls_divergent = 1'b0;
    for (int l = 1; l < LANES; l++)
      if ((dmem_raddr[l] != dmem_raddr[0]) ||
          (dmem_waddr[l] != dmem_waddr[0])) ls_divergent = 1'b1;
  end

  covergroup cg_lsu @(posedge clk iff (rst_n && (dmem_ren || dmem_wen)));
    cp_op: coverpoint {dmem_ren, dmem_wen} {
      bins rd = {2'b10}; bins wr = {2'b01};
    }
    cp_divergent: coverpoint ls_divergent { bins uni = {0}; bins div = {1}; }
    cp_lanes_active: coverpoint $countones(exec_mask) {
      bins one[] = {1, 2, 3, 4};
    }
    cx_op_div: cross cp_op, cp_divergent;
    cx_div_lanes: cross cp_divergent, cp_lanes_active;
  endgroup

  cg_exec     cov_exec     = new();
  cg_redirect cov_redirect = new();
  cg_lsu      cov_lsu      = new();
  cg_wb       cov_wb       = new();
  cg_mem      cov_mem      = new();
  cg_csr      cov_csr      = new();

endinterface
`endif // OH1_IF_SV
