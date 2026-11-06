// control.v — RV32I control unit (opcode + funct fields -> datapath controls)
//
// Purely combinational. No clock, no state.
//
// >>> YOUR JOB: implement the body. The port list is the contract that
//     tb/control_tb.v compiles against — keep the names and widths.
//
// The decoder (step 3) split the instruction word. This module decides what
// the datapath DOES with those fields. Together they are the whole front end;
// rtl/cpu.v then just wires the muxes these signals point at.
//
// ---------------------------------------------------------------------------
// The one design decision that makes this simple
// ---------------------------------------------------------------------------
// The ALU is the address adder for EVERY instruction that needs an address:
//
//   branch   ALU computes PC  + imm   -> the branch target
//   jal      ALU computes PC  + imm   -> the jump target
//   jalr     ALU computes rs1 + imm   -> the jump target
//   auipc    ALU computes PC  + imm   -> the result
//   lui      ALU computes 0   + imm   -> the result
//   load     ALU computes rs1 + imm   -> the effective address
//   store    ALU computes rs1 + imm   -> the effective address
//
// So alu_a_src / alu_b_src / alu_op are DEFINED for every instruction. There
// are no don't-cares in this module, and the testbench checks all twelve
// outputs on all forty-three vectors. Note this means branches do NOT use the
// ALU to compare — cpu.v gets a separate comparator, which is why `branch` is
// a single bit here and funct3 does the rest downstream.
//
// ---------------------------------------------------------------------------
// Write it as defaults-then-override
// ---------------------------------------------------------------------------
//   always @* begin
//       reg_write = 1'b0;  mem_write = 1'b0;  branch = 1'b0;  ...   // defaults
//       case (opcode)
//           `OP_R: begin ... end                                    // overrides
//           ...
//       endcase
//   end
// Assigning every output at the top means no path through the case can leave
// one unassigned, which is what creates a latch in a combinational block. The
// testbench requires the inactive defaults to be the ones above: mem_size
// reads `SZ_W and load_unsigned reads 0 on instructions that touch no memory.
//
// ---------------------------------------------------------------------------
// Traps to avoid
// ---------------------------------------------------------------------------
//   - funct7 is NOT part of the immediate-shift decision for most of OP_IMM.
//     For addi/slti/sltiu/xori/ori/andi the bits of funct7 are the TOP OF THE
//     IMMEDIATE, so `addi x1,x2,1024` has funct7[5] set and is still an ADD.
//     Only funct3==101 (srli/srai) may look at funct7[5]. Getting this wrong
//     turns some perfectly ordinary addi into a sub, and the testbench has a
//     vector aimed squarely at it.
//   - For OP_R, funct7[5] selects add/sub (funct3==000) and srl/sra
//     (funct3==101), and nothing else.
//   - lbu/lhu set load_unsigned; lb/lh/lw do not. There is no "lwu" in RV32I.
//   - `illegal` covers both an unknown opcode AND a funct3 that does not exist
//     for a known opcode (e.g. LOAD with funct3==3'b011). On any illegal
//     instruction, reg_write and mem_write must be 0 — a bad instruction must
//     not have side effects.

`timescale 1ns/1ps
`include "rv32i_defs.vh"
`include "alu_ops.vh"
`include "ctrl_defs.vh"

