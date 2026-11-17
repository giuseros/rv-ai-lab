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
FPGA: Quartus Prime Lite 25.1std (MAX 10 + Cyclone V only, no Questa) in
`~/altera_lite/25.1std`; the Makefile's `QUARTUS` points at its `quartus/bin`, so it
needn't be on `PATH`. USB-Blaster access needs a udev rule (vendor `09fb`, mode 0666).
**Vendor tools are used from the command line only, never their IDEs** (no GUI project
settings, no Platform Designer): projects are generated from the Tcl files in `boards/`.

## Layout and commands
```
rtl/<mod>.v      RTL                          rtl/*.vh   shared `define headers
tb/<mod>_tb.v    self-checking testbench      tb/p_*.S   regression programs (soc_tb)
tb/tb_lib.v      console_sink, retire_log,    tb/c_*.c   C regression programs (soc_tb)
                 uart_monitor (PC end of a serial line)
tb/run_tb.v      runs any one program         sw/        programs to run (make run)
sw/rt/           C runtime: crt0.S, link.ld, soc.h, runtime.c
boards/<board>/  one folder per FPGA board: <top>_top.v + <top>_top_tb.v (blinky = smoke
                 test, written first for every board), other board modules (any non-top
                 .v, e.g. max10_pll.v: built and simulated with every top), pins.tcl,
                 timing.sdc, build.tcl, reference/README.md (where to get the vendor
                 manuals; PDFs gitignored)
build/           generated artifacts (gitignored); Quartus runs in build/<board>/<top>/
                 (build/<board>/soc-<prog>/ for the SoC top: one per program)
```
```sh
make sim  MOD=<mod>        # compile rtl/<mod>.v + tb/tb_lib.v + tb/<mod>_tb.v, run, check
                           #   (plus the submodules listed in the Makefile's DEPS_<mod>)
make wave MOD=<mod>        # same, then open build/<mod>.vcd in gtkwave
make run   PROG=<prog>     # run sw/<prog>.c|.S (or tb/): console output, exit code, CPI
                           #   LAT=1|3 for slow memory, SYNC=1 for the clocked RAM (as on
                           #   an FPGA), TRACE=1 for the retire log
make build/<prog>.hex      # assemble sw/ or tb/<prog>.S into a $readmemh image
make dis   PROG=<prog>     # disassemble a test program
make trace PROG=<prog>     # retire log: one line per executed instruction + its effect
                           #   ends with instructions, cycles and CPI; LAT=1|3 for slow RAM,
                           #   LAT=sync for the clocked RAM
make fpga-sim BOARD=<b> TOP=<t>   # simulate boards/<b>/<t>_top.v with its testbench
make fpga     BOARD=<b> TOP=<t>   # Quartus: synthesise, fit, assemble, time; report LEs/Fmax
make program  BOARD=<b> TOP=<t>   # load the .sof over JTAG (volatile: gone at power-off)
                                  #   TOP=soc takes PROG=<prog> (default primes): the program
                                  #   is the RAM's initial contents, so a new one = a new build
