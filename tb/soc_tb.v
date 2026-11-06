// soc_tb.v — system testbench: the core plus its memory, running programs.
// Run: make sim MOD=soc       (waveform: make wave MOD=soc)
//
// Every program in tb/p_*.S runs on its own SoC, and the whole set runs three
// times: with the RAM answering instantly (latency 0), after 1 extra cycle, and
// after 3. All twelve SoCs share a clock and reset, run to completion (every
// program ends in `loop: jal x0, loop`), and must end in exactly the same
// architectural state. Latency may change how long a program takes, never what
// it computes: that is what the CPU's stall on d_ready guarantees.
//
// State is inspected through hierarchical references, so these instance names
// are part of the contract:
//     soc.v:  cpu    -> u_cpu    memory -> u_mem   (read as <soc>.u_mem.mem[n])
//     cpu.v:  regfile -> u_rf                      (read as <soc>.u_cpu.u_rf.regs[n])
//
// Expected values were derived from the RISC-V spec and cross-checked against
// the disassembly (`make dis PROG=p_arith`). If a check fails, run the retire
// log for that SoC (`make trace PROG=p_mem LAT=3`) and compare it with LAT=0.
`timescale 1ns/1ps

// ---- per-program checks ----
// Each macro checks one SoC, C, and prefixes every message with the tag T.
// `define is plain text substitution, so C can be a hierarchical instance name.
// Do not check u_rf.regs[0]: x0 is a read-mux constant, the array slot is X.
`define CHECK_ARITH(C, T) \
    chk(C.u_cpu.i_data, 32'h0000006F, {T, "arith reached its final loop"}); \
    chk(C.u_cpu.u_rf.regs[1], 32'd5, {T, "arith x1  addi 5"}); \
    chk(C.u_cpu.u_rf.regs[2], 32'hFFFFFFFD, {T, "arith x2  addi -3"}); \
    chk(C.u_cpu.u_rf.regs[3], 32'd2, {T, "arith x3  add  5 + -3"}); \
    chk(C.u_cpu.u_rf.regs[4], 32'd8, {T, "arith x4  sub  5 - -3"}); \
    chk(C.u_cpu.u_rf.regs[5], 32'd5, {T, "arith x5  and"}); \
    chk(C.u_cpu.u_rf.regs[6], 32'hFFFFFFFD, {T, "arith x6  or"}); \
    chk(C.u_cpu.u_rf.regs[7], 32'hFFFFFFF8, {T, "arith x7  xor"}); \
    chk(C.u_cpu.u_rf.regs[8], 32'h00000050, {T, "arith x8  slli 5 << 4"}); \
    chk(C.u_cpu.u_rf.regs[9], 32'h0000000F, {T, "arith x9  srli (zero-fill)"}); \
    chk(C.u_cpu.u_rf.regs[10], 32'hFFFFFFFE, {T, "arith x10 srai (sign-fill)"}); \
    chk(C.u_cpu.u_rf.regs[11], 32'd1, {T, "arith x11 slt  -3 < 5 signed"}); \
    chk(C.u_cpu.u_rf.regs[12], 32'd0, {T, "arith x12 sltu not < unsigned"}); \
    chk(C.u_cpu.u_rf.regs[13], 32'd1, {T, "arith x13 slti"}); \
    chk(C.u_cpu.u_rf.regs[14], 32'hFFFFFFFA, {T, "arith x14 xori 5 ^ -1"}); \
    chk(C.u_cpu.u_rf.regs[15], 32'h12345000, {T, "arith x15 lui"}); \
    chk(C.u_cpu.u_rf.regs[17], 32'h0000103C, {T, "arith x17 auipc pc(0x3c) + 0x1000"}); \
    chk(C.u_cpu.u_rf.regs[18], 32'h00000040, {T, "arith x18 auipc pc(0x40) + 0"}); \
    chk(C.u_cpu.u_rf.regs[19], 32'h00000FFC, {T, "arith x19 auipc difference"}); \
    chk(C.u_cpu.u_rf.regs[20], 32'd0, {T, "arith x20 = x0 + x0 after write"});

`define CHECK_MEM(C, T) \
    chk(C.u_cpu.i_data, 32'h0000006F, {T, "mem reached its final loop"}); \
    chk(C.u_cpu.u_rf.regs[2], 32'hAABBCCDD, {T, "mem x2  li (lui+addi)"}); \
    chk(C.u_cpu.u_rf.regs[3], 32'hAABBCCDD, {T, "mem x3  lw"}); \
    chk(C.u_cpu.u_rf.regs[4], 32'hFFFFFFDD, {T, "mem x4  lb  byte 0, sign-extended"}); \
    chk(C.u_cpu.u_rf.regs[5], 32'h000000DD, {T, "mem x5  lbu byte 0, zero-extended"}); \
    chk(C.u_cpu.u_rf.regs[6], 32'hFFFFFFAA, {T, "mem x6  lb  byte 3"}); \
    chk(C.u_cpu.u_rf.regs[7], 32'hFFFFAABB, {T, "mem x7  lh  upper half, signed"}); \
    chk(C.u_cpu.u_rf.regs[8], 32'h0000AABB, {T, "mem x8  lhu upper half, unsigned"}); \
    chk(C.u_cpu.u_rf.regs[9], 32'hAABB00DD, {T, "mem x9  after sb x0,1(x1)"}); \
    chk(C.u_cpu.u_rf.regs[10], 32'h000000DD, {T, "mem x10 after sh x0,2(x1)"}); \
    chk(C.u_mem.mem[64], 32'h000000DD, {T, "mem mem[0x100] final"}); \
    chk(C.u_cpu.u_rf.regs[12], 32'hFFFFFF80, {T, "mem x12 lb  byte 3 neg, byte 0 pos"}); \
    chk(C.u_cpu.u_rf.regs[13], 32'hFFFF8000, {T, "mem x13 lh  high neg, low pos"}); \
    chk(C.u_cpu.u_rf.regs[15], 32'h0000007F, {T, "mem x15 lb  byte 3 pos, byte 0 neg"}); \
    chk(C.u_cpu.u_rf.regs[16], 32'h00007F00, {T, "mem x16 lh  high pos, low neg"}); \
    chk(C.u_mem.mem[67], 32'h1234AB00, {T, "mem mem[0x10C] sb/sh to lanes 1-3"}); \
    chk(C.u_cpu.u_rf.regs[19], 32'h1234AB00, {T, "mem x19 lw after sb/sh"}); \
    chk(C.u_cpu.u_rf.regs[20], 32'h00000100, {T, "mem x20 lw x20,0(x20) (base == dest)"});

