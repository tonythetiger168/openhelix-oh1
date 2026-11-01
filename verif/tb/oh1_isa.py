"""OH-1 ISA: encoders and the hardware decode rules, in Python.

Mirrors rtl/oh1_pkg.sv (encoders) and rtl/oh1_decode.sv (what the hardware
accepts). Note the one intentional difference from oh1_pkg::dec_kind: the
hardware treats the FP16 vdot form and WSPAWN as illegal, so decode() returns
ILL for them (dec_kind returns I_VDOT / I_WSPAWN, which the SV ISS then also
treats as illegal; the visible behaviour is the same).
"""
from enum import Enum

LANES = 4
STK_DEPTH = 8
MEM_WORDS = 4096
MASK32 = 0xFFFF_FFFF

OPC_CUSTOM0 = 0b0001011
F3_SPLIT, F3_JOIN, F3_TMC, F3_BAR, F3_WEXIT, F3_TEXIT, F3_VDOT, F3_WSPAWN = range(8)
F7_VDOT4_I8 = 0b0000001
CSR_TID = 0x8C0
CSR_LANEID = 0x8CD


class K(Enum):
    ADD = "add"; SUB = "sub"; AND = "and"; OR = "or"; XOR = "xor"
    SLL = "sll"; SRL = "srl"; SRA = "sra"; SLT = "slt"; SLTU = "sltu"; MUL = "mul"
    ADDI = "addi"; ANDI = "andi"; ORI = "ori"; XORI = "xori"; SLTI = "slti"; SLTIU = "sltiu"
    SLLI = "slli"; SRLI = "srli"; SRAI = "srai"
    LUI = "lui"; AUIPC = "auipc"; JAL = "jal"; JALR = "jalr"
    BEQ = "beq"; BNE = "bne"; BLT = "blt"; BGE = "bge"
    LW = "lw"; SW = "sw"; CSRR = "csrr"
    SPLIT = "split"; JOIN = "join"; TMC = "tmc"; BAR = "bar"; WEXIT = "wexit"; TEXIT = "texit"
    VDOT4 = "vdot4"
    ILL = "illegal"


R_OPS = [K.ADD, K.SUB, K.AND, K.OR, K.XOR, K.SLL, K.SRL, K.SRA, K.SLT, K.SLTU, K.MUL]
I_OPS = [K.ADDI, K.ANDI, K.ORI, K.XORI, K.SLTI, K.SLTIU, K.SLLI, K.SRLI, K.SRAI]
BR_OPS = [K.BEQ, K.BNE, K.BLT, K.BGE]
WB_OPS = set(R_OPS + I_OPS + [K.LUI, K.AUIPC, K.CSRR, K.VDOT4, K.LW, K.JAL, K.JALR])

_R_F = {K.ADD: (0, 0), K.SUB: (0x20, 0), K.AND: (0, 7), K.OR: (0, 6), K.XOR: (0, 4),
        K.SLL: (0, 1), K.SRL: (0, 5), K.SRA: (0x20, 5), K.SLT: (0, 2), K.SLTU: (0, 3),
        K.MUL: (1, 0)}
_I_F3 = {K.ADDI: 0, K.ANDI: 7, K.ORI: 6, K.XORI: 4, K.SLTI: 2, K.SLTIU: 3,
         K.SLLI: 1, K.SRLI: 5, K.SRAI: 5}
_B_F3 = {K.BEQ: 0, K.BNE: 1, K.BLT: 4, K.BGE: 5}


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sext(v, 32)


# ---------------------------------------------------------------- encoders
def enc_r(k, rd, rs1, rs2):
    f7, f3 = _R_F[k]
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0b0110011


def enc_i(k, rd, rs1, imm):
    f3 = _I_F3[k]
    if k in (K.SLLI, K.SRLI):
        imm = imm & 0x1F
    elif k == K.SRAI:
        imm = 0x400 | (imm & 0x1F)
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0b0010011


def enc_lw(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0b0000011


def enc_sw(rs2, rs1, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1F) << 7) | 0b0100011


