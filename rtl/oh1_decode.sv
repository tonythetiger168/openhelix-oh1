// =============================================================================
// OH-1 組合解碼器：instr -> 解碼結構體（v0.1 與 oh1_pkg::dec_kind 對齊）
// =============================================================================
module oh1_decode import oh1_pkg::*; (
  input  logic [31:0]      instr_i,
  output oh1_pkg::ikind_e  kind_o,
  output logic [4:0]       rd_o,
  output logic [4:0]       rs1_o,
  output logic [4:0]       rs2_o,
  output logic [31:0]      imm_o,       // 已依種類做符號/零擴展
  output logic             illegal_o
);
  import oh1_pkg::*;

  ikind_e kind;
  logic [31:0] imm;
  logic [6:0] opc;
  logic [11:0] i_imm;
  logic [12:1] b_imm;
  logic [31:12] u_imm;

  assign opc   = instr_i[6:0];
  assign i_imm = instr_i[31:20];
  assign b_imm = {instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8]};
  assign u_imm = instr_i[31:12];

  always_comb begin
    kind = I_ILL; imm = '0;
    unique case (opc)
      7'b0110011: begin
        unique case ({instr_i[31:25], instr_i[14:12]})
          {7'b0000000,3'b000}: kind = I_ADD;
          {7'b0100000,3'b000}: kind = I_SUB;
          {7'b0000000,3'b111}: kind = I_AND;
          {7'b0000000,3'b110}: kind = I_OR;
          {7'b0000000,3'b100}: kind = I_XOR;
          {7'b0000000,3'b001}: kind = I_SLL;
          {7'b0000000,3'b101}: kind = I_SRL;
          {7'b0100000,3'b101}: kind = I_SRA;
          {7'b0000000,3'b010}: kind = I_SLT;
          {7'b0000000,3'b011}: kind = I_SLTU;
          default: ;
        endcase
      end
      7'b0010011: begin
        unique case (instr_i[14:12])
          3'b000: begin kind = I_ADDI; imm = {{20{i_imm[11]}}, i_imm}; end
          3'b111: begin kind = I_ANDI; imm = {{20{i_imm[11]}}, i_imm}; end
          3'b110: begin kind = I_ORI;  imm = {{20{i_imm[11]}}, i_imm}; end
          3'b100: begin kind = I_XORI; imm = {{20{i_imm[11]}}, i_imm}; end
          3'b010: begin kind = I_SLTI; imm = {{20{i_imm[11]}}, i_imm}; end
          3'b011: begin kind = I_SLTIU;imm = {{20{i_imm[11]}}, i_imm}; end
          3'b001: begin kind = I_SLLI; imm = {27'b0, i_imm[4:0]}; end
          3'b101: begin
            if (instr_i[31:25]==7'b0100000) begin kind = I_SRAI; imm = {27'b0, i_imm[4:0]}; end
            else                            begin kind = I_SRLI; imm = {27'b0, i_imm[4:0]}; end
          end
          default: ;
        endcase
      end
      7'b0110111: begin kind = I_LUI;   imm = {u_imm, 12'b0}; end
      7'b0010111: begin kind = I_AUIPC; imm = {u_imm, 12'b0}; end
      7'b1100011: begin
        unique case (instr_i[14:12])
          3'b000: kind = I_BEQ;
          3'b001: kind = I_BNE;
          3'b100: kind = I_BLT;
          3'b101: kind = I_BGE;
          default: ;
        endcase
        imm = {{19{b_imm[12]}}, b_imm, 1'b0}; // B-type 立即數（位元組）
      end
      7'b0000011: if (instr_i[14:12]==3'b010) begin
        kind = I_LW; imm = {{20{i_imm[11]}}, i_imm};
      end
      7'b0100011: if (instr_i[14:12]==3'b010) begin
        kind = I_SW; imm = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
      end
      7'b1110011: if (instr_i[14:12]==3'b010) begin
        kind = I_CSRR; imm = {20'b0, i_imm}; // imm_o 此時攜帶 CSR 位址
      end
      OPC_CUSTOM0: begin
        unique case (instr_i[14:12])
          F3_SPLIT: begin kind = I_SPLIT; imm = {{19{i_imm[11]}}, i_imm, 1'b0}; end
          F3_JOIN : kind = I_JOIN;
          F3_TMC  : kind = I_TMC;
          F3_BAR  : kind = I_BAR;
          F3_WEXIT: kind = I_WEXIT;
          F3_TEXIT: kind = I_TEXIT;
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  assign kind_o    = kind;
  assign rd_o      = instr_i[11:7];
  assign rs1_o     = instr_i[19:15];
  assign rs2_o     = instr_i[24:20];
  assign imm_o     = imm;
  assign illegal_o = (kind == I_ILL);

endmodule
