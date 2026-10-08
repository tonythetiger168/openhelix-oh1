// =============================================================================
// OpenHelix OH-1 參數與 ISA 定義套件
// Milestone 0.1：RV32I 子集 + custom-0 SIMT 擴展（split/join/tmc/bar/wexit/texit）
// 本檔為 generator（CRV）與 ISS（scoreboard）共用之編碼單一事實來源
// =============================================================================
package oh1_pkg;

  // ---- 結構參數 ----
  /* verilator lint_off UNUSEDPARAM */
  parameter int LANES        = 4;           // v0.1 固定 4 lanes（lane_mask_t 以字面寬度定義，見下）
  parameter int DIV_STK_DEPTH = 8;          // 分歧堆疊深度
  parameter int MEM_WORDS    = 4096;        // 指令/資料記憶體字數（16KB）

  // 註：v0.1 以字面寬度定義 lane_mask_t（=LANES=4）。
  // iverilog 無法在 module scope 綁定 package 參數作為 typedef 維度（verilator/VCS 則可）。
  typedef logic [3:0] lane_mask_t;

  // ---- custom-0 opcode ----
  parameter logic [6:0] OPC_CUSTOM0 = 7'b0001011;

  // ---- custom-0 內以 funct3 區分指令 ----
  // SPLIT 帶 12-bit 立即數（else 偏移，×2 位元組）：else_pc = split_pc + sext(imm12)*2
  // 註：以 localparam 取代 enum —— iverilog 無法在 package function 內以 enum 成員為 case item
  localparam logic [2:0] F3_SPLIT = 3'b000;
  localparam logic [2:0] F3_JOIN  = 3'b001;
  localparam logic [2:0] F3_TMC   = 3'b010;
  localparam logic [2:0] F3_BAR   = 3'b011;
  localparam logic [2:0] F3_WEXIT = 3'b100;
  localparam logic [2:0] F3_TEXIT = 3'b101;
  localparam logic [2:0] F3_VDOT  = 3'b110;  // M1.0：4-lane FP16 dot-product（Tensor Lite）
  localparam logic [2:0] F3_WSPAWN = 3'b111; // M2.0：多 warp 產生（M1.0 預留）

  // ---- CSR 位址（唯讀）----
  parameter logic [11:0] CSR_TID    = 12'h8C0;  // lane 線性 id
  parameter logic [11:0] CSR_LANEID = 12'h8CD;  // lane id（同 tid，語義對齊 CUDA %laneid）

  // ---- 指令種類（generator/ISS 層級抽象）----
  typedef enum {
    I_ADD, I_SUB, I_AND, I_OR, I_XOR, I_SLL, I_SRL, I_SRA, I_SLT, I_SLTU,
    I_ADDI, I_ANDI, I_ORI, I_XORI, I_SLTI, I_SLTIU, I_SLLI, I_SRLI, I_SRAI,
    I_LUI, I_AUIPC,
    I_BEQ, I_BNE, I_BLT, I_BGE,
    I_LW, I_SW,
    I_CSRR,
    I_SPLIT, I_JOIN, I_TMC, I_BAR, I_WEXIT, I_TEXIT,
    I_VDOT, I_WSPAWN,
    I_ILL
  } ikind_e;

  // ---- 編碼函數（generator 使用；DUT 硬體解碼獨立實作，二者由本套件對齊）----
  function automatic logic [31:0] enc_rtype(ikind_e k, logic [4:0] rd, rs1, rs2);
    logic [6:0] f7; logic [2:0] f3;
    case (k)
      I_ADD : begin f7=7'b0000000; f3=3'b000; end
      I_SUB : begin f7=7'b0100000; f3=3'b000; end
      I_AND : begin f7=7'b0000000; f3=3'b111; end
      I_OR  : begin f7=7'b0000000; f3=3'b110; end
      I_XOR : begin f7=7'b0000000; f3=3'b100; end
      I_SLL : begin f7=7'b0000000; f3=3'b001; end
      I_SRL : begin f7=7'b0000000; f3=3'b101; end
      I_SRA : begin f7=7'b0100000; f3=3'b101; end
      I_SLT : begin f7=7'b0000000; f3=3'b010; end
      I_SLTU: begin f7=7'b0000000; f3=3'b011; end
      default: begin f7=7'b0000000; f3=3'b000; end
    endcase
    return {f7, rs2, rs1, f3, rd, 7'b0110011};
  endfunction

  function automatic logic [31:0] enc_itype(ikind_e k, logic [4:0] rd, logic [4:0] rs1, logic [11:0] imm);
    logic [2:0] f3; logic [6:0] opc;
    case (k)
      I_ADDI : begin f3=3'b000; opc=7'b0010011; end
      I_ANDI : begin f3=3'b111; opc=7'b0010011; end
      I_ORI  : begin f3=3'b110; opc=7'b0010011; end
      I_XORI : begin f3=3'b100; opc=7'b0010011; end
      I_SLTI : begin f3=3'b010; opc=7'b0010011; end
      I_SLTIU: begin f3=3'b011; opc=7'b0010011; end
      I_SLLI : begin f3=3'b001; opc=7'b0010011; end
      I_SRLI : begin f3=3'b101; opc=7'b0010011; end
      I_SRAI : begin f3=3'b101; opc=7'b0010011; end
      I_LW   : begin f3=3'b010; opc=7'b0000011; end
      I_CSRR : begin f3=3'b010; opc=7'b1110011; end // csrrs rd, csr, x0
      default: begin f3=3'b000; opc=7'b0010011; end
    endcase
    // SRAI 為 RV 的特殊編碼（imm[11:5]=0100000）
    if (k == I_SRAI) return {7'b0100000, imm[4:0], rs1, f3, rd, opc};
    if ((k==I_SLLI)||(k==I_SRLI)) return {7'b0000000, imm[4:0], rs1, f3, rd, opc};
    return {imm, rs1, f3, rd, opc};
  endfunction

  function automatic logic [31:0] enc_btype(ikind_e k, logic [4:0] rs1, rs2, logic [12:1] imm);
    logic [2:0] f3;
    case (k)
      I_BEQ: f3=3'b000; I_BNE: f3=3'b001;
      I_BLT: f3=3'b100; I_BGE: f3=3'b101;
      default: f3=3'b000;
    endcase
    return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
  endfunction

  function automatic logic [31:0] enc_lui(ikind_e k, logic [4:0] rd, logic [31:12] imm);
    return {imm, rd, (k==I_AUIPC) ? 7'b0010111 : 7'b0110111};
  endfunction

  // split rs1, imm12（else 偏移 ×2）
  function automatic logic [31:0] enc_split(logic [4:0] rs1, logic [11:0] imm);
    return {imm, rs1, F3_SPLIT, 5'd0, OPC_CUSTOM0};
  endfunction

  // 註：參數型別用 logic[2:0] 而非 f3_e —— iverilog 不支援 enum 作為函數參數型別
  function automatic logic [31:0] enc_custom3(logic [2:0] f3, logic [4:0] rs1, rs2);
    return {7'd0, rs2, rs1, f3, 5'd0, OPC_CUSTOM0};
  endfunction

  // SW：S-type，imm 為位元組偏移（字對齊由約束保證）
  function automatic logic [31:0] enc_sw(logic [4:0] rs2, logic [4:0] rs1, logic [11:0] imm);
    return {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  // ---- 軟體端解碼（ISS 使用；與 rtl/oh1_decode.sv 硬體解碼對齊）----
  function automatic ikind_e dec_kind(logic [31:0] ins);
    logic [6:0] opc = ins[6:0];
    case (opc)
      7'b0110011: case ({ins[31:25], ins[14:12]})
                    {7'b0000000,3'b000}: return I_ADD;  {7'b0100000,3'b000}: return I_SUB;
                    {7'b0000000,3'b111}: return I_AND;  {7'b0000000,3'b110}: return I_OR;
                    {7'b0000000,3'b100}: return I_XOR;  {7'b0000000,3'b001}: return I_SLL;
                    {7'b0000000,3'b101}: return I_SRL;  {7'b0100000,3'b101}: return I_SRA;
                    {7'b0000000,3'b010}: return I_SLT;  {7'b0000000,3'b011}: return I_SLTU;
                    default: return I_ILL;
                  endcase
      7'b0010011: case (ins[14:12])
                    3'b000: return I_ADDI; 3'b111: return I_ANDI; 3'b110: return I_ORI;
                    3'b100: return I_XORI; 3'b010: return I_SLTI; 3'b011: return I_SLTIU;
                    3'b001: return I_SLLI;
                    3'b101: return (ins[31:25]==7'b0100000) ? I_SRAI : I_SRLI;
                    default: return I_ILL;
                  endcase
      7'b0110111: return I_LUI;
      7'b0010111: return I_AUIPC;
      7'b1100011: case (ins[14:12])
                    3'b000: return I_BEQ; 3'b001: return I_BNE;
                    3'b100: return I_BLT; 3'b101: return I_BGE;
                    default: return I_ILL;
                  endcase
      7'b0000011: return (ins[14:12]==3'b010) ? I_LW : I_ILL;
      7'b0100011: return (ins[14:12]==3'b010) ? I_SW : I_ILL;
      7'b1110011: return (ins[14:12]==3'b010) ? I_CSRR : I_ILL; // 僅支援 csrrs
      OPC_CUSTOM0: case (ins[14:12])
                     F3_SPLIT: return I_SPLIT; F3_JOIN: return I_JOIN;
                     F3_TMC:   return I_TMC;   F3_BAR:  return I_BAR;
                     F3_WEXIT: return I_WEXIT; F3_TEXIT:return I_TEXIT;
                     F3_VDOT:  return I_VDOT;                    // M1.0 Tensor Lite
                     F3_WSPAWN:return I_WSPAWN;                  // M2.0 多 warp
                     default: return I_ILL;
                   endcase
      default: return I_ILL;
    endcase
  endfunction

  // ---- M1.0 Tensor Lite：vdot 編碼（rd 為累加器目標暫存器）----
  // vdot rd, rs1, rs2, len：rd 為目標累加器，rs1/rs2 為向量基址（各 lane 獨立），
  // len=向量長度（2/4/8，儲存於 rs2[4:0] 或 imm——此處用 rs2 欄位傳遞長度編碼）
  function automatic logic [31:0] enc_vdot(input logic [4:0] rd,
                                           input logic [4:0] rs1,
                                           input logic [4:0] len);  // len 2/4/8
    return {2'b00, 12'(len), 5'(rs1), 3'(F3_VDOT), 5'(rd), 5'(OPC_CUSTOM0)};
  endfunction

endpackage : oh1_pkg