make clean
```
`MOD=soc` compiles all of `rtl/*.v`. The `.S -> .hex` rule is `as -march=rv32i
-mabi=ilp32` -> `ld -m elf32lriscv -Ttext=0` -> `objcopy -O binary` -> `od -An -tx4 -v -w4`
(one little-endian 32-bit word per line), plus `<prog>.hex.b0`..`.b3` (byte i of each
word, one per line) for `ram_sync`'s byte lanes. C: `gcc -march=rv32i -mabi=ilp32 -O2
-ffreestanding -nostdlib -nostartfiles -T sw/rt/link.ld crt0.S runtime.c prog.c -lgcc`
(libgcc supplies mul/div; there is no libc, `soc.h` is the whole library: `printf` and
`snprintf` (`%d %i %u %x %X %c %s %p %%`, `-`/`0` flags, width, `ll`; no `%f`, no
precision), `puts` (which, unlike the standard one, adds NO newline), `print_dec`,
`print_hex`, `exit`, `mem*`, `strlen`). `-Wshadow` is on. On this toolchain `int32_t` is
`long`, so `printf("%d", an_int32)` warns: cast to `(int)` or use `%ld`.

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
- `soc_tb` runs every `tb/p_*.S` and `tb/c_*.c` at memory latency 0, 1 and 3 and on the
  clocked RAM (24 SoCs; per-program checks are `` `define `` macros taking the instance
  name), runs until every SoC reaches its final `jal x0, 0` (timeout otherwise), and
  checks state through hierarchical references, so instance names are a contract:
  **`soc.v` names `u_cpu` and `g_mem.u_mem`, and `g_mem.word(n)` reads RAM word n
  whichever RAM it is; `cpu.v` names `u_rf`**. Never check `u_rf.regs[0]`: x0 is a
  read-mux constant, the array slot is X. The retire log must be identical on every RAM
  (`make trace PROG=c_basics` vs `LAT=sync`); only the cycle count may differ.

## Design decisions worth knowing
- **Memory** is one unified array (GCC emits one address space) with two async read
  ports and one sync write port with byte strobes (`wstrb`, no separate write enable).
  Byte addresses; `addr[1:0]` ignored by memory. Sub-word load extraction and store
  alignment live in `cpu.v`, keeping memory ISA-agnostic.
- **Two RAMs, chosen by `soc`'s `SYNC_RAM`.** `memory.v` (async read) is the ideal
  memory, sim only. `ram_sync.v` reads on the clock edge, as FPGA block RAM does: fetch
  samples the CPU's `i_next` (the value the PC takes on this edge: 0 in reset, PC while
  stalled, else next_pc), loads wait one cycle (`ram_delay`'s `MIN_READ`), stores don't.
  It is four byte-wide `ram_lane`s, one write enable each: Quartus (Verilog-2005) builds
  block RAM from a 32-bit array with per-byte writes but then DROPS its initial contents,
  and a fill loop next to per-byte writes is not recognised as RAM at all (it then tries
  131k flip-flops and seems to hang). Lanes also suit RAM without byte enables (DVK600).
  Same edge, same word: reads see the old data (RISC-V needs FENCE.I for that anyway).
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
  pointers, and printf via snprintf, then exits with its failure count). **Phase 2 is
  complete.** It built:
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
- **Phase 3 — FPGA bring-up (in progress).** Target several boards, starting with the
  **Terasic DE10-Lite** (Altera MAX 10 10M50, Quartus Prime Lite, built-in USB-Blaster).
  Later the **DE10-Nano** (Cyclone V SoC; its USB serial port belongs to the ARM side) and
  a **Waveshare DVK600 + Core3S500E** (Spartan-3E XC3S500E: Xilinx ISE 14.7 only, external
  JTAG programmer, RS-232 via an onboard SP3232; its block RAM has no byte write enables, so
  memory must be four 8-bit lanes). Plan:
  - Layout: everything reusable is plain RTL in `rtl/` with unit tests in `tb/` (a UART,
    a clocked RAM, `hex7seg.v` are not "FPGA code"; test: could another board use it
    unchanged?). `boards/<board>/` holds only board-specific things: tops (pins, clock,
    reset, polarity), their testbenches, pins/timing/build scripts. Quartus output never
    lands in the source tree.
  - Bring-up order per board: `blinky_top` first (clock, LEDs, switches, displays, keys),
    then the SoC top. **DE10-Lite blinky: done** (97 LEs, 44 regs, Fmax 212 MHz, verified
    on the board). **DE10-Lite UART TX: done**: `rtl/uart_tx.v` (8N1, valid/ready) and
    `uart_hello_top` (a numbered line per second; 210 LEs, Fmax 131 MHz), verified on the
    board with the PL2303 on JP1 pins 28 (TX -> adapter RXD), 30 (GND), 32 (RX <- adapter
    TXD); RX is only an activity LED until there is a `uart_rx`. **UART on the SoC: done
    in sim**: `console.v` owns a `uart_tx`; a char store prints as an event *and* on
    `soc.serial_tx`, and completes when the transmitter takes the byte (`d_ready` stall
    only if the line is still busy); exit completes only once the line is idle. The baud
    rate is a `soc` parameter, default a sim speed (4 cycles/bit at 10 ns, which makes
    printing C programs' CPI > 1); `console_tb` unit test; `soc_tb` decodes the line.
    **Clocked RAM: done in sim** (`ram_sync`, see Design decisions); every program passes
    on it with an identical retire log. Quartus synthesis of `soc` with `SYNC_RAM=1`:
    3,769 LEs, 1,094 registers (1,024 are the register file), 4 initialised M9K RAMs.
    **DE10-Lite SoC: done, verified on the board** (`soc_top`): `sw/primes.c` prints over
    the UART, byte-identical to simulation, and its exit code shows on HEX5..0 (`01295F`);
    KEY[0] reruns it (RAM is not reloaded: crt0 re-zeroes .bss, initialised globals keep
    their last values). The single-cycle core makes only ~40 MHz (slow corner): its
    critical path is the whole loop in one cycle, RAM out -> regfile read mux -> ALU ->
    console address decode -> `d_ready` -> stall -> PC mux -> `i_next` -> RAM address
    (the combinational ready alone is ~4 ns). So it runs at 25 MHz from a MAX 10 PLL
    (`max10_pll.v`: `altpll` for Quartus, a behavioural model under `` `ifdef __ICARUS__ ``,
    since iverilog can't compile Quartus's `altera_mf.v`); 3,131 LEs, setup slack +7.9 ns.
    **UART RX: done in sim**: `rtl/uart_rx.v` (8N1, one sample mid-bit, start re-checked
    at half a bit; `valid` is a one-cycle pulse, no ready; `armed` = a byte starts only on
    a falling edge after the line was seen high, so a break or a reset released mid-byte
    gives no phantom bytes); `uart_rx_tb` at 115200 and 59172 baud (a rate that doesn't
    divide evenly), senders +-3.5%. Next: `uart_echo_top` (RX on the board, no CPU), then
    RX as a console device + `getchar()`, then a bootloader, so a new program needn't be
    a new 8-minute build.
    Quartus has no Verilog-2005 mode: it parses as `VERILOG_2001`, and
    iverilog `-g2005` stays the strict language check.
  - Memory must read on the clock edge (block RAM): done, `ram_sync` (above).
  - DE10-Lite output: 7-segment + LEDs first; then `printf` through **our own UART**
    (`rtl/uart_tx.v` inside the console: done in sim) to a PL2303 USB-serial board set to 3.3 V
    on the GPIO header (GND, TXD, RXD only; never its VCCIO). The board's only USB port is
    the USB-Blaster (no USB-serial chip), and its JTAG UART would need Platform Designer.
    The same UART serves the DVK600 through its RS-232 port.
  - Simulate every board top before building it. The owner does what needs hands or sudo
    (installs, udev, wiring); Claude writes, simulates, builds, reports resources/timing,
    and programs over JTAG.
  - Board gotchas: a `.sof` is lost at power-off, so reprogram after every replug; if
    `jtagconfig` hangs after a replug, a stale `jtagd` holds the old USB handle (kill it).
    Reading the serial port: `stty ... raw clocal` (without `clocal` a read can wait for
    carrier forever); a shell older than the `dialout` membership needs `sg dialout -c`.
    Programs print bare `\n`: `picocom -b 115200 --imap lfcrlf /dev/ttyUSB0` (`cat` is
    fine as is). Only one reader per tty: two split the bytes between them.
    RAM with initial contents needs `INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"`
    (in `build.tcl`): in the default mode the MAX 10 can't initialise RAM. Check a RAM
    with a synthesis-only run first (minutes) and read the map report's RAM Summary
    (Mode, MIF column) before a full build.
- **Then, open-ended:** CSRs and exceptions (today an illegal instruction, misaligned
  access or null-pointer write fails silently), which also gives performance counters
  (`rdcycle`/`rdinstret`) to measure everything after; a pipelined core (hazards,
  forwarding, branch prediction); caches in front of a slower memory; the M extension;
  a matmul accelerator; eventually an FPGA.
