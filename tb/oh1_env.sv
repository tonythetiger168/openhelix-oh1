// =============================================================================
// OpenHelix OH-1 UVM env（tb/oh1_env.sv）
// =============================================================================
`ifndef OH1_ENV_SV
`define OH1_ENV_SV

class oh1_env extends uvm_env;
  `uvm_component_utils(oh1_env)

  oh1_agent      agt;
  oh1_scoreboard scb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agt = oh1_agent::type_id::create("agt", this);
    scb = oh1_scoreboard::type_id::create("scb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agt.drv.item_ap.connect(scb.item_export);
    agt.mon.exec_ap.connect(scb.exec_export);
    agt.mon.wb_ap.connect(scb.wb_export);
  endfunction

endclass
`endif // OH1_ENV_SV
