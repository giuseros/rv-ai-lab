# RVI32 — a single-cycle RV32I CPU in Verilog

Relearning Verilog by building a RISC-V core, **simulation-first**. No board flashing
until the design is fully verified in sim.

## Workflow
- **You** write the RTL in `rtl/`.
- **Claude** writes the testbenches in `tb/` and the sim flow.
- We read the waveforms together to confirm each module works.

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
- **Phase 0** — toolchain
- **Phase 1** — single-cycle RV32I, module by module:
  1. [ ] regfile   ← current
  2. [ ] alu
  3. [ ] decoder
  4. [ ] memory (loads a .hex program)
  5. [ ] datapath + control
  6. [ ] top-level testbench
- **Phase 2** — run a GCC program (crt0 + linker script + memory-mapped putchar/exit)
```
