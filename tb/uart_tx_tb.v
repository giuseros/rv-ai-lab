// uart_tx_tb.v — self-checking testbench for the UART transmitter.
// Run: make sim MOD=uart_tx
//
// Two transmitters at different rates (50 MHz / 115200 like the board, and
// 1 MHz / 9600), each listened to by a uart_monitor (tb_lib.v) that knows only
// the nominal baud rate. A second rate catches a bit length that was right for
// the first one by accident (e.g. 434 typed in instead of computed).
//
// The bytes are chosen so that each likely bug gives a different answer:
//   0x01 / 0x80   bit order: sent MSB-first, each turns into the other
//   0x00          line low for 9 bits: a missing or short stop bit is a
//                 framing error, and a missing start bit loses the byte
//   0xFF          only the start bit is low
//   0xA5, 0x3C    mixed patterns; a shifted frame (a bit dropped or doubled)
//                 changes them
// After each byte is taken, the testbench changes `data` to its complement: a
// transmitter that kept reading `data` instead of its own copy sends garbage.
// Single bytes are separated by real idle time (3 bit periods), and the line
// must be high then: with back-to-back bytes only, a line that idled LOW was
// invisible (the next start bit is low anyway). Bit timing is checked to 0.5%:
// correct rounding errs by at most 0.5/DIV (0.007% and 0.16% here), while a bit
// one cycle too long is 0.23% and 0.96% off.
`timescale 1ns/1ps

module uart_tx_tb;

    // ---- the board's rate ----
    reg        clk = 0, rst = 1, valid = 0;
    reg  [7:0] data = 8'h00;
    wire       ready, tx;
    always #10 clk = !clk;                          // 50 MHz
    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) dut (
        .clk(clk), .rst(rst), .valid(valid), .data(data), .ready(ready), .tx(tx));
    uart_monitor #(.BAUD(115_200)) mon (.line(tx));

    // ---- a second rate ----
    reg        clk2 = 0, rst2 = 1, valid2 = 0;
    reg  [7:0] data2 = 8'h00;
    wire       ready2, tx2;
    always #500 clk2 = !clk2;                       // 1 MHz
    uart_tx #(.CLK_HZ(1_000_000), .BAUD(9_600)) dut2 (
        .clk(clk2), .rst(rst2), .valid(valid2), .data(data2), .ready(ready2), .tx(tx2));
    uart_monitor #(.BAUD(9_600)) mon2 (.line(tx2));

    integer errors = 0;
    task chk(input [8*48:1] what, input ok);
    begin
        if (ok) $display("  ok: %0s", what);
        else begin $display("FAIL: %0s", what); errors = errors + 1; end
    end
    endtask

    // Offer one byte; return after the edge that took it. valid/data change on
    // the negedge; ready is sampled there too, so "ready at this negedge" means
    // "taken at the next posedge".
    task send(input [7:0] b, input hold);           // hold: keep valid for the next byte
    begin
        @(negedge clk); valid = 1'b1; data = b;
        while (!ready) @(negedge clk);
        @(negedge clk);                             // the posedge in between took it
        if (!hold) begin
            valid = 1'b0;
            data  = ~b;                             // the copy must be used from now on
        end
    end
    endtask

    task send2(input [7:0] b);
    begin
        @(negedge clk2); valid2 = 1'b1; data2 = b;
        while (!ready2) @(negedge clk2);
        @(negedge clk2); data2 = ~b; valid2 = 1'b0;
    end
    endtask

    // A byte's start-to-start time vs 10 nominal bit periods, within 0.5%.
    function period_ok(input real p, input real baud);
        real want;
    begin
        want = 10.0 * 1.0e9 / baud;
        period_ok = (p > 0.995 * want) && (p < 1.005 * want);
    end
    endfunction

    // Wait until the line has been idle for 3 bit periods, then check it is high.
    integer idle_bad = 0;
    task idle_gap;
    begin
        repeat (3 * 434) @(negedge clk);
        if (tx !== 1'b1) idle_bad = idle_bad + 1;
    end
    endtask

    reg [8*6:1] hello;
    integer i, base, bad;

    initial begin
        // ---- power-up and reset: the line idles high, nothing is taken ----
        #1;
        chk("power-up: line idle (high)",         tx === 1'b1 && tx2 === 1'b1);
        @(negedge clk); valid = 1'b1; data = 8'h00;  // offered during reset ...
        repeat (5) @(negedge clk);
        chk("in reset: ready is 0",               ready === 1'b0);
        valid = 1'b0;
        rst = 1'b0; rst2 = 1'b0;
        repeat (3) @(negedge clk);
        chk("after reset: ready, line high",      ready === 1'b1 && tx === 1'b1);

        // ---- single bytes, with idle time between ----
        send(8'h01, 0);
        chk("busy (ready 0) right after taking a byte", ready === 1'b0);
        while (!ready) @(negedge clk);
        idle_gap;
        for (i = 1; i < 6; i = i + 1) begin
            case (i)
                1: send(8'h80, 0);  2: send(8'h00, 0);  3: send(8'hFF, 0);
                4: send(8'hA5, 0);  default: send(8'h3C, 0);
            endcase
            while (!ready) @(negedge clk);
            idle_gap;
        end
        // the last idle gap has passed: the monitor has seen everything by now
        chk("line idles high between bytes",      idle_bad == 0);
        chk("exactly 6 bytes received",           mon.count == 6);
        chk("0x01 (bit order)",                   mon.bytes[0] == 8'h01);
        chk("0x80 (bit order)",                   mon.bytes[1] == 8'h80);
        chk("0x00 (stop bit after 9 low bits)",   mon.bytes[2] == 8'h00);
        chk("0xFF (only the start bit low)",      mon.bytes[3] == 8'hFF);
        chk("0xA5, 0x3C",                         mon.bytes[4] == 8'hA5 && mon.bytes[5] == 8'h3C);

        // ---- back to back: valid held, "hello\n" ----
        hello = "hello\n";
        for (i = 5; i >= 0; i = i - 1)
            send(hello[i*8+1 +: 8], i != 0);
        wait (mon.count == 12);
        bad = 0;
        for (i = 0; i < 6; i = i + 1)
            if (mon.bytes[6 + i] != hello[(5 - i)*8+1 +: 8]) bad = bad + 1;
        chk("\"hello\\n\" back to back",          bad == 0);
        bad = 0;
        for (i = 7; i < 12; i = i + 1)              // [6] follows an idle gap
            if (!period_ok(mon.period[i], 115_200.0)) bad = bad + 1;
        chk("back to back: 10 bit periods each (0.5%)", bad == 0);
        $display("        (measured %0.1f ns per byte; nominal %0.1f)",
                 mon.period[8], 10.0e9 / 115_200.0);
        chk("no framing errors, no false starts", mon.framing_errors == 0 && mon.false_starts == 0);

        // ---- reset in the middle of a byte ----
        send(8'h00, 0);
        repeat (3 * 434) @(negedge clk);            // ~3 bits into it
        rst = 1'b1;
        @(negedge clk);
        chk("reset mid-byte: line back high at once", tx === 1'b1);
        rst = 1'b0;
        repeat (30 * 434) @(negedge clk);           // let the monitor finish its partial frame
        base = mon.count;
        send(8'h5A, 0);
        wait (mon.count == base + 1);
        chk("after a mid-byte reset: 0x5A sent cleanly", mon.bytes[base & 255] == 8'h5A);

        // ---- the second rate ----
        send2(8'h3C); send2(8'hC3);
        wait (mon2.count == 2);
        chk("9600 baud: 0x3C, 0xC3",              mon2.bytes[0] == 8'h3C && mon2.bytes[1] == 8'hC3);
        chk("9600 baud: no framing errors",       mon2.framing_errors == 0 && mon2.false_starts == 0);
        send2(8'h00); send2(8'hFF);                 // send2 drops valid: a 1-cycle gap
        wait (mon2.count == 4);
        chk("9600 baud: byte period (0.5%)",      period_ok(mon2.period[3], 9_600.0));

        $display("--------------------------------------------------");
        if (errors == 0) $display("UART_TX: ALL TESTS PASSED");
        else             $display("UART_TX: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin                                   // watchdog
        #20_000_000;
        $display("UART_TX: TIMEOUT");
        $finish;
    end
endmodule
