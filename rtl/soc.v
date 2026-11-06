// soc.v — the system: the CPU plus everything it talks to
//
// cpu.v is just a core with a fetch port and a data port. This module decides
// what is on the other side of those ports:
//
//            fetch port
//        +------------------------------------------+
//        |                                          v
//     +-----+  data port  +-----+  region 0  +-----------+   +-------+
//     | cpu | ----------> | bus | ---------> | ram_delay | ->|  RAM  |
//     +-----+ <---------- +-----+            +-----------+   +-------+
//                            |    region 1   +---------+
//                            +-------------> | console | --> char / exit events
//                                            +---------+     (to the testbench)
//
// The bus routes each data request by address (see soc_map.vh). Instruction
// fetch stays a direct connection to the RAM: code only ever comes from RAM.
//
// The console reports what the program printed and its exit code as events on
// the SoC's outputs. Acting on them ($write, ending the simulation) is the
// testbench's job; everything in here is plain RTL.
//
// tb/soc_tb.v reaches into this hierarchy, so the instance names u_cpu and
// u_mem are part of its contract.

`timescale 1ns/1ps

module soc #(
    parameter WORDS       = 4096,  // RAM size in 32-bit words (4096 = 16 KiB)
    parameter HEXFILE     = "",    // program image loaded into RAM at time 0
    parameter RAM_LATENCY = 0,     // extra cycles per RAM access (0 = instant)
    parameter IO_LATENCY  = 0,     // extra cycles per console access
    parameter [31:0] RAM_FILL = 32'd0  // RAM contents outside the program image
) (
    input  wire        clk,
    input  wire        rst,

    // console events: one-cycle pulses, see console.v
    output wire        char_valid,
    output wire [7:0]  char_data,
    output wire        exit_valid,
    output wire [31:0] exit_code
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

    // bus -> console
    wire        io_valid;
    wire [31:0] io_addr;
    wire [3:0]  io_wstrb;
    wire [31:0] io_wdata;
    wire [31:0] io_rdata;
    wire        io_ready;

    // ram_delay -> RAM
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

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

    // Turns the instant RAM into a target that answers after RAM_LATENCY cycles.
    ram_delay #(.LATENCY(RAM_LATENCY)) u_delay (
        .clk       (clk),
        .rst       (rst),
        .valid     (ram_valid),
        .wstrb     (ram_wstrb),
        .rdata     (ram_rdata),
        .ready     (ram_ready),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata)
    );

    // The RAM itself is passive and answers combinationally: it writes only the
    // lanes whose strobe is set (ram_delay sets them on the completing cycle
    // only), and an unrequested read is harmless.
    memory #(.WORDS(WORDS), .HEXFILE(HEXFILE), .FILL(RAM_FILL)) u_mem (
        .clk    (clk),
        .iaddr  (i_addr),
        .idata  (i_data),
        .daddr  (ram_addr),
        .drdata (mem_rdata),
        .dwdata (ram_wdata),
        .wstrb  (mem_wstrb)
    );

    console #(.LATENCY(IO_LATENCY)) u_console (
        .clk        (clk),
        .rst        (rst),
        .valid      (io_valid),
        .addr       (io_addr),
        .wstrb      (io_wstrb),
        .wdata      (io_wdata),
        .rdata      (io_rdata),
        .ready      (io_ready),
        .char_valid (char_valid),
        .char_data  (char_data),
        .exit_valid (exit_valid),
        .exit_code  (exit_code)
    );

endmodule
