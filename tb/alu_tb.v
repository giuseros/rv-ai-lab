// alu_tb.v — self-checking testbench for the RV32I ALU.
// Run: make sim MOD=alu       (waveform: make wave MOD=alu)
//
// The ALU is combinational, so there is no clock. Each check drives the
// inputs, waits a delta (#1) for the logic to settle, and compares.
// Every check also verifies the `zero` flag, derived from the expected y.
`timescale 1ns/1ps
`include "alu_ops.vh"

module alu_tb;

    reg  [31:0] a, b;
    reg  [3:0]  alu_op;
    wire [31:0] y;
    wire        zero;

    integer errors = 0;

    alu dut (.a(a), .b(b), .alu_op(alu_op), .y(y), .zero(zero));

    // Names for the failure messages.
    function [8*5:1] opname(input [3:0] op);
        case (op)
            `ALU_ADD:  opname = "ADD ";
            `ALU_SUB:  opname = "SUB ";
            `ALU_AND:  opname = "AND ";
            `ALU_OR:   opname = "OR  ";
            `ALU_XOR:  opname = "XOR ";
            `ALU_SLL:  opname = "SLL ";
            `ALU_SRL:  opname = "SRL ";
            `ALU_SRA:  opname = "SRA ";
            `ALU_SLT:  opname = "SLT ";
            `ALU_SLTU: opname = "SLTU";
            default:  opname = "????";
        endcase
    endfunction

    // Drive one operation and check both y and the zero flag.
    task check(input [3:0] op, input [31:0] av, input [31:0] bv,
               input [31:0] exp);
        reg exp_zero;
    begin
        alu_op = op; a = av; b = bv;
        #1;
        exp_zero = (exp == 32'd0);
        if (y !== exp) begin
            $display("FAIL: %0s 0x%08h, 0x%08h -> 0x%08h, expected 0x%08h",
                     opname(op), av, bv, y, exp);
            errors = errors + 1;
        end else if (zero !== exp_zero) begin
            $display("FAIL: %0s 0x%08h, 0x%08h -> y ok (0x%08h) but zero=%b, expected %b",
                     opname(op), av, bv, y, zero, exp_zero);
            errors = errors + 1;
        end else begin
            $display("  ok: %0s 0x%08h, 0x%08h -> 0x%08h (zero=%b)",
                     opname(op), av, bv, y, zero);
        end
    end
    endtask

    initial begin
        $dumpfile("build/alu.vcd");
        $dumpvars(0, alu_tb);

        a = 0; b = 0; alu_op = `ALU_ADD;

        // --- ADD: wraps mod 2^32, no overflow trap in RV32I ---
        check(`ALU_ADD,  32'd1,        32'd2,        32'd3);
        check(`ALU_ADD,  32'hFFFF_FFFF, 32'd1,       32'd0);           // wraps to 0 -> zero flag
        check(`ALU_ADD,  32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFE); // (-1)+(-1)

        // --- SUB ---
        check(`ALU_SUB,  32'd5,        32'd3,        32'd2);
        check(`ALU_SUB,  32'd3,        32'd5,        32'hFFFF_FFFE);   // -2
        check(`ALU_SUB,  32'h1234_5678, 32'h1234_5678, 32'd0);         // zero flag

        // --- bitwise ---
        check(`ALU_AND,  32'hF0F0_F0F0, 32'h0FF0_0FF0, 32'h00F0_00F0);
        check(`ALU_OR,   32'hF0F0_F0F0, 32'h0FF0_0FF0, 32'hFFF0_FFF0);
        check(`ALU_XOR,  32'hF0F0_F0F0, 32'h0FF0_0FF0, 32'hFF00_FF00);
        check(`ALU_XOR,  32'hAAAA_AAAA, 32'hAAAA_AAAA, 32'd0);
        check(`ALU_AND,  32'hFFFF_FFFF, 32'h0000_0000, 32'd0);

        // --- SLL: shift amount is b[4:0] ONLY ---
        check(`ALU_SLL,  32'd1,        32'd0,        32'd1);
        check(`ALU_SLL,  32'd1,        32'd31,       32'h8000_0000);
        check(`ALU_SLL,  32'hFFFF_FFFF, 32'd4,       32'hFFFF_FFF0);
        check(`ALU_SLL,  32'd1,        32'd33,       32'd2);           // 33 & 31 == 1
        check(`ALU_SLL,  32'd1,        32'hFFFF_FFE1, 32'd2);          // low 5 bits = 1

        // --- SRL: zero-fill ---
        check(`ALU_SRL,  32'h8000_0000, 32'd4,       32'h0800_0000);
        check(`ALU_SRL,  32'h8000_0000, 32'd31,      32'd1);
        check(`ALU_SRL,  32'hFFFF_FFFF, 32'd28,      32'h0000_000F);
        check(`ALU_SRL,  32'h8000_0000, 32'd36,      32'h0800_0000);   // 36 & 31 == 4

        // --- SRA: sign-fill ---
        check(`ALU_SRA,  32'h8000_0000, 32'd4,       32'hF800_0000);
        check(`ALU_SRA,  32'h7FFF_FFFF, 32'd4,       32'h07FF_FFFF);   // positive: same as SRL
        check(`ALU_SRA,  32'hFFFF_FFFF, 32'd31,      32'hFFFF_FFFF);   // -1 >>> anything == -1
        check(`ALU_SRA,  32'h8000_0000, 32'd36,      32'hF800_0000);   // 36 & 31 == 4

        // --- SLT: SIGNED comparison ---
        check(`ALU_SLT,  32'hFFFF_FFFF, 32'd1,       32'd1);           // -1 <  1
        check(`ALU_SLT,  32'd1,        32'hFFFF_FFFF, 32'd0);          //  1 !< -1
        check(`ALU_SLT,  32'd5,        32'd5,        32'd0);           // equal
        check(`ALU_SLT,  32'h8000_0000, 32'd0,       32'd1);           // most negative < 0
        check(`ALU_SLT,  32'd3,        32'd7,        32'd1);

        // --- SLTU: UNSIGNED comparison (same bits, opposite answers) ---
        check(`ALU_SLTU, 32'hFFFF_FFFF, 32'd1,       32'd0);           // huge !< 1
        check(`ALU_SLTU, 32'd1,        32'hFFFF_FFFF, 32'd1);          // 1 < huge
        check(`ALU_SLTU, 32'h8000_0000, 32'd0,       32'd0);
        check(`ALU_SLTU, 32'd5,        32'd5,        32'd0);

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALU: ALL TESTS PASSED");
        else             $display("ALU: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
