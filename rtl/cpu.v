// cpu.v — single-cycle RV32I core
//
// >>> YOUR JOB: implement the body. Everything it needs already exists and is
//     verified: regfile, alu, decoder, control, memory. This module is the
//     wiring plus six small pieces of new logic.
//
// ===========================================================================
// REQUIRED INSTANCE NAMES
// ===========================================================================
// tb/cpu_tb.v inspects architectural state through hierarchical references,
// so two instance names are part of the contract:
//
//     regfile ... u_rf     -> testbench reads u_rf.regs[n]
//     memory  ... u_mem    -> testbench reads u_mem.mem[n]
//
// Name the other three whatever you like. Pass WORDS and HEXFILE straight
// through to u_mem.
//
// ===========================================================================
// WHAT YOU HAVE TO BUILD
// ===========================================================================
//
// 1. THE PC. The only new state in the whole core. On posedge clk: if rst,
//    PC <= 32'd0, else PC <= next_pc. Synchronous reset, active high.
//    Non-blocking assignment. This is the one clocked block in this module
//    (the regfile and memory have their own).
//
// 2. ALU OPERAND MUXES, driven by control.
//       alu_a = `A_RS1 -> rd1,  `A_PC -> pc,   `A_ZERO -> 32'd0
//       alu_b = `B_RS2 -> rd2,  `B_IMM -> imm
//
// 3. BRANCH COMPARATOR. The ALU is busy computing the target, so comparison
//    is separate. Compute three facts from rd1/rd2 -- equal, signed less-than,
//    unsigned less-than -- then select with funct3 and invert with funct3[0]:
//       funct3[2] ? (funct3[1] ? ltu : lt) : eq,  then XOR funct3[0]
//    Remember $signed() for the signed compare; rd1/rd2 are unsigned wires.
//
// 4. NEXT-PC MUX.
//       jalr                  -> (rd1 + imm) & ~32'd1   <- note the masked LSB
//       jump, or branch&taken -> alu_y                   (the ALU computed it)
//       otherwise             -> pc + 4
//    jalr is the only target the ALU result cannot be used for directly,
//    because the spec requires clearing bit 0.
//
// 5. LOAD EXTRACT. u_mem returns the whole aligned 32-bit word. Select the
//    byte or halfword named by alu_y[1:0], then sign- or zero-extend
//    according to mem_size and load_unsigned. `SZ_W passes the word through.
//       lb  at 0x...2 -> drdata[23:16], sign-extended
//       lhu at 0x...2 -> drdata[31:16], zero-extended
//
// 6. STORE ALIGN + WSTRB. The reverse of 5, and it is two jobs:
//    (a) replicate the data into the right lane(s) of dwdata, and
//    (b) build wstrb from mem_size and alu_y[1:0]:
//          `SZ_B -> 4'b0001 << alu_y[1:0]
//          `SZ_H -> 4'b0011 << alu_y[1:0]      (alu_y[1] picks the half)
//          `SZ_W -> 4'b1111
//    wstrb must be 4'b0000 whenever mem_write is 0 -- a load must not write.
//
// 7. WRITEBACK MUX, driven by result_src: `RES_ALU -> alu_y,
//    `RES_MEM -> the extracted load data, `RES_PC4 -> pc + 4.
//    Gate the regfile write enable with reg_write AND NOT illegal.
//
// ===========================================================================
// TRAPS
// ===========================================================================
//   - The instruction fetch address is pc, the data address is alu_y. Two
//     different ports on u_mem; do not cross them.
//   - `illegal` must suppress BOTH reg_write and mem_write.
//   - rst must also hold wstrb at 0, or cycle 0 writes garbage to memory.
//   - Every mux is combinational: `always @*` with defaults, or assigns with
//     ternaries. Same latch rules as control.v.
//   - The regfile write and the memory write both land on the same posedge
//     that advances the PC. That is what "single cycle" means.

`timescale 1ns/1ps
`include "rv32i_defs.vh"
`include "alu_ops.vh"
`include "ctrl_defs.vh"


module cpu #(
    parameter WORDS   = 4096,
    parameter HEXFILE = ""
) (
    input wire clk,
    input wire rst
);
    reg [31:0] PC;
    wire [31:0] next_pc;

    // PC register management
    always @(posedge clk) begin
        if (rst) begin
            PC = 32'd0;
        end else begin
            PC = next_pc;
        end
    end

    wire [1:0] alu_a_src, result_src, mem_size;
    wire [31:0] a, b, y, instr;
    wire [31:0] imm;
    wire [6:0] opcode, funct7;
    wire [2:0] funct3;
    wire [4:0] rd, rs1, rs2;
    wire [3:0] wstrb, alu_op;
    wire [31:0] rd1, rd2, wd, daddr, drdata, dwdata, load_data;
    wire [2:0] fmt;
    wire reg_write, jalr, branch, load_unsigned, mem_write, illegal, zero, alu_b_src, jump, we;
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

   memory #(.WORDS(WORDS), .HEXFILE(HEXFILE)) u_mem(
       .clk    (clk    ),
       .iaddr  (PC),
       .idata  (instr),
       .daddr  (daddr  ),
       .drdata (drdata ),
       .dwdata (dwdata ),
       .wstrb  (wstrb  )
   );

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
   wire [7:0]  ld_byte = drdata[idx_B*8  +: 8];
   wire [15:0] ld_half = drdata[idx_H*16 +: 16];

   assign load_data = (mem_size == `SZ_B) ? ((load_unsigned) ? {24'd0, ld_byte} : {{24{ld_byte[7]}}, ld_byte}) :
                      (mem_size == `SZ_H) ? ((load_unsigned) ? {16'd0, ld_half} : {{16{ld_half[15]}}, ld_half}) :
                      drdata;

   assign wstrb = (mem_write) ? ((mem_size == `SZ_B) ? (4'b0001 << y[1:0]) : (mem_size == `SZ_H) ? (4'b0011 << y[1:0]) : 4'b1111) : 4'b0000;
   assign daddr = y;
   assign we = reg_write && !illegal;
   assign dwdata = rd2;

endmodule
