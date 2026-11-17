// uart_rx_tb.v — self-checking testbench for the UART receiver.
// Run: make sim MOD=uart_rx
//
// The testbench is the sender: it drives the line in real time (ns), with its
// own idea of the bit length, the way a PC's adapter does, unrelated to the
// receiver's clock. Two receivers, run one after the other:
//   - 50 MHz / 115200: the board's rate, 434 cycles a bit
//   - 1 MHz / 59172:   16.9 cycles a bit, rounded to 17 (0.6% slow). One cycle is
//                      6% of a bit, so a sample point a cycle or two off shows
//                      up, and truncating to 16 instead (5.3% fast) puts the
//                      stop bit's sample into d7
//
// What is checked, and the bug each part is there to catch:
//   - reset: a byte sent during reset gives nothing, and neither does its
//     tail once reset is released mid-byte (the line is low there: the
//     receiver must wait for idle, not start in the middle of a byte)
//   - all 256 values, back to back with no idle between frames: bit order, a
//     dropped or doubled bit, a receiver that needs idle time between bytes
//   - a sender 3.5% fast and one 3.5% slow, back to back: the sample point.
//     Sampling a quarter of a bit early or late still works at the nominal rate,
//     but by the stop bit the drift has moved such a sample into a neighbouring bit
//   - glitches: a low pulse of 0.4 bit, of 0.25 bit and of ~1.5 clock cycles is
//     no start bit (it is gone by the middle of the start bit); a real byte after
//     them is still received
//   - reset in the middle of a byte, held past its end: the byte is dropped and
//     the receiver starts clean (as KEY[0] pressed while someone types)
//   - a stop bit of 0: the byte comes with frame_err, the next one without
//   - a break (the line low for 3 frames): ONE byte 0x00 with frame_err, then
//     nothing until the line has gone high again, then normal bytes
//   - valid lasts one cycle (a longer one records the byte twice), data changes
//     only in a cycle where valid is 1 (or in reset, which clears it), and
//     nothing arrives while the line idles
//
// Mutation-tested: 18 of 19 mutants fail it. The survivor is equivalent here: no
// synchroniser (metastability isn't simulated). Two others first survived and
// shaped the test: DIV truncated instead of rounded (both rates divided evenly;
// hence 59172 baud) and reset not clearing the state (no reset mid-byte; added).
`timescale 1ns/1ps

module rx_check #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200,
    // Exactly 6 characters: iverilog 12 prints a string parameter overridden
    // with a SHORTER string as empty (the value itself is right).
    parameter [8*6:1] NAME = "      "
) (
    input  wire go,                 // start the checks
    output reg  done = 1'b0
);
    localparam real CLK_NS = 1.0e9 / CLK_HZ;
    localparam real BIT_NS = 1.0e9 / BAUD;

    reg clk = 1'b0, rst = 1'b1, line = 1'b1;
    always #(CLK_NS / 2.0) clk = !clk;

    wire       valid, frame_err;
    wire [7:0] data;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .clk(clk), .rst(rst), .rx(line), .valid(valid), .data(data), .frame_err(frame_err));

    // ---- what the receiver delivered ----
    reg [7:0] got     [0:1023];
    reg       got_err [0:1023];
    integer   ngot = 0, data_changes = 0;
    reg [7:0] data_prev = 8'd0;
    always @(posedge clk) begin
        #0.1;                       // look just after the edge, at the new outputs
        if (valid === 1'b1) begin
            got[ngot] = data; got_err[ngot] = frame_err; ngot = ngot + 1;
        end else if (data !== data_prev && !rst)
            data_changes = data_changes + 1;     // data moved without valid (reset clears it)
        data_prev = data;
    end

    // ---- what it should have delivered ----
    reg [7:0] exp     [0:1023];
    reg       exp_err [0:1023];
    integer   nexp = 0;
    task expect(input [7:0] b, input e);
    begin exp[nexp] = b; exp_err[nexp] = e; nexp = nexp + 1; end
    endtask

    integer errors = 0;
    task chk(input [8*52:1] what, input ok);
    begin
        if (ok) $display("  ok: [%0s] %0s", NAME, what);
        else begin $display("FAIL: [%0s] %0s", NAME, what); errors = errors + 1; end
    end
    endtask

    // Did the receiver deliver exactly what was expected so far?
    task compare(input [8*52:1] what);
        integer k, bad;
    begin
        bad = 0;
        for (k = 0; k < nexp && k < ngot; k = k + 1)
            if (got[k] !== exp[k] || got_err[k] !== exp_err[k]) begin
                if (bad == 0)
                    $display("      byte %0d: got 0x%h err %b, expected 0x%h err %b",
                             k, got[k], got_err[k], exp[k], exp_err[k]);
                bad = bad + 1;
            end
        if (ngot != nexp) $display("      %0d bytes received, %0d expected", ngot, nexp);
        chk(what, bad == 0 && ngot == nexp);
    end
    endtask

    // ---- the sender ----
    // One frame, each bit lasting `scale` nominal bit times; stop = the stop
    // bit's level. The line is left high, with no idle time added: the next
    // frame may follow at once.
    task send(input [7:0] b, input real scale, input stop);
        integer k;
    begin
        line = 1'b0; #(BIT_NS * scale);
        for (k = 0; k < 8; k = k + 1) begin line = b[k]; #(BIT_NS * scale); end
        line = stop;  #(BIT_NS * scale);
        line = 1'b1;
    end
    endtask

    task idle(input real bits);
    begin line = 1'b1; #(BIT_NS * bits); end
    endtask

    integer i;
    reg [7:0] pat [0:9];

    initial begin
        pat[0] = 8'h55; pat[1] = 8'hAA; pat[2] = 8'h00; pat[3] = 8'hFF; pat[4] = 8'h01;
        pat[5] = 8'h80; pat[6] = 8'h0F; pat[7] = 8'hF0; pat[8] = 8'hC3; pat[9] = 8'h7E;

        wait (go === 1'b1);
        // Start between clock edges, so that line changes never coincide with one.
        @(negedge clk); #(CLK_NS * 0.3);

        // ---- reset ----
        // 0x00: the line is low from the start bit through d7. Reset is released
        // in the middle of d3, while the line is low.
        fork
            send(8'h00, 1.0, 1'b1);
            begin #(BIT_NS * 4.5); rst = 1'b0; end
        join
        idle(3);
        compare("reset: nothing, even with reset released mid-byte");

        // ---- all 256 values, back to back ----
        for (i = 0; i < 256; i = i + 1) begin
            send(i, 1.0, 1'b1);
            expect(i, 1'b0);
        end
        idle(3);
        compare("256 values back to back, nominal rate");

        // ---- off-rate senders, back to back ----
        for (i = 0; i < 10; i = i + 1) begin send(pat[i], 1.0 / 1.035, 1'b1); expect(pat[i], 1'b0); end
        idle(3);
        compare("sender 3.5% fast, back to back");
        for (i = 0; i < 10; i = i + 1) begin send(pat[i], 1.035, 1'b1); expect(pat[i], 1'b0); end
        idle(3);
        compare("sender 3.5% slow, back to back");

        // ---- glitches: no start bit ----
        line = 1'b0; #(BIT_NS * 0.4);  idle(2);
        line = 1'b0; #(BIT_NS * 0.25); idle(2);
        line = 1'b0; #(CLK_NS * 1.5);  idle(2);
        compare("glitches of 0.4 bit, 0.25 bit, 1.5 cycles: nothing");
        send(8'hA5, 1.0, 1'b1); expect(8'hA5, 1'b0);
        idle(2);
        compare("... and a byte after them is received");

        // ---- reset in the middle of a byte ----
        fork
            send(8'h96, 1.0, 1'b1);
            begin #(BIT_NS * 5.5); rst = 1'b1; #(BIT_NS * 6); rst = 1'b0; end
        join
        idle(2);
        send(8'h69, 1.0, 1'b1); expect(8'h69, 1'b0);
        idle(2);
        compare("reset mid-byte: dropped, next byte clean");

        // ---- a stop bit of 0 ----
        send(8'h3C, 1.0, 1'b0); expect(8'h3C, 1'b1);
        idle(1);
        send(8'hC3, 1.0, 1'b1); expect(8'hC3, 1'b0);
        idle(2);
        compare("stop bit 0: frame_err; next byte clean");

        // ---- a break: the line low for 3 frames ----
        line = 1'b0; #(BIT_NS * 30);
        expect(8'h00, 1'b1);                         // one byte, then waiting for idle
        idle(1);
        send(8'h81, 1.0, 1'b1); expect(8'h81, 1'b0);
        idle(2);
        compare("break: one 0x00 with frame_err, then normal");

        // ---- quiet line ----
        idle(40);
        compare("idle line: nothing more");
        chk("valid one cycle, data changes only with valid", data_changes == 0);

        done = 1'b1;
    end
endmodule

module uart_rx_tb;
    wire done_a, done_b;
    rx_check #(.CLK_HZ(50_000_000), .BAUD(115_200), .NAME("115200")) a (.go(1'b1),   .done(done_a));
    rx_check #(.CLK_HZ(1_000_000),  .BAUD(59_172),  .NAME("59172 ")) b (.go(done_a), .done(done_b));

    initial begin
        $dumpfile("build/uart_rx.vcd");
        $dumpvars(0, uart_rx_tb);
        wait (done_b === 1'b1);
        $display("--------------------------------------------------");
        if (a.errors + b.errors == 0) $display("UART_RX: ALL TESTS PASSED");
        else $display("UART_RX: %0d FAILURE(S)", a.errors + b.errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000_000;                             // 2 s; the run needs ~0.1
        $display("UART_RX: TIMEOUT");
        $finish;
    end
endmodule
