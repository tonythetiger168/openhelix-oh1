// =============================================================================
// OpenHelix OH-1 UVM tests（tb/oh1_tests.sv）
// - oh1_base_test：watchdog（預設 100k 週期未完成即 fatal）＋覆蓋率摘要報告
// - oh1_smoke_test / oh1_rand_test / oh1_stress_test
// =============================================================================
`ifndef OH1_TESTS_SV
`define OH1_TESTS_SV

class oh1_base_test extends uvm_test;
  `uvm_component_utils(oh1_base_test)

  oh1_env   env;
  virtual   oh1_if vif;
  int       max_cyc = 100000;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = oh1_env::type_id::create("env", this);
    void'(uvm_config_db#(virtual oh1_if)::get(this, "", "vif", vif));
    void'(uvm_config_db#(int)::get(this, "", "max_cyc", max_cyc));
  endfunction

  // 各 test 覆寫：回傳要跑的 sequence
  virtual task run_seq();
    `uvm_fatal(get_type_name(), "run_seq() not overridden")
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin : body
        run_seq();
      end
      begin : watchdog
        repeat (max_cyc) @(vif.clk);
        `uvm_fatal("WATCHDOG",
          $sformatf("program not done within %0d cycles", max_cyc))
      end
    join_any
    disable body;
    disable watchdog;
    repeat (10) @(vif.clk);   // settle
    phase.drop_objection(this);
  endtask

  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    if (vif != null) begin
      `uvm_info("COV",
        $sformatf("cg_exec     = %6.2f%%", vif.cov_exec.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_redirect = %6.2f%%", vif.cov_redirect.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_lsu      = %6.2f%%", vif.cov_lsu.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_fsm      = %6.2f%%", tb_top.u_cov.cg_fsm_i.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_stack    = %6.2f%%", tb_top.u_cov.cg_stack_i.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_wb       = %6.2f%%", vif.cov_wb.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_mem      = %6.2f%%", vif.cov_mem.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_csr      = %6.2f%%", vif.cov_csr.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_tmc      = %6.2f%%", tb_top.u_cov.cg_tmc_i.get_coverage()), UVM_LOW)
      `uvm_info("COV",
        $sformatf("cg_nest     = %6.2f%%", tb_top.u_cov.cg_nest_i.get_coverage()), UVM_LOW)
    end
  endfunction

endclass

class oh1_smoke_test extends oh1_base_test;
  `uvm_component_utils(oh1_smoke_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_seq();
    oh1_directed_smoke_seq seq = oh1_directed_smoke_seq::type_id::create("seq");
    seq.start(env.agt.sqr);
  endtask
endclass

class oh1_simd_test extends oh1_base_test;
  `uvm_component_utils(oh1_simd_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_seq();
    oh1_simd_seq seq = oh1_simd_seq::type_id::create("seq");
    seq.start(env.agt.sqr);
  endtask
endclass

class oh1_rand_test extends oh1_base_test;
  `uvm_component_utils(oh1_rand_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_seq();
    oh1_rand_seq seq = oh1_rand_seq::type_id::create("seq");
    void'(uvm_config_db#(int)::get(this, "", "n_prog", seq.n_prog));
    seq.start(env.agt.sqr);
  endtask
endclass

class oh1_stress_test extends oh1_base_test;
  `uvm_component_utils(oh1_stress_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_seq();
    oh1_stress_seq seq = oh1_stress_seq::type_id::create("seq");
    void'(uvm_config_db#(int)::get(this, "", "n_prog", seq.n_prog));
    seq.start(env.agt.sqr);
  endtask
endclass

`endif // OH1_TESTS_SV
