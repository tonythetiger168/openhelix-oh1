// =============================================================================
// OpenHelix OH-1 UVM agent（tb/oh1_agent.sv）
// - oh1_exec_tr / oh1_wb_tr：monitor transactions
// - oh1_driver：backdoor 載入程式 → reset/start → 等待 done
// - oh1_monitor：exec/wb transaction 上 analysis port
// - oh1_agent：sqr + drv + mon
// =============================================================================
`ifndef OH1_AGENT_SV
`define OH1_AGENT_SV

// ---- 執行觀測 transaction ----
class oh1_exec_tr extends uvm_sequence_item;
  `uvm_object_utils(oh1_exec_tr)
  logic [31:0] pc;
  logic [31:0] ins;
  oh1_pkg::lane_mask_t mask;
  function new(string name = "oh1_exec_tr");
    super.new(name);
  endfunction
endclass

// ---- 寫回觀測 transaction ----
class oh1_wb_tr extends uvm_sequence_item;
  `uvm_object_utils(oh1_wb_tr)
  logic [31:0] pc;
  logic [4:0]  rd;
  oh1_pkg::lane_mask_t lane_mask;
  logic [31:0] data [oh1_pkg::LANES];
  function new(string name = "oh1_wb_tr");
    super.new(name);
  endfunction
endclass

// ---- driver ----
class oh1_driver extends uvm_driver #(oh1_prog_item);
  `uvm_component_utils(oh1_driver)
  virtual oh1_if vif;
  uvm_analysis_port #(oh1_prog_item) item_ap;   // 給 scoreboard（ISS 輸入）

  function new(string name, uvm_component parent);
    super.new(name, parent);
    item_ap = new("item_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(virtual oh1_if)::get(this, "", "vif", vif));
  endfunction

  task run_phase(uvm_phase phase);
    oh1_prog_item tr;
    forever begin
      seq_item_port.get_next_item(tr);
      drive_prog(tr);
      seq_item_port.item_done();
    end
  endtask

  task drive_prog(oh1_prog_item tr);
    // 載入程式與資料記憶體（backdoor）
    vif.mem_clear();
    foreach (tr.pmem[i]) vif.write_pmem(i, tr.pmem[i]);
    foreach (tr.dmem_init[i]) vif.write_dmem(tr.dmem_init[i].idx, tr.dmem_init[i].val);
    item_ap.write(tr);

    // reset → start
    vif.drv_cb.rst_n  <= 1'b0;
    vif.drv_cb.start  <= 1'b0;
    repeat (4) @vif.drv_cb;
    vif.drv_cb.rst_n  <= 1'b1;
    @vif.drv_cb;
    vif.drv_cb.start_pc <= tr.start_pc;
    vif.drv_cb.start    <= 1'b1;
    @vif.drv_cb;
    vif.drv_cb.start    <= 1'b0;

    wait (vif.drv_cb.done === 1'b1);
    repeat (4) @vif.drv_cb;   // 讓最後 wb settle
  endtask
endclass

// ---- monitor ----
class oh1_monitor extends uvm_monitor;
  `uvm_component_utils(oh1_monitor)
  virtual oh1_if vif;
  uvm_analysis_port #(oh1_exec_tr) exec_ap;
  uvm_analysis_port #(oh1_wb_tr)   wb_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    exec_ap = new("exec_ap", this);
    wb_ap   = new("wb_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(virtual oh1_if)::get(this, "", "vif", vif));
  endfunction

  task run_phase(uvm_phase phase);
    oh1_exec_tr et;
    oh1_wb_tr   wt;
    forever begin
      @vif.mon_cb;
      if (vif.mon_cb.exec_valid) begin
        et      = oh1_exec_tr::type_id::create("et");
        et.pc   = vif.mon_cb.exec_pc;
        et.ins  = vif.read_pmem(vif.mon_cb.exec_pc >> 2);
        et.mask = vif.mon_cb.exec_mask;
        exec_ap.write(et);
      end
      if (vif.mon_cb.wb_valid) begin
        wt           = oh1_wb_tr::type_id::create("wt");
        wt.pc        = vif.mon_cb.exec_pc;
        wt.rd        = vif.mon_cb.wb_rd;
        wt.lane_mask = vif.mon_cb.wb_lane_mask;
        foreach (wt.data[l]) wt.data[l] = vif.mon_cb.wb_data[l];
        wb_ap.write(wt);
      end
    end
  endtask
endclass

// ---- agent ----
class oh1_agent extends uvm_agent;
  `uvm_component_utils(oh1_agent)
  oh1_driver                          drv;
  oh1_monitor                         mon;
  uvm_sequencer #(oh1_prog_item)      sqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = uvm_sequencer#(oh1_prog_item)::type_id::create("sqr", this);
    drv = oh1_driver::type_id::create("drv", this);
    mon = oh1_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

`endif // OH1_AGENT_SV
