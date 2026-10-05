// =============================================================================
// OpenHelix OH-1 UVM tb_top（tb/tb_top.sv）
// - DUT 實例＋interface 連接
// - SVA bind：7 assertions（安全/一致性情質）＋8 cover property（情境覆蓋）
// - FSM/堆疊深度覆蓋（XMR 採樣 DUT 內部）
// - 覆蓋率收集：line/toggle/fsm/assert 由模擬器旗標收集（見 Makefile cov target）
//   執行：make sim SIM=vcs TEST=oh1_rand_test  /  make cov TEST=oh1_stress_test
// =============================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// SVA：bind 進 oh1_core，可直接引用 host 內部訊號
// ---------------------------------------------------------------------------
module oh1_sva;
  import oh1_pkg::*;

  // 安全：done 後不再有任何 WB/LSU 活動，且 done 保持
  ast_done_quiet: assert property (@(posedge clk_i) disable iff (!rst_ni)
    done_o |-> (!wb_valid_o && !dmem_ren_o && !dmem_wen_o))
    else $error("[SVA] activity after done");
  ast_done_hold: assert property (@(posedge clk_i) disable iff (!rst_ni)
    done_o |=> done_o)
    else $error("[SVA] done not held");

  // 安全：分歧堆疊不越界/不 pop 空堆疊；推 2 前有足夠空間
  ast_stk_bounds: assert property (@(posedge clk_i) disable iff (!rst_ni)
    stk_ptr_q <= DIV_STK_DEPTH)
    else $error("[SVA] stack pointer overflow");
  ast_stk_no_pop_empty: assert property (@(posedge clk_i) disable iff (!rst_ni)
    pop_en_c |-> (stk_ptr_q != 0))
    else $error("[SVA] pop from empty stack");
  ast_stk_push_room: assert property (@(posedge clk_i) disable iff (!rst_ni)
    push_two_c |-> (stk_ptr_q <= DIV_STK_DEPTH - 2))
    else $error("[SVA] push_two exceeds stack depth");

  // 一致：redirect 目標字對齊、IF PC 字對齊
  ast_redirect_aligned: assert property (@(posedge clk_i) disable iff (!rst_ni)
    (redirect_en_c && ex_vld_q) |-> (redirect_pc_c[1:0] == 2'b00))
    else $error("[SVA] redirect target misaligned");
  ast_pc_aligned: assert property (@(posedge clk_i) disable iff (!rst_ni)
    active_q |-> (imem_addr_o[1:0] == 2'b00))
    else $error("[SVA] imem addr misaligned");

  // 一致：空遮罩不得執行（TMC 除外，其為合法清空遮罩指令）；
  // split 的 then 遮罩為原遮罩子集
  ast_no_empty_exec: assert property (@(posedge clk_i) disable iff (!rst_ni)
    (ex_vld_q && (kind != I_TMC)) |-> (act_mask_q != '0))
    else $error("[SVA] execute with empty mask");
  ast_split_subset: assert property (@(posedge clk_i) disable iff (!rst_ni)
    (ex_vld_q && (kind == I_SPLIT)) |->
      ($countones(next_act_c) <= $countones(act_mask_q)))
    else $error("[SVA] split then-mask not subset");

  // ------- assertion coverage：關鍵情境必須發生過 -------
  cov_branch_taken: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind inside {I_BEQ, I_BNE, I_BLT, I_BGE}) && redirect_en_c);
  cov_branch_fallthrough: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind inside {I_BEQ, I_BNE, I_BLT, I_BGE}) && !redirect_en_c);
  cov_split_mixed: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_SPLIT) && push_two_c);          // 有 then 有 else
  cov_split_all_false: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_SPLIT) && redirect_en_c);       // 全假→直接跳 else
  cov_split_all_true: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_SPLIT) && !push_en_c);          // 全真→不推堆疊
  cov_join_else_redirect: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_JOIN) && redirect_en_c);        // pop 到 else entry
  cov_join_tag_restore: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_JOIN) && pop_en_c && stk_top_tag); // pop 到 tag
  cov_tmc_shrink: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_TMC) &&
      ($countones(next_act_c) < $countones(act_mask_q)));
  cov_lw_divergent: cover property (@(posedge clk_i) disable iff (!rst_ni)
    dmem_ren_o && (dmem_raddr_o[0] != dmem_raddr_o[LANES-1]));
  cov_sw_divergent: cover property (@(posedge clk_i) disable iff (!rst_ni)
    dmem_wen_o && (dmem_waddr_o[0] != dmem_waddr_o[LANES-1]));

  // ---- TMC 深化：零遮罩/成長/持平/clamp ----
  cov_tmc_zero: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_TMC) && (next_act_c == '0));
  cov_tmc_grow: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_TMC) &&
      ($countones(next_act_c) > $countones(act_mask_q)));
  cov_tmc_equal: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_TMC) &&
      ($countones(next_act_c) == $countones(act_mask_q)));
  cov_tmc_clamp: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_TMC) && (tmc_rs1_w >= LANES_P));
  // 深層分歧：堆疊已有 ≥2 個活躍 split（≥4 entry）時再 split
  cov_split_at_depth: cover property (@(posedge clk_i) disable iff (!rst_ni)
    ex_vld_q && (kind == I_SPLIT) && (stk_ptr_q >= 4));
  // 堆疊縮小轉移（join pop 生效）
  cov_stack_shrink: cover property (@(posedge clk_i) disable iff (!rst_ni)
    pop_en_c |=> (stk_ptr_q < $past(stk_ptr_q)));

  // ------- 追加 assertions：RTL 結構不變量 -------
  // TMC 結果遮罩必為低位連續 1（n-lanes ones-mask，無空洞）
  ast_tmc_ones_mask: assert property (@(posedge clk_i) disable iff (!rst_ni)
    (ex_vld_q && (kind == I_TMC)) |-> ((next_act_c & (next_act_c + 4'd1)) == 4'b0))
    else $error("[SVA] tmc mask not contiguous low ones");

  // 推入/彈出遮罩必非空（堆疊只存有意義的遮罩）
  ast_push_mask_nonempty: assert property (@(posedge clk_i) disable iff (!rst_ni)
    push_en_c |-> (push_mask_c != '0))
    else $error("[SVA] push empty mask");
  ast_pop_mask_nonempty: assert property (@(posedge clk_i) disable iff (!rst_ni)
    pop_en_c |-> (stk_top_mask != '0))
    else $error("[SVA] pop empty mask entry");

  // start 下一週期必進 RUN；RUN 與 DONE 互斥
  ast_start2active: assert property (@(posedge clk_i) disable iff (!rst_ni)
    $rose(start_i) |=> active_q)
    else $error("[SVA] start did not activate");
  ast_run_done_mutex: assert property (@(posedge clk_i) disable iff (!rst_ni)
    active_q |-> !done_q)
    else $error("[SVA] active and done overlap");

  // done 時所有 lane 的 x0 恆為 0（RTL 抑制 rd==0 寫入）
  for (genvar gl = 0; gl < LANES_P; gl++) begin : g_x0_zero
    ast_x0_zero: assert property (@(posedge clk_i) disable iff (!rst_ni)
      done_o |-> (rf_q[gl][0] == 32'd0))
      else $error("[SVA] x0 clobbered");
  end

endmodule

// ---------------------------------------------------------------------------
// FSM / 堆疊深度覆蓋（需 DUT 內部狀態 → XMR）
// ---------------------------------------------------------------------------
module oh1_cov_dut (input logic clk, input logic rst_n);
  import oh1_pkg::*;

  logic [1:0] fsm_state;
  always_comb fsm_state = {tb_top.dut.active_q, tb_top.dut.done_q};

  covergroup cg_fsm @(posedge clk iff rst_n);
    cp_state: coverpoint fsm_state {
      bins idle = {2'b00};
      bins run  = {2'b10};
      bins done = {2'b01, 2'b11};
    }
    cp_trans: coverpoint fsm_state {
      bins idle2run  = (2'b00 => 2'b10);
      bins run2done  = (2'b10 => 2'b01);
      bins done2idle = (2'b01 => 2'b00);   // reset 換程式
      bins run2idle  = (2'b10 => 2'b00);   // reset 中斷
    }
  endgroup

  covergroup cg_stack @(posedge clk iff (rst_n && tb_top.dut.active_q));
    cp_depth: coverpoint tb_top.dut.stk_ptr_q {
      bins d[] = {[0:6]};                 // 每層深度（每 split 佔 2）
      bins d7  = {7}; bins d8 = {8};      // 滿栈/近滿（stress 巢狀 3 + flat 區塊可達）
    }
    cp_act_cnt: coverpoint $countones(tb_top.dut.act_mask_q) {
      bins c[] = {[0:4]};                 // 含 tmc 清空的 0-lane
    }
    cx_depth_act: cross cp_depth, cp_act_cnt;
  endgroup

  // ---- TMC 功能覆蓋（XMR：tmc_rs1_w / next_act_c 為 DUT 內部）----
  covergroup cg_tmc @(posedge clk iff (rst_n && tb_top.dut.ex_vld_q && tb_top.dut.kind == I_TMC));
    cp_tmc_n: coverpoint tb_top.dut.tmc_rs1_w {
      bins zero  = {0};
      bins n[]   = {[1:LANES-1]};
      bins clamp = {[LANES:31]};          // 超界 clamp 到全 lane
    }
    cp_delta: coverpoint
        ($countones(tb_top.dut.next_act_c) - $countones(tb_top.dut.act_mask_q)) {
      bins shrink[] = {-4, -3, -2, -1};
      bins same     = {0};
      bins grow[]   = {1, 2, 3, 4};
    }
    cp_lane0_act: coverpoint tb_top.dut.act_mask_q[0] {
      bins inactive = {0}; bins active = {1};   // lane0 不活躍時 tmc 取值的角落
    }
    cx_n_lane0: cross cp_tmc_n, cp_lane0_act;
  endgroup

  // ---- 分歧巢狀實績：split 發生時的即時堆疊深度 ----
  covergroup cg_nest @(posedge clk iff (rst_n && tb_top.dut.ex_vld_q && tb_top.dut.kind == I_SPLIT));
    cp_ptr_at_split: coverpoint tb_top.dut.stk_ptr_q {
      bins d0 = {0}; bins d1 = {2};
      bins d2 = {4}; bins d3 = {6};
    }
    cp_act_cnt: coverpoint $countones(tb_top.dut.act_mask_q) {
      bins c[] = {[1:4]};
    }
    cx_nest_act: cross cp_ptr_at_split, cp_act_cnt;
  endgroup

  cg_fsm   cg_fsm_i   = new();
  cg_stack cg_stack_i = new();
  cg_tmc   cg_tmc_i   = new();
  cg_nest  cg_nest_i  = new();
endmodule

// ---------------------------------------------------------------------------
// tb_top
// ---------------------------------------------------------------------------
module tb_top;
  import uvm_pkg::*;
  import oh1_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  oh1_if vif (clk);

  oh1_core #(.LANES_P(LANES)) dut (
    .clk_i          (clk),
    .rst_ni         (vif.rst_n),
    .start_i        (vif.start),
    .start_pc_i     (vif.start_pc),
    .imem_addr_o    (vif.imem_addr),
    .imem_rdata_i   (vif.imem_rdata),
    .dmem_ren_o     (vif.dmem_ren),
    .dmem_raddr_o   (vif.dmem_raddr),
    .dmem_rdata_i   (vif.dmem_rdata),
    .dmem_wen_o     (vif.dmem_wen),
    .dmem_waddr_o   (vif.dmem_waddr),
    .dmem_wdata_o   (vif.dmem_wdata),
    .exec_valid_o   (vif.exec_valid),
    .exec_pc_o      (vif.exec_pc),
    .exec_mask_o    (vif.exec_mask),
    .wb_valid_o     (vif.wb_valid),
    .wb_rd_o        (vif.wb_rd),
    .wb_lane_mask_o (vif.wb_lane_mask),
    .wb_data_o      (vif.wb_data),
    .done_o         (vif.done),
    .illegal_o      (vif.illegal)
  );

  bind oh1_core oh1_sva u_sva();

  oh1_cov_dut u_cov (.clk(clk), .rst_n(vif.rst_n));

  initial begin
    uvm_config_db#(virtual oh1_if)::set(null, "uvm_test_top.env.agt*", "vif", vif);
    uvm_config_db#(virtual oh1_if)::set(null, "uvm_test_top.env.scb", "vif", vif);
    run_test();
  end

  // 全域超時（watchdog 之外的底線）
  initial begin
    #50ms;
    $fatal(1, "[tb_top] global timeout");
  end

endmodule
