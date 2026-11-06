# RVI32 — simulation flow (Icarus Verilog + GTKWave)
#
# Usage:
#   make sim   MOD=regfile    # compile rtl/<MOD>.v + tb/<MOD>_tb.v, run, self-check
#   make wave  MOD=regfile    # same, then open the waveform in gtkwave
#   make trace PROG=p_mem     # run the soc, print one line per retired instruction
#   make trace PROG=p_mem LAT=3   # same, on the SoC whose RAM answers 3 cycles late
#   make dis   PROG=p_mem     # disassemble a test program
#   make clean
#
# Convention: each module <MOD> has rtl/<MOD>.v and a testbench tb/<MOD>_tb.v
# whose top module is <MOD>_tb and which dumps build/<MOD>.vcd.

MOD   ?= regfile
BUILD := build
# -g2005 = strict Verilog-2005. SystemVerilog constructs are rejected on
# purpose: this project is for learning Verilog.
IVFLAGS := -g2005 -Wall -I rtl

# soc.v instantiates every other module, so it needs the whole rtl/ tree.
ifeq ($(MOD),soc)
SRCS := $(wildcard rtl/*.v) tb/$(MOD)_tb.v
else
SRCS := rtl/$(MOD).v tb/$(MOD)_tb.v
endif

# Test programs: .S -> .hex (one 32-bit little-endian word per line, for
# $readmemh). This is the Phase 2 GCC flow in miniature.
RISCV   := riscv64-unknown-elf
ASFLAGS := -march=rv32i -mabi=ilp32

# Every tb/p_*.S program, as the .hex image the soc testbench loads. The
# soc simulation depends on these, so editing a program rebuilds it.
PROG_HEX := $(patsubst tb/%.S,$(BUILD)/%.hex,$(wildcard tb/p_*.S))

$(BUILD)/%.hex: tb/%.S | $(BUILD)
	$(RISCV)-as $(ASFLAGS) -o $(BUILD)/$*.o $<
	$(RISCV)-ld -m elf32lriscv -Ttext=0 -o $(BUILD)/$*.elf $(BUILD)/$*.o
	$(RISCV)-objcopy -O binary $(BUILD)/$*.elf $(BUILD)/$*.bin
	od -An -tx4 -v -w4 $(BUILD)/$*.bin | awk '{print $$1}' > $@

# Disassemble a test program, to read alongside the waveform.
dis: $(BUILD)/$(PROG).hex
	@$(RISCV)-objdump -d -M no-aliases,numeric $(BUILD)/$(PROG).elf | sed -n '/>:/,$$p'
.PHONY: dis

.PHONY: sim wave trace clean
sim: $(BUILD)/$(MOD).vvp $(if $(filter soc,$(MOD)),$(PROG_HEX))
	@vvp $<

wave: sim
	@gtkwave $(BUILD)/$(MOD).vcd $(wildcard tb/$(MOD).gtkw) >/dev/null 2>&1 &

# Retire log for one soc_tb core (named by its program), with disassembly.
trace:
	@$(MAKE) -s --no-print-directory MOD=soc $(BUILD)/soc.vvp $(PROG_HEX)
	@vvp $(BUILD)/soc.vvp +trace=$(PROG)$(if $(filter-out 0,$(LAT)),@$(LAT)) | python3 tb/annotate.py $(BUILD)/$(PROG).elf

$(BUILD)/$(MOD).vvp: $(SRCS) | $(BUILD)
	iverilog $(IVFLAGS) -o $@ $(SRCS)

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)/*.vvp $(BUILD)/*.vcd $(BUILD)/*.o $(BUILD)/*.elf $(BUILD)/*.bin $(BUILD)/*.hex
	@echo "cleaned"