`define CHECK_BRANCH(C, T) \
    chk(C.u_cpu.i_data, 32'h0000006F, {T, "branch reached its final loop"}); \
    chk(C.u_cpu.u_rf.regs[10], 32'd63, {T, "branch x10 = 1+2+4+8+16+32"});

`define CHECK_JUMP(C, T) \
    chk(C.u_cpu.i_data, 32'h0000006F, {T, "jump reached its final loop"}); \
    chk(C.u_cpu.u_rf.regs[10], 32'd57, {T, "jump x10 = 8+1+16+32"}); \
    chk(C.u_cpu.u_rf.regs[1], 32'h00000008, {T, "jump x1  link address from jal"}); \
    chk(C.u_cpu.u_rf.regs[6], 32'h00000031, {T, "jump x6  odd jalr target"});

module soc_tb;

    localparam WORDS  = 256;     // 1 KiB, enough for these programs
    localparam CYCLES = 400;     // ample even at latency 3

    reg clk, rst;
    integer errors = 0;
    integer checks = 0;

    // RAM latency 0 (instant)
    soc #(.WORDS(WORDS), .HEXFILE("build/p_arith.hex"), .RAM_LATENCY(0)) c_arith (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_mem.hex"), .RAM_LATENCY(0)) c_mem (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_branch.hex"), .RAM_LATENCY(0)) c_branch (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_jump.hex"), .RAM_LATENCY(0)) c_jump (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    // RAM latency 1: every load/store waits 1 extra cycle
    soc #(.WORDS(WORDS), .HEXFILE("build/p_arith.hex"), .RAM_LATENCY(1)) l1_arith (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_mem.hex"), .RAM_LATENCY(1)) l1_mem (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_branch.hex"), .RAM_LATENCY(1)) l1_branch (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_jump.hex"), .RAM_LATENCY(1)) l1_jump (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    // RAM latency 3: every load/store waits 3 extra cycles
    soc #(.WORDS(WORDS), .HEXFILE("build/p_arith.hex"), .RAM_LATENCY(3)) l3_arith (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_mem.hex"), .RAM_LATENCY(3)) l3_mem (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_branch.hex"), .RAM_LATENCY(3)) l3_branch (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));
    soc #(.WORDS(WORDS), .HEXFILE("build/p_jump.hex"), .RAM_LATENCY(3)) l3_jump (
        .clk(clk), .rst(rst),
        .io_valid(), .io_addr(), .io_wstrb(), .io_wdata(),   // no console yet (step 4)
        .io_rdata(32'd0), .io_ready(1'b1));

    // ---- waveform probes for the c_mem walkthrough (tb/soc.gtkw) ----
    // $dumpvars skips arrays, so the register file and memory never show up in
    // the waveform. Mirror the words p_mem uses onto plain wires, which are
    // dumped like any other signal. Memory words are named by BYTE address.
    wire [31:0] c_mem_x1 = c_mem.u_cpu.u_rf.regs[1];
    wire [31:0] c_mem_x2 = c_mem.u_cpu.u_rf.regs[2];
    wire [31:0] c_mem_x3 = c_mem.u_cpu.u_rf.regs[3];
    wire [31:0] c_mem_x4 = c_mem.u_cpu.u_rf.regs[4];
    wire [31:0] c_mem_x5 = c_mem.u_cpu.u_rf.regs[5];
    wire [31:0] c_mem_x6 = c_mem.u_cpu.u_rf.regs[6];
    wire [31:0] c_mem_x7 = c_mem.u_cpu.u_rf.regs[7];
    wire [31:0] c_mem_x8 = c_mem.u_cpu.u_rf.regs[8];
    wire [31:0] c_mem_x9 = c_mem.u_cpu.u_rf.regs[9];
    wire [31:0] c_mem_x10= c_mem.u_cpu.u_rf.regs[10];
    wire [31:0] c_mem_m100 = c_mem.u_mem.mem[64];   // byte address 0x100
    wire [31:0] c_mem_m104 = c_mem.u_mem.mem[65];   // byte address 0x104
    wire [31:0] c_mem_m108 = c_mem.u_mem.mem[66];   // byte address 0x108

    // ---- retire log: `make trace PROG=p_mem [LAT=1|3]` ----
    // Off unless +trace=<name> is given; then only that SoC is logged.
    // Names are the program, plus @<latency> for the slow-RAM SoCs.
    retire_log #(.NAME("p_arith")) t_c_arith (.clk(clk), .rst(rst),
        .pc(c_arith.u_cpu.i_addr), .instr(c_arith.u_cpu.i_data),
        .we(c_arith.u_cpu.u_rf.we), .rd(c_arith.u_cpu.u_rf.rd), .wd(c_arith.u_cpu.u_rf.wd),
        .daddr(c_arith.u_cpu.d_addr), .dwdata(c_arith.u_cpu.d_wdata), .wstrb(c_arith.u_cpu.d_wstrb),
        .valid(c_arith.u_cpu.d_valid), .ready(c_arith.u_cpu.d_ready));
    retire_log #(.NAME("p_mem")) t_c_mem (.clk(clk), .rst(rst),
        .pc(c_mem.u_cpu.i_addr), .instr(c_mem.u_cpu.i_data),
        .we(c_mem.u_cpu.u_rf.we), .rd(c_mem.u_cpu.u_rf.rd), .wd(c_mem.u_cpu.u_rf.wd),
        .daddr(c_mem.u_cpu.d_addr), .dwdata(c_mem.u_cpu.d_wdata), .wstrb(c_mem.u_cpu.d_wstrb),
        .valid(c_mem.u_cpu.d_valid), .ready(c_mem.u_cpu.d_ready));
    retire_log #(.NAME("p_branch")) t_c_branch (.clk(clk), .rst(rst),
        .pc(c_branch.u_cpu.i_addr), .instr(c_branch.u_cpu.i_data),
        .we(c_branch.u_cpu.u_rf.we), .rd(c_branch.u_cpu.u_rf.rd), .wd(c_branch.u_cpu.u_rf.wd),
        .daddr(c_branch.u_cpu.d_addr), .dwdata(c_branch.u_cpu.d_wdata), .wstrb(c_branch.u_cpu.d_wstrb),
        .valid(c_branch.u_cpu.d_valid), .ready(c_branch.u_cpu.d_ready));
    retire_log #(.NAME("p_jump")) t_c_jump (.clk(clk), .rst(rst),
        .pc(c_jump.u_cpu.i_addr), .instr(c_jump.u_cpu.i_data),
        .we(c_jump.u_cpu.u_rf.we), .rd(c_jump.u_cpu.u_rf.rd), .wd(c_jump.u_cpu.u_rf.wd),
        .daddr(c_jump.u_cpu.d_addr), .dwdata(c_jump.u_cpu.d_wdata), .wstrb(c_jump.u_cpu.d_wstrb),
        .valid(c_jump.u_cpu.d_valid), .ready(c_jump.u_cpu.d_ready));
    retire_log #(.NAME("p_arith@1")) t_l1_arith (.clk(clk), .rst(rst),
        .pc(l1_arith.u_cpu.i_addr), .instr(l1_arith.u_cpu.i_data),
        .we(l1_arith.u_cpu.u_rf.we), .rd(l1_arith.u_cpu.u_rf.rd), .wd(l1_arith.u_cpu.u_rf.wd),
        .daddr(l1_arith.u_cpu.d_addr), .dwdata(l1_arith.u_cpu.d_wdata), .wstrb(l1_arith.u_cpu.d_wstrb),
        .valid(l1_arith.u_cpu.d_valid), .ready(l1_arith.u_cpu.d_ready));
    retire_log #(.NAME("p_mem@1")) t_l1_mem (.clk(clk), .rst(rst),
        .pc(l1_mem.u_cpu.i_addr), .instr(l1_mem.u_cpu.i_data),
        .we(l1_mem.u_cpu.u_rf.we), .rd(l1_mem.u_cpu.u_rf.rd), .wd(l1_mem.u_cpu.u_rf.wd),
        .daddr(l1_mem.u_cpu.d_addr), .dwdata(l1_mem.u_cpu.d_wdata), .wstrb(l1_mem.u_cpu.d_wstrb),
        .valid(l1_mem.u_cpu.d_valid), .ready(l1_mem.u_cpu.d_ready));
    retire_log #(.NAME("p_branch@1")) t_l1_branch (.clk(clk), .rst(rst),
        .pc(l1_branch.u_cpu.i_addr), .instr(l1_branch.u_cpu.i_data),
        .we(l1_branch.u_cpu.u_rf.we), .rd(l1_branch.u_cpu.u_rf.rd), .wd(l1_branch.u_cpu.u_rf.wd),
        .daddr(l1_branch.u_cpu.d_addr), .dwdata(l1_branch.u_cpu.d_wdata), .wstrb(l1_branch.u_cpu.d_wstrb),
        .valid(l1_branch.u_cpu.d_valid), .ready(l1_branch.u_cpu.d_ready));
    retire_log #(.NAME("p_jump@1")) t_l1_jump (.clk(clk), .rst(rst),
        .pc(l1_jump.u_cpu.i_addr), .instr(l1_jump.u_cpu.i_data),
        .we(l1_jump.u_cpu.u_rf.we), .rd(l1_jump.u_cpu.u_rf.rd), .wd(l1_jump.u_cpu.u_rf.wd),
        .daddr(l1_jump.u_cpu.d_addr), .dwdata(l1_jump.u_cpu.d_wdata), .wstrb(l1_jump.u_cpu.d_wstrb),
        .valid(l1_jump.u_cpu.d_valid), .ready(l1_jump.u_cpu.d_ready));
    retire_log #(.NAME("p_arith@3")) t_l3_arith (.clk(clk), .rst(rst),
        .pc(l3_arith.u_cpu.i_addr), .instr(l3_arith.u_cpu.i_data),
        .we(l3_arith.u_cpu.u_rf.we), .rd(l3_arith.u_cpu.u_rf.rd), .wd(l3_arith.u_cpu.u_rf.wd),
        .daddr(l3_arith.u_cpu.d_addr), .dwdata(l3_arith.u_cpu.d_wdata), .wstrb(l3_arith.u_cpu.d_wstrb),
        .valid(l3_arith.u_cpu.d_valid), .ready(l3_arith.u_cpu.d_ready));
    retire_log #(.NAME("p_mem@3")) t_l3_mem (.clk(clk), .rst(rst),
        .pc(l3_mem.u_cpu.i_addr), .instr(l3_mem.u_cpu.i_data),
        .we(l3_mem.u_cpu.u_rf.we), .rd(l3_mem.u_cpu.u_rf.rd), .wd(l3_mem.u_cpu.u_rf.wd),
        .daddr(l3_mem.u_cpu.d_addr), .dwdata(l3_mem.u_cpu.d_wdata), .wstrb(l3_mem.u_cpu.d_wstrb),
        .valid(l3_mem.u_cpu.d_valid), .ready(l3_mem.u_cpu.d_ready));
    retire_log #(.NAME("p_branch@3")) t_l3_branch (.clk(clk), .rst(rst),
        .pc(l3_branch.u_cpu.i_addr), .instr(l3_branch.u_cpu.i_data),
        .we(l3_branch.u_cpu.u_rf.we), .rd(l3_branch.u_cpu.u_rf.rd), .wd(l3_branch.u_cpu.u_rf.wd),
        .daddr(l3_branch.u_cpu.d_addr), .dwdata(l3_branch.u_cpu.d_wdata), .wstrb(l3_branch.u_cpu.d_wstrb),
        .valid(l3_branch.u_cpu.d_valid), .ready(l3_branch.u_cpu.d_ready));
    retire_log #(.NAME("p_jump@3")) t_l3_jump (.clk(clk), .rst(rst),
        .pc(l3_jump.u_cpu.i_addr), .instr(l3_jump.u_cpu.i_data),
        .we(l3_jump.u_cpu.u_rf.we), .rd(l3_jump.u_cpu.u_rf.rd), .wd(l3_jump.u_cpu.u_rf.wd),
        .daddr(l3_jump.u_cpu.d_addr), .dwdata(l3_jump.u_cpu.d_wdata), .wstrb(l3_jump.u_cpu.d_wstrb),
        .valid(l3_jump.u_cpu.d_valid), .ready(l3_jump.u_cpu.d_ready));

    initial clk = 0;
    always #5 clk = ~clk;

    task chk(input [31:0] got, input [31:0] exp, input [8*44:1] what);
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
        $dumpfile("build/soc.vcd");
        $dumpvars(0, soc_tb);

        // Release reset on a NEGEDGE: changing it in the same timestep as a
        // posedge races the DUT's always @(posedge clk). Two clean reset edges
        // (5 ns, 15 ns), reset drops at 20 ns, first real edge at 25 ns.
        rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        repeat (CYCLES) @(posedge clk);
        #1;

        $display("--- RAM latency 0 -------------------------------------------");
        `CHECK_ARITH(c_arith, "L0 ")
        `CHECK_MEM(c_mem, "L0 ")
        `CHECK_BRANCH(c_branch, "L0 ")
        `CHECK_JUMP(c_jump, "L0 ")
        $display("--- RAM latency 1 -------------------------------------------");
        `CHECK_ARITH(l1_arith, "L1 ")
        `CHECK_MEM(l1_mem, "L1 ")
        `CHECK_BRANCH(l1_branch, "L1 ")
        `CHECK_JUMP(l1_jump, "L1 ")
        $display("--- RAM latency 3 -------------------------------------------");
        `CHECK_ARITH(l3_arith, "L3 ")
        `CHECK_MEM(l3_mem, "L3 ")
        `CHECK_BRANCH(l3_branch, "L3 ")
        `CHECK_JUMP(l3_jump, "L3 ")

        $display("--------------------------------------------------");
        if (errors == 0) $display("SOC: ALL TESTS PASSED (%0d checks)", checks);
        else             $display("SOC: %0d/%0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule


// ===========================================================================
// retire_log -- one line per retired instruction, for one core.
//
// Single-cycle only: on every cycle out of reset the instruction being fetched
// either retires on the closing edge or, if it is a load/store whose target is
// not ready, waits; its architectural effects are exactly the register-file and
// memory writes on the edge where it retires. Sampling on the posedge reads
// those values before the edge's non-blocking updates land, so they still
// belong to the instruction that is finishing.
//
// Taps the CPU's fetch and data ports plus the u_rf write port, never cpu.v's
// internal signal names. Watching the CPU's data port rather than the RAM's
// means stores to any target (RAM, console, ...) show up in the log. A pipelined core retires at writeback, not at fetch,
// so it will have to export its own retire signals (cf. RISC-V's RVFI).
//
// Output is machine-readable ("RETIRE n pc instr effect..."); tb/annotate.py
// formats it and adds the disassembly.
// ===========================================================================
module retire_log #(parameter [8*16:1] NAME = "") (
    input wire        clk, rst,
    input wire [31:0] pc, instr,
    input wire        we,
    input wire [4:0]  rd,
    input wire [31:0] wd,
    input wire [31:0] daddr, dwdata,
    input wire [3:0]  wstrb,
    input wire        valid, ready
);
    reg [8*16:1] want;
    reg          on, halted;
    integer      n, cycles;
    wire [31:0]  base = {daddr[31:2], 2'b00};

    initial begin
        on = 1'b0; halted = 1'b0; n = 0; cycles = 0;
        if ($value$plusargs("trace=%s", want)) on = (want == NAME);
    end

    // Every clock edge out of reset is a cycle. An instruction retires on this
    // edge unless it is a memory access still waiting for its target
    // (valid && !ready): then the CPU holds it, and it retires on a later edge.
    always @(posedge clk) if (on && !rst && !halted) begin
      cycles = cycles + 1;
      if (!valid || ready) begin
        n = n + 1;
        if (we && rd != 5'd0)
            $display("RETIRE %0d %08h %08h x%0d <- %08h", n, pc, instr, rd, wd);
        else case (wstrb)
            4'b1111: $display("RETIRE %0d %08h %08h mem32[%08h] <- %08h", n, pc, instr, base,      dwdata);
            4'b0011: $display("RETIRE %0d %08h %08h mem16[%08h] <- %04h", n, pc, instr, base,      dwdata[15:0]);
            4'b1100: $display("RETIRE %0d %08h %08h mem16[%08h] <- %04h", n, pc, instr, base + 2,  dwdata[31:16]);
            4'b0001: $display("RETIRE %0d %08h %08h mem8[%08h] <- %02h",  n, pc, instr, base,      dwdata[7:0]);
            4'b0010: $display("RETIRE %0d %08h %08h mem8[%08h] <- %02h",  n, pc, instr, base + 1,  dwdata[15:8]);
            4'b0100: $display("RETIRE %0d %08h %08h mem8[%08h] <- %02h",  n, pc, instr, base + 2,  dwdata[23:16]);
            4'b1000: $display("RETIRE %0d %08h %08h mem8[%08h] <- %02h",  n, pc, instr, base + 3,  dwdata[31:24]);
            4'b0000: $display("RETIRE %0d %08h %08h", n, pc, instr);   // no architectural write
            default: $display("RETIRE %0d %08h %08h ?? wstrb=%b", n, pc, instr, wstrb);
        endcase
        // `jal x0, 0` jumps to itself: the program has finished. Stop logging.
        if (instr == 32'h0000006f) begin
            halted = 1'b1;
            $display("RETIRE halt %0d %0d", n, cycles);   // instructions, cycles
        end
      end
    end
endmodule
