// =============================================================================
// OpenHelix OH-1 CRV sequence library（tb/oh1_seq_lib.sv）
// - oh1_prog_item：受約束隨機「程式」transaction（knobs + build() 結構化產生）
// - 產生器保證結構合法性（CRV 約束重點）：
//   * split/join 靜態配平：每個 split 配兩個 join（then 尾、else 尾），imm 偏移自動計算
//   * 分支目標界內且字對齊（imm 為半字組，enc_btype 傳 byte_off/2）
//   * LW/SW 字對齊：基址 x6 = tid*4（slli），imm 4 的倍數
//   * tmc 值域 0..LANES
//   * 巢狀深度上限 3（堆疊每層佔 2 entry，上限 3 → 最多 6/8，不觸頂）
// - sequences：directed smoke / rand / stress
// =============================================================================
`ifndef OH1_SEQ_LIB_SV
`define OH1_SEQ_LIB_SV

// ---- dmem 初始化 entry ----
class oh1_dmem_init extends uvm_object;
  `uvm_object_utils(oh1_dmem_init)
  int unsigned idx;
  logic [31:0] val;
  function new(string name = "oh1_dmem_init");
    super.new(name);
  endfunction
endclass

// ---- program item ----
class oh1_prog_item extends uvm_sequence_item;
  `uvm_object_utils(oh1_prog_item)
  import oh1_pkg::*;

  // ---- CRV knobs ----
  rand int unsigned n_filler;     // 每區塊填充密度
  rand int unsigned n_region;     // 頂層分歧區塊數
  rand int unsigned nest_depth;   // 允許巢狀深度（0=不巢狀）
  rand int unsigned n_tmc;
  rand int unsigned n_branch;
  rand int unsigned n_lsu;
  rand int unsigned n_dmem_init;

  constraint c_knob {
    n_filler    inside {[2:8]};
    n_region    inside {[0:4]};
    nest_depth  inside {[0:3]};
    n_tmc       inside {[0:3]};
    n_branch    inside {[0:6]};
    n_lsu       inside {[0:6]};
    n_dmem_init inside {[0:16]};
  }

  // ---- 產出（build 後有效）----
  logic [31:0]   pmem [$];
  oh1_dmem_init  dmem_init [$];
  logic [31:0]   start_pc = 32'h0;
  int unsigned   n_instr;

  function new(string name = "oh1_prog_item");
    super.new(name);
  endfunction

  // ------------------------------------------------------------------
  // 隨機算術填充指令（x2..x7，讀未寫暫存器＝0 亦確定，ISS 可鏡像）
  // ------------------------------------------------------------------
  local function automatic void emit_filler();
    randcase
      40: pmem.push_back(enc_rtype(ikind_e'($urandom_range(I_ADD, I_SLTU)),
                                   $urandom_range(2, 7), $urandom_range(2, 7), $urandom_range(2, 7)));
      40: pmem.push_back(enc_itype(ikind_e'($urandom_range(I_ADDI, I_SRAI)),
                                   $urandom_range(2, 7), $urandom_range(2, 7), $urandom_range(0, 63)));
      10: pmem.push_back(enc_lui(I_LUI,  $urandom_range(2, 7), $urandom_range(0, 16'hFFFF)));
      10: pmem.push_back(enc_lui(I_AUIPC,$urandom_range(2, 7), $urandom_range(0, 16'hFFFF)));
    endcase
  endfunction

  // ------------------------------------------------------------------
  // 分歧區塊：split x1（then=lanes!=0）／join／else（lane0）／join
  // imm = else 相對位址（byte，±4KB 內）
  // ------------------------------------------------------------------
  local function automatic void emit_region(int depth);
    int then_len, else_len;
    int split_idx, else_idx;
    // 先決定區塊長度；split imm 以實際索引回填（巢狀時 then 長度會膨脹）
    then_len = $urandom_range(1, 4);
    else_len = $urandom_range(1, 4);
    split_idx = pmem.size();
    pmem.push_back(enc_split(5'd1, 12'd0));   // imm 稍後回填
    // then 區塊
    for (int i = 0; i < then_len; i++) begin
      if (depth < int'(nest_depth) && i == 0 && $urandom_range(0, 1))
        emit_region(depth + 1);               // 巢狀（長度不固定）
      else
        emit_filler();
    end
    pmem.push_back(enc_custom3(F3_JOIN, 5'd0, 5'd0));
    else_idx = pmem.size();                    // else 起點（實際索引）
    // else 區塊
    for (int i = 0; i < else_len; i++) emit_filler();
    pmem.push_back(enc_custom3(F3_JOIN, 5'd0, 5'd0));
    // 回填：byte 偏移 = (else_idx - split_idx) * 4，imm 半字組 → ×2
    pmem[split_idx] = enc_split(5'd1, 12'((else_idx - split_idx) * 2));
  endfunction

  // ------------------------------------------------------------------
  // 分支：目標界內、字對齊（跳 1..3 條指令）
  // ------------------------------------------------------------------
  local function automatic void emit_branch();
    int unsigned off_instr = $urandom_range(1, 3);
    randcase
      30: pmem.push_back(enc_btype(I_BEQ, 5'd0, 5'd0, 12'(off_instr * 2)));  // 必跳
      20: pmem.push_back(enc_btype(I_BNE, 5'd0, 5'd0, 12'(off_instr * 2)));  // 必不跳
      20: pmem.push_back(enc_btype(I_BEQ, 5'd1, 5'd0, 12'(off_instr * 2)));  // lanes>0 → AND 不跳
      15: pmem.push_back(enc_btype(I_BGE, 5'd0, 5'd0, 12'(off_instr * 2)));  // 必跳
      15: pmem.push_back(enc_btype(I_BLT, 5'd0, 5'd0, 12'(off_instr * 2)));  // 必不跳
    endcase
    // 填充被跳過的延遲槽指令（跳 1 條時填充 1 條，保證目標存在）
    for (int i = 0; i < off_instr; i++) emit_filler();
  endfunction

  // ------------------------------------------------------------------
  // LSU：divergent（每 lane 獨立字位址）；sw 資料先以 addi 設定
  // ------------------------------------------------------------------
  local function automatic void emit_lsu();
    bit do_store = $urandom_range(0, 1);
    int unsigned aligned_imm = $urandom_range(0, 15) * 4;
    if (do_store) begin
      pmem.push_back(enc_itype(I_ADDI, 5'd5, 5'd0, $urandom_range(1, 127)));  // x5 = 資料
      pmem.push_back(enc_sw(5'd5, 5'd6, 12'(aligned_imm)));                   // sw x5, imm(x6)
    end else begin
      pmem.push_back(enc_itype(I_LW, 5'd7, 5'd6, 12'(aligned_imm)));          // lw x7, imm(x6)
    end
  endfunction

  local function automatic void emit_tmc();
    pmem.push_back(enc_itype(I_ADDI, 5'd2, 5'd0, $urandom_range(0, LANES)));  // x2 = n
    pmem.push_back(enc_custom3(F3_TMC, 5'd2, 5'd0));
    repeat ($urandom_range(1, 3)) emit_filler();                              // tmc 後觀察新遮罩
  endfunction

  // ------------------------------------------------------------------
  // 結構化程式產生（保證合法性）
  // ------------------------------------------------------------------
  function void build();
    int unsigned body_budget;
    pmem.delete();
    dmem_init.delete();

    // prologue：tid → x1、tid*4 → x6（LSU 基址）、x2 種子
    pmem.push_back(enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID));
    pmem.push_back(enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2));
    pmem.push_back(enc_itype(I_ADDI, 5'd2, 5'd0, $urandom_range(1, 31)));

    // body：隨機交錯各類片段
    body_budget = n_region + n_branch + n_lsu + n_tmc;
    repeat (body_budget) begin
      randcase
        (n_region > 0) * 10: begin emit_region(0); n_region--; end
        (n_branch > 0) * 10: begin emit_branch(); n_branch--; end
        (n_lsu    > 0) * 10: begin emit_lsu();    n_lsu--;    end
        (n_tmc    > 0) *  4: begin emit_tmc();    n_tmc--;    end
        default:             emit_filler();
      endcase
      repeat ($urandom_range(0, n_filler)) emit_filler();
    end

    // epilogue
    pmem.push_back(enc_custom3(F3_TEXIT, 5'd0, 5'd0));

    // dmem 初始化
    for (int i = 0; i < int'(n_dmem_init); i++) begin
      oh1_dmem_init d = oh1_dmem_init::type_id::create($sformatf("dinit_%0d", i));
      d.idx = $urandom_range(0, 511) * 4;      // 字對齊位址
      d.val = $urandom();
      dmem_init.push_back(d);
    end
    n_instr = pmem.size();
  endfunction

  // directed SIMD 程式（與 tb_simd 相同，供 UVM/ISS 逐步比對版）
  function void build_simd();
    pmem.delete(); dmem_init.delete();
    pmem = { enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID),     // 0
             enc_itype(I_SLLI, 5'd2, 5'd1, 12'd1),        // 1
             enc_rtype(I_ADD,  5'd3, 5'd2, 5'd1),         // 2
             enc_itype(I_ADDI, 5'd4, 5'd3, 12'd7),        // 3
             enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2),        // 4
             enc_sw(5'd4, 5'd6, 12'd128),                 // 5
             enc_itype(I_LW, 5'd5, 5'd6, 12'd128),        // 6
             enc_itype(I_ADDI, 5'd7, 5'd0, 12'd2),        // 7
             enc_custom3(F3_TMC, 5'd7, 5'd0),             // 8  tmc→{0,1}
             enc_itype(I_ADDI, 5'd8, 5'd4, 12'd1),        // 9
             enc_itype(I_CSRR, 5'd9, 5'd0, CSR_TID),      // 10
             enc_itype(I_ADDI, 5'd7, 5'd0, 12'd4),        // 11
             enc_custom3(F3_TMC, 5'd7, 5'd0),             // 12 tmc→全
             enc_rtype(I_ADD, 5'd10, 5'd4, 5'd5),         // 13
             enc_split(5'd1, 12'd6),                      // 14 else@pc76
             enc_rtype(I_SUB, 5'd11, 5'd10, 5'd4),        // 15
             enc_custom3(F3_JOIN, 5'd0, 5'd0),            // 16
             enc_rtype(I_XOR, 5'd11, 5'd10, 5'd4),        // 17
             enc_custom3(F3_JOIN, 5'd0, 5'd0),            // 18
             enc_custom3(F3_TEXIT, 5'd0, 5'd0) };         // 19
    n_instr = pmem.size();
  endfunction

  // directed smoke 程式（與 tb_smoke 相同語意，enc_sw 參數序 rs2,rs1,imm）
  function void build_smoke();
    pmem.delete(); dmem_init.delete();
    pmem = { enc_itype(I_CSRR, 5'd1, 5'd0, CSR_TID),     // 0: csrr x1, tid
             enc_split(5'd1, 12'd12),                     // 1: split x1, else@pc16
             enc_itype(I_ADDI, 5'd2, 5'd0, 12'd99),       // 2: then
             enc_custom3(F3_JOIN, 5'd0, 5'd0),            // 3: join#1
             enc_itype(I_ADDI, 5'd2, 5'd0, 12'd20),       // 4: else
             enc_custom3(F3_JOIN, 5'd0, 5'd0),            // 5: join#2
             enc_itype(I_SLLI, 5'd6, 5'd1, 12'd2),        // 6: x6 = tid*4
             enc_sw(5'd1, 5'd6, 12'd64),                  // 7: sw x1, 64(x6)
             enc_itype(I_LW, 5'd3, 5'd6, 12'd64),         // 8: lw x3, 64(x6)
             enc_btype(I_BEQ, 5'd1, 5'd0, 12'd4),         // 9: 不跳
             enc_itype(I_ADDI, 5'd4, 5'd0, 12'd7),        // 10: x4=7
             enc_btype(I_BEQ, 5'd0, 5'd0, 12'd4),         // 11: 必跳→pc52
             enc_itype(I_ADDI, 5'd5, 5'd0, 12'd111),      // 12: 跳過
             enc_itype(I_ADDI, 5'd5, 5'd0, 12'd99),       // 13: x5=99
             enc_custom3(F3_TEXIT, 5'd0, 5'd0) };         // 14: texit
    n_instr = pmem.size();
  endfunction

endclass

// =============================================================================
// Sequences
// =============================================================================
class oh1_base_seq extends uvm_sequence #(oh1_prog_item);
  `uvm_object_utils(oh1_base_seq)
  function new(string name = "oh1_base_seq");
    super.new(name);
  endfunction
endclass

class oh1_directed_smoke_seq extends oh1_base_seq;
  `uvm_object_utils(oh1_directed_smoke_seq)
  function new(string name = "oh1_directed_smoke_seq");
    super.new(name);
  endfunction
  task body();
    oh1_prog_item tr = oh1_prog_item::type_id::create("tr");
    tr.build_smoke();
    start_item(tr); finish_item(tr);
  endtask
endclass

class oh1_simd_seq extends oh1_base_seq;
  `uvm_object_utils(oh1_simd_seq)
  function new(string name = "oh1_simd_seq");
    super.new(name);
  endfunction
  task body();
    oh1_prog_item tr = oh1_prog_item::type_id::create("tr");
    tr.build_simd();
    start_item(tr); finish_item(tr);
  endtask
endclass

class oh1_rand_seq extends oh1_base_seq;
  `uvm_object_utils(oh1_rand_seq)
  rand int n_prog = 10;
  constraint c_np { n_prog inside {[1:50]}; }
  function new(string name = "oh1_rand_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n_prog) begin
      oh1_prog_item tr = oh1_prog_item::type_id::create("tr");
      void'(tr.randomize());
      tr.build();
      `uvm_info(get_type_name(), $sformatf("rand prog: %0d instrs", tr.n_instr), UVM_MEDIUM)
      start_item(tr); finish_item(tr);
    end
  endtask
endclass

class oh1_stress_seq extends oh1_base_seq;
  `uvm_object_utils(oh1_stress_seq)
  rand int n_prog = 5;
  constraint c_np { n_prog inside {[1:20]}; }
  function new(string name = "oh1_stress_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n_prog) begin
      oh1_prog_item tr = oh1_prog_item::type_id::create("tr");
      // 極端 knobs：最大巢狀、飽和 LSU/分支/TMC
      void'(tr.randomize() with {
        nest_depth == 3; n_region == 4; n_branch == 6;
        n_lsu == 6; n_tmc == 3; n_filler == 8; n_dmem_init == 16;
      });
      tr.build();
      `uvm_info(get_type_name(), $sformatf("stress prog: %0d instrs", tr.n_instr), UVM_MEDIUM)
      start_item(tr); finish_item(tr);
    end
  endtask
endclass

`endif // OH1_SEQ_LIB_SV
