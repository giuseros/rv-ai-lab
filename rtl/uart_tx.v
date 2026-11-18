`timescale 1ns/1ps
// uart_tx.v — serial transmitter, 8N1 (8 data bits, no parity, 1 stop bit)
//
// The line idles high (1). Each byte goes out as 10 bits, each lasting one bit
// period (1/BAUD seconds), least significant data bit first:
//
//   idle  start  d0  d1  d2  d3  d4  d5  d6  d7  stop  idle
//   ‾‾‾‾‾‾\____/‾‾‾\___/ ... (the data bits) ... /‾‾‾‾‾‾‾‾‾‾‾‾
//          0                                     1
//
// No clock travels with the data: the receiver knows the baud rate in advance,
// sees the falling edge of the start bit, and samples each bit in its middle.
//
// Handshake: the same valid/ready rule as the bus. A byte is taken in a cycle
// where valid && ready. A sender with more to say holds valid (and data) until
// it sees ready, so a byte is never lost or sent twice. Once taken, the byte is
// copied: data may change right after.
//
// ready is 1 while idle, AND in the last cycle of a stop bit: a byte taken
// there starts its start bit right as the stop bit ends, so back-to-back bytes
// are exactly 10 * DIV cycles apart, the full baud rate. (If ready waited for
// idle, every frame would be one cycle longer: 0.02% slow at 434 cycles a bit,
// which is enough to lose bytes when echoing an endless stream from a sender at
// the same nominal rate.) `idle` is the other question, "is the line quiet,
// the last frame over?", which is not the same thing any more.

module uart_tx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,        // a byte to send
    input  wire [7:0] data,
    output wire       ready,        // a byte offered now is taken at this edge
    output wire       idle,         // nothing being sent: the last stop bit has ended
    output wire       tx            // the serial line
);
    // Clock cycles per bit, rounded to nearest: 50 MHz / 115200 = 434.03 -> 434,
    // 0.007% fast. A receiver tolerates a few percent.
    localparam DIV = (CLK_HZ + BAUD / 2) / BAUD;
    localparam W   = $clog2(DIV);

    // The frame, sent from bit 0 by shifting right: {stop, data, start}. 1s are
    // shifted in at the top, so after the last bit the register is all 1s: idle.
    // tx comes straight from a flip-flop, never through logic: a glitch on this
    // line, even nanoseconds long, would look to the receiver like a start bit.
    reg [9:0]   frame = 10'h3FF;    // power-up: line idle (high)
    reg [3:0]   left  = 4'd0;       // bits still to send; 0 = idle
    reg [W-1:0] count = {W{1'b0}};  // cycles into the current bit
    // 1 in exactly one cycle per frame: the stop bit's last one. A flip-flop,
    // set one cycle ahead, rather than a compare of left and count: ready feeds
    // the console's d_ready, which is on the SoC's critical path (see soc_top).
    // Needs DIV >= 2.
    reg         last  = 1'b0;

    wire busy = (left != 4'd0);
    assign idle  = !busy;
    assign ready = (!busy || last) && !rst;
    assign tx    = frame[0];

    always @(posedge clk) begin
        last <= 1'b0;                           // set below for one cycle
        if (rst) begin
            frame <= 10'h3FF;
            left  <= 4'd0;
            count <= {W{1'b0}};
        end else if (ready && valid) begin      // idle, or the stop bit's end: take it
            frame <= {1'b1, data, 1'b0};
            left  <= 4'd10;
            count <= {W{1'b0}};
        end else if (!busy) begin
            // idle, nothing offered
        end else if (count == DIV - 1) begin    // end of a bit: next one
            frame <= {1'b1, frame[9:1]};
            left  <= left - 4'd1;
            count <= {W{1'b0}};
        end else begin
            count <= count + 1'b1;
            if (left == 4'd1 && count == DIV - 2)
                last <= 1'b1;                   // the next cycle ends the stop bit
        end
    end
endmodule
