`timescale 1ns/1ps
// soc_top.v — the RISC-V SoC on the DE10-Lite: a C program, printf to the serial line.
//
// Build and load (PROG = any sw/ or tb/ program; default primes):
//   make fpga BOARD=de10-lite TOP=soc PROG=primes && make program BOARD=de10-lite TOP=soc PROG=primes
// On the PC (the adapter wired as for uart_hello_top, see pins.tcl):
//   stty -F /dev/ttyUSB0 115200 raw -echo clocal && cat /dev/ttyUSB0
//
// The program is part of the bitstream: it is the initial contents of the RAM
// (ram_sync's block RAMs), so a different program means a new build.
//
//   UART_TX      everything the program prints (115200 8N1)
//   HEX5..HEX0   blank while it runs; after exit(), the exit code's low 24 bits in hex
//   LEDR[0]      the program has exited
//   LEDR[9]      serial activity: on for 0.1 s after any bit on UART_TX
//   KEY[0]       reset, held while pressed: the program runs again on release.
//                The RAM is NOT reloaded: crt0 clears .bss again, but initialised
//                globals keep whatever the last run left in them.
//
// ---- clock: 25 MHz, from a PLL ----
// The single-cycle core does not make 50 MHz: Quartus puts its Fmax at 40 MHz
// (slow corner). Its critical path is the whole loop in one cycle: the RAM's
// instruction output, the register-file read mux, the ALU, the console's
// address decode (d_ready depends on the address the ALU just computed), the
// stall, the PC mux, i_next, and back into the RAM's address register. So a
// PLL halves the board's 50 MHz, and everything here runs on that one clock:
// CPU, RAM, UART, reset, displays. The UART's divider follows CPU_HZ.

module soc_top #(
    parameter HEXFILE = "",                 // program image; build.tcl passes it
    parameter CLK_HZ  = 50_000_000,         // the board's oscillator
    parameter BAUD    = 115_200
) (
    input  wire       MAX10_CLK1_50,
    input  wire [1:0] KEY,                  // push buttons: 0 while pressed (KEY[1] unused)
    output wire [9:0] LEDR,
    output wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,   // {dp, g..a}: 0 = segment ON
    output wire       UART_TX               // to the adapter's RXD
);
    localparam PLL_DIV = 2;
    localparam CPU_HZ  = CLK_HZ / PLL_DIV;

    wire clk, locked;
    // period in ps = 10^12 / CLK_HZ, written so that no step exceeds 32 bits
    max10_pll #(.IN_PS(1_000_000_000 / (CLK_HZ / 1000)), .DIV(PLL_DIV)) u_pll (
        .inclk(MAX10_CLK1_50), .clk(clk), .locked(locked));

    // locked comes from the PLL, not from a flip-flop on clk: synchronised.
    reg [1:0] locked_sync = 2'b00;
    always @(posedge clk)
        locked_sync <= {locked_sync[0], locked};

    // ---- reset: at power-up, and while KEY[0] is pressed ----
    // The CPU must see at least one clock edge in reset: that edge sets PC to 0
    // and (through i_next = 0) loads the first instruction into the RAM's output
    // register. Without it the core would start from whatever those registers
    // power up to; FPGA registers start at 0, and instruction word 0 is illegal, so
    // the first real instruction would be skipped. por counts 15 cycles once the
    // PLL has locked; reset is held until it is done (and again if lock is lost).
    reg [3:0] por = 4'd0;
    wire      por_done = (por == 4'hF);
    always @(posedge clk)
        if (!locked_sync[1]) por <= 4'd0;
        else if (!por_done)  por <= por + 4'd1;

    // KEY[0] is asynchronous: two flip-flops synchronise it (as in blinky_top)
    reg [1:0] key0_sync = 2'b11;
    always @(posedge clk)
        key0_sync <= {key0_sync[0], KEY[0]};

    wire rst = !por_done || !key0_sync[1];

    // ---- the SoC, with the clocked RAM (block RAM) ----
    wire        exit_valid;
    wire [31:0] exit_code;

    soc #(
        .HEXFILE  (HEXFILE),
        .SYNC_RAM (1),
        .CLK_HZ   (CPU_HZ),
        .BAUD     (BAUD)
    ) u_soc (
        .clk(clk), .rst(rst),
        .char_valid(), .char_data(),        // printed characters: they go out on serial_tx
        .exit_valid(exit_valid), .exit_code(exit_code),
        .serial_tx(UART_TX)
    );

    // ---- the exit code, latched for the displays ----
    // exit_valid is a one-cycle event (console.v); the code is only valid then.
    reg        done = 1'b0;
    reg [23:0] code = 24'd0;
    always @(posedge clk)
        if (rst) begin
            done <= 1'b0;
            code <= 24'd0;
        end else if (exit_valid) begin
            done <= 1'b1;
            code <= exit_code[23:0];
        end

    wire [6:0] s0, s1, s2, s3, s4, s5;      // active-high segments
    hex7seg u_h0 (.digit(code[3:0]),   .seg(s0));
    hex7seg u_h1 (.digit(code[7:4]),   .seg(s1));
    hex7seg u_h2 (.digit(code[11:8]),  .seg(s2));
    hex7seg u_h3 (.digit(code[15:12]), .seg(s3));
    hex7seg u_h4 (.digit(code[19:16]), .seg(s4));
    hex7seg u_h5 (.digit(code[23:20]), .seg(s5));

    // The board lights a segment on 0; all ones = blank. Decimal points stay off.
    assign HEX0 = done ? {1'b1, ~s0} : 8'hFF;
    assign HEX1 = done ? {1'b1, ~s1} : 8'hFF;
    assign HEX2 = done ? {1'b1, ~s2} : 8'hFF;
    assign HEX3 = done ? {1'b1, ~s3} : 8'hFF;
    assign HEX4 = done ? {1'b1, ~s4} : 8'hFF;
    assign HEX5 = done ? {1'b1, ~s5} : 8'hFF;

    // ---- serial activity LED ----
    // A character lasts 87 us at 115200: far too short to see. Any low on the
    // line (a start bit, a 0 data bit) reloads a 0.1 s timer; the LED is on
    // while it runs. If the terminal shows nothing but this LED flashes, the
    // problem is the wiring or the terminal, not the CPU.
    localparam TENTH = CPU_HZ / 10;                     // cycles in 0.1 s
    localparam FW    = $clog2(TENTH);
    localparam [FW-1:0] FLASH = TENTH[FW-1:0] - 1'b1;   // as in uart_hello_top
    reg [FW-1:0] flash = {FW{1'b0}};
    always @(posedge clk)
        if (!UART_TX)          flash <= FLASH;
        else if (flash != 0)   flash <= flash - 1'b1;

    assign LEDR = {flash != 0, 8'd0, done};
endmodule
