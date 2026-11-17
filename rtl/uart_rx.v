`timescale 1ns/1ps
// uart_rx.v — serial receiver, 8N1 (8 data bits, no parity, 1 stop bit)
//
// The other half of uart_tx.v. The line idles high; a byte arrives as
//
//   idle  start  d0  d1  d2  d3  d4  d5  d6  d7  stop  idle
//   ‾‾‾‾‾‾\____/‾‾‾\___/ ... (the data bits) ... /‾‾‾‾‾‾‾‾‾‾‾‾
//          ^ ^     ^    ^                    ^     ^
//          | |     +----+---- one sample in the middle of each bit,
//          | |                DIV cycles apart
//          | +-- half a bit later: still low? then it is a start bit
//          +-- falling edge: maybe a start bit
//
// No clock comes with the data, so everything is timed from the start bit's
// falling edge, with our own idea of the bit length (DIV cycles). Sampling in
// the middle of the bit leaves half a bit of slack for the two ends' clocks to
// disagree; by the stop bit (9.5 bits in) that allows about 5% total error.
// (Textbook UARTs sample 16 times a bit and vote, against noise on long cables;
// this line is a few centimetres of wire, so one sample is enough.)
//
// Out: valid is 1 for ONE cycle per byte, with data, and frame_err if the stop
// bit was 0 (the byte is suspect: wrong baud rate, a glitch, or a "break", the
// line held low). There is no ready: a sender never waits, so whoever listens
// must take the byte in that cycle. data holds its value until the next byte.
//
// Rules that keep it from inventing bytes:
//   - rx is asynchronous to clk: two flip-flops synchronise it before use. The
//     delay they add applies to every edge and every sample alike, so it cancels.
//   - a low that is gone by the middle of the start bit was a glitch: ignored
//   - a new byte may start only after the line has been seen HIGH: after a
//     break, or after reset in the middle of a byte, the receiver waits for
//     idle instead of reading the low line as an endless run of 0x00 bytes
//   - the stop bit is sampled in its middle, and the receiver is ready again
//     right then: a sender slightly faster than us can start the next byte
//     before our idea of the stop bit has ended

module uart_rx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,           // the serial line (asynchronous)
    output reg        valid     = 1'b0,    // a byte arrived (one cycle)
    output reg  [7:0] data      = 8'd0,    // the byte; held until the next one
    output reg        frame_err = 1'b0     // with valid: its stop bit was 0
);
    // Clock cycles per bit, rounded to nearest, as in uart_tx.
    localparam DIV  = (CLK_HZ + BAUD / 2) / BAUD;
    localparam HALF = DIV / 2;
    localparam W    = $clog2(DIV);

    // ---- synchroniser ----
    reg [1:0] sync = 2'b11;         // power-up: as if idle
    always @(posedge clk)
        sync <= {sync[0], rx};
    wire line = sync[1];

    // ---- receiver ----
    localparam [1:0] IDLE = 2'd0,   // waiting for a falling edge
                     START = 2'd1,  // in the start bit, waiting for its middle
                     DATA = 2'd2,   // sampling d0..d7
                     STOP = 2'd3;   // waiting for the middle of the stop bit
    reg [1:0]   state = IDLE;
    reg         armed = 1'b0;       // the line has been high since the last byte
    reg [W-1:0] count = {W{1'b0}};  // cycles since the last sample point
    reg [2:0]   nbit  = 3'd0;       // data bit being received
    reg [7:0]   shift = 8'd0;       // data bits, LSB first: shifted in at the top

    always @(posedge clk) begin
        valid <= 1'b0;              // a one-cycle pulse unless set below
        if (rst) begin
            state     <= IDLE;
            armed     <= 1'b0;
            count     <= {W{1'b0}};
            data      <= 8'd0;
            frame_err <= 1'b0;
        end else begin
            case (state)
            IDLE: begin
                if (line)
                    armed <= 1'b1;
                else if (armed) begin           // falling edge after idle
                    state <= START;
                    count <= {W{1'b0}};
                end
            end
            START: begin
                if (count == HALF - 1) begin    // middle of the start bit
                    count <= {W{1'b0}};
                    nbit  <= 3'd0;
                    if (line) state <= IDLE;    // high again: a glitch (still armed)
                    else      state <= DATA;
                end else
                    count <= count + 1'b1;
            end
            DATA: begin
                if (count == DIV - 1) begin     // middle of data bit nbit
                    count <= {W{1'b0}};
                    shift <= {line, shift[7:1]};
                    nbit  <= nbit + 3'd1;
                    if (nbit == 3'd7) state <= STOP;
                end else
                    count <= count + 1'b1;
            end
            STOP: begin
                if (count == DIV - 1) begin     // middle of the stop bit
                    valid     <= 1'b1;
                    data      <= shift;
                    frame_err <= !line;
                    armed     <= line;          // a low stop bit: wait for idle
                    state     <= IDLE;
                end else
                    count <= count + 1'b1;
            end
            endcase
        end
    end
endmodule
