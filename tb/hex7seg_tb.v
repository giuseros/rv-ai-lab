// hex7seg_tb.v — self-checking testbench for the 7-segment decoder.
// Run: make sim MOD=hex7seg
//
// Comparing against a copy of the decoder's table would only prove the table
// was typed twice the same way. Instead the shapes are described from the other
// direction, read off the drawn digits independently of the table:
//   - for each SEGMENT, which digits light it (the table lists, for each digit,
//     which segments it lights): a typo would have to be made the same way twice
//   - how many segments each digit lights (8 lights all 7, 1 lights 2 ...)
//   - all 16 patterns are different (no two digits look the same)
// Mutation-tested: every single-bit flip (112) and every swap of two segments
// within a digit (142) fails this test. Checking only segments a and g, 58 of
// the swaps survived. The final check is still the eye: the blinky shows every
// digit on HEX0/HEX1.
`timescale 1ns/1ps

module hex7seg_tb;

    reg  [3:0] digit;
    wire [6:0] seg;
    integer errors = 0;
    integer i, j, n;
    reg [6:0] pattern [0:15];

    hex7seg dut (.digit(digit), .seg(seg));

    // segments lit, per digit:   0  1  2  3  4  5  6  7  8  9  A  b  C  d  E  F
    function integer want_count(input [3:0] d);
        case (d)
            4'h0: want_count = 6;  4'h1: want_count = 2;  4'h2: want_count = 5;
            4'h3: want_count = 5;  4'h4: want_count = 4;  4'h5: want_count = 5;
            4'h6: want_count = 6;  4'h7: want_count = 3;  4'h8: want_count = 7;
            4'h9: want_count = 6;  4'hA: want_count = 6;  4'hB: want_count = 5;
            4'hC: want_count = 4;  4'hD: want_count = 5;  4'hE: want_count = 5;
            default: want_count = 4;                                   // F
        endcase
    endfunction

    // Which digits light each segment: bit k of the mask = digit k.
    // Written as the digits WITHOUT that segment, which is the shorter list.
    function [15:0] without(input [8*8:1] digits);   // "14bd" -> mask of those digits
        integer c;
        reg [7:0] ch;
    begin
        without = 16'h0000;
        for (c = 0; c < 8; c = c + 1) begin
            ch = digits[c*8+1 +: 8];
            if (ch >= "0" && ch <= "9") without[ch - "0"]      = 1'b1;
            if (ch >= "a" && ch <= "f") without[ch - "a" + 10] = 1'b1;
        end
    end
    endfunction
    function [15:0] lit_by(input integer s);         // digits that light segment s
        case (s)
            0: lit_by = ~without("14bd");    // a  top bar
            1: lit_by = ~without("56bcef");  // b  upper right
            2: lit_by = ~without("2cef");    // c  lower right
            3: lit_by = ~without("147af");   // d  bottom bar
            4: lit_by = ~without("134579");  // e  lower left
            5: lit_by = ~without("1237d");   // f  upper left
            default: lit_by = ~without("017c"); // g  middle bar
        endcase
    endfunction

    // The segments digit d should light, assembled from the seven lists above.
    // (A function's result can't be indexed directly in Verilog-2005: lit_by(s)[d]
    // is illegal, so it goes through m.)
    function [6:0] want_seg(input [3:0] d);
        integer s;
        reg [15:0] m;
    begin
        for (s = 0; s < 7; s = s + 1) begin
            m = lit_by(s);
            want_seg[s] = m[d];
        end
    end
    endfunction

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            digit = i;
            #1;
            pattern[i] = seg;
            n = seg[0] + seg[1] + seg[2] + seg[3] + seg[4] + seg[5] + seg[6];
            if (^seg === 1'bx) begin
                $display("FAIL: %h -> %b has X/Z bits", digit, seg);
                errors = errors + 1;
            end else if (n != want_count(digit)) begin
                $display("FAIL: %h -> %b lights %0d segments, want %0d",
                         digit, seg, n, want_count(digit));
                errors = errors + 1;
            end else if (seg !== want_seg(digit)) begin
                $display("FAIL: %h -> gfedcba %b, the segment lists say %b",
                         digit, seg, want_seg(digit));
                errors = errors + 1;
            end else
                $display("  ok: %h -> gfedcba %b", digit, seg);
        end

        for (i = 0; i < 16; i = i + 1)
            for (j = i + 1; j < 16; j = j + 1)
                if (pattern[i] == pattern[j]) begin
                    $display("FAIL: %h and %h look the same (%b)", i[3:0], j[3:0], pattern[i]);
                    errors = errors + 1;
                end

        $display("--------------------------------------------------");
        if (errors == 0) $display("HEX7SEG: ALL TESTS PASSED");
        else             $display("HEX7SEG: %0d FAILURE(S)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
