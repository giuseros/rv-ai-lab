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
//                                                 |
//                                                 +--------> serial_tx (8N1)
//                                                 +<-------- serial_rx (8N1)
//
// The bus routes each data request by address (see soc_map.vh). Instruction
// fetch stays a direct connection to the RAM: code only ever comes from RAM.
//
// The console reports what the program printed and its exit code as events on
// the SoC's outputs. Acting on them ($write, ending the simulation) is the
// testbench's job; everything in here is plain RTL. It also sends every printed
// character out of serial_tx, for a board's UART pin, and makes the CPU wait
// (d_ready) while the line is busy. Bytes arriving on serial_rx wait in the
// console until the program loads them (RX_DATA, soc_map.vh).
//
// The RAM is one of two, chosen by SYNC_RAM:
//   0  memory.v:   reads in the same cycle (an ideal memory; simulation only,
//                  it cannot be built from FPGA block RAM)
//   1  ram_sync.v: reads on the clock edge, as FPGA block RAM does. Fetch then
//                  uses the CPU's i_next (next cycle's PC), and loads wait one
//                  cycle for their data (ram_delay's MIN_READ).
// Either way the instance is g_mem.u_mem, and g_mem.word(n) returns word n
// (simulation only), so testbenches read memory the same way for both.
//
// tb/soc_tb.v reaches into this hierarchy, so the names u_cpu, g_mem.u_mem and
// g_mem.word are part of its contract.

`timescale 1ns/1ps

module soc #(
    parameter WORDS       = 4096,  // RAM size in 32-bit words (4096 = 16 KiB)
    parameter HEXFILE     = "",    // program image loaded into RAM at time 0
    parameter RAM_LATENCY = 0,     // extra cycles per RAM access (0 = instant)
    parameter IO_LATENCY  = 0,     // extra cycles per console access
    parameter [31:0] RAM_FILL = 32'd0, // RAM contents outside the program image
    parameter SYNC_RAM    = 0,     // 1 = RAM reads on the clock edge (block RAM)
    // Serial line. The default is a simulation speed: the testbenches' 10 ns
    // clock and 4 cycles a bit, so printing stays cheap. A board passes its own.
    parameter CLK_HZ      = 100_000_000,
    parameter BAUD        = 25_000_000
) (
    input  wire        clk,
    input  wire        rst,

    // console events: one-cycle pulses, see console.v
    output wire        char_valid,
    output wire [7:0]  char_data,
    output wire        exit_valid,
    output wire [31:0] exit_code,

    // serial console, 8N1, idle high: to a board's UART TX pin, and from its
    // RX pin (asynchronous; tie it to 1 if nothing drives it: idle)
    output wire        serial_tx,
    input  wire        serial_rx
);

    // fetch port
    wire [31:0] i_addr, i_data, i_next;

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
        .i_next  (i_next),
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
    ram_delay #(.LATENCY(RAM_LATENCY), .MIN_READ(SYNC_RAM ? 1 : 0)) u_delay (
        .clk       (clk),
        .rst       (rst),
        .valid     (ram_valid),
        .wstrb     (ram_wstrb),
        .rdata     (ram_rdata),
        .ready     (ram_ready),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata)
    );

    // The RAM itself is passive: it writes only the lanes whose strobe is set
    // (ram_delay sets them on the completing cycle only), and a read nobody
    // asked for is harmless.
    generate if (SYNC_RAM) begin : g_mem
        ram_sync #(.WORDS(WORDS), .HEXFILE(HEXFILE), .FILL(RAM_FILL)) u_mem (
            .clk    (clk),
            .iaddr  (i_next),       // sampled on the edge: the next cycle's PC
            .idata  (i_data),
            .daddr  (ram_addr),
            .drdata (mem_rdata),
            .dwdata (ram_wdata),
            .wstrb  (mem_wstrb)
        );
        // synthesis translate_off
        function [31:0] word(input integer n);
            word = {u_mem.lane[3].u_lane.m[n], u_mem.lane[2].u_lane.m[n],
                    u_mem.lane[1].u_lane.m[n], u_mem.lane[0].u_lane.m[n]};
        endfunction
        // synthesis translate_on
    end else begin : g_mem
        memory #(.WORDS(WORDS), .HEXFILE(HEXFILE), .FILL(RAM_FILL)) u_mem (
            .clk    (clk),
            .iaddr  (i_addr),
            .idata  (i_data),
            .daddr  (ram_addr),
            .drdata (mem_rdata),
            .dwdata (ram_wdata),
            .wstrb  (mem_wstrb)
        );
        // synthesis translate_off
        function [31:0] word(input integer n);
            word = u_mem.mem[n];
        endfunction
        // synthesis translate_on
    end endgenerate

    console #(.LATENCY(IO_LATENCY), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_console (
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
        .exit_code  (exit_code),
        .tx         (serial_tx),
        .rx         (serial_rx)
    );

endmodule
