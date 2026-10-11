// memory.v — unified byte-addressed memory for the single-cycle core
//
// One storage array, three ports:
//   - instruction read  (asynchronous)
//   - data read         (asynchronous)
//   - data write        (synchronous, per-byte strobes)
//
// A single-cycle core fetches an instruction AND performs a load/store in the
// same cycle, so two independent read paths are required. Instruction and data
// share one array on purpose: GCC lays .text/.rodata/.data into one contiguous
// address space, and Phase 2 will load a real program image here.
//
// >>> YOUR JOB: implement the body. The port list is the contract that
//     tb/memory_tb.v compiles against — keep the names and widths.
//
// Behavior the testbench expects:
//
//   - Storage is WORDS x 32 bits. Addresses are BYTE addresses; the word index
//     is addr[2 +: IDXBITS], i.e. addr >> 2 truncated to the array size. So
//     addr[1:0] is IGNORED on reads: reading 0x6 returns the whole word at 0x4.
//     Sub-word extraction and sign-extension for lb/lh/lbu/lhu is the load
//     unit's job in the datapath (step 5), not this module's.
//
//   - Addresses past the end of the array WRAP, because the index is simply
//     truncated. That is not a design choice so much as what you get for free;
//     the testbench pins it down so the behavior is at least deterministic.
//
//   - Every word is 32'd0 at time zero, then HEXFILE (if non-empty) is loaded
//     over the low words with $readmemh. Zeroing first matters: an unwritten
//     Verilog array element is X, and X propagates through the whole datapath.
//     ($readmemh warns "Not enough words in the file" when the program is
//     shorter than the array. That warning is expected and harmless.)
//
//   - idata/drdata follow iaddr/daddr combinationally (asynchronous read).
//
//   - On posedge clk, for each byte lane i in 0..3, if wstrb[i] is set then
//     byte i of the addressed word takes byte i of dwdata. wstrb == 4'b0000
//     writes nothing. There is no separate write-enable: the strobes are it.
//       wstrb = 4'b1111 -> sw     4'b0011 / 4'b1100 -> sh     one bit -> sb
//
// Traps to avoid:
//   - A part-select with a variable index must use the +: form. m[i][7:0] is
//     fine, but m[i][n*8 +: 8] is how you select a byte lane by a computed
//     index — m[i][n*8+7 : n*8] is a syntax error in Verilog.
//   - The write must be non-blocking (<=) and the reads continuous (assign).
//   - Do not gate the reads on wstrb or clk. They are always live.

`timescale 1ns/1ps

module memory #(
    parameter WORDS   = 4096,          // 4096 words = 16 KiB
    parameter HEXFILE = ""             // "" means leave memory zeroed
) (
    input  wire        clk,

    // instruction port — read only, asynchronous
    input  wire [31:0] iaddr,
    output wire [31:0] idata,

    // data port — asynchronous read, synchronous byte-strobed write
    input  wire [31:0] daddr,
    output wire [31:0] drdata,
    input  wire [31:0] dwdata,
    input  wire [3:0]  wstrb
);

    localparam IDXBITS = $clog2(WORDS);

    // instr read
    reg [31:0] mem[0:WORDS-1];
    wire [30:0] wordiaddr;
    assign wordiaddr = iaddr[2 +: IDXBITS];
    assign idata = mem[wordiaddr];

    wire [30:0] worddaddr;
    assign worddaddr = daddr[2 +: IDXBITS];
    assign drdata = mem[worddaddr];
    integer k;
    initial begin
        for (k=0; k<WORDS; k=k+1)
            mem[k] = 32'd0;
        if (HEXFILE!= "")
            $readmemh(HEXFILE, mem);
    end

    always @(posedge clk) begin
        for (k=0; k<=3; k=k+1) begin
            if (wstrb[k]) begin
                mem[worddaddr][k*8 +: 8] <= dwdata[k*8 +: 8];
            end
        end
    end
    // data read

    // TODO (you): the storage array, the zero-init + $readmemh initial block,
    // the two asynchronous read assigns, and the synchronous byte-strobed write.

endmodule
