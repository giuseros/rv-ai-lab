# rv-ai-lab — project context for Claude

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
tb/<mod>_tb.v    self-checking testbench      tb/p_*.S   regression programs (soc_tb)
tb/tb_lib.v      console_sink, retire_log     tb/c_*.c   C regression programs (soc_tb)
tb/run_tb.v      runs any one program         sw/        programs to run (make run)
sw/rt/           C runtime: crt0.S, link.ld, soc.h, runtime.c
build/           generated artifacts (gitignored)
```
```sh
make sim  MOD=<mod>        # compile rtl/<mod>.v + tb/<mod>_tb.v, run, self-check
make wave MOD=<mod>        # same, then open build/<mod>.vcd in gtkwave
make run   PROG=<prog>     # run sw/<prog>.c|.S (or tb/): console output, exit code, CPI
                           #   LAT=1|3 for slow memory, TRACE=1 for the retire log
make build/<prog>.hex      # assemble sw/ or tb/<prog>.S into a $readmemh image
make dis   PROG=<prog>     # disassemble a test program
make trace PROG=<prog>     # retire log: one line per executed instruction + its effect
                           #   ends with instructions, cycles and CPI; LAT=1|3 for slow RAM
make clean
```
`MOD=soc` compiles all of `rtl/*.v`. The `.S -> .hex` rule is `as -march=rv32i
-mabi=ilp32` -> `ld -m elf32lriscv -Ttext=0` -> `objcopy -O binary` -> `od -An -tx4 -v -w4`
(one little-endian 32-bit word per line). C: `gcc -march=rv32i -mabi=ilp32 -O2
-ffreestanding -nostdlib -nostartfiles -T sw/rt/link.ld crt0.S runtime.c prog.c -lgcc`
(libgcc supplies mul/div; there is no libc, `soc.h` is the whole library).

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
- C programs run with RAM outside the image filled with `0xDEADBEEF` (`RAM_FILL`, and
  `run_tb`'s default): real RAM powers up with garbage, and with zero-filled RAM a
  crt0 that never cleared `.bss` passed every test.
- Verify every new testbench before relying on it: against a reference implementation,
  or by **mutation testing** — break the RTL in realistic ways and confirm each mutant
  fails (done for `bus_tb` and the stall logic). A surviving mutant is either a test gap
  or *equivalent* (no test could ever see it): e.g. writing RAM on every waiting cycle is
  equivalent for RAM, but not for the console, so the console test must cover it.
  Survivors also expose **dead code** (the console's redundant lane-0 check, removed) and
  **masking**: a bus that leaks console stores into RAM is invisible at SoC level because
  `ram_delay` only writes on its own completed requests. Only `bus_tb` catches it, which
  is why unit tests stay even when system tests exist.
- The **retire log** (`retire_log` in `tb/tb_lib.v`, formatted by `tb/annotate.py`) is the
  reference for future microarchitectures: a pipelined core must retire exactly the same
  lines. It taps the CPU's ports (so stores to any target appear) and the `u_rf` write
  port; a pipelined core must export its own retire signals.
- Stimulus changes on the opposite clock edge from the one the DUT samples (e.g. reset
  is released on a negedge).
- `soc_tb` runs every `tb/p_*.S` at memory latency 0, 1 and 3 (15 SoCs; per-program
  checks are `` `define `` macros taking the instance name), runs until every SoC reaches
  its final `jal x0, 0` (timeout otherwise), and checks state through
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
- **Phase 2 — in progress.** Done: step 1 (memory out of the cpu, `soc.v`), step 2
  (`bus.v`, `soc_map.vh`, `bus_tb`), step 3 (`d_ready` stall + `ram_delay`), step 4
  (`console.v`, `p_hello.S` prints "hello"), step 5 (C: `sw/rt/`; `tb/c_basics.c`
  self-checks mul/div via libgcc, 64-bit, recursion, .data/.bss, jump tables, function
  pointers, and exits with its failure count). **Phase 2 is complete.** It built:
  Run C on a small SoC:
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
  - The console is RTL (`console.v`): it decodes its two addresses and emits one-cycle
    char/exit *events* on completed stores; `soc` exposes the events and the testbench's
    `console_sink` prints/records them. This is the template for future MMIO devices.
  - Then `crt0.S`, a linker script, `volatile` MMIO from C, and a hello-world.
  - The existing `p_*.S` programs and retire log must keep passing on the SoC.
- **Then, open-ended:** CSRs and exceptions (today an illegal instruction, misaligned
  access or null-pointer write fails silently), which also gives performance counters
  (`rdcycle`/`rdinstret`) to measure everything after; a pipelined core (hazards,
  forwarding, branch prediction); caches in front of a slower memory; the M extension;
  a matmul accelerator; eventually an FPGA.
