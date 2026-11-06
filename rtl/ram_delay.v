// ram_delay.v — make the RAM answer after LATENCY extra cycles
//
// Sits between the bus and the (instant) RAM and turns it into a slow target:
// each request waits LATENCY cycles before ready goes high. LATENCY = 0 is a
// pass-through that answers in the same cycle, exactly like the bare RAM.
//
//      bus  --valid/wstrb-->  ram_delay  --mem_wstrb-->  memory
//           <--rdata/ready--             <--mem_rdata--
//
// This exists to exercise the CPU's stall path now, before any real slow
// target (a cache, a DRAM controller) exists. Two details make it an honest
// stand-in for one:
//
//   - A store is written exactly once, on the cycle that completes it. A slow
//     memory commits the write when it finishes, not on every waiting cycle.
//
//   - Read data is garbage (0xDEADDEAD) until ready. A real slow memory has
//     nothing useful on its data lines before it answers, and this makes a CPU
//     that uses read data too early visibly wrong instead of accidentally right.
//
// Back-to-back requests: d_valid can stay high across two consecutive memory
// instructions, so "valid is high" does not mean "same request". The counter
// therefore restarts after every completed request, not only when valid drops.

`timescale 1ns/1ps

module ram_delay #(
    parameter LATENCY = 0                 // extra cycles per request, 0..255
) (
    input  wire        clk,
    input  wire        rst,

    // from the bus
    input  wire        valid,
    input  wire [3:0]  wstrb,
    output wire [31:0] rdata,
    output wire        ready,

    // to the RAM
    output wire [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata
);

    // cycles the current request has already waited
    reg [7:0] waited;

    always @(posedge clk) begin
        if (rst || !valid || ready)
            waited <= 8'd0;               // no request, or one just completed
        else
            waited <= waited + 8'd1;
    end

    assign ready     = valid && (waited == LATENCY);
    assign mem_wstrb = ready ? wstrb     : 4'b0000;        // write once, on completion
    assign rdata     = ready ? mem_rdata : 32'hDEAD_DEAD;  // nothing to see until then

endmodule
