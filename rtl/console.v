// console.v — memory-mapped console and exit register (the I/O target)
//
// Sits behind the bus in region 1 (see soc_map.vh) and has four registers:
//
//     CONSOLE_ADDR  0x1000_0000   store a byte  -> print that character
//     EXIT_ADDR     0x1000_0004   store a word  -> end the program with that code
//     RX_DATA_ADDR  0x1000_0008   load a word   -> the byte received (see below)
//     RX_STAT_ADDR  0x1000_000C   load a word   -> receiver status (see below)
//                                 store a word  -> clear status flags (see below)
//
// Other loads read 0. Stores to any other I/O address (RX_DATA included) are
// accepted and ignored.
//
// A printed character goes two ways at once:
//
//   - as an EVENT for the testbench: char_valid + char_data, high for the one
//     cycle the store completes (exit_valid + exit_code likewise). Printing and
//     ending a simulation are testbench jobs ($write is not hardware), so the
//     module stays plain RTL.
//   - out of the serial line `tx` (8N1, uart_tx.v), for a real board.
//
// The serial line is slow (a character is 10 bit times; at 115200 baud and
// 50 MHz that is 4340 cycles), so the console must be able to make the CPU
// wait. It does so through `ready`, the bus's one way of saying "not yet":
//
//   - a character store completes in the cycle the transmitter takes the byte.
//     The transmitter is idle most of the time, so the store goes straight
//     through; only a character that arrives while the previous one is still
//     on the line waits, until that frame ends.
//   - an exit store completes only when the transmitter is idle: everything
//     printed is on the wire before the program's end is signalled.
//   - anything else (loads, other addresses) never waits for the transmitter.
//
// Events fire only in the cycle a store COMPLETES (bus protocol rule 4). While
// a store waits, the bus shows it on every cycle; a console that acted on each
// of them would print the character several times.
//
// ---- receiving ----
// Bytes arriving on `rx` (uart_rx.v) wait in a FIFO of RX_DEPTH bytes (16, as
// in the 16550 UART) until the program loads them, oldest first. There are
// two ways to wait for one:
//
//   RX_DATA  bits 7:0 the oldest byte, and loading it removes it from the
//            FIFO; or, if the FIFO is empty, 0x8000_0000 and nothing happens.
//            Bit 31 is not stored: it is "empty", put there by the read mux. So
//            one load both asks and takes; as an int it is negative when
//            empty, and a byte is 0..255 with nothing to mask off.
//   RX_STAT  bit 0  a byte is waiting (the FIFO is not empty; loading RX_STAT
//                   does NOT take the byte)
//            bit 1  a byte was dropped: it arrived while the FIFO was full
//                   (the bytes already in it are kept)
//            bit 2  a byte arrived with a framing error (stop bit 0); it is
//                   delivered anyway
//            Loading RX_STAT has no side effect, so it is safe to poll bit 0.
//            Bits 1 and 2 are sticky: set until the program clears them by
//            storing a 1 in that bit ("write 1 to clear"; a 0 leaves the bit
//            alone, bit 0 is read-only). The usual way: read RX_STAT, act on
//            the flags, store back what was read. Only the flags seen are then
//            cleared, and an event after the load is still there afterwards
//            (or merged into a flag that was already set and seen).
//
// Loading RX_DATA and storing to RX_STAT act only in the cycle the request
// COMPLETES; a load waiting out the latency must not take the byte on every
// waiting cycle. That a load is real at all is the CPU's promise (d_valid is
// 1 only for loads and stores): an add whose result happens to equal
// RX_DATA_ADDR reads nothing.
// The FIFO has no ready towards the line (a sender never waits). It absorbs
// bursts: a program may fall behind by up to RX_DEPTH bytes, e.g. while it
// prints, as long as it catches up. One that is slower ON AVERAGE than the
// line loses bytes whatever the depth; only flow control could stop that.
// The software can't see the depth: any RX_DEPTH runs the same programs.

`timescale 1ns/1ps
`include "soc_map.vh"

