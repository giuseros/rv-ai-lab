# timing.sdc — DE10-Lite timing constraints (Synopsys Design Constraints format)
#
# The one fact the timing analyser can't know: how fast the clock is. With it,
# it checks that every flip-flop-to-flip-flop path settles within one period
# and reports the highest frequency the design could run at (Fmax).

create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]   ;# 50 MHz
derive_clock_uncertainty

# Switches and keys change whenever a person moves them, unrelated to the clock
# (KEY[0] goes through a synchroniser in the RTL), and LEDs and displays are
# watched by eyes. No timing relationship to check on any of them.
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LEDR[*] HEX*}]
