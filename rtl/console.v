// console.v — memory-mapped console and exit register (the I/O target)
//
// Sits behind the bus in region 1 (see soc_map.vh) and has two write-only
// registers:
//
//     CONSOLE_ADDR  0x1000_0000   store a byte  -> print that character
//     EXIT_ADDR     0x1000_0004   store a word  -> end the program with that code
//
// Loads read 0. Stores to any other I/O address are accepted and ignored.
//
// A printed character goes two ways at once:
//
//   - as an EVENT for the testbench: char_valid + char_data, high for the one
//     cycle the store completes (exit_valid + exit_code likewise). Printing and
//     ending a simulation are testbench jobs ($write is not hardware), so the
//     module stays plain RTL.
//   - out of the serial line `tx` (8N1, uart_tx.v), for a real board.
//
// The serial line is slow (a character is 10 bit times; at 115200 baud and
// 50 MHz that is 4340 cycles), so the console must be able to make the CPU
// wait. It does so through `ready`, the bus's one way of saying "not yet":
//
//   - a character store completes in the cycle the transmitter takes the byte.
//     The transmitter is idle most of the time, so the store goes straight
//     through; only a character that arrives while the previous one is still
//     on the line waits, until that frame ends.
//   - an exit store completes only when the transmitter is idle: everything
//     printed is on the wire before the program's end is signalled.
//   - anything else (loads, other addresses) never waits for the transmitter.
//
// Events fire only in the cycle a store COMPLETES (bus protocol rule 4). While
// a store waits, the bus shows it on every cycle; a console that acted on each
// of them would print the character several times.

`timescale 1ns/1ps
`include "soc_map.vh"

module console #(
    parameter LATENCY = 0,                // extra cycles per request, 0..255
    parameter CLK_HZ  = 100_000_000,      // clock and baud rate of the serial line.
    parameter BAUD    = 25_000_000        // The default is a simulation speed, 4 cycles
                                          // a bit; a board passes its real ones.
) (
    input  wire        clk,
    input  wire        rst,

    // target side of the bus
    input  wire        valid,
    input  wire [31:0] addr,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,

    // events, each high for exactly the cycle the store completes
    output wire        char_valid,
    output wire [7:0]  char_data,
    output wire        exit_valid,
    output wire [31:0] exit_code,

    // serial line, 8N1, idle high
    output wire        tx
);

    // ---- latency, as in ram_delay: cycles the current request has waited ----
    // It stops counting at LATENCY instead of running on: a request can now
    // also wait for the transmitter, far longer than 255 cycles, and a counter
    // that wrapped around would no longer read LATENCY when the transmitter
    // became free.
    reg [7:0] waited;
    wire      waited_enough = (waited == LATENCY);

    always @(posedge clk) begin
        if (rst || !valid || ready)
            waited <= 8'd0;
        else if (!waited_enough)
            waited <= waited + 8'd1;
    end

    // ---- what the request is ----
    // addr is a full byte address, so addr == CONSOLE_ADDR already means the
    // store starts at lane 0: the character is in wdata[7:0]
    wire is_store = (wstrb != 4'b0000);
    wire is_char  = is_store && (addr == `CONSOLE_ADDR);
    wire is_exit  = is_store && (addr == `EXIT_ADDR);

    // ---- the transmitter ----
    // Offered the character once the latency has passed; it takes it in a cycle
    // where it is also ready (idle). tx_valid must not depend on tx_ready (the
    // handshake rule), which is why it is not simply char_valid.
    wire tx_valid = valid && waited_enough && is_char;
    wire tx_ready;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .valid(tx_valid), .data(wdata[7:0]),
        .ready(tx_ready), .tx(tx));

    // ---- completing the request ----
    // tx_ready means "idle": for a character, that the byte is taken now; for
    // exit, that the last frame has ended.
    wire tx_wait = (is_char || is_exit) && !tx_ready;
    assign ready = valid && waited_enough && !tx_wait;

    wire store_done = ready && is_store;

    // char_valid is exactly the transmitter's handshake (tx_valid && tx_ready):
    // the event and the serial byte are the same character, never one without
    // the other.
    assign char_valid = store_done && is_char;
    assign char_data  = wdata[7:0];

    assign exit_valid = store_done && is_exit;
    assign exit_code  = wdata;

    assign rdata = 32'd0;

endmodule
