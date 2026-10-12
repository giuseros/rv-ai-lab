# RVI32 — project context for Claude

A RISC-V (RV32I) core in Verilog, used as a platform for learning RTL properly and for
exploring microarchitecture. It started as a single-cycle core; the plan is to keep
going — pipelining, caches, branch prediction, and eventually custom units such as a
matmul accelerator — and compare designs against each other.

The owner writes the RTL to learn it, and may ask for help with mechanical parts.
Everything is **simulation-first**: no FPGA work until a design is verified in sim.

## Objectives
- Learn Verilog and HDL verification discipline the proper way.
- Run **GCC-compiled C programs** on the core.
- Use the core to explore design directions and measure them (cycles, CPI, hit rates).

Implications for how things are built now:
- **Keep tests architectural.** Check end state and program output, never internal
  timing, so the same tests verify a single-cycle, pipelined or cached core. The C
  programs from Phase 2 become the regression suite every future design must pass.
- **Keep module interfaces honest.** Today's memory answers instantly (async read); a
  cache only matters once memory has latency, so a ready/valid style interface will be
  needed before caches. Don't let the CPU assume zero-latency memory more than it has to.
- **Accelerators** can use RISC-V's reserved *custom-0* opcode (`0001011`), which the
  control unit currently treats as illegal, or sit behind memory-mapped registers.

## Toolchain (Ubuntu 24.04)
```sh
sudo apt install -y iverilog gtkwave gcc-riscv64-unknown-elf universal-ctags
```

## Layout and commands
```
rtl/<mod>.v      RTL                          rtl/*.vh   shared `define headers
tb/<mod>_tb.v    self-checking testbench      tb/p_*.S   test programs for the cpu
build/           all generated artifacts (gitignored)
```
```sh
make sim  MOD=<mod>        # compile rtl/<mod>.v + tb/<mod>_tb.v, run, self-check
make wave MOD=<mod>        # same, then open build/<mod>.vcd in gtkwave
make build/<prog>.hex      # assemble tb/<prog>.S into a $readmemh image
make dis  PROG=<prog>      # disassemble a test program
make clean
```
`MOD=cpu` compiles all of `rtl/*.v`. The `.S -> .hex` rule is `as -march=rv32i
-mabi=ilp32` -> `ld -m elf32lriscv -Ttext=0` -> `objcopy -O binary` -> `od -An -tx4 -v -w4`
(one little-endian 32-bit word per line).

## Conventions
- **Strict Verilog-2005** (`-g2005`). No SystemVerilog, including packages — SV is
  rejected by the compiler on purpose. Shared constants are `` `define `` headers in
  `rtl/*.vh` with include guards, pulled in via `-I rtl`.
- **`make sim` is the source of truth.** Editor linting is off: single-file linters can't
  see includes, submodules, or the Makefile's flags, so they report false errors.
- `<=` in clocked blocks, `=` in `always @*`. Combinational blocks assign defaults first.
- Every `.v` file declares its own `` `timescale 1ns/1ps ``.

## Testbench conventions
- **Design test data so a wrong implementation gives a different answer.** Tests here
  have passed for the wrong reason three times:
  - `control_tb` replays all vectors after 8 "poison" instructions, so a latched output
    can't hide behind a lucky predecessor (384 checks).
  - `p_mem` uses words where the selected byte's sign bit differs from byte 0's;
    `0xAABBCCDD` (every byte negative) once hid a wrong-lane sign-extension bug.
- Verify every new testbench against a reference implementation before handing it over.
- Stimulus changes on the opposite clock edge from the one the DUT samples (e.g. reset
  is released on a negedge).
- `cpu_tb` instantiates four cores, one per `tb/p_*.S`, and checks state through
  hierarchical references, so **`cpu.v` must name its instances `u_rf` and `u_mem`**.
  Never check `u_rf.regs[0]`: x0 is a read-mux constant, the array slot is X.

## Design decisions worth knowing
- **Memory** is one unified array (GCC emits one address space) with two async read
  ports and one sync write port with byte strobes (`wstrb`, no separate write enable).
  Byte addresses; `addr[1:0]` ignored by memory. Sub-word load extraction and store
  alignment live in `cpu.v`, keeping memory ISA-agnostic.
- **The ALU computes every address** (branch/jump targets, load/store addresses,
  lui/auipc), so `alu_a_src`/`alu_b_src`/`alu_op` are defined for every instruction.
  Branch comparison is a separate comparator in `cpu.v` driven by funct3.
- Illegal instructions (unknown opcode or unallocated funct3) force `reg_write` and
  `mem_write` to 0. Writes are also gated off during reset.

## Status and roadmap
- **Phase 1 — done.** Single-cycle core: regfile, alu, decoder, memory, control, cpu.
- **Phase 2 — next.** Run C: `crt0.S`, a linker script for the memory map, and
  memory-mapped putchar/exit (the `tohost` pattern) so a program can print and halt.
- **Then, open-ended:** performance counters (cycles, instret) to measure everything
  after; a pipelined core (hazards, forwarding, branch prediction); a memory with latency
  and caches in front of it; the M extension; a matmul accelerator; eventually an FPGA.
