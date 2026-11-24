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
#   make sim   MOD=boot       # the bootloader (sw/boot.c) receiving a program in sim
#   make load  PROG=talk      # send sw/talk.c to the board's bootloader, then talk to it
#   make clean
#
# Convention: each module <MOD> has rtl/<MOD>.v and a testbench tb/<MOD>_tb.v
# whose top module is <MOD>_tb and which dumps build/<MOD>.vcd.

MOD   ?= regfile
BUILD := build
# -g2005 = strict Verilog-2005. SystemVerilog constructs are rejected on
# purpose: this project is for learning Verilog.
IVFLAGS := -g2005 -Wall -I rtl

# soc.v instantiates every other module, so it needs the whole rtl/ tree. Every
# testbench may use tb/tb_lib.v; -s picks <MOD>_tb as the one top module, so the
# library's (and rtl/'s) other modules are just parsed, never run.
# A module built from other modules lists them in DEPS_<MOD>.
DEPS_console  := rtl/uart_tx.v rtl/uart_rx.v
DEPS_ram_sync := rtl/ram_lane.v
ifneq ($(filter soc boot,$(MOD)),)
SRCS := $(wildcard rtl/*.v) tb/tb_lib.v tb/$(MOD)_tb.v
else
SRCS := rtl/$(MOD).v $(DEPS_$(MOD)) tb/tb_lib.v tb/$(MOD)_tb.v
endif

# Test programs: .S -> .hex (one 32-bit little-endian word per line, for
# $readmemh). This is the Phase 2 GCC flow in miniature.
RISCV   := riscv64-unknown-elf
ASFLAGS := -march=rv32i -mabi=ilp32

# Every tb/p_*.S and tb/c_*.c program, as the .hex image the soc testbench loads. The
# soc simulation depends on these, so editing a program rebuilds it.
PROG_HEX := $(patsubst tb/%.S,$(BUILD)/%.hex,$(wildcard tb/p_*.S)) \
            $(patsubst tb/%.c,$(BUILD)/%.hex,$(wildcard tb/c_*.c))

# Every .hex also gets its byte lanes, <name>.hex.b0 .. .b3: one byte per line,
# byte i of each word, for ram_sync's four byte-wide RAMs. A line of the .hex is
# 8 hex digits, most significant first, so byte i is the 2 digits at 7 - 2i.
define HEX_LANES
	for b in 0 1 2 3; do awk -v b=$$b '{print substr($$1, 7 - 2*b, 2)}' $@ > $@.b$$b; done
endef

# Assembly programs live in sw/ (programs you run) or tb/ (regression tests).
define ASM_TO_HEX
	$(RISCV)-as $(ASFLAGS) -o $(BUILD)/$*.o $<
	$(RISCV)-ld -m elf32lriscv -Ttext=0 -o $(BUILD)/$*.elf $(BUILD)/$*.o
	$(RISCV)-objcopy -O binary $(BUILD)/$*.elf $(BUILD)/$*.bin
	od -An -tx4 -v -w4 $(BUILD)/$*.bin | awk '{print $$1}' > $@
	$(HEX_LANES)
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
	$(RISCV)-gcc $(CFLAGS) -T sw/rt/link.ld $(LDFLAGS) $(LDSYMS) -o $(BUILD)/$*.elf $(RT) $< -lgcc
	$(RISCV)-objcopy -O binary $(BUILD)/$*.elf $(BUILD)/$*.bin
	od -An -tx4 -v -w4 $(BUILD)/$*.bin | awk '{print $$1}' > $@
	$(HEX_LANES)
endef
$(BUILD)/%.hex: sw/%.c $(RT) sw/rt/soc.h sw/rt/link.ld | $(BUILD)
	$(C_TO_HEX)
$(BUILD)/%.hex: tb/%.c $(RT) sw/rt/soc.h sw/rt/link.ld | $(BUILD)
	$(C_TO_HEX)

# The bootloader (sw/boot.c) owns RAM below LOAD_ORIGIN; the programs it loads
# are linked to start there. It is built like any program (build/boot.hex, the
# image for `make fpga ... PROG=boot`), except: its stack starts at LOAD_ORIGIN
# (inside its own space, below anything it loads), it needs little of it, and it
# links crt0 alone (runtime.c's printf would not fit).
LOAD_ORIGIN := 0x800
$(BUILD)/boot.hex: RT     := sw/rt/crt0.S
BOOT_LDSYMS := -Wl,--defsym=STACK_TOP=$(LOAD_ORIGIN) -Wl,--defsym=STACK_MIN=512 \
               -Wl,--defsym=__load_addr=$(LOAD_ORIGIN)
$(BUILD)/boot.hex: LDSYMS := $(BOOT_LDSYMS)

# The simulation's bootloader (tb/boot_tb.v): the same, except that after reset it
# waits 2000 polls for a new program instead of ~1 s (25M cycles: minutes of sim).
$(BUILD)/boot_sim.hex: sw/boot.c sw/rt/crt0.S sw/rt/soc.h sw/rt/link.ld | $(BUILD)
	$(RISCV)-gcc $(CFLAGS) -DWAIT_POLLS=2000 -T sw/rt/link.ld $(LDFLAGS) $(BOOT_LDSYMS) \
	    -o $(BUILD)/boot_sim.elf sw/rt/crt0.S $< -lgcc
	$(RISCV)-objcopy -O binary $(BUILD)/boot_sim.elf $(BUILD)/boot_sim.bin
	od -An -tx4 -v -w4 $(BUILD)/boot_sim.bin | awk '{print $$1}' > $@
	$(HEX_LANES)

# A program for the bootloader: linked at LOAD_ORIGIN, as a raw image (its first
# byte belongs at LOAD_ORIGIN), plus one byte per line for a testbench to send.
define C_TO_LOAD
	$(RISCV)-gcc $(CFLAGS) -T sw/rt/link.ld $(LDFLAGS) -Wl,--defsym=PROG_ORIGIN=$(LOAD_ORIGIN) \
	    -o $(BUILD)/load/$*.elf $(RT) $< -lgcc
	$(RISCV)-objcopy -O binary $(BUILD)/load/$*.elf $@
endef
$(BUILD)/load/%.bin: sw/%.c $(RT) sw/rt/soc.h sw/rt/link.ld | $(BUILD)/load
	$(C_TO_LOAD)
$(BUILD)/load/%.bin: tb/%.c $(RT) sw/rt/soc.h sw/rt/link.ld | $(BUILD)/load
	$(C_TO_LOAD)
$(BUILD)/load/%.bytes: $(BUILD)/load/%.bin
	od -An -tx1 -v -w1 $< | awk '{print $$1}' > $@
$(BUILD)/load:
	@mkdir -p $@
.PRECIOUS: $(BUILD)/load/%.bin              # make load sends it: not an intermediate

# Disassemble a test program, to read alongside the waveform.
dis: $(BUILD)/$(PROG).hex
	@$(RISCV)-objdump -d -M no-aliases,numeric $(BUILD)/$(PROG).elf | sed -n '/>:/,$$p'
.PHONY: dis

.PHONY: sim wave trace clean
BOOT_SIM := $(BUILD)/boot_sim.hex $(BUILD)/load/c_basics.bytes $(BUILD)/load/primes.bytes
sim: $(BUILD)/$(MOD).vvp $(if $(filter soc,$(MOD)),$(PROG_HEX)) $(if $(filter boot,$(MOD)),$(BOOT_SIM))
	@vvp $<

wave: sim
	@gtkwave $(BUILD)/$(MOD).vcd $(wildcard tb/$(MOD).gtkw) >/dev/null 2>&1 &

# Retire log for one soc_tb core (named by its program), with disassembly.
trace:
	@$(MAKE) -s --no-print-directory MOD=soc $(BUILD)/soc.vvp $(PROG_HEX)
	@vvp $(BUILD)/soc.vvp +trace=$(PROG)$(if $(filter-out 0,$(LAT)),@$(LAT)) | python3 tb/annotate.py $(BUILD)/$(PROG).elf

# Run one program (sw/<PROG>.c, sw/<PROG>.S or tb/<PROG>.S) on a single SoC.
#   make run PROG=count [LAT=3] [TRACE=1] [SYNC=1]   (SYNC=1: clocked RAM, ram_sync)
RUN_SRCS := $(wildcard rtl/*.v) tb/tb_lib.v tb/run_tb.v
run: $(BUILD)/$(PROG).hex
	@iverilog $(IVFLAGS) -o $(BUILD)/run.vvp \
	    -Prun_tb.HEXFILE='"$(BUILD)/$(PROG).hex"' \
	    -Prun_tb.LAT=$(or $(LAT),0) \
	    -Prun_tb.SYNC=$(or $(SYNC),0) \
	    -Prun_tb.ECHO=$(if $(TRACE),0,1) \
	    $(RUN_SRCS)
	@vvp -n $(BUILD)/run.vvp $(if $(TRACE),+trace=run) \
	    | grep -vE "Not enough words in the file|finish called at" \
	    $(if $(TRACE),| python3 tb/annotate.py --all $(BUILD)/$(PROG).elf)
.PHONY: run

# Send a program to the bootloader on the board (sw/boot.c, built into the FPGA
# with `make fpga BOARD=de10-lite TOP=soc PROG=boot`), then talk to it.
#   make load PROG=talk [PORT=/dev/ttyUSB0] [NOW=1: the bootloader is already waiting]
PORT ?= /dev/ttyUSB0
load: $(BUILD)/load/$(PROG).bin
	@python3 tools/load.py $(PORT) $< $(if $(NOW),--now)
.PHONY: load

$(BUILD)/$(MOD).vvp: $(SRCS) | $(BUILD)
	iverilog $(IVFLAGS) -s $(MOD)_tb -o $@ $(SRCS)

# ---- FPGA (Phase 3) --------------------------------------------------------
# Each board is a folder boards/<BOARD>/ holding its tops (<TOP>_top.v), their
# testbenches (<TOP>_top_tb.v), pins.tcl, timing.sdc and build.tcl. Quartus runs
# from the command line only, inside build/<BOARD>/<TOP>/.
#   make fpga-sim BOARD=de10-lite TOP=blinky   # simulate the top first
#   make fpga     BOARD=de10-lite TOP=blinky   # synthesise, fit, report
#   make program  BOARD=de10-lite TOP=blinky   # load it into the FPGA (until power-off)
# TOP=soc runs a program, built into the bitstream as the RAM's contents:
#   make fpga BOARD=de10-lite TOP=soc PROG=primes   (PROG: sw/ or tb/, default primes)
# Each program gets its own Quartus directory, build/<BOARD>/soc-<PROG>/, so
# switching programs never reuses a bitstream built for another one. Its
# testbench always runs primes, whose answer it knows.
QUARTUS  ?= $(HOME)/altera_lite/25.1std/quartus/bin
BOARD    ?= de10-lite
TOP      ?= blinky
FPGA_DIR := $(BUILD)/$(BOARD)/$(TOP)
ifeq ($(TOP),soc)
PROG     ?= primes
FPGA_DIR := $(BUILD)/$(BOARD)/soc-$(PROG)
FPGA_HEX := $(BUILD)/$(PROG).hex
FPGA_SIM_HEX := $(BUILD)/primes.hex
endif
SOF      := $(FPGA_DIR)/output_files/$(TOP)_top.sof
FPGA_SRC := $(wildcard rtl/*.v rtl/*.vh) \
            $(filter-out %_tb.v,$(wildcard boards/$(BOARD)/*.v)) \
            $(wildcard boards/$(BOARD)/*.tcl boards/$(BOARD)/*.sdc)

# Board modules that are not tops (e.g. a PLL wrapper): every top may use them.
BOARD_LIB := $(filter-out %_tb.v %_top.v,$(wildcard boards/$(BOARD)/*.v))

fpga-sim: $(FPGA_SIM_HEX) | $(BUILD)
	@iverilog $(IVFLAGS) -s $(TOP)_top_tb -o $(BUILD)/$(BOARD)-$(TOP).vvp \
	    $(wildcard rtl/*.v) tb/tb_lib.v $(BOARD_LIB) boards/$(BOARD)/$(TOP)_top.v boards/$(BOARD)/$(TOP)_top_tb.v
	@vvp -n $(BUILD)/$(BOARD)-$(TOP).vvp | grep -vE "Not enough words in the file"

# The full Quartus log goes to quartus.log; on failure, its errors are shown.
$(SOF): $(FPGA_SRC) $(FPGA_HEX)
	@mkdir -p $(FPGA_DIR)
	@echo "quartus: building $(BOARD) $(TOP)_top (log: $(FPGA_DIR)/quartus.log)"
	@cd $(FPGA_DIR) && $(QUARTUS)/quartus_sh -t $(CURDIR)/boards/$(BOARD)/build.tcl \
	    $(TOP) $(CURDIR) $(if $(FPGA_HEX),$(CURDIR)/$(FPGA_HEX)) > quartus.log 2>&1 \
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
	@rm -rf $(BUILD)/*.vvp $(BUILD)/*.vcd $(BUILD)/*.o $(BUILD)/*.elf $(BUILD)/*.bin $(BUILD)/*.hex $(BUILD)/*.hex.b?
	@rm -rf $(BUILD)/*/
	@echo "cleaned"
