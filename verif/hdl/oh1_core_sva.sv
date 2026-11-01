// =============================================================================
// OH-1 core assertions + cover properties (bound into every oh1_core instance)
//
// Convention: every `a_*` assertion has a matching `c_*` cover on its antecedent,
// so a passing run also proves the assertion was exercised (non-vacuous).
// `s_*` covers are extra scenario targets for coverage closure.
// =============================================================================
module oh1_core_sva import oh1_pkg::*; #(
  parameter int LANES_P = 4,
  parameter int STK_P   = 8
) (
  input logic                         clk_i,
  input logic                         rst_ni,
  input logic                         start_i,
  input logic [31:0]                  start_pc_i,
  input logic                         active_q,
  input logic                         done_q,
  input logic                         ill_q,
  input logic                         ovf_q,
  input logic                         ex_vld_q,
  input logic [31:0]                  if_pc_q,
  input logic [31:0]                  ex_pc_q,
  input oh1_pkg::ikind_e              kind,
  input logic [4:0]                   rd_d,
  input logic                         ill_d,
  input lane_mask_t                   act_mask_q,
  input logic [$clog2(STK_P+1)-1:0]   stk_ptr_q,
  input logic                         push_en_c,
  input logic                         push_two_c,
  input logic                         pop_en_c,
  input logic                         stk_full_c,
  input logic                         stk_top_tag,
  input logic                         redirect_en_c,
  input logic                         jalr_div_c,
  input logic [LANES_P-1:0]           pred_vec,
  input logic [LANES_P-1:0]           cond_vec,
  input logic                         exec_valid_o,
  input logic                         wb_valid_o,
  input logic                         dmem_ren_o,
  input logic                         dmem_wen_o,
  input lane_mask_t                   dmem_wmask_o,
  input logic [31:0]                  rf_q [LANES_P][32],
  input logic                         stk_tag_q  [STK_P],
  input lane_mask_t                   stk_mask_q [STK_P],
  input logic [31:0]                  stk_pc_q   [STK_P]
);

  logic launch, live;
  assign launch = start_i && (!active_q || done_q);
  assign live   = ex_vld_q && !done_q;

  default clocking cb @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  // ---- launch / run / done control ----
  a_launch: assert property (launch |=> active_q && !done_q && !ill_q && !ovf_q && !ex_vld_q
                                       && if_pc_q == $past(start_pc_i) && act_mask_q == '1
                                       && stk_ptr_q == '0);
  c_launch: cover property (launch);
  a_relaunch_ok: assert property (launch && done_q |=> active_q && !done_q);
  c_relaunch_ok: cover property (launch && done_q);
  a_start_ignored: assert property (start_i && active_q && !done_q && live && kind != I_WEXIT
                                    && kind != I_TEXIT |=> !done_q && active_q);
  c_start_ignored: cover property (start_i && active_q && !done_q && live && kind != I_WEXIT
                                   && kind != I_TEXIT);
  a_exec_needs_active: assert property (exec_valid_o |-> active_q && !done_q);
  c_exec_needs_active: cover property (exec_valid_o);
  a_idle_quiet: assert property (!active_q |-> !exec_valid_o && !dmem_wen_o && !dmem_ren_o);
  c_idle_quiet: cover property (!active_q);
  a_exit_done: assert property (live && (kind == I_WEXIT || kind == I_TEXIT) && !launch |=> done_q);
  c_exit_done: cover property (live && (kind == I_WEXIT || kind == I_TEXIT));
  a_done_sticky: assert property (done_q && !launch |=> done_q);
  c_done_sticky: cover property (done_q && !launch);
  a_done_quiet: assert property (done_q |-> !exec_valid_o && !wb_valid_o && !dmem_wen_o && !dmem_ren_o);
  c_done_quiet: cover property (done_q);

  // ---- faults ----
  a_ill_decode: assert property (live && ill_d && !launch |=> ill_q);
  c_ill_decode: cover property (live && ill_d);
  a_ill_jalr_div: assert property (live && kind == I_JALR && jalr_div_c && !launch |=> ill_q);
  c_ill_jalr_div: cover property (live && kind == I_JALR && jalr_div_c);
  a_ill_sticky: assert property (ill_q && !launch |=> ill_q);
  c_ill_sticky: cover property (ill_q && !launch);
  a_ovf_set: assert property (live && push_en_c && stk_full_c && !launch |=> ovf_q && $stable(stk_ptr_q));
  c_ovf_set: cover property (live && push_en_c && stk_full_c);
  a_ovf_sticky: assert property (ovf_q && !launch |=> ovf_q);
  c_ovf_sticky: cover property (ovf_q && !launch);

  // ---- divergence stack ----
  a_stk_bound: assert property (stk_ptr_q <= STK_P);
  c_stk_full: cover property (stk_ptr_q == STK_P);
  a_push_one: assert property (live && push_en_c && !push_two_c && !stk_full_c && !launch
                               |=> stk_ptr_q == $past(stk_ptr_q) + 1);
  c_push_one: cover property (live && push_en_c && !push_two_c && !stk_full_c);
  a_push_two: assert property (live && push_en_c && push_two_c && !stk_full_c && !launch
                               |=> stk_ptr_q == $past(stk_ptr_q) + 2);
  c_push_two: cover property (live && push_en_c && push_two_c && !stk_full_c);
  a_pop: assert property (live && pop_en_c && !launch |=> stk_ptr_q == $past(stk_ptr_q) - 1);
  c_pop: cover property (live && pop_en_c);
  a_pop_needs_entry: assert property (pop_en_c |-> stk_ptr_q != '0);
  c_pop_needs_entry: cover property (pop_en_c && live);
  a_split_subset: assert property (live && kind == I_SPLIT && !launch
                                   |=> (act_mask_q & ~$past(act_mask_q)) == '0);
  c_split_subset: cover property (live && kind == I_SPLIT);

  // ---- masks / writeback / LSU ----
  a_tmc_contig: assert property (live && kind == I_TMC && !launch
                                 |=> act_mask_q inside {4'b0000, 4'b0001, 4'b0011, 4'b0111, 4'b1111});
  c_tmc_contig: cover property (live && kind == I_TMC);
  a_wb_not_x0: assert property (wb_valid_o |-> rd_d != 5'd0 && live);
  c_wb_not_x0: cover property (wb_valid_o);
  a_store_mask: assert property (dmem_wen_o |-> live && kind == I_SW && dmem_wmask_o == act_mask_q
                                                && act_mask_q != '0);
  c_store_mask: cover property (dmem_wen_o);
  a_load_live: assert property (dmem_ren_o |-> live && kind == I_LW);
  c_load_live: cover property (dmem_ren_o);
  a_redirect_bubble: assert property (live && redirect_en_c && !launch |=> !ex_vld_q);
  c_redirect_bubble: cover property (live && redirect_en_c);

  // Entry 0 is only ever written as the tag half of a push at depth 0, so it is
  // always a tag entry holding a lane-0-based contiguous mask (launch/TMC masks)
  a_stk0_tag: assert property (stk_ptr_q != '0 |-> stk_tag_q[0] && stk_pc_q[0] == 32'd0
                               && stk_mask_q[0] inside {4'b0001, 4'b0011, 4'b0111, 4'b1111});
  c_stk0_tag: cover property (stk_ptr_q != '0);

  for (genvar l = 0; l < LANES_P; l++) begin : g_x0
    a_x0_zero: assert property (rf_q[l][0] == 32'd0);
  end

  // ---- control FSM {active_q, done_q}: IDLE=00, RUN=10, DONE=11 (01 is illegal) ----
  // The automatic FSM extraction of the simulator finds no enum state register in oh1_core,
  // so the states and arcs are enumerated here and reported as FSM coverage (f_*).
  logic [1:0] fsm_q;
  assign fsm_q = {active_q, done_q};
  a_fsm_legal: assert property (fsm_q != 2'b01);
  f_core_st_idle: cover property (fsm_q == 2'b00);
  f_core_st_run:  cover property (fsm_q == 2'b10);
  f_core_st_done: cover property (fsm_q == 2'b11);
  f_core_idle_idle: cover property (fsm_q == 2'b00 ##1 fsm_q == 2'b00);
  f_core_idle_run:  cover property (fsm_q == 2'b00 ##1 fsm_q == 2'b10);
  f_core_run_run:   cover property (fsm_q == 2'b10 ##1 fsm_q == 2'b10);
  f_core_run_done:  cover property (fsm_q == 2'b10 ##1 fsm_q == 2'b11);
  f_core_done_done: cover property (fsm_q == 2'b11 ##1 fsm_q == 2'b11);
  f_core_done_run:  cover property (fsm_q == 2'b11 ##1 fsm_q == 2'b10);
  // reset arcs (async reset): sampled without disable iff
  f_core_run_rst:  cover property (@(posedge clk_i) disable iff (1'b0) $past(fsm_q) == 2'b10 && fsm_q == 2'b00);
  f_core_done_rst: cover property (@(posedge clk_i) disable iff (1'b0) $past(fsm_q) == 2'b11 && fsm_q == 2'b00);
  a_fsm_arcs: assert property (fsm_q == 2'b00 |=> fsm_q inside {2'b00, 2'b10});
  a_fsm_arcs_run: assert property (fsm_q == 2'b10 |=> fsm_q inside {2'b10, 2'b11});

  // ---- scenario covers ----
  s_split_all_true:  cover property (live && kind == I_SPLIT && !push_en_c && act_mask_q != '0);
  s_split_all_false: cover property (live && kind == I_SPLIT && push_en_c && !push_two_c);
  s_split_empty:     cover property (live && kind == I_SPLIT && act_mask_q == '0);
  s_join_else:       cover property (live && pop_en_c && !stk_top_tag);
  s_join_tag:        cover property (live && pop_en_c && stk_top_tag);
  s_join_empty:      cover property (live && kind == I_JOIN && stk_ptr_q == '0);
  s_ovf_push_two:    cover property (live && push_en_c && push_two_c && stk_full_c);
  s_ovf_push_one:    cover property (live && push_en_c && !push_two_c && stk_full_c);
  s_tmc_zero:        cover property (live && kind == I_TMC ##1 act_mask_q == '0);
  s_exec_no_lane:    cover property (exec_valid_o && act_mask_q == '0);
  s_branch_taken:    cover property (live && kind inside {I_BEQ, I_BNE, I_BLT, I_BGE} && redirect_en_c);
  s_branch_not_taken:cover property (live && kind inside {I_BEQ, I_BNE, I_BLT, I_BGE} && !redirect_en_c);
  s_branch_divergent:cover property (live && kind inside {I_BEQ, I_BNE, I_BLT, I_BGE}
                                     && (act_mask_q & cond_vec) != '0 && (act_mask_q & ~cond_vec) != '0);
  s_store_partial:   cover property (dmem_wen_o && act_mask_q != '1);
  // a start pulse in the same cycle as WEXIT/TEXIT is dropped (core is not yet done)
  a_start_at_exit: assert property (start_i && live && (kind == I_WEXIT || kind == I_TEXIT)
                                    |=> done_q && active_q);
  c_start_at_exit: cover property (start_i && live && (kind == I_WEXIT || kind == I_TEXIT));
  s_launch_restart_after_fault: cover property (launch && done_q && (ill_q || ovf_q));
endmodule

bind oh1_core oh1_core_sva #(.LANES_P(LANES_P), .STK_P(STK_P)) u_core_sva (.*);