def enc_csrr(rd, csr, rs1=0):
    return ((csr & 0xFFF) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0b1110011


def enc_b(k, rs1, rs2, off):
    """off = signed byte offset (even)."""
    i = off & 0x1FFF
    return ((((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15)
            | (_B_F3[k] << 12) | (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | 0b1100011)


def enc_u(k, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | (0b0110111 if k == K.LUI else 0b0010111)


def enc_jal(rd, off):
    i = off & 0x1FFFFF
    return ((((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) | (((i >> 11) & 1) << 20)
            | (((i >> 12) & 0xFF) << 12) | (rd << 7) | 0b1101111)


def enc_jalr(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0b1100111


def enc_split(rs1, half_off):
    """else_pc = split_pc + sext(imm12)*2  (half_off = imm12)."""
    return ((half_off & 0xFFF) << 20) | (rs1 << 15) | (F3_SPLIT << 12) | OPC_CUSTOM0


def enc_c3(f3, rs1=0, rs2=0, f7=0, rd=0):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OPC_CUSTOM0


def enc_vdot4(rd, rs1, rs2):
    return enc_c3(F3_VDOT, rs1, rs2, F7_VDOT4_I8, rd)


# ---------------------------------------------------------------- decode
def decode(ins):
    """Return (kind, rd, rs1, rs2, imm32) with the hardware's legality rules."""
    opc = ins & 0x7F
    rd = (ins >> 7) & 0x1F
    f3 = (ins >> 12) & 7
    rs1 = (ins >> 15) & 0x1F
    rs2 = (ins >> 20) & 0x1F
    f7 = ins >> 25
    i_imm = sext(ins >> 20, 12)
    k, imm = K.ILL, 0
    if opc == 0b0110011:
        for kk, (ff7, ff3) in _R_F.items():
            if f7 == ff7 and f3 == ff3:
                k = kk
    elif opc == 0b0010011:
        k = {0: K.ADDI, 7: K.ANDI, 6: K.ORI, 4: K.XORI, 2: K.SLTI, 3: K.SLTIU, 1: K.SLLI}.get(f3)
        imm = i_imm
        if f3 == 5:
            k = K.SRAI if f7 == 0x20 else K.SRLI
        if k in (K.SLLI, K.SRLI, K.SRAI):
            imm = (ins >> 20) & 0x1F
        if k is None:
            k, imm = K.ILL, 0
    elif opc == 0b0110111:
        k, imm = K.LUI, ins & 0xFFFFF000
    elif opc == 0b0010111:
        k, imm = K.AUIPC, ins & 0xFFFFF000
    elif opc == 0b1101111:
        k = K.JAL
        imm = sext((((ins >> 31) & 1) << 20) | (((ins >> 12) & 0xFF) << 12)
                   | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1), 21)
    elif opc == 0b1100111:
        if f3 == 0:
            k, imm = K.JALR, i_imm
    elif opc == 0b1100011:
        k = {0: K.BEQ, 1: K.BNE, 4: K.BLT, 5: K.BGE}.get(f3, K.ILL)
        imm = sext((((ins >> 31) & 1) << 12) | (((ins >> 7) & 1) << 11)
                   | (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1), 13)
    elif opc == 0b0000011:
        if f3 == 2:
            k, imm = K.LW, i_imm
    elif opc == 0b0100011:
        if f3 == 2:
            k, imm = K.SW, sext(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12)
    elif opc == 0b1110011:
        if f3 == 2:
            k, imm = K.CSRR, (ins >> 20) & 0xFFF
    elif opc == OPC_CUSTOM0:
        if f3 == F3_SPLIT:
            k, imm = K.SPLIT, i_imm * 2
        else:
            k = {F3_JOIN: K.JOIN, F3_TMC: K.TMC, F3_BAR: K.BAR,
                 F3_WEXIT: K.WEXIT, F3_TEXIT: K.TEXIT}.get(f3, K.ILL)
            if f3 == F3_VDOT and f7 == F7_VDOT4_I8:
                k = K.VDOT4
    return k, rd, rs1, rs2, imm & MASK32


def dot4_i8(a, b):
    acc = 0
    for i in range(4):
        acc += sext(a >> (8 * i), 8) * sext(b >> (8 * i), 8)
    return acc & MASK32
