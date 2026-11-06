// tb_lib.v — testbench helpers shared by soc_tb.v and run_tb.v
//
//   console_sink  records (and optionally echoes) what a SoC's console printed
//   retire_log    prints one line per retired instruction (tb/annotate.py
//                 formats it)
`timescale 1ns/1ps

// ===========================================================================
// console_sink -- the testbench end of a SoC's console.
//
// Watches the console's events and records what happened: every character
// printed (newest in the low byte of `text`), how many, and the exit code.
// With ECHO set it also writes the characters to the simulator's output.
// Sampled on the posedge, like retire_log: an event belongs to the store that
// completes on that edge.
// ===========================================================================
module console_sink #(parameter ECHO = 0) (
    input wire        clk, rst,
    input wire        char_valid,
    input wire [7:0]  char_data,
    input wire        exit_valid,
    input wire [31:0] exit_code
);
    reg [8*64:1] text;
    integer      count;
    reg          exited;
    reg [31:0]   code;

    initial begin text = 0; count = 0; exited = 1'b0; code = 32'd0; end

    always @(posedge clk) if (!rst) begin
        if (char_valid) begin
            text  = {text[8*63:1], char_data};
            count = count + 1;
            if (ECHO) $write("%c", char_data);
        end
        if (exit_valid) begin
            exited = 1'b1;
            code   = exit_code;
        end
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
