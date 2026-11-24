// boot_tb.v — the bootloader (sw/boot.c) receiving a program over the serial line.
// Run: make sim MOD=boot      (builds build/boot_sim.hex and build/load/*.bytes)
//
// Each SoC starts with the bootloader as its RAM image, as the board does, and
// the testbench plays the PC (uart_driver, tb_lib.v). It runs build/boot_sim.hex:
// sw/boot.c with a short wait after reset (2000 polls, not ~1 s), else the same.
//   0. power-on: the RAM is garbage (RAM_FILL), so there is no valid record of a
//      last program: nothing is rerun, and nothing printed. One SoC fills with
//      0xDEADBEEF, the other with 0x00000123: there the record's length looks
//      valid, so only its magic word stops a CRC of garbage and a misleading
//      "last program changed" at power-on (a mutant without the magic check
//      survived with 0xDEADBEEF alone)
// Then it sends, in order:
//   1. typing that is not a frame                -> ignored (nothing printed)
//   2. a frame whose length is impossible        -> "boot: bad length"
//   3. a 64-byte frame with a wrong CRC          -> "boot: bad checksum"
//   4. a 64-byte frame, one byte with stop bit 0 -> "boot: bytes lost"
//   5. c_basics linked at 0x800, correct CRC     -> "boot: ok", then c_basics
//      runs and checks itself: exit code 0. It uses a jump table, function
//      pointers and .data, so it only passes if every absolute address in it
//      is right at 0x800: the image landed intact, where it was linked.
// Then resets, as KEY[0] does:
//   6. nothing sent: c_basics changed its own .data while it ran (data_word +=
//      7), so the RAM no longer matches its CRC -> "boot: last program changed,
//      send it again", and it is not run
//   7. primes sent right after "boot: ready", inside the wait -> "boot: ok", and
//      primes runs: exit code 76127
//   8. nothing sent: primes only writes .bss, which its crt0 re-zeroes -> "boot:
//      running the last program", and it gives 76127 again
// Finally: the bootloader's code in RAM is unchanged (the programs it loaded did
// not overwrite it), and there were exactly three exits.
// The CRC sent is computed here, bit by bit (crc32 below): a second
// implementation, independent of the bootloader's 16-entry table.
//
// Two SoCs: the clocked RAM (as on the board) and memory answering 3 cycles
// late. The line runs at 16 cycles a bit, 160 a byte: slower than soc_tb's, so
// the ratio to the bootloader's per-byte work is closer to the board's (~2,170
// cycles a byte at 115200 baud and 25 MHz).
`timescale 1ns/1ps

module boot_check #(
    parameter SYNC = 0,
    parameter LAT  = 0,
    parameter [31:0] FILL = 32'hDEAD_BEEF,  // RAM outside the image: power-on garbage
    parameter [8*4:1] NAME = "    "         // exactly 4 characters (iverilog quirk)
) (
    input wire clk,
    input wire go
);
    localparam BAUD = 6_250_000;            // at 100 MHz: 16 cycles a bit

    reg rst = 1'b1;
    wire        cv, ev, tx, rx;
    wire [7:0]  ch;
    wire [31:0] code;
    soc #(.WORDS(4096), .HEXFILE("build/boot_sim.hex"), .SYNC_RAM(SYNC),
          .RAM_LATENCY(LAT), .IO_LATENCY(LAT), .RAM_FILL(FILL),
          .CLK_HZ(100_000_000), .BAUD(BAUD)) dut (
        .clk(clk), .rst(rst), .serial_rx(rx),
        .char_valid(cv), .char_data(ch), .exit_valid(ev), .exit_code(code), .serial_tx(tx));
    console_sink s (.clk(clk), .rst(rst), .char_valid(cv), .char_data(ch),
        .exit_valid(ev), .exit_code(code));
    uart_driver #(.BAUD(BAUD)) u (.line(rx));

    integer errors = 0, checks = 0;
    reg     done = 1'b0;
    task chk(input [8*56:1] what, input ok);
    begin
        checks = checks + 1;
        if (ok) $display("  ok: %0s %0s", NAME, what);
        else begin $display("FAIL: %0s %0s", NAME, what); errors = errors + 1; end
    end
    endtask

    // ---- what the program prints, line by line ----
    reg [8*48:1] line = 0, last = 0;
    integer      nlines = 0, nexits = 0;
    always @(posedge clk) if (rst) line = 0; else begin
        if (cv) begin
            if (ch == "\n") begin last = line; line = 0; nlines = nlines + 1; end
            else line = {line[8*47:1], ch};
        end
        if (ev) nexits = nexits + 1;
    end

    // Wait for the next line to be printed; returns it in `last`.
    integer n0;
    task next_line;
    begin
        n0 = nlines;
        wait (nlines == n0 + 1);
    end
    endtask

    // ---- the program to send, and the bootloader's own image ----
    reg [7:0]  img  [0:16383];
    reg [31:0] boot [0:511];
    integer    len, boot_words;

    // img = a program image (one byte per line), len = its length
    task load_image(input [8*40:1] file);
        integer j;
    begin
        for (j = 0; j < 16384; j = j + 1) img[j] = 8'bx;
        $readmemh(file, img);
        len = 0;
        while (len < 16384 && img[len] !== 8'bx) len = len + 1;
    end
    endtask

    task reset_soc;                             // as KEY[0]
    begin
        @(negedge clk) rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
    end
    endtask

    // After a reset: "\nboot: ready\n" is an empty line, then the banner.
    task banner;
    begin
        next_line; next_line;
    end
    endtask

    function [31:0] crc32(input integer n);     // zlib's CRC-32 of img[0..n-1]
        integer i, k;
        reg [31:0] c;
    begin
        c = 32'hFFFF_FFFF;
        for (i = 0; i < n; i = i + 1) begin
            c = c ^ {24'd0, img[i]};
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : (c >> 1);
        end
        crc32 = ~c;
    end
    endfunction

    task send_word(input [31:0] w);             // little-endian
    begin
        u.send(w[7:0], 1'b1);   u.send(w[15:8], 1'b1);
        u.send(w[23:16], 1'b1); u.send(w[31:24], 1'b1);
    end
    endtask

    // A frame: magic, length, the first n bytes of img, then `crc`. Byte `bad`
    // (if in range) goes out with a stop bit of 0, then the line idles for 2
    // bits: after a stop bit of 0 the receiver waits to see the line high before
    // it takes another start bit (uart_rx's `armed`), as a real line would be.
    task send_frame(input integer n, input [31:0] crc, input integer bad);
        integer i;
    begin
        u.send_text("RVLD");
        send_word(n);
        for (i = 0; i < n; i = i + 1) begin
            u.send(img[i], i != bad);
            if (i == bad) u.pause(2);
        end
        send_word(crc);
    end
    endtask

    integer i, same;

    initial begin
        load_image("build/load/c_basics.bytes");
        $readmemh("build/boot_sim.hex", boot);
        boot_words = 0;
        while (boot_words < 512 && boot[boot_words] !== 32'bx) boot_words = boot_words + 1;

        wait (go);
        repeat (2) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        banner;                                                 // 0. power-on
        chk("banner: \"boot: ready\"", last == "boot: ready");
        repeat (60_000) @(posedge clk);         // > the wait (2000 polls, <= ~25 cycles each)
        chk("power-on, RAM garbage: nothing rerun, still waiting", nlines == 2 && nexits == 0);
        @(posedge clk) #3;                      // line changes between clock edges

        u.send_text("hello");                   // 1. not a frame
        u.pause(20);
        chk("typing that is not a frame: ignored", nlines == 2);

        u.send_text("RVLD"); send_word(32'h0001_0000);          // 2. 64 KiB: too long
        next_line;
        chk("impossible length: \"boot: bad length\"", last == "boot: bad length");
        @(posedge clk) #3;

        send_frame(64, crc32(64) ^ 32'h0000_0100, -1);          // 3. wrong CRC
        next_line;
        chk("wrong CRC: \"boot: bad checksum\"", last == "boot: bad checksum");
        @(posedge clk) #3;

        send_frame(64, crc32(64), 17);                          // 4. byte 17 bad stop bit
        next_line;
        chk("a byte with a framing error: \"boot: bytes lost\"", last == "boot: bytes lost");
        chk("... nothing run so far (no exit)", nexits == 0);
        @(posedge clk) #3;

        $display("        %0s sending c_basics: %0d bytes, CRC %h", NAME, len, crc32(len));
        send_frame(len, crc32(len), -1);                        // 5. the real thing
        next_line;
        chk("c_basics: \"boot: ok\"", last == "boot: ok");
        wait (nexits == 1);
        #1;
        chk("c_basics ran and passed its checks: exit code 0", s.code == 32'd0);
        repeat (4) @(posedge clk);
        chk("... and reached its final loop", dut.u_cpu.i_data === 32'h0000006F);

        reset_soc;                                              // 6. nothing sent
        banner;
        next_line;
        chk("reset after c_basics: \"boot: last program changed...\"",
            last == "boot: last program changed, send it again");
        repeat (100) @(posedge clk);
        chk("... and it was not run", nexits == 1);

        load_image("build/load/primes.bytes");
        reset_soc;                                              // 7. primes, in the wait
        banner;
        #3;
        $display("        %0s sending primes: %0d bytes, CRC %h", NAME, len, crc32(len));
        send_frame(len, crc32(len), -1);
        next_line;
        chk("reset, primes sent within the wait: \"boot: ok\"", last == "boot: ok");
        wait (nexits == 2);
        #1;
        chk("... primes ran: exit code 76127", s.code == 32'd76127);

        reset_soc;                                              // 8. nothing sent
        banner;
        next_line;
        chk("reset after primes: \"boot: running the last program\"",
            last == "boot: running the last program");
        wait (nexits == 3);
        #1;
        chk("... primes again: exit code 76127", s.code == 32'd76127);
        repeat (4) @(posedge clk);
        chk("... and reached its final loop", dut.u_cpu.i_data === 32'h0000006F);

        same = 0;
        for (i = 0; i < boot_words; i = i + 1)
            if (dut.g_mem.word(i) === boot[i]) same = same + 1;
        chk("the bootloader's code in RAM is untouched", same == boot_words && boot_words > 200);
        chk("exactly three exits", nexits == 3);
        done = 1'b1;
    end
endmodule


module boot_tb;
    reg clk = 1'b0;
    always #5 clk = !clk;

    boot_check #(.SYNC(1), .LAT(0), .NAME("SR  ")) b_sr (.clk(clk), .go(1'b1));
    boot_check #(.SYNC(0), .LAT(3), .FILL(32'h0000_0123), .NAME("L3  ")) b_l3 (.clk(clk), .go(1'b1));

    initial begin
        $dumpfile("build/boot.vcd");
        $dumpvars(1, boot_tb);                  // top only: the run is millions of cycles
        wait (b_sr.done && b_l3.done);
        $display("--------------------------------------------------");
        if (b_sr.errors + b_l3.errors == 0)
            $display("BOOT: ALL TESTS PASSED (%0d checks)", b_sr.checks + b_l3.checks);
        else
            $display("BOOT: %0d/%0d CHECKS FAILED", b_sr.errors + b_l3.errors,
                     b_sr.checks + b_l3.checks);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #80_000_000;                            // 80 ms; the run needs ~35
        $display("BOOT: TIMEOUT");
        $finish;
    end
endmodule
