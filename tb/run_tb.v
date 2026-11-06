// run_tb.v — run one program on one SoC and report what it did.
//
// Use it through make:
//     make run PROG=count            # console output + summary
//     make run PROG=count LAT=3      # memory and console answer 3 cycles late
//     make run PROG=count TRACE=1    # also print the retire log
//
// Unlike soc_tb this checks nothing: it is for running programs, not testing
// the core. The program is chosen when the simulation is built (make passes
// -Prun_tb.HEXFILE=...), so the same testbench runs any program.
//
// A program ends in one of three ways:
//   - it stores to the exit register (EXIT_ADDR): the normal way
//   - it reaches a `jal x0, 0` (jumps to itself) without exiting
//   - it runs for MAX_CYCLES: reported as a timeout
`timescale 1ns/1ps

module run_tb;

    parameter HEXFILE = "";            // set by make
    parameter LAT     = 0;             // RAM and console latency
    parameter ECHO    = 1;             // print the console output as it happens
    // RAM outside the program image starts as garbage, like real RAM: a program
    // that reads memory it never wrote (an uncleared .bss, say) shows it.
    parameter [31:0] FILL = 32'hDEAD_BEEF;

    localparam WORDS      = 4096;      // the full 16 KiB RAM
    localparam MAX_CYCLES = 1000000;

    reg clk, rst;

    wire        char_valid, exit_valid;
    wire [7:0]  char_data;
    wire [31:0] exit_code;

    soc #(.WORDS(WORDS), .HEXFILE(HEXFILE), .RAM_LATENCY(LAT), .IO_LATENCY(LAT),
          .RAM_FILL(FILL)) dut (
        .clk(clk), .rst(rst),
        .char_valid(char_valid), .char_data(char_data),
        .exit_valid(exit_valid), .exit_code(exit_code));

    console_sink #(.ECHO(ECHO)) sink (.clk(clk), .rst(rst),
        .char_valid(char_valid), .char_data(char_data),
        .exit_valid(exit_valid), .exit_code(exit_code));

    // retire log, enabled by +trace=run
    retire_log #(.NAME("run")) trace (.clk(clk), .rst(rst),
        .pc(dut.u_cpu.i_addr), .instr(dut.u_cpu.i_data),
        .we(dut.u_cpu.u_rf.we), .rd(dut.u_cpu.u_rf.rd), .wd(dut.u_cpu.u_rf.wd),
        .daddr(dut.u_cpu.d_addr), .dwdata(dut.u_cpu.d_wdata), .wstrb(dut.u_cpu.d_wstrb),
        .valid(dut.u_cpu.d_valid), .ready(dut.u_cpu.d_ready));

    initial clk = 0;
    always #5 clk = ~clk;

    // An instruction retires on an edge unless it is a load/store still waiting.
    wire retiring = !dut.u_cpu.d_valid || dut.u_cpu.d_ready;
    wire parked   = (dut.u_cpu.i_data === 32'h0000006F);     // jal x0, 0

    integer cycles, retired;

    initial begin
        if (HEXFILE == "") begin
            $display("run_tb: no program given (use: make run PROG=<name>)");
            $finish;
        end
        cycles = 0; retired = 0;

        rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        while (!sink.exited && !parked && cycles < MAX_CYCLES) begin
            @(posedge clk);
            // sampled at the edge, so this is the instruction that just finished
            cycles = cycles + 1;
            if (retiring) retired = retired + 1;
            #1;     // let the edge's updates (the sink, the new PC) settle
        end

        if (sink.exited)
            $display("--- exit code %0d: %0d instructions in %0d cycles (CPI %0.2f) ---",
                     sink.code, retired, cycles, 1.0 * cycles / retired);
        else if (parked)
            $display("--- stopped at a jump-to-itself without exiting: %0d instructions in %0d cycles ---",
                     retired, cycles);
        else
            $display("--- TIMEOUT after %0d cycles (%0d instructions) ---", cycles, retired);
        $finish;
    end

endmodule
