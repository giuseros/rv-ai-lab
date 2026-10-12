# RVI32 — a RISC-V core in Verilog

Learning RTL by building an RV32I core, **simulation-first**, and then using it to explore
microarchitecture: pipelining, caches, branch prediction, custom accelerators. No board
flashing until a design is fully verified in sim.

## Workflow
Each module `<mod>` has `rtl/<mod>.v` + `tb/<mod>_tb.v`.

```sh
make sim  MOD=regfile     # compile + run self-checking testbench
make wave MOD=regfile     # same, then open build/regfile.vcd in gtkwave
make clean
```

## Toolchain
```sh
sudo apt install -y iverilog gtkwave gcc-riscv64-unknown-elf
```

## Roadmap
- [x] **Phase 0** — toolchain
- [x] **Phase 1** — single-cycle RV32I: regfile, alu, decoder, memory, control, cpu
- [ ] **Phase 2** — run a GCC-compiled C program (crt0, linker script, putchar/exit)
- [ ] **Then** — performance counters, a pipelined core, caches over a slower memory,
  the M extension, a matmul accelerator, FPGA
