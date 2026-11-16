# build.tcl — create the Quartus project for one DE10-Lite top and compile it
#
# Run by `make fpga BOARD=de10-lite TOP=<top>`, from inside build/de10-lite/<top>/,
# so all of Quartus's output (db/, qdb/, output_files/, the .qsf it writes ...)
# lands there and never in the source tree:
#   quartus_sh -t <repo>/boards/de10-lite/build.tcl <top> <repo> [<hexfile>]
#
# The project is recreated from scratch on every build: these files are the
# whole truth about it, and nothing set by hand in a GUI can drift away from them.

package require ::quartus::project
package require ::quartus::flow

set top    [lindex $quartus(args) 0]       ;# e.g. blinky -> module blinky_top
set root   [lindex $quartus(args) 1]       ;# the repository
set board  $root/boards/de10-lite
set module ${top}_top
set hex    [lindex $quartus(args) 2]       ;# a program image, for a top with a CPU

project_new $module -overwrite

set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY $module
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL

# RAM with initial contents (the program in ram_sync): the MAX 10 supports it
# only in a configuration mode "with memory initialization" (ERAM). In the
# default mode Quartus refuses such RAM ("MIF is not supported for the selected
# family") or drops its contents, leaving the CPU to start from an empty memory.
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"

# Sources: all of rtl/ (only what the top instantiates gets built; the rest is
# just parsed) plus the board's top. Quartus has no Verilog-2005 mode (only 1995,
# 2001 and SystemVerilog): 2001 is the closest, and iverilog -g2005 stays the
# strict checker of the language rules.
set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001
set_global_assignment -name SEARCH_PATH $root/rtl          ;# for `include "*.vh"
foreach f [lsort [glob $root/rtl/*.v]] {
    set_global_assignment -name VERILOG_FILE $f
}
# The board's own modules that are not tops (e.g. max10_pll.v), then the top.
foreach f [lsort [glob $board/*.v]] {
    if {![string match *_tb.v $f] && ![string match *_top.v $f]} {
        set_global_assignment -name VERILOG_FILE $f
    }
}
set_global_assignment -name VERILOG_FILE $board/$module.v
set_global_assignment -name SDC_FILE $board/timing.sdc

# Pins the design doesn't use: inputs, not driven. The safe choice when we
# don't know what the board has wired to them.
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"

# A top with a CPU gets its program as the top's HEXFILE parameter, an absolute
# path (the RAM reads the files <hex>.b0 .. .b3 at synthesis, from Quartus's own
# working directory).
if {$hex ne ""} {
    set_parameter -name HEXFILE $hex
}

source $board/pins.tcl
export_assignments

# synthesis -> fit (place and route) -> assembler (.sof) -> timing analysis
if {[catch {execute_flow -compile} result]} {
    puts "BUILD FAILED: $result"
    project_close
    qexit -error
}
project_close
