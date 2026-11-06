// console.v — memory-mapped console and exit register (the I/O target)
//
// Sits behind the bus in region 1 (see soc_map.vh) and has two write-only
// registers:
//
//     CONSOLE_ADDR  0x1000_0000   store a byte  -> emit that character
//     EXIT_ADDR     0x1000_0004   store a word  -> emit an exit code
//
// Loads read 0. Stores to any other I/O address are accepted and ignored.
//
// It does not print anything itself: printing and ending a simulation are
// testbench jobs ($write is not hardware). Instead each completed store is
// reported as a one-cycle EVENT, char_valid + char_data or exit_valid +
// exit_code, and the testbench acts on those. So this module is plain RTL,
// and it is the pattern later memory-mapped devices will follow: decode the
// address inside the region, act on a completed request.
//
// Events fire only in the cycle a store COMPLETES (bus protocol rule 4). With
// LATENCY > 0 the store is visible on the bus for several cycles before that;
// a console that acted on every one of them would print each character
// several times.

`timescale 1ns/1ps
`include "soc_map.vh"

module console #(
    parameter LATENCY = 0                 // extra cycles per request, 0..255
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
    output wire [31:0] exit_code
);

    // Latency, exactly as in ram_delay: count the cycles the current request
    // has waited, restart after each completed request.
    reg [7:0] waited;

    always @(posedge clk) begin
        if (rst || !valid || ready)
            waited <= 8'd0;
        else
            waited <= waited + 8'd1;
    end

    assign ready = valid && (waited == LATENCY);

    // a store completing this cycle
    wire store_done = ready && (wstrb != 4'b0000);

    // addr is a full byte address, so addr == CONSOLE_ADDR already means the
    // store starts at lane 0: the character is in wdata[7:0]
    assign char_valid = store_done && (addr == `CONSOLE_ADDR);
    assign char_data  = wdata[7:0];

    assign exit_valid = store_done && (addr == `EXIT_ADDR);
    assign exit_code  = wdata;

    assign rdata = 32'd0;

endmodule
