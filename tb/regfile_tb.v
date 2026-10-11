// regfile_tb.v — self-checking testbench for the RV32I register file.
// Run: make sim MOD=regfile      (waveform: make wave MOD=regfile)
`timescale 1ns/1ps

module regfile_tb;

    reg         clk;
    reg         we;
    reg  [4:0]  rs1, rs2, rd;
    reg  [31:0] wd;
    wire [31:0] rd1, rd2;

    integer errors = 0;

    regfile dut (
        .clk(clk), .we(we),
        .rs1(rs1), .rs2(rs2), .rd(rd), .wd(wd),
        .rd1(rd1), .rd2(rd2)
    );

    // 10ns clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Write helper: drive rd/wd/we, tick one posedge, drop we.
    task write_reg(input [4:0] a, input [31:0] d);
    begin
        @(negedge clk);
        rd = a; wd = d; we = 1;
        @(negedge clk);          // posedge in between latches the write
        we = 0;
    end
    endtask

    // Check read port 1 against expected.
    task expect_rd1(input [4:0] a, input [31:0] exp);
    begin
        rs1 = a; #1;
        if (rd1 !== exp) begin
            $display("FAIL: rd1[x%0d] = 0x%08h, expected 0x%08h", a, rd1, exp);
            errors = errors + 1;
        end else
            $display("  ok: rd1[x%0d] = 0x%08h", a, rd1);
    end
    endtask

    // Check read port 2 against expected.
    task expect_rd2(input [4:0] a, input [31:0] exp);
    begin
        rs2 = a; #1;
        if (rd2 !== exp) begin
            $display("FAIL: rd2[x%0d] = 0x%08h, expected 0x%08h", a, rd2, exp);
            errors = errors + 1;
        end else
            $display("  ok: rd2[x%0d] = 0x%08h", a, rd2);
    end
    endtask

    initial begin
        $dumpfile("build/regfile.vcd");
        $dumpvars(0, regfile_tb);

        we = 0; rs1 = 0; rs2 = 0; rd = 0; wd = 0;

        // 1) basic write/read
        write_reg(5'd1,  32'hDEAD_BEEF);
        write_reg(5'd2,  32'h0000_0042);
        expect_rd1(5'd1, 32'hDEAD_BEEF);
        expect_rd2(5'd2, 32'h0000_0042);

        // 2) x0 stays zero even after a write attempt
        write_reg(5'd0,  32'hFFFF_FFFF);
        expect_rd1(5'd0, 32'h0000_0000);

        // 3) overwrite an existing register
        write_reg(5'd1,  32'h1234_5678);
        expect_rd1(5'd1, 32'h1234_5678);

        // 4) two independent read ports at once
        expect_rd1(5'd1, 32'h1234_5678);
        expect_rd2(5'd2, 32'h0000_0042);

        // 5) we=0 must NOT write.
        // Seed x5 first, then attempt a write with we=0 and check it is unchanged.
        // (Don't expect 0 here: an unwritten register array is X in sim, not 0.)
        write_reg(5'd5,  32'h0000_0005);
        @(negedge clk); rd = 5'd5; wd = 32'hCAFE_CAFE; we = 0; @(negedge clk);
        expect_rd1(5'd5, 32'h0000_0005);

        $display("--------------------------------------------------");
        if (errors == 0) $display("REGFILE: ALL TESTS PASSED");
        else             $display("REGFILE: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
