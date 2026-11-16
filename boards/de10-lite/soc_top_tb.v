// soc_top_tb.v — simulate the DE10-Lite SoC top before building it.
// Run: make fpga-sim BOARD=de10-lite TOP=soc      (runs sw/primes.c)
//
// The testbench is the board plus the PC: it drives the clock and KEY[0], a
// uart_monitor (tb_lib.v) decodes UART_TX knowing only the baud rate, and the
// HEX outputs are decoded back to digits from their segment patterns. Rates are
// shrunk so a run is short: 1 MHz clock, 100000 baud (10 cycles a bit).
//
// The SoC itself is soc_tb's job. What this top adds, and how it is checked:
//   - power-up reset: the program runs with nobody touching KEY[0]. Without
//     it the CPU's PC is X in simulation and nothing is ever printed
//   - UART_TX is serial_tx: every byte decoded from the line equals, in order,
//     the character the console emitted (tapped inside the SoC as the
//     reference), and the count matches at exit
//   - the program's own answer: the output ends "168 primes, sum 76127" and the
//     displays read 01295F, the sum in hex. Six different digits, so a wrong,
//     swapped or shifted digit gives a different reading
//   - the displays are blank and LEDR[0] off until exit; after it, they show
//     the code and LEDR[0] is on. Decimal points stay off
//   - LEDR[9]: steadily on from the first byte to exit, still on just under
//     0.1 s after, off just over
//   - KEY[0]: held, nothing is sent and the displays blank; released, the
//     program runs again and prints the same text with the same result
//   - the clock: the SoC runs at half the board clock (the PLL, here its
//     behavioural model in max10_pll.v), and the UART is told so. Given the
//     board's rate instead, it sends at twice the baud and nothing decodes
//
// Times below are board clock cycles (1 us each), i.e. real time.
// Mutation-tested: 14 of 18 mutants fail it. The survivors are equivalent here:
// a one-flip-flop KEY synchroniser (metastability isn't simulated), a 1-cycle
// power-up reset (one edge in reset is all the logic needs; 15 is margin),
// ignoring the PLL's locked (the model's clock is clean from its first edge; a
// real PLL's is not), and the async RAM (fine in simulation; it is Quartus that
// cannot build it).
`timescale 1ns/1ps

module soc_top_tb;

    localparam CLK_HZ = 1_000_000;                  // board clock; the SoC gets half
    localparam BAUD   = 50_000;                     // 10 SoC cycles a bit
    localparam CYC    = 1_000;                      // ns per board clock cycle
    localparam [23:0] SUM = 24'h01295F;             // 76127: sum of the primes < 1000

    reg        clk = 0;
    reg  [1:0] KEY = 2'b11;                         // not pressed
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire       UART_TX;

    soc_top #(.HEXFILE("build/primes.hex"), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .UART_TX(UART_TX));
    uart_monitor #(.BAUD(BAUD)) mon (.line(UART_TX));

    always #(CYC / 2) clk = !clk;

    integer errors = 0;
    task chk(input [8*56:1] what, input ok);
    begin
        if (ok) $display("  ok: %0s", what);
        else begin $display("FAIL: %0s  (LEDR=%b)", what, LEDR); errors = errors + 1; end
    end
    endtask

    // ---- reference: the characters the console emitted, tapped in the SoC ----
    // Sampled on the SoC's own clock: its events last one of ITS cycles.
    reg [7:0] sent [0:4095];
    integer   nsent = 0, nexit = 0;
    always @(posedge dut.clk) begin
        if (dut.u_soc.char_valid) begin
            sent[nsent & 4095] = dut.u_soc.char_data;
            nsent = nsent + 1;
        end
        if (dut.u_soc.exit_valid) nexit = nexit + 1;
    end

    // Every byte off the line is compared with the console's, as it arrives (the
    // monitor keeps only the last 256, and a run prints ~750).
    integer mismatches = 0;
    always @(mon.count)
        if (mon.count > 0 && mon.bytes[(mon.count - 1) & 255] !== sent[(mon.count - 1) & 4095]) begin
            if (mismatches == 0)
                $display("FAIL: serial byte %0d is 0x%h, the console sent 0x%h", mon.count - 1,
                         mon.bytes[(mon.count - 1) & 255], sent[(mon.count - 1) & 4095]);
            mismatches = mismatches + 1;
        end

    // ---- the displays, read back: segments (0 = on) -> digit, or 16 if not a digit ----
    function integer seg_digit(input [7:0] h);
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

    // The six displays as one number, HEX5 the most significant digit; -1 if
    // any of them is not showing a digit.
    function integer shown(input dummy);
        integer d5, d4, d3, d2, d1, d0;
    begin
        d5 = seg_digit(HEX5); d4 = seg_digit(HEX4); d3 = seg_digit(HEX3);
        d2 = seg_digit(HEX2); d1 = seg_digit(HEX1); d0 = seg_digit(HEX0);
        if (d5 > 15 || d4 > 15 || d3 > 15 || d2 > 15 || d1 > 15 || d0 > 15) shown = -1;
        else shown = (d5 << 20) | (d4 << 16) | (d3 << 12) | (d2 << 8) | (d1 << 4) | d0;
    end
    endfunction

    wire blank = ({HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} === {6{8'hFF}});
    wire dp_off = HEX0[7] & HEX1[7] & HEX2[7] & HEX3[7] & HEX4[7] & HEX5[7];

    localparam [8*22:1] TAIL = "168 primes, sum 76127\n";

    // ---- one run of the program, from reset release to exit ----
    reg     blank_while_running, done_off_while_running, led9_while_printing;
    integer base;
    reg [23:0] reading;                             // what the displays show, 6 digits
    task one_run(input [8*8:1] which);
    begin
        base = mon.count;
        blank_while_running = 1'b1; done_off_while_running = 1'b1; led9_while_printing = 1'b1;
        while (!LEDR[0]) begin                      // the watchdog ends a hang
            @(negedge clk);
            if (!LEDR[0] && !blank)  blank_while_running    = 1'b0;
            if (!LEDR[0] && LEDR[8:1] !== 8'd0) done_off_while_running = 1'b0;
            // from the first byte on, the gaps are far shorter than 0.1 s: steady on
            if (mon.count > base && LEDR[9] !== 1'b1) led9_while_printing = 1'b0;
        end
        reading = shown(0);
        $display("  [%0s] exited after %0d bytes; displays read %06h", which, mon.count - base, reading);
        chk("program ran and exited (LEDR[0] on)",           LEDR[0] === 1'b1);
        chk("displays blank until exit",                     blank_while_running);
        chk("LEDR[8:1] off",                                 done_off_while_running && LEDR[8:1] === 8'd0);
        chk("every serial byte = the console's, in order",   mismatches == 0);
        chk("all bytes received at exit",                    mon.count == nsent);
        chk("no framing errors, no false starts",            mon.framing_errors == 0 && mon.false_starts == 0);
        chk("output ends \"168 primes, sum 76127\"",         mon.text[8*22:1] == TAIL);
        chk("displays read 01295F (the sum, in hex)",        shown(0) == SUM);
        chk("decimal points off",                            dp_off === 1'b1);
        chk("LEDR[9] steadily on while printing",             led9_while_printing);
    end
    endtask

    integer quiet_bytes, sent_at_press;
    initial begin
        // ---- power-up: nothing pressed ----
        #1;
        chk("power-up: UART_TX idle, displays blank, LEDs off",
            UART_TX === 1'b1 && blank && LEDR === 10'd0);
        one_run("power-up");
        chk("exactly one exit event",                        nexit == 1);

        // ---- LEDR[9] goes off once the line is quiet ----
        // the last low bit was the final byte's d7 or earlier, about 2 bit
        // times before exit: 0.1 s minus 100 cycles from exit it is still lit
        repeat (CLK_HZ / 10 - 100) @(negedge clk);
        chk("LEDR[9] still on just under 0.1 s later",       LEDR[9] === 1'b1);
        repeat (200) @(negedge clk);
        chk("LEDR[9] off 0.1 s after the last bit",          LEDR[9] === 1'b0);
        chk("still showing the result",                      LEDR[0] === 1'b1 && shown(0) == SUM);

        // ---- KEY[0]: held, the SoC is in reset ----
        sent_at_press = nsent;
        quiet_bytes = mon.count;
        KEY[0] = 1'b0;
        repeat (10) @(negedge clk);                         // synchroniser: 3 SoC cycles
        chk("KEY[0] pressed: displays blank, LEDR[0] off",   blank && LEDR[0] === 1'b0);
        repeat (2000) @(negedge clk);
        chk("held: nothing sent, line idle",
            mon.count == quiet_bytes && nsent == sent_at_press && UART_TX === 1'b1);

        // ---- released: the program runs again, same text, same answer ----
        KEY[0] = 1'b1;
        one_run("rerun");
        chk("rerun printed as many bytes as the first run",  mon.count - quiet_bytes == quiet_bytes);
        chk("exactly one more exit event",                   nexit == 2);

        $display("--------------------------------------------------");
        if (errors == 0) $display("SOC_TOP: ALL TESTS PASSED");
        else             $display("SOC_TOP: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                                   // watchdog
        #3_000_000_000;                             // 3 s; a run takes ~0.2
        $display("SOC_TOP: TIMEOUT");
        $finish;
    end
endmodule
