// console_tb.v — self-checking testbench for the console (events + serial line).
// Run: make sim MOD=console
//
// The testbench is the CPU's side of the bus: it issues requests by the bus
// protocol (raise valid on a negedge, hold the request until ready, change it
// only on the negedge after it completes, so back-to-back requests are possible)
// and records when each one completed. A uart_monitor (tb_lib.v) decodes the
// serial line knowing only the baud rate, and the events are counted.
//
// What is checked, at console latency 0 and 3 with the default 16-byte receive
// FIFO, and at latency 0 with the smallest one, 2 bytes (its pointers wrap
// around most often):
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
// and receiving (the testbench drives rx in real time, as a PC would):
//   - RX_DATA reads 0x8000_0000 when empty; a byte arrives: RX_STAT bit 0, and
//     RX_DATA returns it zero-extended (0xA5: bit 7 set, so a sign-extending
//     path shows) and takes it, so the next load is empty again
//   - loading RX_STAT does not take the byte; stores to RX_DATA / RX_STAT (all
//     ones: bit 0 is read-only) and a load of RX_DATA+1 neither wait nor take it
//   - the FIFO: exactly DEPTH bytes fit (no drop flagged), and come out in
//     order; reads and arrivals interleaved keep the order
//   - one byte more than the FIFO holds: dropped (bit 1), the bytes already in
//     it kept, in order; the flag is sticky: loads don't clear it, a store of 0
//     doesn't, a store of 1 to the other flag doesn't; a 1 in bit 1 does
//   - 1s stored to RX_DATA and CONSOLE_ADDR clear no flag
//   - a stop bit of 0: bit 2, the byte delivered anyway (and also when the byte
//     is dropped); the flag outlives a good byte after it and loads; a 1 in
//     bit 2 clears it alone
//   - an RX_STAT load while a character is going out does not wait
//   - reset with the FIFO full and a drop flagged empties it and clears the
//     flag; a byte after it goes through normally
//   - with the FIFO full, a load taking the oldest byte while the next one
//     arrives, swept over 26 cycles around the arrival: each byte is either
//     delivered (last, in order) or flagged as dropped, never silently lost,
//     and both outcomes occur (the sweep really crosses the arrival)
//   - with the FIFO full, a clear of the dropped flag swept over the cycle a
//     byte is dropped: the
//     flag must be set afterwards exactly when the drop came on or after the
//     clear's edge (the same edge: the new event wins). That needs the true time
//     of the drop, so this one looks inside, at dut.rx_valid; the sweep must
//     include the same-edge case
// At latency 3 a load is on the bus for 4 cycles: a console that took the byte
// on the first of them would return "empty" at completion.
//
// Receiving is mutation-tested. The FIFO: 14 of 15 mutants fail (full one byte
// early, full as a 32-bit subtraction (it misses "full" once the pointers have
// wrapped), empty on the slot bits only, a LIFO, writing the read slot,
// overwriting when full, reset leaving either pointer, ...). The survivor is
// equivalent: refusing a byte that arrives in the very cycle a slot frees (it
// is then dropped AND flagged, a legal outcome one cycle early).
// The write-1-to-clear flags: 8 of 9 fail. The survivor is equivalent: clearing
// on every waiting cycle of the store, not only when it completes (a drop in
// those cycles is cleared at completion anyway).
// Survivors that shaped the test (with the one-byte buffer before the FIFO): a
// framing flag that wasn't sticky (it was read before any other byte came), a
// buffer that reset left full (reset only came with nothing waiting), RX loads
// that waited for the transmitter (none was made while it was busy), a clear
// that ignored the address (no other store came while a flag was set).
// The transmitter's frame is 320 cycles, more than the latency counter's 8 bits
// can count: a counter that wrapped around while waiting would complete late.
`timescale 1ns/1ps
`include "soc_map.vh"

