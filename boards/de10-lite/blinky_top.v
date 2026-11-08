`timescale 1ns/1ps
// blinky_top.v — DE10-Lite smoke test: is the board alive and are the pins right?
//
// Build and load:  make fpga BOARD=de10-lite TOP=blinky && make program BOARD=de10-lite TOP=blinky
//
// What you should see, and what each thing proves:
//   LEDR[0]      blinks: on 0.5 s, off 0.5 s    the clock pin, and that it is 50 MHz
//   LEDR[9:1]    follow SW[9:1]                 every switch and LED pin
//   HEX1 HEX0    SW[7:0] in hex                 every glyph 0-F: flip the switches
//   HEX5..HEX2   seconds since reset, in hex    the other four displays
//   KEY[1] held  all six decimal points on      KEY[1] and the DP pins
//   KEY[0]       resets the seconds to 0000     KEY[0], and the reset synchroniser
//
// Port names are Terasic's (the board manual's names), so they can be looked up.

module blinky_top #(
    parameter CLK_HZ = 50_000_000       // the testbench shrinks this to a few cycles
) (
    input  wire       MAX10_CLK1_50,
    input  wire [1:0] KEY,              // push buttons: 0 while pressed (debounced on the board)
    input  wire [9:0] SW,               // slide switches: 1 = up
    output wire [9:0] LEDR,             // red LEDs: 1 = on
    output wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5   // {dp, g..a}: 0 = segment ON
);
    wire clk = MAX10_CLK1_50;

    // ---- reset ----
    // KEY[0] changes whenever a finger decides, unrelated to the clock. Fed straight
    // into flip-flops it could change just as they sample it, and some of them could
    // see the new value while others see the old (or go metastable). Two flip-flops
    // in a row re-time it to the clock: the second one's output is safe to use.
    // The initial values are the power-up state: an FPGA loads every flip-flop
    // with a known value at configuration (an ASIC would not), so the design starts
    // running without anyone pressing reset.
    reg [1:0] key0_sync = 2'b11;
    always @(posedge clk)
        key0_sync <= {key0_sync[0], KEY[0]};
    wire rst = !key0_sync[1];           // pressed = 0 = reset

    // ---- half-second tick ----
    localparam HALF = CLK_HZ / 2;       // cycles in half a second
    localparam W    = $clog2(HALF);     // counter bits: 25 at 50 MHz
    reg [W-1:0] count = {W{1'b0}};
    wire tick = (count == HALF - 1);

    reg        led  = 1'b0;
    reg [15:0] secs = 16'd0;
    always @(posedge clk) begin
        if (rst) begin
            count <= {W{1'b0}};
            led   <= 1'b0;
            secs  <= 16'd0;
        end else begin
            count <= tick ? {W{1'b0}} : count + 1'b1;
            if (tick) begin
                led <= !led;
                if (led)                // on -> off: one full second has passed
                    secs <= secs + 16'd1;
            end
        end
    end

    assign LEDR = {SW[9:1], led};

    // ---- displays ----
    // SW and KEY[1] drive the displays through logic only (no flip-flops), so the
    // asynchronous-input problem above doesn't apply: a glitch while a switch moves
    // lasts nanoseconds and the eye can't see it.
    wire [6:0] s0, s1, s2, s3, s4, s5;
    hex7seg u_h0 (.digit(SW[3:0]),     .seg(s0));
    hex7seg u_h1 (.digit(SW[7:4]),     .seg(s1));
    hex7seg u_h2 (.digit(secs[3:0]),   .seg(s2));
    hex7seg u_h3 (.digit(secs[7:4]),   .seg(s3));
    hex7seg u_h4 (.digit(secs[11:8]),  .seg(s4));
    hex7seg u_h5 (.digit(secs[15:12]), .seg(s5));

    // The board's displays light a segment on 0: invert hex7seg's active-high output.
    // The decimal point: KEY[1] is 0 while pressed, and the DP lights on 0, so it
    // goes straight through.
    assign HEX0 = {KEY[1], ~s0};
    assign HEX1 = {KEY[1], ~s1};
    assign HEX2 = {KEY[1], ~s2};
    assign HEX3 = {KEY[1], ~s3};
    assign HEX4 = {KEY[1], ~s4};
    assign HEX5 = {KEY[1], ~s5};
endmodule
