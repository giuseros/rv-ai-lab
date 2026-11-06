// cpu.v — single-cycle RV32I core
//
// One instruction per clock: fetch, decode, execute, memory and writeback all
// happen between two rising edges, and the PC, register file and any store
// commit together on the closing edge.
//
// The core has no memory of its own. It talks to the outside through two ports:
//
//   Fetch port   i_addr -> instruction address (the PC)
//                i_data <- the instruction word at that address (same cycle)
//
//   Data port    d_valid -> there is a load or store this cycle
//   (the bus)    d_addr  -> byte address (the ALU result)
//                d_wstrb -> byte lanes to write; 4'b0000 means this is a load
//                d_wdata -> store data, already placed in the right lane(s)
//                d_rdata <- the aligned 32-bit word read from d_addr
//                d_ready <- the target has completed the request this cycle
//
// d_valid is high only for real loads and stores: targets must ignore the bus
// otherwise, because a device read can have side effects.
//
// Waiting: a load or store completes in the cycle where d_valid and d_ready are
// both 1. Until then the instruction STALLS: the PC holds and the register file
// is not written, so the same instruction stays in place and keeps presenting
// the same request on the bus, which is exactly what the handshake requires.
//
// tb/soc_tb.v reaches into the register file, so it must stay named u_rf.

`timescale 1ns/1ps
`include "rv32i_defs.vh"
`include "alu_ops.vh"
`include "ctrl_defs.vh"


module cpu (
    input  wire        clk,
    input  wire        rst,

    // fetch port
    output wire [31:0] i_addr,
    input  wire [31:0] i_data,

    // data port (to the bus)
    output wire        d_valid,
    output wire [31:0] d_addr,
    output wire [3:0]  d_wstrb,
    output wire [31:0] d_wdata,
    input  wire [31:0] d_rdata,
    input  wire        d_ready
);
    reg [31:0] PC;
    wire [31:0] next_pc;

    // A memory access whose target has not answered yet: hold everything.
    wire stall = d_valid && !d_ready;

    // PC register management
    always @(posedge clk) begin
        if (rst) begin
            PC <= 32'd0;
        end else if (!stall) begin
            PC <= next_pc;
        end
    end

    wire [1:0] alu_a_src, result_src, mem_size;
    wire [31:0] a, b, y, instr;
    wire [31:0] imm;
    wire [6:0] opcode, funct7;
    wire [2:0] funct3;
    wire [4:0] rd, rs1, rs2;
    wire [3:0] alu_op;
    wire [31:0] rd1, rd2, wd, load_data;
    wire [2:0] fmt;
    wire reg_write, jalr, branch, load_unsigned, mem_read, mem_write, illegal, zero, alu_b_src, jump, we;
    wire taken, lt, ltu, eq;


    alu u_alu(
        .a      (a      ),
        .b      (b      ),
        .alu_op (alu_op ),
        .y      (y      ),
        .zero   (zero   )
    );

    control u_control(
        .opcode        (opcode        ),
        .funct3        (funct3        ),
        .funct7        (funct7        ),
        .reg_write     (reg_write     ),
        .alu_a_src     (alu_a_src     ),
        .alu_b_src     (alu_b_src     ),
        .alu_op        (alu_op        ),
        .result_src    (result_src    ),
        .mem_read      (mem_read      ),
        .mem_write     (mem_write     ),
        .mem_size      (mem_size      ),
        .load_unsigned (load_unsigned ),
        .branch        (branch        ),
        .jump          (jump          ),
        .jalr          (jalr          ),
        .illegal       (illegal       )
    );

    decoder u_decoder(
       .instr  (instr),
       .opcode (opcode ),
       .rd     (rd     ),
       .funct3 (funct3 ),
       .rs1    (rs1    ),
       .rs2    (rs2    ),
       .funct7 (funct7 ),
       .imm    (imm    ),
       .fmt    (fmt    )
   );

   // fetch: the PC goes out, the instruction comes back in the same cycle
   assign i_addr = PC;
   assign instr  = i_data;

   regfile u_rf(
       .clk (clk ),
       .we  (we  ),
       .rs1 (rs1 ),
       .rs2 (rs2 ),
       .rd  (rd  ),
       .wd  (wd  ),
       .rd1 (rd1 ),
       .rd2 (rd2 )
   );

   assign a = (alu_a_src == `A_RS1) ? rd1 : (alu_a_src == `A_PC) ? PC : 32'd0;
   assign b = (alu_b_src == `B_RS2) ? rd2 : imm; 
   assign wd = (result_src == `RES_ALU) ? y : (result_src == `RES_MEM) ? load_data : PC + 32'd4;    

   // comparator logic
   assign ltu = (rd1 < rd2);
   assign lt = ($signed(rd1) < $signed(rd2));
   assign eq = (rd1 == rd2);
   assign taken = (funct3[2] ? (funct3[1] ? ltu : lt) : eq) ^ funct3[0];

   // next_pc logic
   wire [1:0] idx_B;
   wire idx_H;
   assign next_pc = (jalr) ? ((rd1 + imm) & ~32'd1) : (jump || (branch && taken)) ? y : PC + 32'd4;    
   assign idx_B = y[1:0];
   assign idx_H = y[1];
   wire [7:0]  ld_byte = d_rdata[idx_B*8  +: 8];
   wire [15:0] ld_half = d_rdata[idx_H*16 +: 16];

   assign load_data = (mem_size == `SZ_B) ? ((load_unsigned) ? {24'd0, ld_byte} : {{24{ld_byte[7]}}, ld_byte}) :
                      (mem_size == `SZ_H) ? ((load_unsigned) ? {16'd0, ld_half} : {{16{ld_half[15]}}, ld_half}) :
                      d_rdata;

   assign d_wstrb = (mem_write && !rst) ? ((mem_size == `SZ_B) ? (4'b0001 << y[1:0]) : (mem_size == `SZ_H) ? (4'b0011 << y[1:0]) : 4'b1111) : 4'b0000;
   assign d_addr  = y;
   // no register write while stalled: a load's data is not there yet
   assign we = reg_write && !illegal && !rst && !stall;
   // Store data: replicate the byte/half into every lane, so whichever lane
   // d_wstrb selects already holds the right data (sb to 0x...1 writes lane 1,
   // which must contain rd2[7:0], not rd2[15:8]).
   assign d_wdata = (mem_size == `SZ_B) ? {4{rd2[7:0]}}  :
                    (mem_size == `SZ_H) ? {2{rd2[15:0]}} :
                                          rd2;
   // a request only for real loads and stores
   assign d_valid = (mem_read || mem_write) && !rst;

endmodule
