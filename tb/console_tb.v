// console_tb.v — self-checking testbench for the console (events + serial line).
// Run: make sim MOD=console
//
// The testbench is the CPU's side of the bus: it issues requests by the bus
// protocol (raise valid on a negedge, hold the request until ready, change it
// only on the negedge after it completes, so back-to-back requests are possible)
// and records when each one completed. A uart_monitor (tb_lib.v) decodes the
// serial line knowing only the baud rate, and the events are counted.
//
// What is checked, at console latency 0 and 3:
//   - an idle console takes a character after the latency alone
//   - a character that finds the line busy completes exactly when the
//     transmitter frees up: one frame after the previous character
//   - one event per character, never one per waiting cycle; the byte is lane 0
//     (the other lanes hold different, non-zero bytes)
//   - while the line is busy, loads, stores elsewhere in I/O and a byte to
//     CONSOLE_ADDR+1 do not wait and print nothing
//   - exit waits for the line to go idle (one cycle after the next character
//     could have been taken), so every character has been received when the
//     exit event fires; exit while idle does not wait
//   - the line carries exactly the characters printed, in order, back to back,
//     with no framing errors
// The transmitter's frame is 320 cycles, more than the latency counter's 8 bits
// can count: a counter that wrapped around while waiting would complete late.
`timescale 1ns/1ps
`include "soc_map.vh"

