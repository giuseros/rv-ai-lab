// blinky_top_tb.v — simulate the DE10-Lite blinky before building it.
// Run: make fpga-sim BOARD=de10-lite TOP=blinky
//
// The "board" here is the testbench: it drives the clock, switches and keys and
// reads the LEDs and displays, through the top's pins only. CLK_HZ is shrunk to
// 10 so half a second is 5 cycles and a "second" is 10.
//
// Reading the displays back: a reference hex7seg fills a table of the 16 glyphs,
// and decode() turns a display's pins back into the digit it shows ('?' if it
// shows no valid glyph). That checks what this top adds: the polarity, which
// switch bits and counter bits go to which display, and the decimal points.
// The glyphs themselves are hex7seg_tb's job.
`timescale 1ns/1ps

module blinky_top_tb;

    localparam CLK_HZ = 10;
    localparam HALF   = CLK_HZ / 2;

    reg        clk = 0;
    reg  [1:0] KEY = 2'b11;             // not pressed
    reg  [9:0] SW  = 10'd0;
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    blinky_top #(.CLK_HZ(CLK_HZ)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

    always #10 clk = !clk;              // 20 ns period, like the real 50 MHz

    // ---- glyph table from a reference decoder ----
    reg  [3:0] ref_digit;
    wire [6:0] ref_seg;
    reg  [6:0] glyph [0:15];
    hex7seg u_ref (.digit(ref_digit), .seg(ref_seg));

    function [7:0] decode(input [7:0] hex);     // returns an ASCII char
        integer k;
    begin
        decode = "?";
        for (k = 15; k >= 0; k = k - 1)
            if (hex[6:0] === ~glyph[k])         // board segments are active-low
                decode = (k < 10) ? ("0" + k) : ("A" + k - 10);
    end
    endfunction

    integer errors = 0;
    task chk(input [8*40:1] what, input ok);
    begin
        if (ok) $display("  ok: %0s", what);
        else begin
            $display("FAIL: %0s  (LEDR=%b HEX5..0=%c%c%c%c %c%c)", what, LEDR,
                     decode(HEX5), decode(HEX4), decode(HEX3), decode(HEX2),
                     decode(HEX1), decode(HEX0));
            errors = errors + 1;
        end
    end
    endtask

    function [31:0] shown_secs(input dummy);    // HEX5..HEX2 as a 4-char string
        shown_secs = {decode(HEX5), decode(HEX4), decode(HEX3), decode(HEX2)};
    endfunction

    task cycles(input integer n);
        repeat (n) @(negedge clk);              // stimulus/checks on the negedge
    endtask

    integer i, t_on, t_off;

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            ref_digit = i; #1; glyph[i] = ref_seg;
        end

        // ---- power-up: no reset pressed, it must run on its own ----
        @(negedge clk);
        chk("power-up: seconds show 0000", shown_secs(0) == "0000");
        chk("power-up: LED off",           LEDR[0] == 1'b0);

        // ---- blink period: exactly HALF cycles on, HALF off ----
        @(posedge LEDR[0]); t_on  = $time;
        @(negedge LEDR[0]); t_off = $time;
        chk("LED on for half a second",  (t_off - t_on) == HALF * 20);
        @(posedge LEDR[0]);
        chk("LED off for half a second", ($time - t_off) == HALF * 20);

        // ---- the seconds counter, on all four displays ----
        // 0x1234 seconds: four different digits, so a swapped display shows.
        while (shown_secs(0) != "1234") @(negedge clk);
        chk("seconds reach 1234 (digits in order)", shown_secs(0) == "1234");
        cycles(2 * HALF);
        chk("one second later: 1235", shown_secs(0) == "1235");

        // ---- switches: LEDs and HEX1 HEX0 ----
        @(negedge clk); SW = 10'b10_1010_0101;      // 0x2A5
        #1;
        chk("SW[9:1] on LEDR[9:1]",       LEDR[9:1] == SW[9:1]);
        chk("SW[7:0]=A5 shows A5",        {decode(HEX1), decode(HEX0)} == "A5");
        SW = 10'b01_0101_1010;                       // 0x15A: every bit flipped
        #1;
        chk("SW flipped: LEDR follows",   LEDR[9:1] == SW[9:1]);
        chk("SW[7:0]=5A shows 5A",        {decode(HEX1), decode(HEX0)} == "5A");
        for (i = 0; i < 16; i = i + 1) begin         // every glyph, on both digits
            SW[3:0] = i; SW[7:4] = 15 - i; #1;
            if (decode(HEX0) == "?" || decode(HEX1) == "?") begin
                $display("FAIL: SW=%h shows no valid glyph", SW[7:0]);
                errors = errors + 1;
            end
        end
        chk("16 glyphs decode on HEX0/HEX1", 1'b1);

        // ---- KEY[1]: decimal points ----
        chk("DPs off",  {HEX5[7], HEX4[7], HEX3[7], HEX2[7], HEX1[7], HEX0[7]} == 6'b111111);
        KEY[1] = 1'b0; #1;
        chk("KEY[1] pressed: all DPs on", {HEX5[7], HEX4[7], HEX3[7], HEX2[7], HEX1[7], HEX0[7]} == 6'b000000);
        KEY[1] = 1'b1;

        // ---- KEY[0]: reset (through the 2-flop synchroniser) ----
        @(negedge clk); KEY[0] = 1'b0;
        cycles(3);
        chk("KEY[0] held: seconds 0000, LED off", shown_secs(0) == "0000" && LEDR[0] == 1'b0);
        cycles(20);
        chk("still held: stays 0000",            shown_secs(0) == "0000" && LEDR[0] == 1'b0);
        KEY[0] = 1'b1;
        cycles(3 * HALF);               // 1.5 s: mid-second, whatever the reset latency
        chk("released: counting again (0001)", shown_secs(0) == "0001");

        $display("--------------------------------------------------");
        if (errors == 0) $display("BLINKY_TOP: ALL TESTS PASSED");
        else             $display("BLINKY_TOP: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                       // watchdog
        #5_000_000;
        $display("BLINKY_TOP: TIMEOUT");
        $finish;
    end
endmodule