// One console at latency LAT, with its own testbench sequence.
// It starts when `go` rises, so two of them can run one after the other.
// NAME: exactly 7 characters (an iverilog 12 quirk: a string parameter
// overridden with a shorter string prints as empty).
module console_check #(parameter LAT = 0, parameter DEPTH = 16,
                       parameter [8*7:1] NAME = "       ") (
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

    reg rx = 1'b1;                          // the PC's line into the console: idle
    console #(.LATENCY(LAT), .CLK_HZ(CLK_HZ), .BAUD(BAUD), .RX_DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst), .valid(valid), .addr(addr), .wstrb(wstrb), .wdata(wdata),
        .rdata(rdata), .ready(ready),
        .char_valid(char_valid), .char_data(char_data),
        .exit_valid(exit_valid), .exit_code(exit_code), .tx(tx), .rx(rx));

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

    real t_a, t_b, t_c, t_clr;

    // ---- the PC typing: one 8N1 frame on rx ----
    // Starts 3 ns after a falling edge; a bit is exactly 32 cycles, so every
    // change of the line falls between clock edges. Returns at the end of the
    // stop bit, by which time the byte has been delivered (at its middle).
    localparam BIT_NS = DIV * CYC;
    task rx_send(input [7:0] b, input stop);
        integer k;
    begin
        @(negedge clk); #3;
        rx = 1'b0; #(BIT_NS);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; #(BIT_NS); end
        rx = stop; #(BIT_NS);
        rx = 1'b1;
    end
    endtask

    // ---- filling and emptying the FIFO ----
    // Byte i of a run: base + 29*i, all different within a run (29 is odd), with
    // varied bit patterns, bit 7 included.
    function [7:0] pat(input [7:0] base, input [7:0] i);
        pat = base + i * 8'd29;
    endfunction

    task fill(input [7:0] base, input integer n);       // send bytes 0..n-1 of a run
        integer j;
    begin
        for (j = 0; j < n; j = j + 1) rx_send(pat(base, j), 1'b1);
    end
    endtask

    integer bad = 0;                                    // bytes not as expected
    task drain(input [7:0] base, input integer from, input integer to);
        integer j;                                      // expect bytes from..to-1
    begin
        for (j = from; j < to; j = j + 1) begin
            req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
            if (got !== {24'd0, pat(base, j)}) begin
                if (bad < 4) $display("      byte %0d of run 0x%h: got 0x%h, expected 0x%h",
                                      j, base, got, pat(base, j));
                bad = bad + 1;
            end
        end
    end
    endtask

    integer    k, n_kept, n_dropped, n_lost, n_same;
    reg [31:0] first, st, second;

    // The edge at which the receiver last delivered a byte (sampled as the
    // console samples it). Only the clear-vs-drop sweep needs this.
    real t_rx;
    always @(posedge clk) if (dut.rx_valid) t_rx = $realtime;

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
        req(`RX_STAT_ADDR, 4'b0000, 32'd0);                         // receiving: unrelated
        chk("busy: an RX_STAT load does not wait, reads 0", waits == LAT && got == 32'd0);

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

        // ---- receiving: one byte ----
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("rx: nothing arrived: status 0",            got == 32'd0 && waits == LAT);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("rx: empty: data reads 0x8000_0000",        got == 32'h8000_0000 && waits == LAT);
        rx_send(8'hA5, 1'b1);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("rx: a byte arrived: status 1 (waiting)",   got == 32'd1 && waits == LAT);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... reading status did not take it",       got == 32'd1);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... data: 0x000000A5 (zero-extended)",     got == 32'h0000_00A5 && waits == LAT);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... taken: data empty again, status 0",    got == 32'h8000_0000);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... status 0",                             got == 32'd0);

        // ---- what must not take a byte ----
        rx_send(8'h3C, 1'b1);
        req(`RX_DATA_ADDR, 4'b1111, 32'hFFFF_FFFF); idle;
        chk("store to RX_DATA: no wait, no event",      waits == LAT && nchar == 4 && nexit == 2);
        req(`RX_STAT_ADDR, 4'b1111, 32'hFFFF_FFFF); idle;
        chk("store to RX_STAT: no wait, no event",      waits == LAT && nchar == 4 && nexit == 2);
        req(`RX_DATA_ADDR + 1, 4'b0000, 32'd0); idle;
        chk("load of RX_DATA+1: reads 0",               got == 32'd0 && waits == LAT);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... stores and RX_DATA+1 took nothing: 0x3C", got == 32'h0000_003C);

        // ---- the FIFO: exactly DEPTH bytes fit, in order ----
        bad = 0;
        fill(8'h91, DEPTH);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("fifo: DEPTH bytes fit: status 1, nothing dropped", got == 32'd1);
        drain(8'h91, 0, DEPTH);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... all of them, in order, then empty",    bad == 0 && got == 32'h8000_0000);
        // reads and arrivals interleaved, never more than 2 waiting (the
        // smallest FIFO): 2 in, 1 out, 1 in, 2 out, 2 in, 2 out
        bad = 0;
        fill(8'h2B, 2);
        drain(8'h2B, 0, 1);
        rx_send(pat(8'h2B, 2), 1'b1);
        drain(8'h2B, 1, 3);
        rx_send(pat(8'h2B, 3), 1'b1);
        rx_send(pat(8'h2B, 4), 1'b1);
        drain(8'h2B, 3, 5);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... interleaved reads and arrivals: in order, empty", bad == 0 && got == 32'd0);

        // ---- one byte more than the FIFO holds: dropped ----
        bad = 0;
        fill(8'h11, DEPTH);
        rx_send(8'h22, 1'b1);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("fifo full: the next byte dropped: status 3", got == 32'd3);
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... a load does not clear it: 3",          got == 32'd3);
        req(`RX_STAT_ADDR, 4'b1111, 32'h0000_0000); idle;
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... a store of 0 does not: 3",             got == 32'd3);
        rx_send(8'h33, 1'b0);                       // dropped too, and a framing error
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("dropped with stop bit 0: status 7",        got == 32'd7);
        req(`RX_DATA_ADDR, 4'b1111, 32'hFFFF_FFFF); idle;   // 1s in bits 1, 2, but elsewhere
        req(`CONSOLE_ADDR, 4'b0001, 32'h0000_0006); idle;     // prints 0x06
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... 1s stored to other registers clear nothing: 7", got == 32'd7 && nchar == 5);
        req(`RX_STAT_ADDR, 4'b0001, 32'h0000_0004); idle;   // sb: 1 in bit 2
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... 1 in bit 2 clears that flag alone: 3", got == 32'd3);
        req(`RX_STAT_ADDR, 4'b1111, 32'hFFFF_FFF2); idle;   // 1 in bit 1 (and bit 0)
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... 1 in bit 1 clears the other: 1",       got == 32'd1);
        drain(8'h11, 0, DEPTH);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... the bytes in it kept, in order; no 0x22/0x33", bad == 0 && got == 32'h8000_0000);

        // ---- a stop bit of 0 ----
        rx_send(8'h66, 1'b0);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("stop bit 0: the byte delivered anyway: 0x66", got == 32'h0000_0066);
        rx_send(8'h77, 1'b1);                       // a good one after it
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... status 5: the flag outlived a good byte", got == 32'd5);
        req(`RX_STAT_ADDR, 4'b1111, 32'h0000_0002); idle;   // the wrong flag
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... 1 in bit 1 leaves it: status 5",       got == 32'd5);
        req(`RX_STAT_ADDR, 4'b1111, 32'h0000_0004); idle;
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("... 1 in bit 2 clears it: status 1",       got == 32'd1);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... and the good byte: 0x77",              got == 32'h0000_0077);

        // ---- the FIFO full: taking a byte as the next one arrives ----
        // The FIFO is filled (run k), B is sent, and the oldest byte is taken k
        // cycles after B's start bit begins. B arrives at its stop bit's middle
        // (~304 cycles); k sweeps across it. Taken before: B goes in. Taken
        // after: B found the FIFO full and was dropped. Same cycle: B goes in.
        // Afterwards the FIFO must hold the rest of the run, then B if kept.
        n_kept = 0; n_dropped = 0; n_lost = 0; bad = 0;
        for (k = 290; k < 316; k = k + 1) begin
            fill(k, DEPTH);
            fork
                rx_send(pat(k, DEPTH), 1'b1);       // B
                begin
                    repeat (k - LAT) @(negedge clk);
                    req(`RX_DATA_ADDR, 4'b0000, 32'd0); first = got; idle;
                end
            join
            req(`RX_STAT_ADDR, 4'b0000, 32'd0); st = got; idle;
            drain(k, 1, DEPTH);
            req(`RX_DATA_ADDR, 4'b0000, 32'd0); second = got; idle;
            req(`RX_STAT_ADDR, 4'b1111, 32'h0000_0006); idle;  // clear for the next round
            if (first != {24'd0, pat(k, 0)})                             n_lost = n_lost + 1;
            else if (st == 32'd1 && second == {24'd0, pat(k, DEPTH)})    n_kept = n_kept + 1;
            else if (st == 32'd3 && second == 32'h8000_0000)             n_dropped = n_dropped + 1;
            else begin
                n_lost = n_lost + 1;
                $display("      k=%0d: oldest 0x%h, status %0d, then 0x%h", k, first, st, second);
            end
        end
        $display("        (sweep: B kept %0d times, dropped and flagged %0d)", n_kept, n_dropped);
        chk("take vs arrival: each byte delivered or flagged", n_lost == 0 && bad == 0);
        chk("... both outcomes seen (the sweep crosses it)", n_kept > 0 && n_dropped > 0);

        // ---- the FIFO full: clearing the dropped flag as a byte is dropped ----
        // The FIFO is filled; B arrives and is dropped; a store clearing bit 1
        // completes k cycles after B's start. Afterwards bit 1 must be set
        // exactly when the drop came at or after the clear's edge: a clear
        // before it can't have seen it, and in the same edge the new event wins.
        n_kept = 0; n_dropped = 0; n_lost = 0; n_same = 0; bad = 0;
        for (k = 290; k < 316; k = k + 1) begin
            fill(k, DEPTH);
            fork
                rx_send(pat(k, DEPTH), 1'b1);       // B: dropped
                begin
                    repeat (k - LAT) @(negedge clk);
                    req(`RX_STAT_ADDR, 4'b1111, 32'h0000_0002); t_clr = t_done; idle;
                end
            join
            req(`RX_STAT_ADDR, 4'b0000, 32'd0); st = got; idle;
            drain(k, 0, DEPTH);                     // empty it for the next round
            req(`RX_STAT_ADDR, 4'b1111, 32'h0000_0006); idle;
            if (t_rx == t_clr) n_same = n_same + 1;
            if (t_rx >= t_clr ? st == 32'd3 : st == 32'd1) begin
                if (st == 32'd3) n_kept = n_kept + 1; else n_dropped = n_dropped + 1;
            end else begin
                n_lost = n_lost + 1;
                $display("      k=%0d: drop at %0t, clear at %0t, then status %0d", k, t_rx, t_clr, st);
            end
        end
        $display("        (clear sweep: flag kept %0d times, cleared %0d, same edge %0d)",
                 n_kept, n_dropped, n_same);
        chk("clear vs drop: flag set iff the drop came at/after it", n_lost == 0 && bad == 0);
        chk("... both outcomes and the same edge seen", n_kept > 0 && n_dropped > 0 && n_same > 0);

        // ---- reset with the FIFO full and a drop flagged ----
        fill(8'h5A, DEPTH);
        rx_send(8'hA5, 1'b1);                       // dropped
        @(negedge clk) rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        req(`RX_STAT_ADDR, 4'b0000, 32'd0); idle;
        chk("reset: the waiting bytes and the flags are gone", got == 32'd0);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... data empty",                           got == 32'h8000_0000);
        rx_send(8'hC7, 1'b1);
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        st = got;
        req(`RX_DATA_ADDR, 4'b0000, 32'd0); idle;
        chk("... a byte after reset: just that one",    st == 32'h0000_00C7 && got == 32'h8000_0000);
        done = 1'b1;
    end
endmodule


module console_tb;
    reg clk = 1'b0;
    always #5 clk = !clk;

    console_check #(.LAT(0), .DEPTH(16), .NAME("L0 D16 ")) c0 (.clk(clk), .go(1'b1));
    console_check #(.LAT(3), .DEPTH(16), .NAME("L3 D16 ")) c3 (.clk(clk), .go(c0.done));
    console_check #(.LAT(0), .DEPTH(2),  .NAME("L0 D2  ")) c2 (.clk(clk), .go(c3.done));

    initial begin
        $dumpfile("build/console.vcd");
        $dumpvars(0, console_tb);
        wait (c0.done && c3.done && c2.done);
        $display("--------------------------------------------------");
        if (c0.errors + c3.errors + c2.errors == 0)
            $display("CONSOLE: ALL TESTS PASSED (%0d checks)", c0.checks + c3.checks + c2.checks);
        else
            $display("CONSOLE: %0d/%0d CHECKS FAILED", c0.errors + c3.errors + c2.errors,
                     c0.checks + c3.checks + c2.checks);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                               // watchdog: a request that never completes
        #50_000_000;                            // 50 ms; the run needs ~13
        $display("CONSOLE: TIMEOUT (a request never completed?)");
        $finish;
    end
endmodule
