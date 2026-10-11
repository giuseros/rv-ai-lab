// memory_tb.v — self-checking testbench for the unified memory.
// Run: make sim MOD=memory      (waveform: make wave MOD=memory)
//
// Uses a small 16-word instance so wrap-around is reachable, preloaded from
// tb/memory_tb.hex (5 words; the rest stay zero). vvp runs from the project
// root, so the relative path in HEXFILE resolves.
`timescale 1ns/1ps

module memory_tb;

    localparam WORDS = 16;

    reg         clk;
    reg  [31:0] iaddr, daddr, dwdata;
    reg  [3:0]  wstrb;
    wire [31:0] idata, drdata;

    integer errors = 0;

    memory #(.WORDS(WORDS), .HEXFILE("tb/memory_tb.hex")) dut (
        .clk(clk),
        .iaddr(iaddr),   .idata(idata),
        .daddr(daddr),   .drdata(drdata),
        .dwdata(dwdata), .wstrb(wstrb)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task expect_i(input [31:0] addr, input [31:0] exp, input [8*24:1] what);
    begin
        iaddr = addr; #1;
        if (idata !== exp) begin
            $display("FAIL: %0s: idata[0x%08h] = 0x%08h, expected 0x%08h", what, addr, idata, exp);
            errors = errors + 1;
        end else
            $display("  ok: %0s: idata[0x%08h] = 0x%08h", what, addr, idata);
    end
    endtask

    task expect_d(input [31:0] addr, input [31:0] exp, input [8*24:1] what);
    begin
        daddr = addr; #1;
        if (drdata !== exp) begin
            $display("FAIL: %0s: drdata[0x%08h] = 0x%08h, expected 0x%08h", what, addr, drdata, exp);
            errors = errors + 1;
        end else
            $display("  ok: %0s: drdata[0x%08h] = 0x%08h", what, addr, drdata);
    end
    endtask

    // Drive one synchronous write: set up on the negedge, latch on the posedge,
    // then drop the strobes so nothing else is written by accident.
    task wr(input [31:0] addr, input [31:0] data, input [3:0] strb);
    begin
        @(negedge clk);
        daddr = addr; dwdata = data; wstrb = strb;
        @(negedge clk);
        wstrb = 4'b0000;
    end
    endtask

    initial begin
        $dumpfile("build/memory.vcd");
        $dumpvars(0, memory_tb);

        iaddr = 0; daddr = 0; dwdata = 0; wstrb = 4'b0000;
        #1;

        // ---- 1. the hex image landed, and both ports can see it ----
        expect_i(32'h0000_0000, 32'h0000_0013, "load word 0    ");
        expect_i(32'h0000_0004, 32'hdead_beef, "load word 1    ");
        expect_d(32'h0000_0008, 32'h0000_0042, "load word 2    ");
        expect_d(32'h0000_000C, 32'hcafe_babe, "load word 3    ");
        expect_d(32'h0000_0010, 32'h1122_3344, "load word 4    ");

        // ---- 2. words past the image are zero, not X ----
        expect_d(32'h0000_0014, 32'h0000_0000, "unloaded is 0  ");
        expect_d(32'h0000_003C, 32'h0000_0000, "unloaded is 0  ");

        // ---- 3. addr[1:0] is ignored: any byte in a word reads that word ----
        expect_d(32'h0000_0005, 32'hdead_beef, "addr[1:0] ignored");
        expect_d(32'h0000_0006, 32'hdead_beef, "addr[1:0] ignored");
        expect_d(32'h0000_0007, 32'hdead_beef, "addr[1:0] ignored");

        // ---- 4. the two read ports are independent ----
        iaddr = 32'h0000_0000; daddr = 32'h0000_000C; #1;
        if (idata !== 32'h0000_0013 || drdata !== 32'hcafe_babe) begin
            $display("FAIL: independent ports: idata=0x%08h drdata=0x%08h", idata, drdata);
            errors = errors + 1;
        end else
            $display("  ok: independent ports: idata=0x%08h drdata=0x%08h", idata, drdata);

        // ---- 5. both ports may read the SAME word ----
        iaddr = 32'h0000_0008; daddr = 32'h0000_0008; #1;
        if (idata !== 32'h0000_0042 || drdata !== 32'h0000_0042) begin
            $display("FAIL: same word both ports: idata=0x%08h drdata=0x%08h", idata, drdata);
            errors = errors + 1;
        end else
            $display("  ok: same word both ports: 0x%08h", idata);

        // ---- 6. full word write (sw) ----
        wr(32'h0000_0014, 32'h5555_AAAA, 4'b1111);
        expect_d(32'h0000_0014, 32'h5555_AAAA, "sw             ");

        // ---- 7. wstrb = 0 must not write ----
        wr(32'h0000_0014, 32'hFFFF_FFFF, 4'b0000);
        expect_d(32'h0000_0014, 32'h5555_AAAA, "wstrb=0 no write");

        // ---- 8. each byte lane writes only its own byte (sb) ----
        wr(32'h0000_0018, 32'h0000_0000, 4'b1111);   // clear the scratch word
        wr(32'h0000_0018, 32'hAABB_CCDD, 4'b0001);
        expect_d(32'h0000_0018, 32'h0000_00DD, "sb lane 0      ");
        wr(32'h0000_0018, 32'hAABB_CCDD, 4'b0010);
        expect_d(32'h0000_0018, 32'h0000_CCDD, "sb lane 1      ");
        wr(32'h0000_0018, 32'hAABB_CCDD, 4'b0100);
        expect_d(32'h0000_0018, 32'h00BB_CCDD, "sb lane 2      ");
        wr(32'h0000_0018, 32'hAABB_CCDD, 4'b1000);
        expect_d(32'h0000_0018, 32'hAABB_CCDD, "sb lane 3      ");

        // ---- 9. halfword strobes (sh) ----
        wr(32'h0000_001C, 32'hFFFF_FFFF, 4'b1111);
        wr(32'h0000_001C, 32'h1234_5678, 4'b0011);
        expect_d(32'h0000_001C, 32'hFFFF_5678, "sh low half    ");
        wr(32'h0000_001C, 32'h1234_5678, 4'b1100);
        expect_d(32'h0000_001C, 32'h1234_5678, "sh high half   ");

        // ---- 10. a write is visible on the instruction port too (one array) ----
        wr(32'h0000_0020, 32'h0BAD_F00D, 4'b1111);
        expect_i(32'h0000_0020, 32'h0BAD_F00D, "write seen by ifetch");

        // ---- 11. the write ignores addr[1:0] the same way reads do ----
        wr(32'h0000_0026, 32'hFEED_FACE, 4'b1111);
        expect_d(32'h0000_0024, 32'hFEED_FACE, "write addr[1:0] ignored");

        // ---- 12. the index truncates, so addresses wrap at WORDS ----
        // WORDS=16 -> 64 bytes. Byte 0x40 is word 16, which wraps to word 0.
        wr(32'h0000_0040, 32'h1111_2222, 4'b1111);
        expect_d(32'h0000_0000, 32'h1111_2222, "wrap: 0x40 -> 0x00");

        $display("--------------------------------------------------");
        if (errors == 0) $display("MEMORY: ALL TESTS PASSED");
        else             $display("MEMORY: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
