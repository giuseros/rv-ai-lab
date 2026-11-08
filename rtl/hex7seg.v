`timescale 1ns/1ps
// hex7seg.v — one hex digit (0-F) to the segments of a 7-segment display
//
//        a
//      -----
//   f |     | b
//     |  g  |
//      -----
//   e |     | c
//     |     |
//      -----
//        d
//
// seg = {g, f, e, d, c, b, a}, ACTIVE-HIGH: 1 lights the segment. Polarity is a
// property of the board (the DE10-Lite's displays light on 0), so the board's top
// inverts; this module stays board-independent. b and d are lower case so they
// can't be confused with 8 and 0.

module hex7seg (
    input  wire [3:0] digit,
    output reg  [6:0] seg
);
    always @* begin
        case (digit)            //  gfedcba
            4'h0:    seg = 7'b0111111;
            4'h1:    seg = 7'b0000110;
            4'h2:    seg = 7'b1011011;
            4'h3:    seg = 7'b1001111;
            4'h4:    seg = 7'b1100110;
            4'h5:    seg = 7'b1101101;
            4'h6:    seg = 7'b1111101;
            4'h7:    seg = 7'b0000111;
            4'h8:    seg = 7'b1111111;
            4'h9:    seg = 7'b1101111;
            4'hA:    seg = 7'b1110111;
            4'hB:    seg = 7'b1111100;
            4'hC:    seg = 7'b0111001;
            4'hD:    seg = 7'b1011110;
            4'hE:    seg = 7'b1111001;
            default: seg = 7'b1110001;  // F (the only value left)
        endcase
    end
endmodule
