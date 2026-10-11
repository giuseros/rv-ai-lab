// decoder_tb.v — self-checking testbench for the RV32I instruction decoder.
// Run: make sim MOD=decoder      (waveform: make wave MOD=decoder)
//
// The vectors below are NOT hand-encoded. They were produced by assembling
// real instructions with riscv64-unknown-elf-as and reading back the words
// with objdump, then decoding those words with an independent reference
// implementation of the spec. The branch and jump immediates were additionally
// cross-checked against objdump's own computed branch targets. So if your
// decoder disagrees with a vector, the vector is right.
//
// The decoder is combinational: drive instr, wait a delta, compare.
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module decoder_tb;

    reg  [31:0] instr;
    wire [6:0]  opcode, funct7;
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3, fmt;
    wire [31:0] imm;

    integer errors = 0;

    decoder dut (
        .instr(instr), .opcode(opcode), .rd(rd), .funct3(funct3),
        .rs1(rs1), .rs2(rs2), .funct7(funct7), .imm(imm), .fmt(fmt)
    );

    function [8*4:1] fmtname(input [2:0] f);
        case (f)
            `FMT_R:  fmtname = "R   ";
            `FMT_I:  fmtname = "I   ";
            `FMT_S:  fmtname = "S   ";
            `FMT_B:  fmtname = "B   ";
            `FMT_U:  fmtname = "U   ";
            `FMT_J:  fmtname = "J   ";
            `FMT_X:  fmtname = "X   ";
            default: fmtname = "??? ";
        endcase
    endfunction

    // One vector: drive the word, check every output, report the first
    // mismatch found so the message points at one thing.
    task chk(input [31:0] word,   input [2:0] e_fmt,  input [6:0] e_opcode,
             input [4:0] e_rd,    input [2:0] e_f3,   input [4:0] e_rs1,
             input [4:0] e_rs2,   input [6:0] e_f7,   input [31:0] e_imm,
             input [8*20:1] name);
    begin
        instr = word;
        #1;
        if (fmt !== e_fmt)
            report(name, word, "fmt",    {29'd0, fmt},    {29'd0, e_fmt});
        else if (opcode !== e_opcode)
            report(name, word, "opcode", {25'd0, opcode}, {25'd0, e_opcode});
        else if (rd !== e_rd)
            report(name, word, "rd",     {27'd0, rd},     {27'd0, e_rd});
        else if (funct3 !== e_f3)
            report(name, word, "funct3", {29'd0, funct3}, {29'd0, e_f3});
        else if (rs1 !== e_rs1)
            report(name, word, "rs1",    {27'd0, rs1},    {27'd0, e_rs1});
        else if (rs2 !== e_rs2)
            report(name, word, "rs2",    {27'd0, rs2},    {27'd0, e_rs2});
        else if (funct7 !== e_f7)
            report(name, word, "funct7", {25'd0, funct7}, {25'd0, e_f7});
        else if (imm !== e_imm)
            report(name, word, "imm",    imm,             e_imm);
        else
            $display("  ok: %08h  %0s  %0s imm=0x%08h", word, fmtname(fmt), name, imm);
    end
    endtask

    task report(input [8*20:1] name, input [31:0] word, input [8*6:1] field,
                input [31:0] got,   input [31:0] exp);
    begin
        $display("FAIL: %08h  %0s", word, name);
        $display("        %0s = 0x%08h, expected 0x%08h", field, got, exp);
        errors = errors + 1;
    end
    endtask

    initial begin
        $dumpfile("build/decoder.vcd");
        $dumpvars(0, decoder_tb);
        instr = 32'd0;

        // ---- R-type: no immediate; funct7 is what separates add from sub ----
        chk(32'h003100b3, `FMT_R, 7'h33, 5'd1 , 3'd0, 5'd2 , 5'd3 , 7'h00, 32'h00000000, "add x1,x2,x3");
        chk(32'h407302b3, `FMT_R, 7'h33, 5'd5 , 3'd0, 5'd6 , 5'd7 , 7'h20, 32'h00000000, "sub x5,x6,x7");
        chk(32'h00a4f433, `FMT_R, 7'h33, 5'd8 , 3'd7, 5'd9 , 5'd10, 7'h00, 32'h00000000, "and x8,x9,x10");
        chk(32'h00d615b3, `FMT_R, 7'h33, 5'd11, 3'd1, 5'd12, 5'd13, 7'h00, 32'h00000000, "sll x11,x12,x13");
        chk(32'h0107a733, `FMT_R, 7'h33, 5'd14, 3'd2, 5'd15, 5'd16, 7'h00, 32'h00000000, "slt x14,x15,x16");

        // ---- I-type: sign-extended instr[31:20]. srai/slli reuse the top bits as funct7+shamt ----
        chk(32'hfff10093, `FMT_I, 7'h13, 5'd1 , 3'd0, 5'd2 , 5'd31, 7'h7f, 32'hffffffff, "addi x1,x2,-1");
        chk(32'h7ff10093, `FMT_I, 7'h13, 5'd1 , 3'd0, 5'd2 , 5'd31, 7'h3f, 32'h000007ff, "addi x1,x2,2047");
        chk(32'h80010093, `FMT_I, 7'h13, 5'd1 , 3'd0, 5'd2 , 5'd0 , 7'h40, 32'hfffff800, "addi x1,x2,-2048");
        chk(32'hff027193, `FMT_I, 7'h13, 5'd3 , 3'd7, 5'd4 , 5'd16, 7'h7f, 32'hfffffff0, "andi x3,x4,-16");
        chk(32'hfff32293, `FMT_I, 7'h13, 5'd5 , 3'd2, 5'd6 , 5'd31, 7'h7f, 32'hffffffff, "slti x5,x6,-1");
        chk(32'hfff43393, `FMT_I, 7'h13, 5'd7 , 3'd3, 5'd8 , 5'd31, 7'h7f, 32'hffffffff, "sltiu x7,x8,-1");
        chk(32'h40555493, `FMT_I, 7'h13, 5'd9 , 3'd5, 5'd10, 5'd5 , 7'h20, 32'h00000405, "srai x9,x10,0x5");
        chk(32'h01f61593, `FMT_I, 7'h13, 5'd11, 3'd1, 5'd12, 5'd31, 7'h00, 32'h0000001f, "slli x11,x12,0x1f");
        chk(32'hffc12083, `FMT_I, 7'h03, 5'd1 , 3'd2, 5'd2 , 5'd28, 7'h7f, 32'hfffffffc, "lw x1,-4(x2)");
        chk(32'h7ff20183, `FMT_I, 7'h03, 5'd3 , 3'd0, 5'd4 , 5'd31, 7'h3f, 32'h000007ff, "lb x3,2047(x4)");
        chk(32'h80035283, `FMT_I, 7'h03, 5'd5 , 3'd5, 5'd6 , 5'd0 , 7'h40, 32'hfffff800, "lhu x5,-2048(x6)");
        chk(32'hff8100e7, `FMT_I, 7'h67, 5'd1 , 3'd0, 5'd2 , 5'd24, 7'h7f, 32'hfffffff8, "jalr x1,-8(x2)");

        // ---- S-type: immediate split across instr[31:25] and instr[11:7] ----
        chk(32'h00312423, `FMT_S, 7'h23, 5'd8 , 3'd2, 5'd2 , 5'd3 , 7'h00, 32'h00000008, "sw x3,8(x2)");
        chk(32'hfe312623, `FMT_S, 7'h23, 5'd12, 3'd2, 5'd2 , 5'd3 , 7'h7f, 32'hffffffec, "sw x3,-20(x2)");
        chk(32'h7e530fa3, `FMT_S, 7'h23, 5'd31, 3'd0, 5'd6 , 5'd5 , 7'h3f, 32'h000007ff, "sb x5,2047(x6)");
        chk(32'h80741023, `FMT_S, 7'h23, 5'd0 , 3'd1, 5'd8 , 5'd7 , 7'h40, 32'hfffff800, "sh x7,-2048(x8)");

        // ---- B-type: scrambled halfword offset, bit 0 implicit 0, sign-extended ----
        chk(32'h0a208c63, `FMT_B, 7'h63, 5'd24, 3'd0, 5'd1 , 5'd2 , 7'h05, 32'h000000b8, "beq x1,x2,11c <fwd>");
        chk(32'hf8419ce3, `FMT_B, 7'h63, 5'd25, 3'd1, 5'd3 , 5'd4 , 7'h7c, 32'hffffff98, "bne x3,x4,0 <_start>");
        chk(32'h0a62c863, `FMT_B, 7'h63, 5'd16, 3'd4, 5'd5 , 5'd6 , 7'h05, 32'h000000b0, "blt x5,x6,11c <fwd>");
        chk(32'hf883f8e3, `FMT_B, 7'h63, 5'd17, 3'd7, 5'd7 , 5'd8 , 7'h7c, 32'hffffff90, "bgeu x7,x8,0 <_start>");

        // ---- U-type: instr[31:12] is already the top 20 bits -- no sign extension ----
        chk(32'hfffff0b7, `FMT_U, 7'h37, 5'd1 , 3'd7, 5'd31, 5'd31, 7'h7f, 32'hfffff000, "lui x1,0xfffff");
        chk(32'h00001137, `FMT_U, 7'h37, 5'd2 , 3'd1, 5'd0 , 5'd0 , 7'h00, 32'h00001000, "lui x2,0x1");
        chk(32'h12345197, `FMT_U, 7'h17, 5'd3 , 3'd5, 5'd8 , 5'd3 , 7'h09, 32'h12345000, "auipc x3,0x12345");
        chk(32'h80000217, `FMT_U, 7'h17, 5'd4 , 3'd0, 5'd0 , 5'd0 , 7'h40, 32'h80000000, "auipc x4,0x80000");

        // ---- J-type: scrambled 21-bit halfword offset, sign-extended ----
        chk(32'h0a8000ef, `FMT_J, 7'h6f, 5'd1 , 3'd0, 5'd0 , 5'd8 , 7'h05, 32'h000000a8, "jal x1,11c <fwd>");
        chk(32'hf89ff16f, `FMT_J, 7'h6f, 5'd2 , 3'd7, 5'd31, 5'd9 , 7'h7c, 32'hffffff88, "jal x2,0 <_start>");
        // ---- unrecognised opcode: fmt must be `FMT_X and imm must be 0 ----
        chk(32'hFFFFFFFF, `FMT_X, 7'h7f, 5'd31, 3'd7, 5'd31, 5'd31, 7'h7f, 32'h00000000, "all-ones (illegal)");
        chk(32'h0000006B, `FMT_X, 7'h6b, 5'd0 , 3'd0, 5'd0 , 5'd0 , 7'h00, 32'h00000000, "unused opcode 0x6b");

        $display("--------------------------------------------------");
        if (errors == 0) $display("DECODER: ALL TESTS PASSED");
        else             $display("DECODER: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
