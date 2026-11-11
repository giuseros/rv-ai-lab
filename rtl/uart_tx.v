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
// where valid && ready; ready is 1 only while idle. A sender with more to say
// holds valid (and data) until it sees ready, so a byte is never lost or sent
// twice. Once taken, the byte is copied: data may change right after.

module uart_tx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,        // a byte to send
    input  wire [7:0] data,
    output wire       ready,        // idle: a byte offered now is taken
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

    wire busy = (left != 4'd0);
    assign ready = !busy && !rst;
    assign tx    = frame[0];

    always @(posedge clk) begin
        if (rst) begin
            frame <= 10'h3FF;
            left  <= 4'd0;
            count <= {W{1'b0}};
        end else if (!busy) begin
            if (valid) begin                    // ready is 1 here: take it
                frame <= {1'b1, data, 1'b0};
                left  <= 4'd10;
                count <= {W{1'b0}};
            end
        end else if (count == DIV - 1) begin    // end of a bit: next one
            frame <= {1'b1, frame[9:1]};
            left  <= left - 4'd1;
            count <= {W{1'b0}};
        end else begin
            count <= count + 1'b1;
        end
    end
endmodule
