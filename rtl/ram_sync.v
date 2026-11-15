// ram_sync.v — unified memory that reads on the clock edge (FPGA block RAM)
//
// The same memory as memory.v (one array, an instruction port, a data port
// with byte strobes; byte addresses, addr[1:0] ignored, addresses wrap; FILL
// then HEXFILE as initial contents) with one difference: BOTH READS ARE
// REGISTERED. On every rising edge each port samples its address, and the word
// at that address appears on its data output after the edge, staying there
// until the next one:
//
//            edge E                      edge E+1
//              |                            |
//   iaddr  ==X==A==========================X==B=====
//   idata  ==========X==  mem[A]  =================X==  mem[B]
//
// That is how FPGA block RAM works (the MAX 10's M9K, the Spartan-3E's block
// RAM): the address goes into a register inside the RAM block, so the data
// for an address presented in one cycle arrives in the next. A RAM that answers
// in the same cycle (memory.v) can only be built from logic cells, and 16 KiB
// of those does not fit.
//
// So whoever drives the address must present it one edge early:
//   - fetch: the CPU gives the address of the NEXT cycle's instruction (cpu.v's
//     i_next), so the instruction is ready when that cycle starts
//   - data: a load presents its address, and the word arrives a cycle later;
//     ram_delay makes loads wait for it (MIN_READ = 1)
// Writes are as in memory.v: on the edge, only the lanes whose strobe is set.
//
// ---- four byte lanes ----
// The word is stored as four byte-wide RAMs (ram_lane.v) that all see the same
// word index; lane i holds byte i of every word, and its write enable is
// wstrb[i]. The RAM blocks have byte enables, but synthesis will not build
// them from a 32-bit array with per-byte writes AND keep its initial contents
// (checked with Quartus). Separate lanes need neither, and they also suit RAM
// without byte enables (the Spartan-3E's).
//
// The program image is split the same way: lane i loads HEXFILE.b<i>, one byte
// per line (the Makefile writes these next to every .hex).
//
// ---- same edge, same word ----
// A read and a write on the same edge to the same word read the OLD contents.
// On the data port this never matters (a store does not use drdata). On the
// fetch port it means a store into the very next instruction is not seen by
// that fetch; RISC-V allows exactly that (code must use FENCE.I to see its own
// stores as instructions).

`timescale 1ns/1ps

module ram_sync #(
    parameter WORDS   = 4096,          // 4096 words = 16 KiB
    parameter HEXFILE = "",            // program image; "" = every word is FILL
    parameter [31:0] FILL = 32'd0      // words the image does not cover
) (
    input  wire        clk,

    // instruction port: read only
    input  wire [31:0] iaddr,          // sampled on the edge
    output wire [31:0] idata,          // the word at iaddr as of the last edge

    // data port: read and write
    input  wire [31:0] daddr,          // sampled on the edge
    output wire [31:0] drdata,         // the word at daddr as of the last edge
    input  wire [31:0] dwdata,
    input  wire [3:0]  wstrb           // lanes to write on the edge
);

    localparam IDXBITS = $clog2(WORDS);

    wire [IDXBITS-1:0] iidx = iaddr[2 +: IDXBITS];
    wire [IDXBITS-1:0] didx = daddr[2 +: IDXBITS];

    // Lane i's image file: HEXFILE followed by ".b<i>"; none if HEXFILE is "".
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : lane
        // the digit as ONE character, picked out of a string: "0" + i would be
        // 32 bits wide (i is an integer), and the file name would carry 3 NULs
        localparam [8*4:1] DIGITS = "3210";             // "0" is the low byte
        localparam [7:0]   DIGIT  = DIGITS[i*8+1 +: 8];
        ram_lane #(
            .WORDS   (WORDS),
            .HEXFILE ((HEXFILE == "") ? "" : {HEXFILE, ".b", DIGIT}),
            .FILL    (FILL[i*8 +: 8])
        ) u_lane (
            .clk  (clk),
            .aidx (iidx), .aq (idata[i*8 +: 8]),
            .bidx (didx), .bq (drdata[i*8 +: 8]), .bw (dwdata[i*8 +: 8]), .we (wstrb[i])
        );
    end endgenerate

endmodule
