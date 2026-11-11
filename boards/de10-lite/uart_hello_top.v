`timescale 1ns/1ps
// uart_hello_top.v — DE10-Lite serial smoke test: uart_tx on the real pins, no CPU.
//
// Build and load:  make fpga BOARD=de10-lite TOP=uart_hello && make program BOARD=de10-lite TOP=uart_hello
// On the PC:       stty -F /dev/ttyUSB0 115200 raw -echo && cat /dev/ttyUSB0
//                  (or any serial terminal at 115200 8N1, e.g. picocom -b 115200 /dev/ttyUSB0)
//
// Once a second it sends one line, numbered in hex (two digits, wrapping after FF):
//   hello from the DE10-Lite, line 00
//   hello from the DE10-Lite, line 01 ...
//   LEDR[7:0]  the number of lines sent, in binary: the LEDs and the terminal agree
//   LEDR[9]    flashes for 0.1 s when anything arrives on UART_RX (type in screen):
//              proves the other wire before there is a receiver to decode it
//   KEY[0]     reset: the numbering restarts, and line 00 is sent at once
//
// UART_TX / UART_RX are not on the board: they are our wiring on the GPIO header
// to a USB-serial adapter (see pins.tcl for which header pins).

module uart_hello_top #(
    parameter CLK_HZ   = 50_000_000,
    parameter BAUD     = 115_200,
    parameter INTERVAL = CLK_HZ         // cycles from one line to the next: 1 s
) (
    input  wire       MAX10_CLK1_50,
    input  wire [1:0] KEY,              // push buttons: 0 while pressed (KEY[1] unused)
    output wire [9:0] LEDR,
    output wire       UART_TX,          // to the adapter's RXD
    input  wire       UART_RX           // from the adapter's TXD
);
    wire clk = MAX10_CLK1_50;

    // ---- reset, synchronised (as in blinky_top) ----
    reg [1:0] key0_sync = 2'b11;
    always @(posedge clk)
        key0_sync <= {key0_sync[0], KEY[0]};
    wire rst = !key0_sync[1];

    // ---- the text ----
    // A string literal is a bit vector, 8 bits per character, the first character
    // in the top byte. Character i of TEXT is TEXT[(TLEN-1-i)*8 +: 8].
    localparam [8*31-1:0] TEXT = "hello from the DE10-Lite, line ";
    localparam TLEN = 31;
    localparam LEN  = TLEN + 4;         // + two hex digits + "\r\n"

    reg [7:0] lines = 8'd0;             // lines sent so far = the next line's number
    reg [5:0] idx   = 6'd0;             // which character of the line is offered

    function [7:0] hex_char(input [3:0] n);
        hex_char = (n < 4'd10) ? 8'd48 + n          // '0'..'9'
                               : 8'd55 + n;         // 'A'..'F' ('A' = 65 = 55 + 10)
    endfunction

    reg [7:0] ch;                       // character idx of the current line
    always @* begin
        case (idx)
            TLEN:     ch = hex_char(lines[7:4]);
            TLEN + 1: ch = hex_char(lines[3:0]);
            TLEN + 2: ch = 8'h0D;       // \r: back to column 0 (terminals need both)
            TLEN + 3: ch = 8'h0A;       // \n: next line
            default:  ch = TEXT[(TLEN - 1 - idx) * 8 +: 8];
        endcase
    end

    // ---- once per INTERVAL, send a line ----
    // The counter starts at its last value, so the first line goes out right after
    // power-up or reset, and then one every INTERVAL cycles.
    // LAST = INTERVAL - 1 in W bits. Writing "INTERVAL - 1" makes a 32-bit value,
    // and Quartus warns when it is cut down to W; taking the low W bits first says
    // the cut is meant. (Still right when INTERVAL = 2^W: 0 - 1 wraps to all 1s.)
    localparam W = $clog2(INTERVAL);
    localparam [W-1:0] LAST = INTERVAL[W-1:0] - 1'b1;
    reg  [W-1:0] count = LAST;
    wire         due   = (count == LAST);

    // While sending, the current character is offered (valid) and held until the
    // transmitter takes it (ready): the handshake rule, so none is lost or doubled.
    // A line that is still going when the next one is due makes that one skip.
    reg  sending = 1'b0;
    wire ready;

    always @(posedge clk) begin
        if (rst) begin
            count   <= LAST;
            sending <= 1'b0;
            idx     <= 6'd0;
            lines   <= 8'd0;
        end else begin
            count <= due ? {W{1'b0}} : count + 1'b1;
            if (!sending) begin
                if (due) begin
                    sending <= 1'b1;
                    idx     <= 6'd0;
                end
            end else if (ready) begin           // character idx taken at this edge
                if (idx == LEN - 1) begin
                    sending <= 1'b0;
                    lines   <= lines + 8'd1;
                end else
                    idx <= idx + 6'd1;
            end
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .valid(sending), .data(ch), .ready(ready), .tx(UART_TX));

    // ---- activity on UART_RX ----
    // UART_RX is asynchronous like a key, so it is synchronised the same way. Any
    // low (a start bit, or a 0 data bit) reloads a 0.1 s timer; the LED is on while
    // it runs. A whole byte lasts 87 us at 115200: far too short to see unstretched.
    reg [1:0] rx_sync = 2'b11;
    always @(posedge clk)
        rx_sync <= {rx_sync[0], UART_RX};
    wire rx = rx_sync[1];

    localparam TENTH = CLK_HZ / 10;                     // cycles in 0.1 s
    localparam FW    = $clog2(TENTH);
    localparam [FW-1:0] FLASH = TENTH[FW-1:0] - 1'b1;   // as LAST above
    reg [FW-1:0] flash = {FW{1'b0}};
    always @(posedge clk)
        if (!rx)               flash <= FLASH;
        else if (flash != 0)   flash <= flash - 1'b1;

    assign LEDR = {flash != 0, 1'b0, lines};
endmodule
