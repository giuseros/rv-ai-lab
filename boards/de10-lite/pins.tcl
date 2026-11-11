# pins.tcl — DE10-Lite pin assignments (sourced by build.tcl)
#
# From the Terasic DE10-Lite user manual's pin tables, cross-checked against two
# independent transcriptions of them. Names are Terasic's, so a top module's port
# called LEDR[3] lands on the LED the manual calls LEDR3. Every pin here is a
# 3.3 V LVTTL bank on this board.
#
# A top only has to declare the ports it uses: assignments to ports that don't
# exist are ignored by Quartus (with a warning).

proc pin {port loc} {
    set_location_assignment $loc -to $port
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $port
}
proc bus {name locs} {
    set i 0
    foreach loc $locs { pin "${name}\[$i\]" $loc; incr i }
}

pin MAX10_CLK1_50 PIN_P11                   ;# 50 MHz oscillator

bus KEY  {PIN_B8 PIN_A7}                    ;# push buttons, 0 = pressed
bus SW   {PIN_C10 PIN_C11 PIN_D12 PIN_C12 PIN_A12 PIN_B12 PIN_A13 PIN_A14 PIN_B14 PIN_F15}
bus LEDR {PIN_A8 PIN_A9 PIN_A10 PIN_B10 PIN_D13 PIN_C13 PIN_E14 PIN_D14 PIN_A11 PIN_B11}

# 7-segment displays, bits 0..6 = segments a..g, bit 7 = decimal point; 0 = on.
bus HEX0 {PIN_C14 PIN_E15 PIN_C15 PIN_C16 PIN_E16 PIN_D17 PIN_C17 PIN_D15}
bus HEX1 {PIN_C18 PIN_D18 PIN_E18 PIN_B16 PIN_A17 PIN_A18 PIN_B17 PIN_A16}
bus HEX2 {PIN_B20 PIN_A20 PIN_B19 PIN_A21 PIN_B21 PIN_C22 PIN_B22 PIN_A19}
bus HEX3 {PIN_F21 PIN_E22 PIN_E21 PIN_C19 PIN_C20 PIN_D19 PIN_E17 PIN_D22}
bus HEX4 {PIN_F18 PIN_E20 PIN_E19 PIN_J18 PIN_H19 PIN_F19 PIN_F20 PIN_F17}
bus HEX5 {PIN_J20 PIN_K20 PIN_L18 PIN_N18 PIN_M20 PIN_N19 PIN_N20 PIN_L19}

# ---- serial port on the 2x20 GPIO header (JP1) ----
# Not part of the board: our own wiring to a USB-serial adapter (a PL2303 set to
# 3.3 V; its VCCIO pin is left unconnected). Header pins from the manual's
# Figure 3-18, FPGA pins from its Table 3-7 (signal names GPIO_25, GPIO_27):
#   JP1 pin 28  GPIO_[25]  UART_TX  FPGA output -> adapter RXD
#   JP1 pin 30  GND                 ground      -- adapter GND
#   JP1 pin 32  GPIO_[27]  UART_RX  FPGA input  <- adapter TXD
# The weak pull-up holds UART_RX at idle (high) when nothing is plugged in, so a
# floating wire doesn't look like traffic.
pin UART_TX PIN_Y7
pin UART_RX PIN_Y6
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to UART_RX
