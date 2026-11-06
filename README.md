# rv-ai-lab

A RISC-V (RV32I) core and a small SoC in Verilog, built **simulation-first** as a
lab for exploring microarchitecture: pipelining, caches, branch prediction, and
eventually custom accelerators. Built by a human and an AI, together.

## How this is built

This is a pair project between Giuseppe Rossini and Claude, Anthropic's AI
assistant, working in Claude Code.

- The single-cycle core (`regfile`, `alu`, `decoder`, `memory`, `control`, `cpu`)
  was written by hand, to learn Verilog properly.
- From the SoC onward, Claude implements and Giuseppe reviews, steering the design
  and asking questions until each piece is understood.
- Testbenches, test programs and tooling are Claude's. Commits it co-authored say so.
- [`CLAUDE.md`](CLAUDE.md) holds the conventions the AI works from: dialect,
  testbench rules, design decisions.

## What is here

- A **single-cycle RV32I core**: one instruction per clock, strict Verilog-2005.
- A **SoC** around it: a valid/ready **bus**, 16 KiB of RAM, and a memory-mapped
  **console** and exit register, so programs can print and finish.
- A self-checking testbench for every module. Every test program runs at memory
  latencies 0, 1 and 3 and must produce identical results; key testbenches are
  checked with mutation testing (deliberately broken RTL must make them fail).

## Quick start

```sh
sudo apt install -y iverilog gtkwave gcc-riscv64-unknown-elf

make run PROG=hello            # compile and run sw/hello.c
make run PROG=count            # run sw/count.S: output, exit code, cycles, CPI
make run PROG=count TRACE=1    # ...plus every instruction it executed
make run PROG=count LAT=3      # ...with memory answering 3 cycles late
make sim MOD=soc               # the system regression (also: regfile alu decoder
                               #   memory control bus)
make wave MOD=soc              # open the waveform in gtkwave
```

To write your own program, copy [`sw/hello.c`](sw/hello.c) (C, using
[`sw/rt/soc.h`](sw/rt/soc.h): `puts`, `print_dec`, `exit`) or
[`sw/count.S`](sw/count.S) (assembly: a store of a byte to `0x1000_0000` prints it,
a store of a word to `0x1000_0004` exits with that code). There is no C library:
RV32I has no multiply or divide instruction, so GCC calls libgcc for those.

## Layout

```
rtl/   the hardware: cpu.v (core), soc.v (system), bus.v, console.v, memory.v, ...
tb/    testbenches, regression programs (p_*.S), run_tb.v, retire-log tooling
sw/    programs to run with `make run`
```

## Memory map

| address | |
|---|---|
| `0x0000_0000` – `0x0000_3FFF` | RAM, 16 KiB (code and data share it) |
| `0x1000_0000` | console: store a byte to print it |
| `0x1000_0004` | exit: store a word to end the program with that code |

## Roadmap

- [x] Single-cycle RV32I core
- [x] SoC: bus with valid/ready handshake, console, runner, slow-memory testing
- [x] Run C programs compiled with GCC (`crt0`, linker script, a small runtime)
- [ ] CSRs and exceptions (trap on illegal instructions), performance counters
- [ ] A pipelined core, compared against the single-cycle one
- [ ] Caches in front of a slower memory
- [ ] The M extension; a matmul accelerator
- [ ] FPGA

## License

MIT, see [LICENSE](LICENSE).
