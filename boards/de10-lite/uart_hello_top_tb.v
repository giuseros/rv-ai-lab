// uart_hello_top_tb.v — simulate the DE10-Lite serial smoke test before building it.
// Run: make fpga-sim BOARD=de10-lite TOP=uart_hello
//
// The testbench is the board plus the PC: it drives the clock, KEY[0] and
// UART_RX, and a uart_monitor (tb_lib.v) decodes UART_TX knowing only the baud
// rate, the way the PC's adapter does. Rates are shrunk so a run is short:
// 1 MHz clock, 100000 baud (10 cycles per bit), a line every 8 ms, not every second.
//
// What this top adds over uart_tx, and how each is checked:
//   - the text of every line, byte for byte, read back by the monitor
//   - the numbering: 257 lines, so the low digit takes all 16 values (A-F
//     included), the high digit 0..F, and FF wraps to 00. The digits are parsed
//     back to a number and compared with the line's position, rather than
//     produced by a second copy of the RTL's hex_char
//   - the interval: line starts are INTERVAL cycles apart (to 0.1%)
//   - LEDR[7:0] = lines sent so far, after every line
//   - UART_RX activity: a single low bit (byte 0xFF: only its start bit is low)
//     lights LEDR[9]; it is still on 50 ms later and off 150 ms later. It is
//     sent while lines are going out, so the lines also show it disturbs nothing
//   - KEY[0]: during reset nothing is sent and LEDR shows 0; after release
//     line 00 starts within a few cycles
// The bit timing is uart_tx_tb's job; here it only has to decode.
// Mutation-tested: 17 of 19 mutants fail it. The two survivors are equivalent
// here: no RX synchroniser (metastability isn't simulated), and uart_tx's reset
// left unwired (KEY[0] is pressed between lines, when the transmitter is idle).
// A halved interval first survived: with an interval under two line lengths, the
// skipped line hid it.
`timescale 1ns/1ps

module uart_hello_top_tb;

    localparam CLK_HZ   = 1_000_000;
    localparam BAUD     = 100_000;
    // A line takes ~3535 cycles. The interval is more than twice that on purpose:
    // a line that comes due while one is still going is skipped, so with 4000 a
    // halved interval (2000) still produced a line every 4000 cycles.
    localparam INTERVAL = 8_000;
    localparam CYC      = 1_000;                    // ns per clock cycle
    localparam BIT_NS   = 1_000_000_000 / BAUD;
    localparam LEN      = 35;                       // characters per line
    localparam NLINES   = 257;

    reg        clk = 0;
    reg  [1:0] KEY = 2'b11;                         // not pressed
    reg        UART_RX = 1'b1;                      // idle
    wire [9:0] LEDR;
    wire       UART_TX;

    uart_hello_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .INTERVAL(INTERVAL)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .LEDR(LEDR), .UART_TX(UART_TX), .UART_RX(UART_RX));
    uart_monitor #(.BAUD(BAUD)) mon (.line(UART_TX));

    always #(CYC / 2) clk = !clk;

    integer errors = 0;
    task chk(input [8*52:1] what, input ok);
    begin
        if (ok) $display("  ok: %0s", what);
        else begin $display("FAIL: %0s  (LEDR=%b)", what, LEDR); errors = errors + 1; end
    end
    endtask

    // '0'-'9', 'A'-'F' -> 0..15; anything else (lowercase too) -> 16
    function integer hex_val(input [7:0] c);
    begin
        if (c >= "0" && c <= "9")      hex_val = c - "0";
        else if (c >= "A" && c <= "F") hex_val = c - "A" + 10;
        else                           hex_val = 16;
    end
    endfunction

    function [7:0] got(input integer i);            // the i-th byte received
        got = mon.bytes[i & 255];
    endfunction

    // Is the line starting at received byte `base` exactly the line numbered n?
    localparam [8*31:1] TEXT = "hello from the DE10-Lite, line ";
    function line_ok(input integer base, input integer n);
        integer k;
    begin
        line_ok = 1'b1;
        for (k = 0; k < 31; k = k + 1)
            if (got(base + k) != TEXT[(30 - k)*8+1 +: 8]) line_ok = 1'b0;
        if (hex_val(got(base + 31)) != ((n >> 4) & 15)) line_ok = 1'b0;   // each digit on its
        if (hex_val(got(base + 32)) != (n & 15))        line_ok = 1'b0;   // own: no aliasing
        if (got(base + 33) != 8'h0D || got(base + 34) != 8'h0A) line_ok = 1'b0;
    end
    endfunction

    task show_line(input integer base);
        integer k;
    begin
        $write("        got: \"");
        for (k = 0; k < LEN; k = k + 1)
            if (got(base + k) >= 8'h20 && got(base + k) < 8'h7F) $write("%c", got(base + k));
            else $write("\\x%h", got(base + k));
        $display("\"");
    end
    endtask

    // Start-to-start time between two received bytes: the sum of the periods.
    function real span(input integer from, input integer to);
        integer k;
    begin
        span = 0.0;
        for (k = from + 1; k <= to; k = k + 1) span = span + mon.period[k & 255];
    end
    endfunction

    // ---- the PC typing: one byte on UART_RX, 8N1 ----
    task rx_byte(input [7:0] b);
        integer k;
    begin
        UART_RX = 1'b0; #(BIT_NS);
        for (k = 0; k < 8; k = k + 1) begin UART_RX = b[k]; #(BIT_NS); end
        UART_RX = 1'b1; #(BIT_NS);
    end
    endtask

    reg rx_before = 1'bx, rx_at50 = 1'bx, rx_at150 = 1'bx;
    initial begin                                   // runs alongside the lines
        #20_000_000;                                // 20 ms in: lines are flowing
        rx_before = LEDR[9];
        rx_byte(8'hFF);                             // only the start bit is low
        #50_000_000;  rx_at50  = LEDR[9];
        #100_000_000; rx_at150 = LEDR[9];
    end

    integer n, bad_text, bad_leds, bad_gap, base, first_bad;
    real    t0, t_rel, gap;

    initial begin
        // ---- power-up: the line idles high, then the first line starts at once ----
        #1;
        chk("power-up: UART_TX idle (high), LEDs off", UART_TX === 1'b1 && LEDR === 10'd0);
        @(negedge UART_TX); t0 = $realtime;
        chk("first line starts right after power-up", t0 < 5 * CYC);

        // ---- 257 lines: text, number, LEDs, interval ----
        bad_text = 0; bad_leds = 0; bad_gap = 0; first_bad = -1;
        for (n = 0; n < NLINES; n = n + 1) begin
            wait (mon.count >= (n + 1) * LEN);
            if (!line_ok(n * LEN, n)) begin
                bad_text = bad_text + 1;
                if (first_bad < 0) begin
                    first_bad = n;
                    $display("FAIL: line %0d is wrong", n);
                    show_line(n * LEN);
                end
            end
            if (LEDR[7:0] !== ((n + 1) & 255)) bad_leds = bad_leds + 1;
            if (n > 0) begin
                gap = span((n - 1) * LEN, n * LEN);
                if (gap < 0.999 * INTERVAL * CYC || gap > 1.001 * INTERVAL * CYC)
                    bad_gap = bad_gap + 1;
            end
        end
        chk("257 lines exact, numbered 00..FF then 00", bad_text == 0);
        chk("LEDR[7:0] = lines sent, after each line", bad_leds == 0);
        chk("one line every INTERVAL cycles (0.1%)",   bad_gap == 0);
        $display("        (line 255 to 256: %0.1f us; nominal %0d)",
                 span(255 * LEN, 256 * LEN) / 1000.0, INTERVAL);
        chk("no framing errors, no false starts",      mon.framing_errors == 0 && mon.false_starts == 0);

        // ---- UART_RX activity (driven by the block above) ----
        chk("RX idle: LEDR[9] off",                    rx_before === 1'b0);
        chk("one low bit on RX: LEDR[9] on 50 ms later", rx_at50 === 1'b1);
        chk("off again 150 ms later",                  rx_at150 === 1'b0);
        chk("LEDR[8] unused, off",                     LEDR[8] === 1'b0);

        // ---- KEY[0]: reset between lines, numbering restarts ----
        repeat (100) @(negedge clk);                // the last line is done; idle
        base = mon.count;
        KEY[0] = 1'b0;
        repeat (INTERVAL + 100) @(negedge clk);     // longer than an interval
        chk("KEY[0] held: nothing sent, LEDs 0",
            mon.count == base && UART_TX === 1'b1 && LEDR[7:0] === 8'd0);
        KEY[0] = 1'b1; t_rel = $realtime;
        @(negedge UART_TX);
        chk("released: a line starts within 5 cycles", $realtime - t_rel < 5 * CYC);
        wait (mon.count == base + LEN);
        chk("... and it is line 00 again",             line_ok(base, 0));
        if (!line_ok(base, 0)) show_line(base);

        $display("--------------------------------------------------");
        if (errors == 0) $display("UART_HELLO_TOP: ALL TESTS PASSED");
        else             $display("UART_HELLO_TOP: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                                   // watchdog
        repeat (3) #1_000_000_000;                  // 3 s; the run needs ~2.1
        $display("UART_HELLO_TOP: TIMEOUT");
        $finish;
    end
endmodule