module control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,

    output reg        reg_write,      // 1 = write rd at the end of the cycle
    output reg  [1:0] alu_a_src,      // `A_RS1 / `A_PC / `A_ZERO
    output reg        alu_b_src,      // `B_RS2 / `B_IMM
    output reg  [3:0] alu_op,         // see alu_ops.vh
    output reg  [1:0] result_src,     // `RES_ALU / `RES_MEM / `RES_PC4
    output reg        mem_read,       // 1 = this is a load
    output reg        mem_write,      // 1 = this is a store
    output reg  [1:0] mem_size,       // `SZ_B / `SZ_H / `SZ_W
    output reg        load_unsigned,  // 1 = lbu/lhu (zero-extend, not sign)
    output reg        branch,         // 1 = conditional branch (cpu.v compares)
    output reg        jump,           // 1 = jal
    output reg        jalr,           // 1 = jalr
    output reg        illegal         // 1 = unrecognised opcode or funct3
);

    always @(*) begin
        illegal = 1'b0;
        reg_write = 1'b0;
        jalr = 1'b0;
        branch = 1'b0;
        load_unsigned = 1'b0;
        mem_read = 1'b0;
        mem_write = 1'b0;
        reg_write = 1'b0;
        load_unsigned = 1'b0;
        mem_size = `SZ_W;
        jump = 1'b0;
        alu_b_src = `B_RS2;
        alu_a_src = `A_RS1;
        result_src = `RES_ALU;
        alu_op = `ALU_ADD;
        case(opcode) 
        `OP_R: begin  
            reg_write = 1'b1;
            alu_a_src = `A_RS1;
            alu_b_src = `B_RS2;
            result_src = `RES_ALU;
            case (funct3)
               3'b000:  alu_op = funct7[5] ? `ALU_SUB : `ALU_ADD;
               3'b001: alu_op = `ALU_SLL;
               3'b010: alu_op = `ALU_SLT;
               3'b011: alu_op = `ALU_SLTU;
               3'b100: alu_op = `ALU_XOR;
               3'b101: alu_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
               3'b110: alu_op = `ALU_OR;
               3'b111: alu_op = `ALU_AND;
               default: illegal = 1'b1;
            endcase
        end
        `OP_IMM: begin
            reg_write = 1'b1;
            alu_a_src = `A_RS1;
            alu_b_src = `B_IMM;
            result_src = `RES_ALU;
            illegal = 1'b0;
            case (funct3)
               3'b000: alu_op = `ALU_ADD;
               3'b001: alu_op = `ALU_SLL;
               3'b010: alu_op = `ALU_SLT;
               3'b011: alu_op = `ALU_SLTU;
               3'b100: alu_op = `ALU_XOR;
               3'b101: alu_op = funct7[5]? `ALU_SRA: `ALU_SRL;
               3'b110: alu_op = `ALU_OR;
               3'b111: alu_op = `ALU_AND;
               default: illegal = 1'b1;
            endcase
        end
        `OP_LOAD: begin
            case (funct3)
                3'b000, 3'b001, 3'b010, 3'b100, 3'b101: begin
                    reg_write = 1'b1;
                    alu_a_src = `A_RS1;
                    alu_b_src = `B_IMM;
                    alu_op = `ALU_ADD;
                    result_src = `RES_MEM;
                    mem_read = 1'b1;
                    load_unsigned = funct3[2];
                    mem_size = funct3[1:0];
                end 
                default: illegal = 1'b1;
            endcase
        end
        `OP_STORE: begin
            case (funct3)
                3'b000, 3'b001, 3'b010: begin
                    alu_a_src = `A_RS1;
                    alu_b_src = `B_IMM;
                    alu_op = `ALU_ADD;
                    mem_size = funct3[1:0];
                    mem_write = 1'b1;
                end
                default: illegal = 1'b1;
            endcase
        end
        `OP_BRANCH: begin
            if (funct3 == 3'b010 || funct3 == 3'b011) begin
                illegal = 1'b1;
            end else begin
                alu_a_src = `A_PC;
                alu_b_src = `B_IMM;
                alu_op = `ALU_ADD;
                branch = 1;
            end 
        end
        `OP_JAL: begin
            alu_a_src = `A_PC;
            alu_b_src = `B_IMM;
            alu_op = `ALU_ADD;
            reg_write = 1'b1;
            result_src = `RES_PC4;
            jump = 1'b1;
        end
        `OP_JALR: begin
            if (funct3 == 3'b0) begin
                alu_a_src = `A_RS1;
                alu_b_src = `B_IMM;
                alu_op = `ALU_ADD;
                result_src = `RES_PC4;
                reg_write = 1'b1;
                jalr = 1'b1;
            end else begin
                illegal = 1'b1;
            end
        end
        `OP_LUI: begin
            alu_a_src = `A_ZERO;
            alu_b_src = `B_IMM;
            alu_op = `ALU_ADD;
            result_src = `RES_ALU;
            illegal = 1'b0;
            reg_write = 1'b1;
        end
        `OP_AUIPC: begin
            alu_a_src = `A_PC;
            alu_b_src = `B_IMM;
            alu_op = `ALU_ADD;
            illegal = 1'b0;
            reg_write = 1'b1;
            result_src = `RES_ALU;
        end
        default: begin
            illegal = 1'b1;
        end
        endcase
    end

endmodule
