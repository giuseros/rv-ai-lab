// bus.v — routes the CPU's data-port requests to the right target
//
// One initiator (the CPU's data port), two targets (RAM and I/O). For every
// request the bus does two things:
//
//   1. Address decoding: look at the top 4 address bits (the region, see
//      soc_map.vh) and forward the request to exactly one target. The others
//      see no request at all: their valid is 0 and, crucially, their write
//      strobes are 0, so a store to the console can never also write RAM.
//
//   2. Response steering: send the selected target's answer (rdata, ready)
//      back to the CPU.
//
// An address in no region is "unmapped": no target sees it, and the bus
// answers by itself with rdata = 0 and ready = 1. It must answer: a request
// that nobody ever completes would stall the CPU forever once it honours
// d_ready.
//
// All of this is combinational. That is enough because the protocol has at
// most one request in flight and the CPU holds it unchanged until it
// completes, so the address, and with it the selected target, stays stable for
// the whole transaction. Buses that allow several outstanding requests (AXI,
// for example) must instead remember which target each response belongs to.

`timescale 1ns/1ps
`include "soc_map.vh"

module bus (
    // initiator: the CPU's data port
    input  wire        d_valid,
    input  wire [31:0] d_addr,
    input  wire [3:0]  d_wstrb,
    input  wire [31:0] d_wdata,
    output wire [31:0] d_rdata,
    output wire        d_ready,

    // target: RAM
    output wire        ram_valid,
    output wire [31:0] ram_addr,
    output wire [3:0]  ram_wstrb,
    output wire [31:0] ram_wdata,
    input  wire [31:0] ram_rdata,
    input  wire        ram_ready,

    // target: I/O
    output wire        io_valid,
    output wire [31:0] io_addr,
    output wire [3:0]  io_wstrb,
    output wire [31:0] io_wdata,
    input  wire [31:0] io_rdata,
    input  wire        io_ready
);

    // ---- 1. address decoding ----
    wire [3:0] region  = d_addr[31:28];
    wire       sel_ram = (region == `REGION_RAM);
    wire       sel_io  = (region == `REGION_IO);

    // Only the selected target sees a request. Address and data can go to
    // every target unconditionally: they mean nothing without valid/strobes.
    assign ram_valid = d_valid && sel_ram;
    assign ram_wstrb = ram_valid ? d_wstrb : 4'b0000;
    assign ram_addr  = d_addr;
    assign ram_wdata = d_wdata;

    assign io_valid  = d_valid && sel_io;
    assign io_wstrb  = io_valid ? d_wstrb : 4'b0000;
    assign io_addr   = d_addr;
    assign io_wdata  = d_wdata;

    // ---- 2. response steering ----
    // Unmapped addresses complete immediately and read as 0.
    assign d_rdata = sel_ram ? ram_rdata :
                     sel_io  ? io_rdata  :
                               32'd0;
    assign d_ready = sel_ram ? ram_ready :
                     sel_io  ? io_ready  :
                               1'b1;

endmodule
