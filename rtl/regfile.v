// regfile.v — RV32I register file
//
// 32 x 32-bit registers. x0 is hardwired to zero (reads 0, writes ignored).
// Two asynchronous read ports, one synchronous write port.
//
// >>> YOUR JOB: implement the body. The port list below is the contract the
//     testbench (tb/regfile_tb.v) compiles against — keep the names/widths.
//
// Behavior the testbench expects:
//   - rd1/rd2 reflect regs[rs1]/regs[rs2] combinationally (async read)
//   - on posedge clk, if we && (rd != 0), regs[rd] <= wd
//   - reads of x0 always return 0
//   - (nice-to-have) write-during-read to same address: read port may show
//     old value until the next cycle — that's fine, async read of a reg array.
`timescale 1ns/1ps

module regfile (
    input  wire        clk,
    input  wire        we,        // write enable
    input  wire [4:0]  rs1,       // read address 1
    input  wire [4:0]  rs2,       // read address 2
    input  wire [4:0]  rd,        // write address
    input  wire [31:0] wd,        // write data
    output wire [31:0] rd1,       // read data 1
    output wire [31:0] rd2        // read data 2
);

    // TODO (you): declare the register array and implement read/write.
    //   reg [31:0] regs [0:31];
    //   assign rd1 = ...;
    //   assign rd2 = ...;
    //   always @(posedge clk) if (we && rd != 5'd0) regs[rd] <= wd;
    reg [31:0] regs [0:31];
    always @(posedge clk) begin
        if (we && rd!= 5'd0) begin
            regs[rd] <= wd;
        end
    end
    assign rd1 = (rs1 == 0? 32'd0:regs[rs1]);
    assign rd2 = (rs2 == 0? 32'd0: regs[rs2]);
endmodule