module console #(
    parameter LATENCY = 0,                // extra cycles per request, 0..255
    parameter CLK_HZ  = 100_000_000,      // clock and baud rate of the serial line.
    parameter BAUD    = 25_000_000,       // The default is a simulation speed, 4 cycles
                                          // a bit; a board passes its real ones.
    parameter RX_DEPTH = 16               // receive FIFO, in bytes: a power of 2, >= 2
) (
    input  wire        clk,
    input  wire        rst,

    // target side of the bus
    input  wire        valid,
    input  wire [31:0] addr,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,

    // events, each high for exactly the cycle the store completes
    output wire        char_valid,
    output wire [7:0]  char_data,
    output wire        exit_valid,
    output wire [31:0] exit_code,

    // serial line, 8N1, idle high
    output wire        tx,
    input  wire        rx           // asynchronous: uart_rx synchronises it
);

    // ---- latency, as in ram_delay: cycles the current request has waited ----
    // It stops counting at LATENCY instead of running on: a request can now
    // also wait for the transmitter, far longer than 255 cycles, and a counter
    // that wrapped around would no longer read LATENCY when the transmitter
    // became free.
    reg [7:0] waited;
    wire      waited_enough = (waited == LATENCY);

    always @(posedge clk) begin
        if (rst || !valid || ready)
            waited <= 8'd0;
        else if (!waited_enough)
            waited <= waited + 8'd1;
    end

    // ---- what the request is ----
    // addr is a full byte address, so addr == CONSOLE_ADDR already means the
    // store starts at lane 0: the character is in wdata[7:0]
    wire is_store   = (wstrb != 4'b0000);
    wire is_char    = is_store && (addr == `CONSOLE_ADDR);
    wire is_exit    = is_store && (addr == `EXIT_ADDR);
    wire is_rx_data = !is_store && (addr == `RX_DATA_ADDR);
    wire is_rx_stat = !is_store && (addr == `RX_STAT_ADDR);

    // ---- the transmitter ----
    // Offered the character once the latency has passed; it takes it in a cycle
    // where it is also ready (idle, or ending a stop bit). tx_valid must not
    // depend on tx_ready (the handshake rule), which is why it is not simply
    // char_valid.
    wire tx_valid = valid && waited_enough && is_char;
    wire tx_ready, tx_idle;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .valid(tx_valid), .data(wdata[7:0]),
        .ready(tx_ready), .idle(tx_idle), .tx(tx));

    // ---- completing the request ----
    // A character waits for tx_ready (the byte is taken now); exit waits for
    // tx_idle (the last frame has ended), which comes one cycle later when a
    // frame is going out.
    wire tx_wait = (is_char && !tx_ready) || (is_exit && !tx_idle);
    assign ready = valid && waited_enough && !tx_wait;

    wire store_done = ready && is_store;

    // char_valid is exactly the transmitter's handshake (tx_valid && tx_ready):
    // the event and the serial byte are the same character, never one without
    // the other.
    assign char_valid = store_done && is_char;
    assign char_data  = wdata[7:0];

    assign exit_valid = store_done && is_exit;
    assign exit_code  = wdata;

    // ---- the receiver and its FIFO ----
    wire       rx_valid, rx_err;
    wire [7:0] rx_data;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(rx),
        .valid(rx_valid), .data(rx_data), .frame_err(rx_err));

    // A circular buffer: rx_wr is where the next byte goes, rx_rd the oldest
    // byte. Both have ONE BIT MORE than an index needs. The low AW bits are
    // the slot; the top bit flips each time a pointer wraps around. Equal
    // pointers = empty; same slot but different top bits = the writer is a
    // whole lap ahead = full. (Without the extra bit, empty and full would
    // both be "same slot".)
    localparam AW = $clog2(RX_DEPTH);
    reg [7:0]  rx_fifo [0:RX_DEPTH-1];      // no reset: a slot is read only once written
    reg [AW:0] rx_wr = {(AW+1){1'b0}};
    reg [AW:0] rx_rd = {(AW+1){1'b0}};
    wire rx_empty = (rx_wr == rx_rd);
    wire rx_full  = (rx_wr[AW] != rx_rd[AW]) && (rx_wr[AW-1:0] == rx_rd[AW-1:0]);

    // A store to RX_STAT is a full byte address, so its strobe always covers
    // lane 0, where the flag bits are: no lane check needed.
    wire take      = ready && is_rx_data && !rx_empty;          // a byte leaves now
    wire clr_drop  = store_done && (addr == `RX_STAT_ADDR) && wdata[1];
    wire clr_ferr  = store_done && (addr == `RX_STAT_ADDR) && wdata[2];

    reg       rx_dropped = 1'b0;            // sticky, until a 1 is stored to it
    reg       rx_ferr    = 1'b0;            // sticky, until a 1 is stored to it

    // Order matters where two things happen in one cycle: a byte arriving at
    // a full FIFO as the oldest one is taken goes in (a slot frees at this
    // edge; it is the slot being read, which is fine: the load has its byte),
    // and an event arriving as its flag is cleared keeps the flag set (the
    // program cleared what it saw before; this one is new).
    always @(posedge clk) begin
        if (rst) begin
            rx_wr      <= {(AW+1){1'b0}};
            rx_rd      <= {(AW+1){1'b0}};
            rx_dropped <= 1'b0;
            rx_ferr    <= 1'b0;
        end else begin
            if (take)      rx_rd <= rx_rd + 1'b1;
            if (clr_drop)  rx_dropped <= 1'b0;
            if (clr_ferr)  rx_ferr    <= 1'b0;
            if (rx_valid) begin
                if (rx_full && !take)
                    rx_dropped <= 1'b1;         // nowhere to put it
                else begin
                    rx_fifo[rx_wr[AW-1:0]] <= rx_data;
                    rx_wr <= rx_wr + 1'b1;
                end
                if (rx_err) rx_ferr <= 1'b1;
            end
        end
    end

    // Only looked at in the cycle a load completes (the bus takes rdata with ready).
    assign rdata = is_rx_data ? (rx_empty ? 32'h8000_0000 : {24'd0, rx_fifo[rx_rd[AW-1:0]]}) :
                   is_rx_stat ? {29'd0, rx_ferr, rx_dropped, !rx_empty} :
                                32'd0;

endmodule
