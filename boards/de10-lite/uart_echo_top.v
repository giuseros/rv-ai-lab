`timescale 1ns/1ps
// uart_echo_top.v — DE10-Lite serial receiver test: uart_rx on the real pins, no CPU.
//
// Build and load:  make fpga BOARD=de10-lite TOP=uart_echo && make program BOARD=de10-lite TOP=uart_echo
// On the PC:       picocom -b 115200 /dev/ttyUSB0      (and type)
//
// Every byte received on UART_RX is sent straight back on UART_TX, so what you
// type appears in the terminal only if both directions work (picocom does not
// print what you type by itself).
//   HEX1..HEX0  the last byte received, in hex (blank until the first): what
//               the terminal really sends, e.g. 61 for 'a', 0D for Enter
//   HEX5..HEX2  how many bytes have been received, in hex (wraps after FFFF)
//   LEDR[0]     a framing error has been seen (a stop bit of 0: wrong baud
//               rate, a loose wire); stays on until reset
//   LEDR[1]     a byte was dropped: it arrived while the previous one was still
//               waiting for the transmitter (see "the buffer"); stays on until reset
//   LEDR[8]     activity on UART_TX, LEDR[9] on UART_RX: on for 0.1 s after any bit
//   KEY[0]      reset: counts, displays and LEDs cleared
//
// There is no CPU and no PLL: everything runs on the board's 50 MHz.
//
// ---- the buffer ----
// The receiver has no ready (a sender never waits), and its valid lasts one
// cycle. The transmitter is busy for a whole frame. When the PC sends back to
// back, the next byte arrives while the transmitter is still finishing the
// previous one, so it waits here, in a one-byte buffer, until the transmitter
// takes it. One byte is enough as long as the transmitter is at least as fast
// as the sender: it then frees the buffer before the byte after that arrives.
// A sender that is faster, by however little, gains on it with every byte, and
// no buffer is big enough for an endless stream: it only postpones the first
// loss. At 50 MHz our bit is 434 cycles, 0.007% shorter than 115200 baud's.

module uart_echo_top #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200
) (
    input  wire       MAX10_CLK1_50,
    input  wire [1:0] KEY,              // push buttons: 0 while pressed (KEY[1] unused)
    output wire [9:0] LEDR,
    output wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,   // {dp, g..a}: 0 = segment ON
    output wire       UART_TX,          // to the adapter's RXD
    input  wire       UART_RX           // from the adapter's TXD
);
    wire clk = MAX10_CLK1_50;

    // ---- reset, synchronised (as in blinky_top) ----
    reg [1:0] key0_sync = 2'b11;
    always @(posedge clk)
        key0_sync <= {key0_sync[0], KEY[0]};
    wire rst = !key0_sync[1];

    // ---- receiver ----
    wire       rx_valid, rx_err;
    wire [7:0] rx_data;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(UART_RX),
        .valid(rx_valid), .data(rx_data), .frame_err(rx_err));

    // ---- the one-byte buffer, and the transmitter ----
    // full: hold has a byte the transmitter has not taken yet. It is offered
    // (valid = full) until taken (full && tx_ready). A byte that arrives while
    // the buffer is still full and not being emptied in this cycle is dropped
    // (the older one is kept), and LEDR[1] remembers it.
    reg       full    = 1'b0;
    reg [7:0] hold    = 8'd0;
    reg       overrun = 1'b0;
    wire      tx_ready;

    always @(posedge clk) begin
        if (rst) begin
            full    <= 1'b0;
            overrun <= 1'b0;
        end else begin
            if (full && tx_ready)
                full <= 1'b0;                   // taken at this edge
            if (rx_valid) begin
                if (full && !tx_ready)
                    overrun <= 1'b1;            // nowhere to put it
                else begin
                    hold <= rx_data;            // (overrides the line above when
                    full <= 1'b1;               //  one leaves as the next arrives)
                end
            end
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .valid(full), .data(hold),
        .ready(tx_ready), .idle(), .tx(UART_TX));

    // ---- what the displays and LEDR[0] show ----
    reg        seen   = 1'b0;               // a byte has arrived since reset
    reg  [7:0] last   = 8'd0;
    reg [15:0] nbytes = 16'd0;
    reg        ferr   = 1'b0;
    always @(posedge clk)
        if (rst) begin
            seen   <= 1'b0;
            last   <= 8'd0;
            nbytes <= 16'd0;
            ferr   <= 1'b0;
        end else if (rx_valid) begin
            seen   <= 1'b1;
            last   <= rx_data;
            nbytes <= nbytes + 16'd1;
            if (rx_err) ferr <= 1'b1;
        end

    wire [6:0] s0, s1, s2, s3, s4, s5;      // active-high segments
    hex7seg u_h0 (.digit(last[3:0]),     .seg(s0));
    hex7seg u_h1 (.digit(last[7:4]),     .seg(s1));
    hex7seg u_h2 (.digit(nbytes[3:0]),   .seg(s2));
    hex7seg u_h3 (.digit(nbytes[7:4]),   .seg(s3));
    hex7seg u_h4 (.digit(nbytes[11:8]),  .seg(s4));
    hex7seg u_h5 (.digit(nbytes[15:12]), .seg(s5));

    // The board lights a segment on 0; all ones = blank. Decimal points stay off.
    assign HEX0 = seen ? {1'b1, ~s0} : 8'hFF;
    assign HEX1 = seen ? {1'b1, ~s1} : 8'hFF;
    assign HEX2 = {1'b1, ~s2};
    assign HEX3 = {1'b1, ~s3};
    assign HEX4 = {1'b1, ~s4};
    assign HEX5 = {1'b1, ~s5};

    // ---- activity LEDs ----
    // As in uart_hello_top: any low on a line reloads a 0.1 s timer, the LED is
    // on while it runs. UART_RX is asynchronous, so it is synchronised first
    // (uart_rx has its own synchroniser inside; this one is for the LED).
    // UART_TX comes from our own flip-flop: no synchroniser.
    reg [1:0] rx_sync = 2'b11;
    always @(posedge clk)
        rx_sync <= {rx_sync[0], UART_RX};

    localparam TENTH = CLK_HZ / 10;                     // cycles in 0.1 s
    localparam FW    = $clog2(TENTH);
    localparam [FW-1:0] FLASH = TENTH[FW-1:0] - 1'b1;   // as in uart_hello_top
    reg [FW-1:0] rx_flash = {FW{1'b0}}, tx_flash = {FW{1'b0}};
    always @(posedge clk) begin
        if (!rx_sync[1])         rx_flash <= FLASH;
        else if (rx_flash != 0)  rx_flash <= rx_flash - 1'b1;
        if (!UART_TX)            tx_flash <= FLASH;
        else if (tx_flash != 0)  tx_flash <= tx_flash - 1'b1;
    end

    assign LEDR = {rx_flash != 0, tx_flash != 0, 6'd0, overrun, ferr};
endmodule
