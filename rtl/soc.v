// soc.v — the system: the CPU plus everything it talks to
//
// cpu.v is just a core with a fetch port and a data port. This module decides
// what is on the other side of those ports:
//
//            fetch port
//        +------------------------------------------+
//        |                                          v
//     +-----+  data port  +-----+   region 0    +-------+
//     | cpu | ----------> | bus | ------------> |  RAM  |
//     +-----+ <---------- +-----+               +-------+
//                            |      region 1
//                            +----------------> io_* ports (to the testbench)
//
// The bus routes each data request by address (see soc_map.vh). Instruction
// fetch stays a direct connection to the RAM: code only ever comes from RAM.
//
// The I/O side leaves the SoC as a port. The console/exit device behind it
// is simulation-only ($write, $finish), so it lives in the testbench and the
// RTL stays synthesizable.
//
// tb/soc_tb.v reaches into this hierarchy, so the instance names u_cpu and
// u_mem are part of its contract.

`timescale 1ns/1ps

module soc #(
    parameter WORDS   = 4096,      // RAM size in 32-bit words (4096 = 16 KiB)
    parameter HEXFILE = ""         // program image loaded into RAM at time 0
) (
    input  wire        clk,
    input  wire        rst,

    // I/O target port (region 1): driven by the bus, answered from outside
    output wire        io_valid,
    output wire [31:0] io_addr,
    output wire [3:0]  io_wstrb,
    output wire [31:0] io_wdata,
    input  wire [31:0] io_rdata,
    input  wire        io_ready
);

    // fetch port
    wire [31:0] i_addr, i_data;

    // data port
    wire        d_valid;
    wire [31:0] d_addr;
    wire [3:0]  d_wstrb;
    wire [31:0] d_wdata;
    wire [31:0] d_rdata;
    wire        d_ready;

    // bus -> RAM
    wire        ram_valid;
    wire [31:0] ram_addr;
    wire [3:0]  ram_wstrb;
    wire [31:0] ram_wdata;
    wire [31:0] ram_rdata;
    wire        ram_ready;

    cpu u_cpu (
        .clk     (clk),
        .rst     (rst),
        .i_addr  (i_addr),
        .i_data  (i_data),
        .d_valid (d_valid),
        .d_addr  (d_addr),
        .d_wstrb (d_wstrb),
        .d_wdata (d_wdata),
        .d_rdata (d_rdata),
        .d_ready (d_ready)
    );

    bus u_bus (
        .d_valid   (d_valid),   .d_addr   (d_addr),   .d_wstrb  (d_wstrb),
        .d_wdata   (d_wdata),   .d_rdata  (d_rdata),  .d_ready  (d_ready),
        .ram_valid (ram_valid), .ram_addr (ram_addr), .ram_wstrb(ram_wstrb),
        .ram_wdata (ram_wdata), .ram_rdata(ram_rdata),.ram_ready(ram_ready),
        .io_valid  (io_valid),  .io_addr  (io_addr),  .io_wstrb (io_wstrb),
        .io_wdata  (io_wdata),  .io_rdata (io_rdata), .io_ready (io_ready)
    );

    // The RAM is passive and answers combinationally. It ignores ram_valid:
    // it only writes when a strobe is set, the bus already zeroes the strobes
    // for requests that are not for it, and an unrequested read is harmless.
    memory #(.WORDS(WORDS), .HEXFILE(HEXFILE)) u_mem (
        .clk    (clk),
        .iaddr  (i_addr),
        .idata  (i_data),
        .daddr  (ram_addr),
        .drdata (ram_rdata),
        .dwdata (ram_wdata),
        .wstrb  (ram_wstrb)
    );

    // The RAM completes every request in the cycle it is made. Step 3 puts a
    // real handshake here.
    assign ram_ready = 1'b1;

endmodule
