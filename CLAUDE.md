# RVI32 — project context for Claude

A RISC-V (RV32I) core in Verilog, used as a platform for learning RTL properly and for
exploring microarchitecture. It started as a single-cycle core; the plan is to keep
going — pipelining, caches, branch prediction, and eventually custom units such as a
matmul accelerator — and compare designs against each other.

**Claude writes the RTL and the tests; the owner reviews to understand it.** (Phase 1's
RTL was written by hand to learn Verilog; from Phase 2 on Claude implements.) Work in
small, reviewable steps and explain each one: what every new signal is for, why the
design is shaped that way, and what the test proves.
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
tb/<mod>_tb.v    self-checking testbench      tb/p_*.S   test programs for the soc
build/           all generated artifacts (gitignored)
```
```sh
make sim  MOD=<mod>        # compile rtl/<mod>.v + tb/<mod>_tb.v, run, self-check
make wave MOD=<mod>        # same, then open build/<mod>.vcd in gtkwave
make build/<prog>.hex      # assemble tb/<prog>.S into a $readmemh image
make dis   PROG=<prog>     # disassemble a test program
make trace PROG=<prog>     # retire log: one line per executed instruction + its effect
make clean
```
`MOD=soc` compiles all of `rtl/*.v`. The `.S -> .hex` rule is `as -march=rv32i
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
  have passed for the wrong reason four times:
  - `control_tb` replays all vectors after 8 "poison" instructions, so a latched output
    can't hide behind a lucky predecessor (384 checks).
  - `p_mem` uses words where the selected byte's sign bit differs from byte 0's;
    `0xAABBCCDD` (every byte negative) once hid a wrong-lane sign-extension bug.
  - `p_mem` stores non-zero bytes/halves to non-zero lanes; storing only `x0` (zero in
    every lane) hid that store data was never moved into the strobed lane.
- Verify every new testbench against a reference implementation before handing it over.
- The **retire log** (`retire_log` in `tb/soc_tb.v`, formatted by `tb/annotate.py`) is the
  reference for future microarchitectures: a pipelined core must retire exactly the same
  lines. It taps the CPU's ports (so stores to any target appear) and the `u_rf` write
  port; a pipelined core must export its own retire signals.
- Stimulus changes on the opposite clock edge from the one the DUT samples (e.g. reset
  is released on a negedge).
- `soc_tb` instantiates four SoCs, one per `tb/p_*.S`, and checks state through
  hierarchical references, so instance names are a contract: **`soc.v` names `u_cpu`
  and `u_mem`; `cpu.v` names `u_rf`**. Never check `u_rf.regs[0]`: x0 is a read-mux
  constant, the array slot is X.

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
- **Phase 2 — in progress (design agreed, not started).** Run C on a small SoC:
  - Memory moves out of `cpu.v`. New `soc.v` wires `cpu` + `bus` + RAM. Instruction
    fetch stays a direct port to RAM; only the data side goes through the bus.
  - Bus interface (PicoRV32 native-interface style): `d_valid`, `d_addr`, `d_wstrb`
    (`0000` = load), `d_wdata` from the CPU; `d_rdata`, `d_ready` back. A transfer
    happens in a cycle where valid and ready are both 1; while valid && !ready the CPU
    holds the request (and its PC) unchanged. `d_valid` = load or store only, because
    device reads can have side effects and slow targets/caches must not see fake reads.
  - `d_ready` is in from day one: the single-cycle CPU stalls (holds PC, suppresses the
    register write) until ready. A slow-RAM test must exercise that path.
  - Memory map, decoded on `addr[31:28]`: `0` -> RAM (`0x0000_0000`-`0x0000_3FFF`,
    partial decode aliases), `1` -> I/O: `0x1000_0000` console (store a byte = print),
    `0x1000_0004` exit (store a word = end sim with that code). Unmapped: stores
    dropped, loads return 0 (no traps yet).
  - The console/exit device lives in the testbench (`$write`/`$finish` are sim-only);
    `soc` exposes the I/O port. RTL stays synthesizable.
  - Then `crt0.S`, a linker script, `volatile` MMIO from C, and a hello-world.
  - The existing `p_*.S` programs and retire log must keep passing on the SoC.
- **Then, open-ended:** performance counters (cycles, instret) to measure everything
  after; a pipelined core (hazards, forwarding, branch prediction); a memory with latency
  and caches in front of it; the M extension; a matmul accelerator; eventually an FPGA.
