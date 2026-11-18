// uart_echo_top_tb.v — simulate the DE10-Lite serial echo before building it.
// Run: make fpga-sim BOARD=de10-lite TOP=uart_echo
//
// The testbench is the board plus the PC: it drives the clock, KEY[0] and
// UART_RX (in real time, with its own idea of the bit length), and a
// uart_monitor (tb_lib.v) decodes UART_TX. Rates are shrunk so a run is short:
// 1 MHz clock, 100000 baud (10 cycles a bit), and 0.1 s is 100000 cycles.
//
// What this top adds over uart_rx and uart_tx, and how each is checked:
//   - typing: each byte comes back, the displays show it in hex and the count.
//     Bytes whose two hex digits differ, so swapped digits show
//   - a paste: 300 bytes back to back, the PC 0.2% faster than us. Each byte
//     arrives while the previous one is still being echoed, so without the
//     buffer they are lost; all must come back, in order, and nothing is
//     flagged as dropped
//   - a sender 2% slow (50 bytes): all come back
//   - a sender 1% fast (150 bytes): the transmitter falls behind, so some are
//     dropped. All 150 are counted (the receiver keeps up), the ones that come
//     back are the sent ones in order with none corrupted or doubled, and
//     LEDR[1] says so, and stays on. The arrivals drift through every cycle of
//     the echo's frame, so a byte lost without the flag (e.g. one arriving in
//     the cycle the buffer empties) is caught
//   - a stop bit of 0: LEDR[0] on, and it stays on after a good byte
//   - LEDR[9] (RX) and LEDR[8] (TX) light for 0.1 s on activity, each for its
//     own line (in reset a byte arrives and none goes out: only RX lights)
//   - KEY[0]: nothing is echoed or counted while held, nor a byte it is
//     released in the middle of; afterwards the count is 0000, HEX1..0 blank,
//     LEDR[1:0] off, and a byte goes through again. Pressed in the middle of an
//     echo, the line goes back to idle at once
//
// Mutation-tested: 20 of 22 mutants fail it. The survivors are equivalent here:
// a 1-flop synchroniser for the activity LED (metastability isn't simulated),
// and a buffer that refuses a byte arriving in the very cycle it empties. That
// one changes which byte is lost, never how many (the transmitter's rate sets
// how many come back), and only while the sender is outrunning the echo. Three
// others first survived and shaped the test: uart_rx's and uart_tx's resets
// unwired (KEY[0] was only pressed with the line quiet: hence released
// mid-byte and pressed mid-echo), and that buffer losing the arriving byte
// without the flag (the 2%-fast sender skipped the cycle: hence 1%, sweeping).
`timescale 1ns/1ps

module uart_echo_top_tb;

    localparam CLK_HZ = 1_000_000;
    localparam BAUD   = 100_000;
    localparam CYC    = 1_000;                      // ns per clock cycle
    localparam real BIT_NS = 1.0e9 / BAUD;

    reg        clk = 0;
    reg  [1:0] KEY = 2'b11;                         // not pressed
    reg        UART_RX = 1'b1;                      // idle
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire       UART_TX;

    uart_echo_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .UART_TX(UART_TX), .UART_RX(UART_RX));
    uart_monitor #(.BAUD(BAUD)) mon (.line(UART_TX));

    always #(CYC / 2) clk = !clk;

    integer errors = 0;
    task chk(input [8*60:1] what, input ok);
    begin
        if (ok) $display("  ok: %0s", what);
        else begin $display("FAIL: %0s  (LEDR=%b)", what, LEDR); errors = errors + 1; end
    end
    endtask

    // ---- reading the displays (as in soc_top_tb) ----
    function integer seg_digit(input [7:0] h);      // 0..15, or 16 = not a digit
        reg [6:0] s;                                // active-high gfedcba
    begin
        s = ~h[6:0];
        case (s)
            7'b0111111: seg_digit = 0;   7'b0000110: seg_digit = 1;
            7'b1011011: seg_digit = 2;   7'b1001111: seg_digit = 3;
            7'b1100110: seg_digit = 4;   7'b1101101: seg_digit = 5;
            7'b1111101: seg_digit = 6;   7'b0000111: seg_digit = 7;
            7'b1111111: seg_digit = 8;   7'b1101111: seg_digit = 9;
            7'b1110111: seg_digit = 10;  7'b1111100: seg_digit = 11;
            7'b0111001: seg_digit = 12;  7'b1011110: seg_digit = 13;
            7'b1111001: seg_digit = 14;  7'b1110001: seg_digit = 15;
            default:    seg_digit = 16;
        endcase
    end
    endfunction

    // HEX5..HEX2 as a number (-1 if any is not a digit), HEX1..HEX0 likewise
    function integer count_shown(input dummy);
        integer d5, d4, d3, d2;
    begin
        d5 = seg_digit(HEX5); d4 = seg_digit(HEX4); d3 = seg_digit(HEX3); d2 = seg_digit(HEX2);
        if (d5 > 15 || d4 > 15 || d3 > 15 || d2 > 15) count_shown = -1;
        else count_shown = (d5 << 12) | (d4 << 8) | (d3 << 4) | d2;
    end
    endfunction
    function integer byte_shown(input dummy);
        integer d1, d0;
    begin
        d1 = seg_digit(HEX1); d0 = seg_digit(HEX0);
        byte_shown = (d1 > 15 || d0 > 15) ? -1 : (d1 << 4) | d0;
    end
    endfunction

    wire low_blank = (HEX1 === 8'hFF) && (HEX0 === 8'hFF);
    wire dp_off    = HEX0[7] & HEX1[7] & HEX2[7] & HEX3[7] & HEX4[7] & HEX5[7];

    // ---- the PC's side: everything sent, everything echoed ----
    reg [7:0] sent [0:1023];
    integer   nsent = 0;
    reg [7:0] echo [0:1023];                        // the monitor keeps only 256
    integer   necho = 0;
    always @(mon.count) begin
        echo[necho] = mon.bytes[(mon.count - 1) & 255];
        necho = necho + 1;
    end

    // One frame on UART_RX, each bit `scale` nominal bit times; stop = the stop
    // bit's level. The line is left high, with no idle added (back to back).
    task send(input [7:0] b, input real scale, input stop);
        integer k;
    begin
        sent[nsent] = b; nsent = nsent + 1;
        UART_RX = 1'b0; #(BIT_NS * scale);
        for (k = 0; k < 8; k = k + 1) begin UART_RX = b[k]; #(BIT_NS * scale); end
        UART_RX = stop; #(BIT_NS * scale);
        UART_RX = 1'b1;
    end
    endtask

    task idle(input real bits);
    begin UART_RX = 1'b1; #(BIT_NS * bits); end
    endtask

    // Typing: one byte, then enough idle for its echo to be fully received.
    // Returns whether it came back, alone, and the displays show it.
    task type_byte(input [7:0] b, output ok);
        integer before;
    begin
        before = necho;
        send(b, 1.0, 1'b1);
        idle(25);
        ok = (necho == before + 1) && (echo[before] == b) &&
             (byte_shown(0) == b) && (count_shown(0) == nsent);
        if (!ok) $display("      sent 0x%h: %0d echoed (0x%h), display %h, count %h (expected %h)",
                          b, necho - before, echo[before], byte_shown(0), count_shown(0), nsent);
    end
    endtask

    // Are echo[e0 ..] exactly sent[s0 .. s0+n-1]?
    function same(input integer s0, input integer e0, input integer n);
        integer k;
    begin
        same = 1'b1;
        for (k = 0; k < n; k = k + 1) if (echo[e0 + k] !== sent[s0 + k]) same = 1'b0;
    end
    endfunction

    // Are echo[e0 .. e0+ne-1] the bytes sent[s0 .. s0+ns-1] in order, some left
    // out, none changed or doubled? (The sent bytes are all different.)
    function in_order(input integer s0, input integer ns, input integer e0, input integer ne);
        integer k, j;
    begin
        in_order = 1'b1; j = s0;
        for (k = 0; k < ne; k = k + 1) begin
            while (j < s0 + ns && sent[j] !== echo[e0 + k]) j = j + 1;
            if (j == s0 + ns) in_order = 1'b0;      // not found after the previous one
            j = j + 1;
        end
    end
    endfunction

    integer i, s0, e0, bad;
    reg ok, ok_all;

    initial begin
        // ---- power-up ----
        #1;
        chk("power-up: UART_TX idle, LEDs off, HEX1..0 blank",
            UART_TX === 1'b1 && LEDR === 10'd0 && low_blank);
        chk("... count shows 0000, decimal points off", count_shown(0) == 0 && dp_off === 1'b1);
        repeat (5) @(negedge clk);
        @(negedge clk); #(CYC * 0.3);               // the PC's edges fall between clock edges

        // ---- typing ----
        ok_all = 1'b1;
        type_byte(8'h61, ok); ok_all = ok_all & ok; // 'a'
        type_byte(8'h0D, ok); ok_all = ok_all & ok; // Enter
        type_byte(8'h00, ok); ok_all = ok_all & ok;
        type_byte(8'hFF, ok); ok_all = ok_all & ok;
        type_byte(8'h3C, ok); ok_all = ok_all & ok;
        type_byte(8'hA5, ok); ok_all = ok_all & ok;
        chk("typing: each byte echoed; HEX1..0 = it, HEX5..2 = count", ok_all);
        chk("... and HEX1..0 no longer blank",      !low_blank);

        // ---- a paste: back to back, the PC a hair faster than us ----
        // At exactly our rate, with the PC's edges at a fixed point in our clock
        // cycle, every byte would arrive in the very cycle the transmitter frees
        // up, and no buffer would be needed. A real PC's edges move around within
        // the cycle; 0.2% fast stands for that: each byte arrives a little sooner,
        // relative to the echo, than the one before. With the buffer, 300 of them
        // add up to 60 cycles behind, less than a frame (100): none is lost.
        s0 = nsent; e0 = necho;
        for (i = 0; i < 300; i = i + 1) send((i * 37 + 11) & 255, 1.0 / 1.002, 1'b1);
        idle(30);
        chk("paste, 300 bytes back to back: all echoed, in order",
            necho - e0 == 300 && same(s0, e0, 300));
        if (necho - e0 != 300) $display("      %0d of 300 echoed", necho - e0);
        chk("... count = 306 (0132), no byte dropped (LEDR[1] off)",
            count_shown(0) == 306 && LEDR[1] === 1'b0);

        // ---- a sender 2% slow ----
        s0 = nsent; e0 = necho;
        for (i = 0; i < 50; i = i + 1) send(i * 5, 1.02, 1'b1);
        idle(30);
        chk("sender 2% slow, 50 bytes: all echoed, none dropped",
            necho - e0 == 50 && same(s0, e0, 50) && LEDR[1] === 1'b0);

        // ---- a sender 1% fast: the echo cannot keep up ----
        // Its frame is ~99 cycles against the transmitter's 100, so each byte
        // arrives about one cycle earlier relative to the echo than the one
        // before: over 150 bytes the arrivals pass every cycle of the echo's
        // frame, including the one where the buffer empties as a byte arrives.
        s0 = nsent; e0 = necho;
        for (i = 0; i < 150; i = i + 1) send(i + 100, 1.0 / 1.01, 1'b1);
        idle(30);
        $display("        (1%% fast: %0d of 150 echoed)", necho - e0);
        chk("sender 1% fast: all 150 counted (506 = 01FA)", count_shown(0) == 506 && nsent == 506);
        chk("... some dropped, the rest echoed in order, intact",
            necho - e0 < 150 && necho - e0 > 140 && in_order(s0, 150, e0, necho - e0));
        chk("... LEDR[1] on (a byte was dropped)",  LEDR[1] === 1'b1);
        type_byte(8'h7E, ok);
        chk("... a typed byte afterwards: echoed, LEDR[1] stays on", ok && LEDR[1] === 1'b1);

        // ---- a stop bit of 0 ----
        chk("no framing error so far (LEDR[0] off)", LEDR[0] === 1'b0);
        send(8'h55, 1.0, 1'b0);
        idle(25);
        chk("stop bit 0: LEDR[0] on, the byte counted and shown",
            LEDR[0] === 1'b1 && byte_shown(0) == 8'h55 && count_shown(0) == nsent);
        type_byte(8'h96, ok);
        chk("... a good byte after it: echoed, LEDR[0] stays on", ok && LEDR[0] === 1'b1);

        // ---- activity LEDs ----
        #100_000_000;                               // 0.1 s quiet: both timers have run out
        chk("quiet line: LEDR[9:8] off",            LEDR[9:8] === 2'b00);
        send(8'hFF, 1.0, 1'b1);                     // only the start bit is low, each way
        #50_000_000;
        chk("one byte: LEDR[9] (RX) and LEDR[8] (TX) on 50 ms later", LEDR[9:8] === 2'b11);
        #100_000_000;
        chk("... off 150 ms later",                 LEDR[9:8] === 2'b00);
        chk("LEDR[7:2] unused, off",                LEDR[7:2] === 6'd0);

        // ---- KEY[0] ----
        KEY[0] = 1'b0;
        e0 = necho;
        send(8'h42, 1.0, 1'b1);                     // typed while reset is held
        idle(25);
        chk("KEY[0] held: nothing echoed",          necho == e0);
        chk("... LEDR[9] (RX) on, LEDR[8] (TX) off", LEDR[9:8] === 2'b10);
        fork                                        // released in the middle of a byte
            send(8'h00, 1.0, 1'b1);                 // (low from the start bit to d7)
            begin #(BIT_NS * 4.5); KEY[0] = 1'b1; end
        join
        idle(25);
        chk("released mid-byte: that byte is not received",
            necho == e0 && count_shown(0) == 0);
        chk("... count 0000, HEX1..0 blank, LEDR[1:0] off",
            count_shown(0) == 0 && low_blank && LEDR[1:0] === 2'b00);
        nsent = 0;                                  // the count starts again
        type_byte(8'h7A, ok);
        chk("... and a byte goes through again ('z' = 7A, count 1)", ok);
        // pressed in the middle of an echo: the line goes back to idle at once
        send(8'h00, 1.0, 1'b1);                     // its echo began half a bit ago
        #(BIT_NS * 2.5);
        KEY[0] = 1'b0;
        repeat (4) @(negedge clk);                  // 2 synchroniser cycles + 1 edge
        chk("pressed mid-echo: UART_TX high within 4 cycles", UART_TX === 1'b1);
        idle(25);
        KEY[0] = 1'b1;
        idle(2);

        // (0x55 arrived with a bad stop bit, but goes back out with a good one)
        chk("echo: no framing errors, no false starts",
            mon.framing_errors == 0 && mon.false_starts == 0);
        $display("--------------------------------------------------");
        if (errors == 0) $display("UART_ECHO_TOP: ALL TESTS PASSED");
        else             $display("UART_ECHO_TOP: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                                   // watchdog
        #2_000_000_000;                             // 2 s; the run needs ~0.4
        $display("UART_ECHO_TOP: TIMEOUT");
        $finish;
    end
endmodule
