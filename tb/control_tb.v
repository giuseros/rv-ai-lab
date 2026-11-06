// control_tb.v — self-checking testbench for the RV32I control unit.
// Run: make sim MOD=control      (waveform: make wave MOD=control)
//
// The control unit is combinational: drive opcode/funct3/funct7, wait a
// delta, compare all twelve outputs at once.
//
// Every vector specifies EVERY output. There are no don't-cares, because the
// ALU is the address adder for every instruction that needs an address (see
// the header of rtl/control.v), so alu_a_src/alu_b_src/alu_op are meaningful
// even for stores and branches.
//
// On instructions that touch no memory the inactive defaults are required to
// be mem_size == `SZ_W and load_unsigned == 0. That is not physics, it is a
// contract: it forces you to assign every output before the case, which is
// what stops a combinational block from inferring latches.

`timescale 1ns/1ps
`include "rv32i_defs.vh"
`include "alu_ops.vh"
`include "ctrl_defs.vh"

module control_tb;

    reg  [6:0] opcode, funct7;
    reg  [2:0] funct3;

    wire       reg_write, alu_b_src, mem_read, mem_write, load_unsigned;
    wire       branch, jump, jalr, illegal;
    wire [1:0] alu_a_src, result_src, mem_size;
    wire [3:0] alu_op;

    integer errors = 0;
    integer checks = 0;

    // Index of the "poison" instruction applied before each vector. Every
    // output is checked on every vector, so an output that is never assigned
    // on some path (a latch) holds its previous value -- but only shows up if
    // that previous value differs from what the vector expects. Running the
    // whole suite once per poison makes the result independent of vector order.
    integer pz = 0;

    control dut (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write), .alu_a_src(alu_a_src), .alu_b_src(alu_b_src),
        .alu_op(alu_op), .result_src(result_src), .mem_read(mem_read), .mem_write(mem_write),
        .mem_size(mem_size), .load_unsigned(load_unsigned), .branch(branch),
        .jump(jump), .jalr(jalr), .illegal(illegal)
    );

    // the twelve outputs packed into one word, MSB..LSB
    wire [18:0] act = {reg_write, alu_a_src, alu_b_src, alu_op, result_src,
                       mem_read, mem_write, mem_size, load_unsigned, branch, jump, jalr,
                       illegal};

    // ---- pretty-printers for the multi-bit fields ----
    function [8*4:1] aname(input [1:0] v);
        case (v) `A_RS1: aname="RS1 "; `A_PC: aname="PC  "; `A_ZERO: aname="ZERO";
                 default: aname="??? "; endcase
    endfunction
    function [8*3:1] bname(input v);
        case (v) `B_RS2: bname="RS2"; `B_IMM: bname="IMM"; default: bname="???"; endcase
    endfunction
    function [8*4:1] rname(input [1:0] v);
        case (v) `RES_ALU: rname="ALU "; `RES_MEM: rname="MEM "; `RES_PC4: rname="PC4 ";
                 default: rname="??? "; endcase
    endfunction
    function [8*1:1] sname(input [1:0] v);
        case (v) `SZ_B: sname="B"; `SZ_H: sname="H"; `SZ_W: sname="W"; default: sname="?"; endcase
    endfunction
    function [8*5:1] oname(input [3:0] v);
        case (v) `ALU_ADD:oname="ADD  "; `ALU_SUB:oname="SUB  "; `ALU_AND:oname="AND  ";
                 `ALU_OR: oname="OR   "; `ALU_XOR:oname="XOR  "; `ALU_SLL:oname="SLL  ";
                 `ALU_SRL:oname="SRL  "; `ALU_SRA:oname="SRA  "; `ALU_SLT:oname="SLT  ";
                 `ALU_SLTU:oname="SLTU "; default: oname="???  "; endcase
    endfunction

    task dbit(input [8*14:1] f, input e, input a);
        if (e !== a) $display("          %0s expected %b, got %b", f, e, a);
    endtask

    // Drive an instruction chosen to push outputs away from their defaults,
    // so a stale (latched) value is visible on the vector that follows.
    task poison(input integer sel);
    begin
        case (sel)
            0: begin opcode = `OP_R;      funct3 = 3'b111; funct7 = F0; end // alu_op=AND
            1: begin opcode = `OP_LOAD;   funct3 = 3'b100; funct7 = F0; end // MEM,SZ_B,unsigned
            2: begin opcode = `OP_STORE;  funct3 = 3'b001; funct7 = F0; end // mem_write,SZ_H
            3: begin opcode = `OP_BRANCH; funct3 = 3'b000; funct7 = F0; end // branch,A_PC
            4: begin opcode = `OP_JAL;    funct3 = 3'b000; funct7 = F0; end // jump,RES_PC4
            5: begin opcode = `OP_JALR;   funct3 = 3'b000; funct7 = F0; end // jalr
            6: begin opcode = `OP_LUI;    funct3 = 3'b000; funct7 = F0; end // A_ZERO
            default: begin opcode = 7'b1111111; funct3 = 3'b111; funct7 = F1; end // illegal
        endcase
        #1;
    end
    endtask

    task chk(input [8*14:1] name, input [6:0] op, input [2:0] f3,
             input [6:0] f7, input [18:0] exp);
        begin
            poison(pz);
            opcode = op; funct3 = f3; funct7 = f7;
            #1;
            checks = checks + 1;
            if (act === exp) begin
                if (pz == 0) $display("  ok: %0s", name);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s  opcode=%b funct3=%b funct7=%b  [after poison %0d]",
                         name, op, f3, f7, pz);
                dbit("reg_write    ", exp[18],    reg_write);
                if (exp[17:16] !== alu_a_src)
                    $display("          alu_a_src     expected %0s, got %0s",
                             aname(exp[17:16]), aname(alu_a_src));
                if (exp[15] !== alu_b_src)
                    $display("          alu_b_src     expected %0s, got %0s",
                             bname(exp[15]), bname(alu_b_src));
                if (exp[14:11] !== alu_op)
                    $display("          alu_op        expected %0s, got %0s",
                             oname(exp[14:11]), oname(alu_op));
                if (exp[10:9] !== result_src)
                    $display("          result_src    expected %0s, got %0s",
                             rname(exp[10:9]), rname(result_src));
                dbit("mem_read     ", exp[8], mem_read);
                dbit("mem_write    ", exp[7], mem_write);
                if (exp[6:5] !== mem_size)
                    $display("          mem_size      expected %0s, got %0s",
                             sname(exp[6:5]), sname(mem_size));
                dbit("load_unsigned", exp[4], load_unsigned);
                dbit("branch       ", exp[3], branch);
                dbit("jump         ", exp[2], jump);
                dbit("jalr         ", exp[1], jalr);
                dbit("illegal      ", exp[0], illegal);
            end
        end
    endtask

    // ---- expected-value builders, one per instruction class ----
    function [18:0] R(input [3:0] o);
        R = {1'b1, `A_RS1, `B_RS2, o, `RES_ALU, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0000};
    endfunction
    function [18:0] I(input [3:0] o);
        I = {1'b1, `A_RS1, `B_IMM, o, `RES_ALU, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0000};
    endfunction
    function [18:0] LD(input [1:0] sz, input u);
        LD = {1'b1, `A_RS1, `B_IMM, `ALU_ADD, `RES_MEM, 1'b1, 1'b0, sz, u, 4'b0000};
    endfunction
    function [18:0] ST(input [1:0] sz);
        ST = {1'b0, `A_RS1, `B_IMM, `ALU_ADD, `RES_ALU, 1'b0, 1'b1, sz, 1'b0, 4'b0000};
    endfunction
    function [18:0] BR;
        input dummy;
        BR = {1'b0, `A_PC, `B_IMM, `ALU_ADD, `RES_ALU, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b1000};
    endfunction
    function [18:0] BAD;
        input dummy;
        BAD = {1'b0, `A_RS1, `B_RS2, `ALU_ADD, `RES_ALU, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0001};
    endfunction

    localparam [18:0] E_LUI   = {1'b1, `A_ZERO, `B_IMM, `ALU_ADD, `RES_ALU, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0000};
    localparam [18:0] E_AUIPC = {1'b1, `A_PC,   `B_IMM, `ALU_ADD, `RES_ALU, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0000};
    localparam [18:0] E_JAL   = {1'b1, `A_PC,   `B_IMM, `ALU_ADD, `RES_PC4, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0100};
    localparam [18:0] E_JALR  = {1'b1, `A_RS1,  `B_IMM, `ALU_ADD, `RES_PC4, 1'b0, 1'b0, `SZ_W, 1'b0, 4'b0010};

    localparam [6:0] F0 = 7'b0000000, F1 = 7'b0100000;

    // The full vector list, wrapped in a task so it can be replayed once per
    // poison instruction (see `poison` above).
    task run_vectors;
    begin
            $display("--- R-type -------------------------------------------------");
            chk("add           ", `OP_R, 3'b000, F0, R(`ALU_ADD));
            chk("sub           ", `OP_R, 3'b000, F1, R(`ALU_SUB));
            chk("sll           ", `OP_R, 3'b001, F0, R(`ALU_SLL));
            chk("slt           ", `OP_R, 3'b010, F0, R(`ALU_SLT));
            chk("sltu          ", `OP_R, 3'b011, F0, R(`ALU_SLTU));
            chk("xor           ", `OP_R, 3'b100, F0, R(`ALU_XOR));
            chk("srl           ", `OP_R, 3'b101, F0, R(`ALU_SRL));
            chk("sra           ", `OP_R, 3'b101, F1, R(`ALU_SRA));
            chk("or            ", `OP_R, 3'b110, F0, R(`ALU_OR));
            chk("and           ", `OP_R, 3'b111, F0, R(`ALU_AND));
    
            $display("--- I-type ALU ---------------------------------------------");
            chk("addi          ", `OP_IMM, 3'b000, F0, I(`ALU_ADD));
            chk("addi imm hi   ", `OP_IMM, 3'b000, F1, I(`ALU_ADD));  // funct7 is IMMEDIATE here
            chk("slti          ", `OP_IMM, 3'b010, F0, I(`ALU_SLT));
            chk("sltiu         ", `OP_IMM, 3'b011, F0, I(`ALU_SLTU));
            chk("xori          ", `OP_IMM, 3'b100, F1, I(`ALU_XOR));  // ditto
            chk("ori           ", `OP_IMM, 3'b110, F1, I(`ALU_OR));   // ditto
            chk("andi          ", `OP_IMM, 3'b111, F0, I(`ALU_AND));
            chk("slli          ", `OP_IMM, 3'b001, F0, I(`ALU_SLL));
            chk("srli          ", `OP_IMM, 3'b101, F0, I(`ALU_SRL));
            chk("srai          ", `OP_IMM, 3'b101, F1, I(`ALU_SRA));
    
            $display("--- loads --------------------------------------------------");
            chk("lb            ", `OP_LOAD, 3'b000, F0, LD(`SZ_B, 1'b0));
            chk("lh            ", `OP_LOAD, 3'b001, F0, LD(`SZ_H, 1'b0));
            chk("lw            ", `OP_LOAD, 3'b010, F0, LD(`SZ_W, 1'b0));
            chk("lbu           ", `OP_LOAD, 3'b100, F0, LD(`SZ_B, 1'b1));
            chk("lhu           ", `OP_LOAD, 3'b101, F0, LD(`SZ_H, 1'b1));
            chk("load f3=011   ", `OP_LOAD, 3'b011, F0, BAD(1'b0));
            chk("load f3=111   ", `OP_LOAD, 3'b111, F0, BAD(1'b0));
    
            $display("--- stores -------------------------------------------------");
            chk("sb            ", `OP_STORE, 3'b000, F0, ST(`SZ_B));
            chk("sh            ", `OP_STORE, 3'b001, F0, ST(`SZ_H));
            chk("sw            ", `OP_STORE, 3'b010, F0, ST(`SZ_W));
            chk("store f3=011  ", `OP_STORE, 3'b011, F0, BAD(1'b0));
            chk("store f3=100  ", `OP_STORE, 3'b100, F0, BAD(1'b0));
    
            $display("--- branches -----------------------------------------------");
            chk("beq           ", `OP_BRANCH, 3'b000, F0, BR(1'b0));
            chk("bne           ", `OP_BRANCH, 3'b001, F0, BR(1'b0));
            chk("blt           ", `OP_BRANCH, 3'b100, F0, BR(1'b0));
            chk("bge           ", `OP_BRANCH, 3'b101, F0, BR(1'b0));
            chk("bltu          ", `OP_BRANCH, 3'b110, F0, BR(1'b0));
            chk("bgeu          ", `OP_BRANCH, 3'b111, F0, BR(1'b0));
            chk("branch f3=010 ", `OP_BRANCH, 3'b010, F0, BAD(1'b0));
            chk("branch f3=011 ", `OP_BRANCH, 3'b011, F0, BAD(1'b0));
    
            $display("--- upper immediate and jumps ------------------------------");
            chk("lui           ", `OP_LUI,   3'b000, F0, E_LUI);
            chk("auipc         ", `OP_AUIPC, 3'b000, F0, E_AUIPC);
            chk("jal           ", `OP_JAL,   3'b000, F0, E_JAL);
            chk("jalr          ", `OP_JALR,  3'b000, F0, E_JALR);
            chk("jalr f3=001   ", `OP_JALR,  3'b001, F0, BAD(1'b0));
    
            $display("--- illegal opcodes ----------------------------------------");
            chk("opcode 0000000", 7'b0000000, 3'b000, F0, BAD(1'b0));
            chk("opcode 1111111", 7'b1111111, 3'b111, F1, BAD(1'b0));
            chk("opcode 0001011", 7'b0001011, 3'b000, F0, BAD(1'b0));  // custom-0, unimplemented
    end
    endtask

    initial begin
        $dumpfile("build/control.vcd");
        $dumpvars(0, control_tb);

        // Replay every vector after each poison, so a latched output cannot
        // hide behind a lucky predecessor.
        for (pz = 0; pz < 8; pz = pz + 1)
            run_vectors;


        $display("--------------------------------------------------");
        if (errors == 0)
            $display("CONTROL: ALL TESTS PASSED (%0d checks)", checks);
        else
            $display("CONTROL: %0d/%0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
