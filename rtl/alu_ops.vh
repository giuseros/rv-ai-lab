// alu_ops.vh — ALU operation encodings.
//
// Shared by rtl/alu.v and tb/alu_tb.v so the two can never disagree about what
// 4'd6 means. Included with:  `include "alu_ops.vh"  (the Makefile passes -I rtl
// so the bare filename resolves from either directory).
//
// These are `define macros, i.e. plain text substitution, so you must write the
// leading backtick at every use site: `ALU_ADD, not ALU_ADD. Macros are global
// to the whole compilation and have no scope and no type -- that is Verilog-2001
// for you. The `ifndef guard below stops a redefinition warning when more than
// one file in the same build includes this.
//
// The decoder (step 3) will map RV32I funct3/funct7 onto these codes.

`ifndef ALU_OPS_VH
`define ALU_OPS_VH

`define ALU_ADD  4'd0    // a + b
`define ALU_SUB  4'd1    // a - b
`define ALU_AND  4'd2    // a & b
`define ALU_OR   4'd3    // a | b
`define ALU_XOR  4'd4    // a ^ b
`define ALU_SLL  4'd5    // a << b[4:0]     (logical left)
`define ALU_SRL  4'd6    // a >> b[4:0]     (logical right)
`define ALU_SRA  4'd7    // a >>> b[4:0]    (arithmetic right)
`define ALU_SLT  4'd8    // (signed)   a < b ? 1 : 0
`define ALU_SLTU 4'd9    // (unsigned) a < b ? 1 : 0

`endif
