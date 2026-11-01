// =============================================================================
// OH-1 AXI4-Lite wrapper assertions + cover properties (bound into oh1_axi_lite)
// Same convention as oh1_core_sva.sv: a_* assertion, c_* antecedent cover, s_* scenario.
// =============================================================================
module oh1_axi_sva #(
  parameter int MEM_WORDS = 4096
) (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        awvalid_i, awready_o,
  input logic        wvalid_i,  wready_o,
  input logic [3:0]  wstrb_i,
  input logic        bvalid_o,  bready_i,
  input logic [1:0]  bresp_o,
  input logic        arvalid_i, arready_o,
  input logic        rvalid_o,  rready_i,
  input logic [1:0]  rresp_o,
  input logic [31:0] rdata_o,
  input logic        aw_full, w_full, ar_full,
  input logic        do_write, do_read,
  input logic [1:0]  rd_state,
  input logic        busy_q,
  input logic        core_start_o,
  input logic        core_done_i,
  input logic        done_d1,
  input logic        ctrl_irq_en,
  input logic [1:0]  irq_stat_q,
  input logic        irq_o,
  input logic        mem_we_o,
  input logic        mem_is_imem_o,
  input logic [31:0] mem_addr_o
);
  default clocking cb @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  // ---- AXI4-Lite handshake rules (slave side) ----
  a_bvalid_hold: assert property (bvalid_o && !bready_i |=> bvalid_o && $stable(bresp_o));
  c_bvalid_hold: cover property (bvalid_o && !bready_i);
  a_rvalid_hold: assert property (rvalid_o && !rready_i |=> rvalid_o && $stable(rresp_o) && $stable(rdata_o));
  c_rvalid_hold: cover property (rvalid_o && !rready_i);
  a_bresp_legal: assert property (bvalid_o |-> bresp_o != 2'b01);
  c_bresp_legal: cover property (bvalid_o);
  a_rresp_legal: assert property (rvalid_o |-> rresp_o != 2'b01);
  c_rresp_legal: cover property (rvalid_o);
  a_awready: assert property (awready_o == !aw_full);
  a_wready:  assert property (wready_o == !w_full);
  a_arready_idle: assert property (arready_o |-> rd_state == 2'd0 && !rvalid_o && !ar_full);
  c_arready_idle: cover property (arready_o);
  a_write_resp: assert property (do_write |=> bvalid_o);
  c_write_resp: cover property (do_write);
  // one outstanding read: a new AR is never held while R is still pending
  a_one_read: assert property (!(ar_full && rvalid_o));
  a_write_prio: assert property (do_write |-> !do_read);
  c_write_prio: cover property (do_write && ar_full && !rvalid_o);
  a_mem_read_seq: assert property (rd_state == 2'd1 |=> rd_state == 2'd2 ##1 rvalid_o && rd_state == 2'd0);
  c_mem_read_seq: cover property (rd_state == 2'd1);

  // ---- control / status ----
  a_start_pulse: assert property (core_start_o |=> !core_start_o);
  c_start_pulse: cover property (core_start_o);
  a_start_busy:  assert property (core_start_o |-> busy_q);
  c_start_busy:  cover property (core_start_o ##[1:$] !busy_q);
  a_busy_clear:  assert property (busy_q && !core_start_o && core_done_i && !done_d1 |=> !busy_q);
  c_busy_clear:  cover property (busy_q && !core_start_o && core_done_i && !done_d1);
  a_irq_level:   assert property (irq_o == (ctrl_irq_en && irq_stat_q != 2'b00));
  a_done_event:  assert property (core_done_i && !done_d1 |=> irq_stat_q[0]);
  c_done_event:  cover property (core_done_i && !done_d1);
  a_mem_range:   assert property (mem_we_o |-> mem_addr_o < MEM_WORDS);
  c_mem_range:   cover property (mem_we_o);
  a_imem_locked: assert property (mem_we_o && mem_is_imem_o |-> !$past(busy_q));
  c_imem_locked: cover property (mem_we_o && mem_is_imem_o);

  // ---- FSMs (the simulator instruments only the first enum case per always block, which in
  //      oh1_axi_lite is the address decoder, so rd_state is enumerated here) ----
  // read FSM rd_state: IDLE=0, MEM_WAIT=1, MEM_SAMPLE=2
  a_rd_legal: assert property (rd_state != 2'd3);
  f_rd_st_idle:   cover property (rd_state == 2'd0);
  f_rd_st_wait:   cover property (rd_state == 2'd1);
  f_rd_st_sample: cover property (rd_state == 2'd2);
  f_rd_idle_idle: cover property (rd_state == 2'd0 ##1 rd_state == 2'd0);
  f_rd_idle_wait: cover property (rd_state == 2'd0 ##1 rd_state == 2'd1);
  f_rd_wait_sample: cover property (rd_state == 2'd1 ##1 rd_state == 2'd2);
  f_rd_sample_idle: cover property (rd_state == 2'd2 ##1 rd_state == 2'd0);
  f_rd_wait_rst:  cover property (@(posedge clk_i) disable iff (1'b0) $past(rd_state) == 2'd1 && !rst_ni);
  a_rd_idle_arcs: assert property (rd_state == 2'd0 |=> rd_state inside {2'd0, 2'd1});
  // write-address/data holding FSM {aw_full, w_full}
  f_wr_00_00: cover property ({aw_full, w_full} == 2'b00 ##1 {aw_full, w_full} == 2'b00);
  f_wr_00_10: cover property ({aw_full, w_full} == 2'b00 ##1 {aw_full, w_full} == 2'b10);
  f_wr_00_01: cover property ({aw_full, w_full} == 2'b00 ##1 {aw_full, w_full} == 2'b01);
  f_wr_00_11: cover property ({aw_full, w_full} == 2'b00 ##1 {aw_full, w_full} == 2'b11);
  f_wr_10_10: cover property ({aw_full, w_full} == 2'b10 ##1 {aw_full, w_full} == 2'b10);
  f_wr_10_11: cover property ({aw_full, w_full} == 2'b10 ##1 {aw_full, w_full} == 2'b11);
  f_wr_01_01: cover property ({aw_full, w_full} == 2'b01 ##1 {aw_full, w_full} == 2'b01);
  f_wr_01_11: cover property ({aw_full, w_full} == 2'b01 ##1 {aw_full, w_full} == 2'b11);
  f_wr_11_11: cover property ({aw_full, w_full} == 2'b11 ##1 {aw_full, w_full} == 2'b11);
  f_wr_11_00: cover property ({aw_full, w_full} == 2'b11 ##1 {aw_full, w_full} == 2'b00);
  a_wr_arcs: assert property ({aw_full, w_full} == 2'b11 |=> {aw_full, w_full} inside {2'b11, 2'b00});
  // busy FSM
  f_busy_0_1: cover property (!busy_q ##1 busy_q);
  f_busy_1_0: cover property (busy_q ##1 !busy_q);
  f_busy_1_1: cover property (busy_q ##1 busy_q);
  f_busy_0_0: cover property (!busy_q ##1 !busy_q);
  f_busy_1_rst: cover property (@(posedge clk_i) disable iff (1'b0) $past(busy_q) && !rst_ni);

  // ---- scenario covers ----
  s_aw_before_w:     cover property (aw_full && !w_full && wvalid_i);
  s_w_before_aw:     cover property (w_full && !aw_full && awvalid_i);
  s_aw_w_together:   cover property (awvalid_i && awready_o && wvalid_i && wready_o);
  s_both_full_wait:  cover property (aw_full && w_full && bvalid_o);
  s_read_wait_write: cover property (ar_full && do_write);
  s_bresp_slverr:    cover property (bvalid_o && bresp_o == 2'b10);
  s_bresp_decerr:    cover property (bvalid_o && bresp_o == 2'b11);
  s_rresp_slverr:    cover property (rvalid_o && rresp_o == 2'b10);
  s_rresp_decerr:    cover property (rvalid_o && rresp_o == 2'b11);
  s_irq_raise:       cover property (!irq_o ##1 irq_o);
  s_irq_clear:       cover property (irq_o ##1 !irq_o && irq_stat_q == 2'b00);
  s_irq_both_events: cover property (irq_stat_q == 2'b11);
  s_partial_strobe:  cover property (wvalid_i && wready_o && wstrb_i != 4'hF && wstrb_i != 4'h0);
  s_zero_strobe:     cover property (wvalid_i && wready_o && wstrb_i == 4'h0);
endmodule

bind oh1_axi_lite oh1_axi_sva #(.MEM_WORDS(MEM_WORDS)) u_axi_sva (.*);
