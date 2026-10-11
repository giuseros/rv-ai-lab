// cpu_tb.v — integration testbench for the single-cycle core.
// Run: make sim MOD=cpu       (waveform: make wave MOD=cpu)
//
// Four independent cores, each preloaded with a different program assembled
// from tb/p_*.S by riscv64-unknown-elf-as. They share a clock and reset, run
// to completion (every program ends in `loop: jal x0, loop`), and then the
// architectural state is inspected through hierarchical references.
//
// That inspection is why cpu.v must name two of its instances exactly:
//     regfile -> u_rf      (read as <core>.u_rf.regs[n])
//     memory  -> u_mem     (read as <core>.u_mem.mem[n])
//
// Expected values were derived from the RISC-V spec and cross-checked against
// the disassembly (`make dis PROG=p_arith`). If a check fails, disassemble the
// program and single-step it in the waveform against `pc`.
`timescale 1ns/1ps

module cpu_tb;

    localparam WORDS  = 256;     // 1 KiB, enough for these programs
    localparam CYCLES = 200;

    reg clk, rst;
    integer errors = 0;
    integer checks = 0;

    cpu #(.WORDS(WORDS), .HEXFILE("build/p_arith.hex"))  c_arith  (.clk(clk), .rst(rst));
    cpu #(.WORDS(WORDS), .HEXFILE("build/p_mem.hex"))    c_mem    (.clk(clk), .rst(rst));
    cpu #(.WORDS(WORDS), .HEXFILE("build/p_branch.hex")) c_branch (.clk(clk), .rst(rst));
    cpu #(.WORDS(WORDS), .HEXFILE("build/p_jump.hex"))   c_jump   (.clk(clk), .rst(rst));

    initial clk = 0;
    always #5 clk = ~clk;

    task chk(input [31:0] got, input [31:0] exp, input [8*34:1] what);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            $display("FAIL: %0s = 0x%08h, expected 0x%08h", what, got, exp);
            errors = errors + 1;
        end else
            $display("  ok: %0s = 0x%08h", what, got);
    end
    endtask

    initial begin
        $dumpfile("build/cpu.vcd");
        $dumpvars(0, cpu_tb);

        // Release reset on a NEGEDGE: changing it in the same timestep as a
        // posedge races the DUT's always @(posedge clk). Two clean reset edges
        // (5 ns, 15 ns), reset drops at 20 ns, first real edge at 25 ns.
        rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        repeat (CYCLES) @(posedge clk);
        #1;

        $display("--- p_arith: arithmetic, logic, shifts, comparisons --------");
        chk(c_arith.u_rf.regs[1],  32'd5,          "arith x1  addi 5                 ");
        chk(c_arith.u_rf.regs[2],  32'hFFFFFFFD,   "arith x2  addi -3                ");
        chk(c_arith.u_rf.regs[3],  32'd2,          "arith x3  add  5 + -3            ");
        chk(c_arith.u_rf.regs[4],  32'd8,          "arith x4  sub  5 - -3            ");
        chk(c_arith.u_rf.regs[5],  32'd5,          "arith x5  and                    ");
        chk(c_arith.u_rf.regs[6],  32'hFFFFFFFD,   "arith x6  or                     ");
        chk(c_arith.u_rf.regs[7],  32'hFFFFFFF8,   "arith x7  xor                    ");
        chk(c_arith.u_rf.regs[8],  32'h00000050,   "arith x8  slli 5 << 4            ");
        chk(c_arith.u_rf.regs[9],  32'h0000000F,   "arith x9  srli (zero-fill)       ");
        chk(c_arith.u_rf.regs[10], 32'hFFFFFFFE,   "arith x10 srai (sign-fill)       ");
        chk(c_arith.u_rf.regs[11], 32'd1,          "arith x11 slt  -3 < 5 signed     ");
        chk(c_arith.u_rf.regs[12], 32'd0,          "arith x12 sltu not < unsigned    ");
        chk(c_arith.u_rf.regs[13], 32'd1,          "arith x13 slti                   ");
        chk(c_arith.u_rf.regs[14], 32'hFFFFFFFA,   "arith x14 xori 5 ^ -1            ");
        chk(c_arith.u_rf.regs[15], 32'h12345000,   "arith x15 lui                    ");
        chk(c_arith.u_rf.regs[17], 32'h0000103C,   "arith x17 auipc pc(0x3c) + 0x1000");
        chk(c_arith.u_rf.regs[18], 32'h00000040,   "arith x18 auipc pc(0x40) + 0     ");
        chk(c_arith.u_rf.regs[19], 32'h00000FFC,   "arith x19 auipc difference       ");

        $display("--- p_mem: loads and stores at every width ----------------");
        chk(c_mem.u_rf.regs[2],  32'hAABBCCDD, "mem x2  li (lui+addi)            ");
        chk(c_mem.u_rf.regs[3],  32'hAABBCCDD, "mem x3  lw                       ");
        chk(c_mem.u_rf.regs[4],  32'hFFFFFFDD, "mem x4  lb  byte 0, sign-extended");
        chk(c_mem.u_rf.regs[5],  32'h000000DD, "mem x5  lbu byte 0, zero-extended");
        chk(c_mem.u_rf.regs[6],  32'hFFFFFFAA, "mem x6  lb  byte 3               ");
        chk(c_mem.u_rf.regs[7],  32'hFFFFAABB, "mem x7  lh  upper half, signed   ");
        chk(c_mem.u_rf.regs[8],  32'h0000AABB, "mem x8  lhu upper half, unsigned ");
        chk(c_mem.u_rf.regs[9],  32'hAABB00DD, "mem x9  after sb x0,1(x1)        ");
        chk(c_mem.u_rf.regs[10], 32'h000000DD, "mem x10 after sh x0,2(x1)        ");
        chk(c_mem.u_mem.mem[64], 32'h000000DD, "mem mem[0x100] final             ");
        // sign bit must come from the selected lane, not from byte 0 / low half
        chk(c_mem.u_rf.regs[12], 32'hFFFFFF80, "mem x12 lb  byte 3 neg, byte 0 pos");
        chk(c_mem.u_rf.regs[13], 32'hFFFF8000, "mem x13 lh  high neg, low pos     ");
        chk(c_mem.u_rf.regs[15], 32'h0000007F, "mem x15 lb  byte 3 pos, byte 0 neg");
        chk(c_mem.u_rf.regs[16], 32'h00007F00, "mem x16 lh  high pos, low neg     ");

        $display("--- p_branch: all six branches, taken and not-taken -------");
        chk(c_branch.u_rf.regs[10], 32'd63, "branch x10 = 1+2+4+8+16+32       ");

        $display("--- p_jump: jal, jalr, link address, LSB mask -------------");
        chk(c_jump.u_rf.regs[10], 32'd57,       "jump x10 = 8+1+16+32             ");
        chk(c_jump.u_rf.regs[1],  32'h00000008, "jump x1  link address from jal   ");
        chk(c_jump.u_rf.regs[6],  32'h00000031, "jump x6  odd jalr target         ");

        // NOTE: do not check u_rf.regs[0]. x0 is not storage -- it is a
        // constant produced by the regfile's read mux, so regs[0] is
        // legitimately X. Check the architectural behaviour instead: the
        // program writes 99 to x0 and then reads it back through the datapath.
        $display("--- x0 semantics through the datapath ---------------------");
        chk(c_arith.u_rf.regs[20], 32'd0, "arith x20 = x0 + x0 after write  ");

        $display("--------------------------------------------------");
        if (errors == 0) $display("CPU: ALL TESTS PASSED (%0d checks)", checks);
        else             $display("CPU: %0d/%0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
