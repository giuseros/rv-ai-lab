// bus.v — routes the CPU's data-port requests to the right target
//
// ===========================================================================
// THE PROTOCOL (every initiator and target on this bus follows it)
// ===========================================================================
// Initiator -> target:  valid, addr[31:0], wstrb[3:0], wdata[31:0]
// Target -> initiator:  ready, rdata[31:0]
//
//   1. A request starts when the initiator raises valid. wstrb == 4'b0000 makes
//      it a read; otherwise it writes the byte lanes whose strobe is set, with
//      wdata already placed in those lanes.
//   2. It completes in the cycle where valid and ready are both 1; its effects
//      land on the clock edge at the end of that cycle.
//   3. While valid && !ready, the initiator holds valid, addr, wstrb and wdata
//      unchanged. A request cannot be cancelled or modified.
//   4. A target may take any number of cycles. Read data needs to be correct
//      only in the completing cycle; a write is performed exactly once, at
//      completion. (Writing on every waiting cycle is harmless for RAM but not
//      for a device: a console would print the character several times.)
//   5. ready means nothing while valid is 0.
//   6. At most one request is in flight. The next one may start in the very
//      next cycle; valid can stay high across back-to-back requests, so a
//      completed cycle (valid && ready), not valid dropping, ends a request.
//   7. valid must not depend on ready. A target may compute ready from the
//      request; the initiator may not compute the request from ready, or the
//      two would form a combinational loop.
//
// Same shape as PicoRV32's native memory interface.
//
// ===========================================================================
// WHAT THE BUS DOES
// ===========================================================================
// One initiator (the CPU's data port), two targets (RAM and I/O). For every
// request:
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
// answers by itself with rdata = 0 and ready = 1. It must answer, or rule 2
// would never be met and the CPU would wait forever.
//
// All of this is combinational. That is enough because of rules 3 and 6: one
// request at a time, held unchanged until it completes, so the address, and
// with it the selected target, stays stable for the whole transaction. Buses
// that allow several outstanding requests (AXI, for example) must instead
// remember which target each response belongs to.

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
