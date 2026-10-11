// alu.v — RV32I arithmetic/logic unit
//
// Purely combinational. No clock, no state.
//
// >>> YOUR JOB: implement the body. The port list is the contract that
//     tb/alu_tb.v compiles against — keep the names and widths.
//
// Operation codes come from rtl/alu_ops.vh (included above). They are `define
// macros, so write the backtick: `ALU_ADD, `ALU_SUB, `ALU_AND, `ALU_OR,
// `ALU_XOR, `ALU_SLL, `ALU_SRL, `ALU_SRA, `ALU_SLT, `ALU_SLTU.
//
// Behavior the testbench expects:
//   - y follows a/b/alu_op combinationally
//   - shifts use ONLY the low 5 bits of b (b[4:0]) as the shift amount.
//     RV32I mandates this: shifting by 33 shifts by 1. Ignore b[31:5].
//   - SRA is an ARITHMETIC right shift (sign-extends); SRL fills with zeros.
//     Verilog's >>> only sign-extends if its LEFT operand is signed --
//     look up $signed().
//   - SLT compares as SIGNED two's complement, SLTU as UNSIGNED. Both
//     produce 32'd1 or 32'd0, not a 1-bit value.
//   - zero is 1 when y == 0. (The branch unit will use it later.)
//   - undefined alu_op: don't care, but pick something deterministic and
//     make sure you cover every case (see the note on latches below).
//
// Note on `always @*` + `case`: if some path through the block leaves y
// unassigned, you have described a LATCH, not combinational logic. Either
// give the case a `default:` or assign y a value before the case. iverilog
// will not warn you; synthesis would.

`timescale 1ns/1ps
`include "alu_ops.vh"

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] y,
    output wire        zero
);

    // TODO (you): a case statement on alu_op inside an always @* block.
    always @* begin
        case (alu_op)
            `ALU_ADD: y = a+b;
            `ALU_SUB: y = a-b;
            `ALU_AND: y = a&b;
            `ALU_OR: y = a|b;
            `ALU_XOR: y = a^b;
            `ALU_SRA: y = $signed(a) >>> b[4:0];
            `ALU_SRL: y = a >> b[4:0];
            `ALU_SLL: y = a << b[4:0];
            `ALU_SLT: y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            `ALU_SLTU: y = (a < b) ? 32'd1 : 32'd0;
            default: y = 32'd0; // deterministic default value
        endcase
    end
    
    // TODO (you): drive `zero`.
    assign zero = (y == 32'd0);

endmodule
