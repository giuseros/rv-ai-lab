# rv-ai-lab — simulation flow (Icarus Verilog + GTKWave)
#
# Usage:
#   make sim   MOD=regfile    # compile rtl/<MOD>.v + tb/<MOD>_tb.v, run, self-check
#   make wave  MOD=regfile    # same, then open the waveform in gtkwave
#   make trace PROG=p_mem     # run the soc, print one line per retired instruction
#   make trace PROG=p_mem LAT=3   # same, on the SoC whose RAM answers 3 cycles late
#   make run   PROG=count     # run sw/count.S (or sw/count.c) on one SoC: output, exit code, CPI
#                             #   add LAT=3 for slow memory, TRACE=1 for the retire log
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
SRCS := $(wildcard rtl/*.v) tb/tb_lib.v tb/$(MOD)_tb.v
else
SRCS := rtl/$(MOD).v tb/$(MOD)_tb.v
endif

# Test programs: .S -> .hex (one 32-bit little-endian word per line, for
# $readmemh). This is the Phase 2 GCC flow in miniature.
RISCV   := riscv64-unknown-elf
ASFLAGS := -march=rv32i -mabi=ilp32

# Every tb/p_*.S and tb/c_*.c program, as the .hex image the soc testbench loads. The
# soc simulation depends on these, so editing a program rebuilds it.
PROG_HEX := $(patsubst tb/%.S,$(BUILD)/%.hex,$(wildcard tb/p_*.S)) \
            $(patsubst tb/%.c,$(BUILD)/%.hex,$(wildcard tb/c_*.c))

# Assembly programs live in sw/ (programs you run) or tb/ (regression tests).
define ASM_TO_HEX
	$(RISCV)-as $(ASFLAGS) -o $(BUILD)/$*.o $<
	$(RISCV)-ld -m elf32lriscv -Ttext=0 -o $(BUILD)/$*.elf $(BUILD)/$*.o
	$(RISCV)-objcopy -O binary $(BUILD)/$*.elf $(BUILD)/$*.bin
	od -An -tx4 -v -w4 $(BUILD)/$*.bin | awk '{print $$1}' > $@
endef
$(BUILD)/%.hex: sw/%.S | $(BUILD)
	$(ASM_TO_HEX)
$(BUILD)/%.hex: tb/%.S | $(BUILD)
	$(ASM_TO_HEX)

# C programs (sw/<name>.c): compiled with the runtime in sw/rt/ (crt0 startup,
# link.ld memory layout, soc.h + runtime.c library) and linked with libgcc,
# which supplies multiply/divide on RV32I. No C library: -ffreestanding.
CFLAGS := -march=rv32i -mabi=ilp32 -O2 -ffreestanding -nostdlib -nostartfiles \
          -Wall -Wextra -Wshadow -Isw/rt
# Code and data share one RAM with no protection, so its single segment really is
# read-write-execute; the linker's warning about that is expected here.
LDFLAGS := -Wl,--no-warn-rwx-segments
RT     := sw/rt/crt0.S sw/rt/runtime.c
define C_TO_HEX
	$(RISCV)-gcc $(CFLAGS) -T sw/rt/link.ld $(LDFLAGS) -o $(BUILD)/$*.elf $(RT) $< -lgcc
	$(RISCV)-objcopy -O binary $(BUILD)/$*.elf $(BUILD)/$*.bin
	od -An -tx4 -v -w4 $(BUILD)/$*.bin | awk '{print $$1}' > $@
endef
$(BUILD)/%.hex: sw/%.c $(RT) sw/rt/soc.h sw/rt/link.ld | $(BUILD)
	$(C_TO_HEX)
$(BUILD)/%.hex: tb/%.c $(RT) sw/rt/soc.h sw/rt/link.ld | $(BUILD)
	$(C_TO_HEX)

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

# Run one program (sw/<PROG>.c, sw/<PROG>.S or tb/<PROG>.S) on a single SoC.
#   make run PROG=count [LAT=3] [TRACE=1]
RUN_SRCS := $(wildcard rtl/*.v) tb/tb_lib.v tb/run_tb.v
run: $(BUILD)/$(PROG).hex
	@iverilog $(IVFLAGS) -o $(BUILD)/run.vvp \
	    -Prun_tb.HEXFILE='"$(BUILD)/$(PROG).hex"' \
	    -Prun_tb.LAT=$(or $(LAT),0) \
	    -Prun_tb.ECHO=$(if $(TRACE),0,1) \
	    $(RUN_SRCS)
	@vvp -n $(BUILD)/run.vvp $(if $(TRACE),+trace=run) \
	    | grep -vE "Not enough words in the file|finish called at" \
	    $(if $(TRACE),| python3 tb/annotate.py --all $(BUILD)/$(PROG).elf)
.PHONY: run

$(BUILD)/$(MOD).vvp: $(SRCS) | $(BUILD)
	iverilog $(IVFLAGS) -o $@ $(SRCS)

# ---- FPGA (Phase 3) --------------------------------------------------------
# Each board is a folder boards/<BOARD>/ holding its tops (<TOP>_top.v), their
# testbenches (<TOP>_top_tb.v), pins.tcl, timing.sdc and build.tcl. Quartus runs
# from the command line only, inside build/<BOARD>/<TOP>/.
#   make fpga-sim BOARD=de10-lite TOP=blinky   # simulate the top first
#   make fpga     BOARD=de10-lite TOP=blinky   # synthesise, fit, report
#   make program  BOARD=de10-lite TOP=blinky   # load it into the FPGA (until power-off)
QUARTUS  ?= $(HOME)/altera_lite/25.1std/quartus/bin
BOARD    ?= de10-lite
TOP      ?= blinky
FPGA_DIR := $(BUILD)/$(BOARD)/$(TOP)
SOF      := $(FPGA_DIR)/output_files/$(TOP)_top.sof
FPGA_SRC := $(wildcard rtl/*.v rtl/*.vh) \
            $(filter-out %_tb.v,$(wildcard boards/$(BOARD)/*.v)) \
            $(wildcard boards/$(BOARD)/*.tcl boards/$(BOARD)/*.sdc)

fpga-sim: | $(BUILD)
	@iverilog $(IVFLAGS) -s $(TOP)_top_tb -o $(BUILD)/$(BOARD)-$(TOP).vvp \
	    $(wildcard rtl/*.v) boards/$(BOARD)/$(TOP)_top.v boards/$(BOARD)/$(TOP)_top_tb.v
	@vvp -n $(BUILD)/$(BOARD)-$(TOP).vvp

# The full Quartus log goes to quartus.log; on failure, its errors are shown.
$(SOF): $(FPGA_SRC)
	@mkdir -p $(FPGA_DIR)
	@echo "quartus: building $(BOARD) $(TOP)_top (log: $(FPGA_DIR)/quartus.log)"
	@cd $(FPGA_DIR) && $(QUARTUS)/quartus_sh -t $(CURDIR)/boards/$(BOARD)/build.tcl \
	    $(TOP) $(CURDIR) > quartus.log 2>&1 \
	 || { grep -E "^Error|BUILD FAILED" quartus.log; exit 1; }

# What it costs and how fast it could run, from Quartus's reports.
fpga: $(SOF)
	@echo "--- $(BOARD) $(TOP)_top ---"
	@grep -E "Total logic elements|Total registers|Total pins|Total memory bits" \
	    $(FPGA_DIR)/output_files/$(TOP)_top.fit.summary | sed 's/^ */  /'
	@grep -A4 "Fmax Summary" $(FPGA_DIR)/output_files/$(TOP)_top.sta.rpt \
	    | grep -E "MHz" | head -1 | awk -F';' '{print "  Fmax (slow corner):" $$2 "(clock " $$4 ")"}'
	@grep -E "Warning \(332" $(FPGA_DIR)/quartus.log | head -5 || true

program: $(SOF)
	$(QUARTUS)/quartus_pgm -m jtag -c 1 -o "p;$(SOF)"

.PHONY: fpga-sim fpga program

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)/*.vvp $(BUILD)/*.vcd $(BUILD)/*.o $(BUILD)/*.elf $(BUILD)/*.bin $(BUILD)/*.hex
	@rm -rf $(BUILD)/*/
	@echo "cleaned"
