// decoder.v — RV32I instruction decoder (field extraction + immediate generation)
//
// Purely combinational. No clock, no state.
//
// >>> YOUR JOB: implement the body. The port list is the contract that
//     tb/decoder_tb.v compiles against — keep the names and widths.
//
// This module does NOT produce control signals (reg write enable, ALU op,
// mux selects). That is the control unit, which comes with the datapath in
// step 5. Here you only split the instruction word and build the immediate.
//
// Behavior the testbench expects:
//
//   - opcode/rd/funct3/rs1/rs2/funct7 are FIXED-POSITION slices of instr,
//     the same bits for every format, with no format-dependent gating.
//     That is a deliberate property of the RV32I encoding: rs1/rs2 always
//     sit at instr[19:15]/[24:20], so a real core can start the register
//     read before it knows what the instruction is. Just slice them out;
//     whether they are meaningful is the control unit's problem.
//
//   - fmt says which format the opcode implies: `FMT_R/I/S/B/U/J, or
//     `FMT_X for an opcode you do not recognise.
//
//   - imm is the 32-bit SIGN-EXTENDED immediate for that format, and 0 for
//     `FMT_R and `FMT_X. This is the actual work. The five layouts are in
//     rv32i_defs.vh; the bit scrambling in B and J is not arbitrary, it
//     keeps each immediate bit in a constant position across formats so the
//     hardware muxes stay cheap. Note B and J encode a HALFWORD offset:
//     bit 0 is always 0 and is not stored.
//
//   - Sign extension comes from instr[31] in every format that has it
//     (I, S, B, J). Verilog's {N{bit}} replication operator is the tool.
//
// Traps to avoid:
//   - Concatenation width: {20{instr[31]}, instr[31:20]} must total 32 bits.
//     Miscount and it silently pads or truncates.
//   - U-type is NOT sign-extended and NOT shifted by you: instr[31:12] is
//     already the top 20 bits of the result.
//   - Give the case a `default` so imm/fmt are assigned on every path, or
//     you have described a latch.

`timescale 1ns/1ps
`include "rv32i_defs.vh"

module decoder (
    input  wire [31:0] instr,
    output wire [6:0]  opcode,
    output wire [4:0]  rd,
    output wire [2:0]  funct3,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [6:0]  funct7,
    output reg  [31:0] imm,
    output reg  [2:0]  fmt
);

    // TODO (you): the six fixed-position field slices (assign ...).
    assign opcode = instr[6:0];
    assign rd = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign funct7 = instr[31:25];

    always @(*) begin
        case (opcode)
            `OP_R: begin fmt = `FMT_R; imm = 32'd0; end
            `OP_STORE: begin fmt = `FMT_S; imm = {{20{instr[31]}}, instr[31:25],instr[11:7]}; end
            `OP_BRANCH: begin fmt = `FMT_B; imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}; end
            `OP_LUI: begin fmt = `FMT_U; imm = {instr[31:12], 12'd0};end
            `OP_AUIPC:begin fmt = `FMT_U; imm = {instr[31:12], 12'd0};end
            `OP_JAL: begin fmt= `FMT_J; imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};end
            `OP_IMM: begin fmt = `FMT_I; imm = {{20{instr[31]}}, instr[31:20]}; end
            `OP_LOAD: begin fmt = `FMT_I; imm = {{20{instr[31]}}, instr[31:20]};end
            `OP_JALR: begin fmt = `FMT_I; imm = {{20{instr[31]}}, instr[31:20]}; end
             default:  begin fmt = `FMT_X; imm = 32'd0;end
        endcase
        
    end
    

endmodule
