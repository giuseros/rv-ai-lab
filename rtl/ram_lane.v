// ram_lane.v — one byte lane of ram_sync: a WORDS x 8 block RAM, two ports
//
// ram_sync is four of these side by side, lane i holding byte i of every word
// (see ram_sync.v for why). Each one is the plainest RAM there is, which is
// what lets synthesis recognise it:
//   - port A reads:            on each edge, aq <= m[aidx]
//   - port B reads and writes: on each edge, if we then m[bidx] <= bw;
//                                            and bq <= m[bidx] (the OLD byte)
//   - one write enable, no byte enables, no reset of the array
//   - initial contents: every byte FILL, then HEXFILE (one byte per line, as
//     $readmemh reads it) over the low addresses
//
// Checked with Quartus (MAX 10): this becomes one true dual-port M9K RAM
// with its contents in the bitstream; a 32-bit array with per-byte writes
// instead loses its contents, and a fill loop next to per-byte writes is not
// recognised as RAM at all.

`timescale 1ns/1ps

module ram_lane #(
    parameter WORDS   = 4096,
    parameter HEXFILE = "",            // "" = every byte is FILL
    parameter [7:0] FILL = 8'h00
) (
    input  wire                     clk,

    input  wire [$clog2(WORDS)-1:0] aidx,   // port A: read only
    output reg  [7:0]               aq,

    input  wire [$clog2(WORDS)-1:0] bidx,   // port B: read and write
    output reg  [7:0]               bq,
    input  wire [7:0]               bw,
    input  wire                     we
);

    reg [7:0] m [0:WORDS-1];

    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1)
            m[k] = FILL;
        if (HEXFILE != "")
            $readmemh(HEXFILE, m);
    end

    always @(posedge clk)
        aq <= m[aidx];

    always @(posedge clk) begin
        if (we) m[bidx] <= bw;
        bq <= m[bidx];
    end

endmodule
