// ctrl_defs.vh — datapath mux selects and memory access sizes.
//
// Shared by rtl/control.v, tb/control_tb.v and (later) rtl/cpu.v, so the
// control unit and the datapath can never disagree about what 2'd1 means.
// Same `define pattern as alu_ops.vh and rv32i_defs.vh: write the leading
// backtick at every use site.
//
// These are NOT part of the ISA. They are this implementation's private
// encoding of "which way is the mux pointing", chosen by us.

`ifndef CTRL_DEFS_VH
`define CTRL_DEFS_VH

// ---- alu_a_src: what feeds ALU operand A ----
`define A_RS1    2'd0   // register rs1        (arithmetic, loads, stores, jalr)
`define A_PC     2'd1   // the current PC      (auipc, jal, branches)
`define A_ZERO   2'd2   // constant 0          (lui: 0 + imm = imm)

// ---- alu_b_src: what feeds ALU operand B ----
`define B_RS2    1'd0   // register rs2        (R-type only)
`define B_IMM    1'd1   // the decoded imm     (everything else)

// ---- result_src: what gets written back to rd ----
`define RES_ALU  2'd0   // the ALU output
`define RES_MEM  2'd1   // load data, after sub-word extract + sign extend
`define RES_PC4  2'd2   // PC+4, the return address (jal, jalr)

// ---- mem_size: width of a load or store ----
`define SZ_B     2'd0   // byte
`define SZ_H     2'd1   // halfword
`define SZ_W     2'd2   // word

`endif
