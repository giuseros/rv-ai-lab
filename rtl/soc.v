// soc.v — the system: the CPU plus everything it talks to
//
// cpu.v is just a core with a fetch port and a data port. This module decides
// what is on the other side of those ports. Right now that is only the RAM,
// connected directly:
//
//            fetch port
//        +------------------------------+
//        |                              v
//     +-----+     data port         +-------+
//     | cpu | --------------------> |  RAM  |
//     +-----+ <-------------------- +-------+
//
// Phase 2, step 2 puts a bus between the CPU's data port and the RAM, so that
// addresses can be routed to other targets (the console, later caches and
// accelerators). Instruction fetch stays a direct connection to the RAM.
//
// tb/soc_tb.v reaches into this hierarchy, so the instance names u_cpu and
// u_mem are part of its contract.

`timescale 1ns/1ps

module soc #(
    parameter WORDS   = 4096,      // RAM size in 32-bit words (4096 = 16 KiB)
    parameter HEXFILE = ""         // program image loaded into RAM at time 0
) (
    input wire clk,
    input wire rst
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

    // The RAM is passive and answers combinationally, so it has no use for
    // d_valid yet: it only writes when a strobe is set, and a read with nothing
    // asking for it is harmless. The bus (step 2) is what starts honouring
    // d_valid, because the console is not harmless to read.
    memory #(.WORDS(WORDS), .HEXFILE(HEXFILE)) u_mem (
        .clk    (clk),
        .iaddr  (i_addr),
        .idata  (i_data),
        .daddr  (d_addr),
        .drdata (d_rdata),
        .dwdata (d_wdata),
        .wstrb  (d_wstrb)
    );

    // Every request completes in the cycle it is made. Step 3 replaces this
    // with a real handshake.
    assign d_ready = 1'b1;

endmodule