// One console at latency LAT, with its own testbench sequence.
// It starts when `go` rises, so two of them can run one after the other.
module console_check #(parameter LAT = 0, parameter [8*3:1] NAME = "") (
    input wire clk,
    input wire go
);

    localparam CYC    = 10;                 // ns, the shared clock's period
    localparam CLK_HZ = 100_000_000;
    localparam BAUD   = 3_125_000;          // 32 cycles a bit
    localparam DIV    = 32;
    // uart_tx takes the next byte on the edge that ends the previous frame, so
    // back-to-back characters are exactly 10 bit times apart. Exit waits for the
    // line to be idle, which it is from that edge on: it completes one edge later.
    localparam FRAME  = 10 * DIV;

    reg         rst = 1'b1;
    reg         valid = 1'b0;
    reg  [31:0] addr = 32'd0, wdata = 32'd0;
    reg  [3:0]  wstrb = 4'b0000;
    wire [31:0] rdata, exit_code;
    wire        ready, char_valid, exit_valid, tx;
    wire [7:0]  char_data;

    console #(.LATENCY(LAT), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .clk(clk), .rst(rst), .valid(valid), .addr(addr), .wstrb(wstrb), .wdata(wdata),
        .rdata(rdata), .ready(ready),
        .char_valid(char_valid), .char_data(char_data),
        .exit_valid(exit_valid), .exit_code(exit_code), .tx(tx));

    uart_monitor #(.BAUD(BAUD)) mon (.line(tx));

    integer errors = 0, checks = 0;
    reg     done = 1'b0;

    task chk(input [8*60:1] what, input ok);
    begin
        checks = checks + 1;
        if (ok) $display("  ok: %0s%0s", NAME, what);
        else begin $display("FAIL: %0s%0s", NAME, what); errors = errors + 1; end
    end
    endtask

    // ---- the events, as the testbench's console_sink would see them ----
    integer     nchar = 0, nexit = 0;
    reg [8*8:1] chars = 0;                  // the characters, newest in the low byte
    reg [31:0]  code  = 32'd0;
    always @(posedge clk) begin
        if (char_valid) begin nchar = nchar + 1; chars = {chars[8*7:1], char_data}; end
        if (exit_valid) begin nexit = nexit + 1; code = exit_code; end
    end

    // ---- one request, by the bus protocol ----
    // Returns the cycles it waited (0 = completed on its first edge), the time
    // of the edge it completed on, and the read data.
    integer    waits;
    real       t_done;
    reg [31:0] got;
    task req(input [31:0] a, input [3:0] s, input [31:0] d);
    begin
        @(negedge clk);
        valid = 1'b1; addr = a; wstrb = s; wdata = d;
        waits = 0;
        @(posedge clk);
        while (!ready) begin waits = waits + 1; @(posedge clk); end
        got = rdata; t_done = $realtime;
    end
    endtask

    task idle;
    begin @(negedge clk); valid = 1'b0; wstrb = 4'b0000; end
    endtask

    function cycles_apart(input real t, input real t0, input integer n);
        cycles_apart = (t - t0 == n * CYC);
    endfunction

    real t_a, t_b, t_c;

    initial begin
        wait (go);
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;
        repeat (3) @(negedge clk);

        // ---- characters: the first goes straight through, the next ones wait ----
        req(`CONSOLE_ADDR, 4'b0001, 32'h5A3C_9F41);                 // 'A'
        t_a = t_done;
        chk("idle line: a character waits only the latency", waits == LAT);
        chk("... one event, the lane-0 byte",           nchar == 1 && chars[8:1] == 8'h41);
        req(`CONSOLE_ADDR, 4'b0001, 32'h1234_5662);                 // 'b', back to back
        t_b = t_done;
        chk("busy line: the next one completes one frame later", cycles_apart(t_b, t_a, FRAME));
        req(`CONSOLE_ADDR, 4'b0001, 32'hC3C3_C363);                 // 'c'
        t_c = t_done;
        chk("... and the one after that too",           cycles_apart(t_c, t_b, FRAME));
        chk("one event per character, not per waiting cycle", nchar == 3);

        // ---- while 'c' is on the line, nothing else waits for it ----
        req(`CONSOLE_ADDR, 4'b0000, 32'h0000_0000);                 // a load
        chk("busy: a load does not wait, reads 0, prints nothing",
            waits == LAT && got == 32'd0 && nchar == 3);
        req(`CONSOLE_ADDR + 8, 4'b1111, 32'h0000_0078);             // another I/O address
        chk("busy: a store elsewhere in I/O does not wait, no event",
            waits == LAT && nchar == 3 && nexit == 0);
        req(`CONSOLE_ADDR + 1, 4'b0010, 32'h0000_7900);             // 'y' in lane 1
        chk("busy: a byte to CONSOLE_ADDR+1 does not wait, no event",
            waits == LAT && nchar == 3);

        // ---- exit waits until the line is idle ----
        req(`EXIT_ADDR, 4'b1111, 32'hC0DE_0007);
        chk("exit while busy: completes once the frame has ended", cycles_apart(t_done, t_c, FRAME + 1));
        #1;
        chk("... by then all 3 characters have been received", mon.count == 3);
        chk("... one exit event, the whole word",       nexit == 1 && code == 32'hC0DE_0007);
        req(`EXIT_ADDR, 4'b1111, 32'h8000_0001);
        chk("exit while idle waits only the latency",   waits == LAT && nexit == 2 && code == 32'h8000_0001);

        // ---- idle again: a character goes straight through ----
        req(`CONSOLE_ADDR, 4'b0001, 32'h0000_0064);                 // 'd'
        chk("idle again: a character waits only the latency", waits == LAT);
        idle;
        repeat (2 * FRAME) @(negedge clk);

        // ---- what the line carried ----
        chk("events: exactly \"Abcd\"",                  nchar == 4 && chars[8*4:1] == "Abcd");
        chk("line: exactly \"Abcd\", in order",
            mon.count == 4 && mon.bytes[0] == "A" && mon.bytes[1] == "b" &&
            mon.bytes[2] == "c" && mon.bytes[3] == "d");
        chk("line: A, b, c back to back (one frame apart)",
            mon.period[1] == FRAME * CYC && mon.period[2] == FRAME * CYC);
        chk("line: no framing errors, no false starts", mon.framing_errors == 0 && mon.false_starts == 0);
        chk("line: idle (high) at the end",             tx === 1'b1);
        done = 1'b1;
    end
endmodule


module console_tb;
    reg clk = 1'b0;
    always #5 clk = !clk;

    console_check #(.LAT(0), .NAME("L0 ")) c0 (.clk(clk), .go(1'b1));
    console_check #(.LAT(3), .NAME("L3 ")) c3 (.clk(clk), .go(c0.done));

    initial begin
        $dumpfile("build/console.vcd");
        $dumpvars(0, console_tb);
        wait (c0.done && c3.done);
        $display("--------------------------------------------------");
        if (c0.errors + c3.errors == 0)
            $display("CONSOLE: ALL TESTS PASSED (%0d checks)", c0.checks + c3.checks);
        else
            $display("CONSOLE: %0d/%0d CHECKS FAILED", c0.errors + c3.errors, c0.checks + c3.checks);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                               // watchdog: a request that never completes
        #1_000_000;
        $display("CONSOLE: TIMEOUT (a request never completed?)");
        $finish;
    end
endmodule
