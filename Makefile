# RVI32 — simulation flow (Icarus Verilog + GTKWave)
#
# Usage:
#   make sim  MOD=regfile     # compile rtl/<MOD>.v + tb/<MOD>_tb.v, run, self-check
#   make wave MOD=regfile     # same, then open the waveform in gtkwave
#   make clean
#
# Convention: each module <MOD> has rtl/<MOD>.v and a testbench tb/<MOD>_tb.v
# whose top module is <MOD>_tb and which dumps build/<MOD>.vcd.

MOD   ?= regfile
BUILD := build
# -g2005 = strict Verilog-2005. SystemVerilog constructs are rejected on
# purpose: this project is for learning Verilog.
IVFLAGS := -g2005 -Wall -I rtl

# cpu.v instantiates every other module, so it needs the whole rtl/ tree.
ifeq ($(MOD),cpu)
SRCS := $(wildcard rtl/*.v) tb/$(MOD)_tb.v
else
SRCS := rtl/$(MOD).v tb/$(MOD)_tb.v
endif

# Test programs: .S -> .hex (one 32-bit little-endian word per line, for
# $readmemh). This is the Phase 2 GCC flow in miniature.
RISCV   := riscv64-unknown-elf
ASFLAGS := -march=rv32i -mabi=ilp32

$(BUILD)/%.hex: tb/%.S | $(BUILD)
	$(RISCV)-as $(ASFLAGS) -o $(BUILD)/$*.o $<
	$(RISCV)-ld -m elf32lriscv -Ttext=0 -o $(BUILD)/$*.elf $(BUILD)/$*.o
	$(RISCV)-objcopy -O binary $(BUILD)/$*.elf $(BUILD)/$*.bin
	od -An -tx4 -v -w4 $(BUILD)/$*.bin | awk '{print $$1}' > $@

# Disassemble a test program, to read alongside the waveform.
dis: $(BUILD)/$(PROG).hex
	@$(RISCV)-objdump -d -M no-aliases,numeric $(BUILD)/$(PROG).elf | sed -n '/>:/,$$p'
.PHONY: dis

.PHONY: sim wave clean
sim: $(BUILD)/$(MOD).vvp
	@vvp $<

wave: sim
	@gtkwave $(BUILD)/$(MOD).vcd $(wildcard tb/$(MOD).gtkw) >/dev/null 2>&1 &

$(BUILD)/$(MOD).vvp: $(SRCS) | $(BUILD)
	iverilog $(IVFLAGS) -o $@ $(SRCS)

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)/*.vvp $(BUILD)/*.vcd
	@echo "cleaned"
