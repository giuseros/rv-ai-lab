// ram_sync_tb.v — self-checking testbench for the clocked RAM (four byte lanes).
// Run: make sim MOD=ram_sync
//
// Inputs change on the negedge; outputs are checked just after the posedge and
// again just before the next one. A RAM that read asynchronously would show the
// new address's word before the edge; one that read a cycle late would still
// show the old word after it.
//
// Image: tb/ram_sync_tb.hex, split into tb/ram_sync_tb.hex.b0..b3 (the files
// ram_sync actually loads; .hex is the readable version). Every byte of every
// word differs from the other lanes, sign bits mixed, so a lane swap or a
// wrong lane file gives a different word. FILL is 0xDEADBEEF: its four bytes
// differ too, so the fill is checked per lane.
//
// What is checked:
//   - initial contents: the 4 image words, and FILL after them, on both ports
//   - both ports read on the edge: before it the old word, after it the new one
//   - the ports are independent: different words at the same time
//   - addr[1:0] are ignored; addresses past the end wrap
//   - every strobe pattern (sb in each lane, sh in both halves, sw) writes only
//     its lanes, read back on both ports; wstrb = 0 writes nothing
//   - same edge, same word: the read sees the OLD word, on both ports; the
//     next edge sees the new one
`timescale 1ns/1ps

module ram_sync_tb;

    localparam WORDS = 16;
    localparam [31:0] FILL = 32'hDEAD_BEEF;

    reg         clk = 1'b0;
    reg  [31:0] iaddr = 32'd0, daddr = 32'd0, dwdata = 32'd0;
    reg  [3:0]  wstrb = 4'b0000;
    wire [31:0] idata, drdata;

    ram_sync #(.WORDS(WORDS), .HEXFILE("tb/ram_sync_tb.hex"), .FILL(FILL)) dut (
        .clk(clk), .iaddr(iaddr), .idata(idata),
        .daddr(daddr), .drdata(drdata), .dwdata(dwdata), .wstrb(wstrb));

    always #5 clk = !clk;

    integer errors = 0, checks = 0;
    task chk(input [31:0] got, input [31:0] exp, input [8*48:1] what);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            $display("FAIL: %0s = 0x%08h, expected 0x%08h", what, got, exp);
            errors = errors + 1;
        end
    end
    endtask

    // What the memory should hold: a model updated alongside every write.
    reg [31:0] model [0:WORDS-1];
    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1) model[k] = FILL;
        model[0] = 32'h1357_9BDF; model[1] = 32'h0246_8ACE;
        model[2] = 32'hF0E1_D2C3; model[3] = 32'h7F80_017E;
    end

    // One cycle: on the negedge present addresses (and maybe a write), then
    // let the posedge happen. Returns with the outputs just after the edge.
    task cycle(input [31:0] ia, input [31:0] da, input [3:0] s, input [31:0] wd);
    begin
        @(negedge clk);
        iaddr = ia; daddr = da; wstrb = s; dwdata = wd;
        @(posedge clk); #1;
    end
    endtask

    function [31:0] merge(input [31:0] old, input [31:0] wd, input [3:0] s);
        integer b;
    begin
        merge = old;
        for (b = 0; b < 4; b = b + 1) if (s[b]) merge[b*8 +: 8] = wd[b*8 +: 8];
    end
    endfunction

    reg [31:0] before_i, before_d, old;
    integer n, p;
    reg [3:0] pat [0:7];

    initial begin
        $dumpfile("build/ram_sync.vcd");
        $dumpvars(0, ram_sync_tb);

        // ---- initial contents, both ports, every word ----
        for (n = 0; n < WORDS; n = n + 1) begin
            cycle(4 * n, 4 * (WORDS - 1 - n), 4'b0000, 32'd0);
            chk(idata,  model[n],             "init: fetch port, word n");
            chk(drdata, model[WORDS - 1 - n], "init: data port, word 15-n");
        end

        // ---- reads happen on the edge, not before, not after ----
        cycle(4 * 1, 4 * 2, 4'b0000, 32'd0);            // now showing words 1 and 2
        @(negedge clk);
        iaddr = 4 * 3; daddr = 4 * 0;                    // new addresses mid-cycle
        #4;                                              // just before the edge
        chk(idata,  model[1], "fetch: old word until the edge");
        chk(drdata, model[2], "data: old word until the edge");
        @(posedge clk); #1;
        chk(idata,  model[3], "fetch: new word right after the edge");
        chk(drdata, model[0], "data: new word right after the edge");
        #8;                                              // just before the next edge
        chk(idata,  model[3], "fetch: word held through the cycle");
        chk(drdata, model[0], "data: word held through the cycle");

        // ---- addr[1:0] ignored, addresses wrap ----
        cycle(4 * 2 + 3, 4 * 1 + 2, 4'b0000, 32'd0);
        chk(idata,  model[2], "fetch: addr[1:0] ignored");
        chk(drdata, model[1], "data: addr[1:0] ignored");
        cycle(4 * (WORDS + 3), 32'h1000_0000 + 4 * 2, 4'b0000, 32'd0);
        chk(idata,  model[3], "fetch: address wraps past the end");
        chk(drdata, model[2], "data: high address bits ignored");

        // ---- every strobe pattern writes only its lanes ----
        pat[0] = 4'b0001; pat[1] = 4'b0010; pat[2] = 4'b0100; pat[3] = 4'b1000;
        pat[4] = 4'b0011; pat[5] = 4'b1100; pat[6] = 4'b1111; pat[7] = 4'b0000;
        for (p = 0; p < 8; p = p + 1) begin
            n = 4 + p;                                   // a FILL word each time
            cycle(0, 4 * n, pat[p], 32'hA1B2_C3D4 ^ (p * 32'h0101_0101));
            model[n] = merge(model[n], 32'hA1B2_C3D4 ^ (p * 32'h0101_0101), pat[p]);
            cycle(4 * n, 4 * n, 4'b0000, 32'd0);         // read it back on both ports
            chk(idata,  model[n], "strobes: fetch port reads only those lanes");
            chk(drdata, model[n], "strobes: data port reads only those lanes");
        end

        // ---- same edge, same word: old data, then new ----
        n = 13;
        old = model[n];
        cycle(4 * n, 4 * n, 4'b1111, 32'h5A5A_A5A5);     // write and read word 13
        model[n] = 32'h5A5A_A5A5;
        chk(idata,  old, "same edge: fetch port reads the OLD word");
        chk(drdata, old, "same edge: data port reads the OLD word");
        cycle(4 * n, 4 * n, 4'b0000, 32'd0);
        chk(idata,  model[n], "next edge: fetch port reads the new word");
        chk(drdata, model[n], "next edge: data port reads the new word");

        // ---- nothing else changed ----
        for (n = 0; n < WORDS; n = n + 1) begin
            cycle(4 * n, 4 * n, 4'b0000, 32'd0);
            chk(idata, model[n], "final: every word as the model says");
        end

        $display("--------------------------------------------------");
        if (errors == 0) $display("RAM_SYNC: ALL TESTS PASSED (%0d checks)", checks);
        else             $display("RAM_SYNC: %0d/%0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end
endmodule
