// rv32i_defs.vh — RV32I opcodes and instruction-format codes.
//
// Shared by rtl/decoder.v and tb/decoder_tb.v. `define macros, so write the
// backtick at every use site. See rtl/alu_ops.vh for the same pattern.

`ifndef RV32I_DEFS_VH
`define RV32I_DEFS_VH

// ---- opcodes (instr[6:0]) ----
`define OP_R      7'b0110011   // add sub and or xor sll srl sra slt sltu
`define OP_IMM    7'b0010011   // addi andi ori xori slli srli srai slti sltiu
`define OP_LOAD   7'b0000011   // lb lh lw lbu lhu
`define OP_STORE  7'b0100011   // sb sh sw
`define OP_BRANCH 7'b1100011   // beq bne blt bge bltu bgeu
`define OP_LUI    7'b0110111
`define OP_AUIPC  7'b0010111
`define OP_JAL    7'b1101111
`define OP_JALR   7'b1100111

// ---- instruction formats (the `fmt` output of the decoder) ----
// These say how to build the immediate; they are not part of the ISA encoding.
`define FMT_R     3'd0    // no immediate
`define FMT_I     3'd1    // instr[31:20], sign-extended
`define FMT_S     3'd2    // instr[31:25],instr[11:7], sign-extended
`define FMT_B     3'd3    // scrambled, bit 0 always 0, sign-extended
`define FMT_U     3'd4    // instr[31:12] << 12, low 12 bits zero
`define FMT_J     3'd5    // scrambled, bit 0 always 0, sign-extended
`define FMT_X     3'd7    // unrecognised opcode

`endif
