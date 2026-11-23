// soc_map.vh — the SoC memory map.
//
// Shared by rtl/bus.v, the testbenches and (later) the C runtime, so that every
// side agrees on what lives where. `define macros: write the backtick.
//
// The bus decodes only addr[31:28], the top 4 bits, into 16 regions of 256 MiB.
// Within a region the target sees the full address and decodes what it needs.
//
//   region 0  0x0000_0000 - 0x0FFF_FFFF   RAM (16 KiB, aliased every 16 KiB)
//   region 1  0x1000_0000 - 0x1FFF_FFFF   I/O
//                0x1000_0000  console: store a byte  -> print it (as a testbench event
//                             and on the serial line; waits while the line is busy)
//                0x1000_0004  exit:    store a word  -> end the simulation (waits until
//                             the line is idle: everything printed has been sent)
//                0x1000_0008  rx data: load a word -> the byte received, in bits 7:0,
//                             and it is removed; bit 31 = 1: nothing waiting (no
//                             byte removed). Negative as an int = empty
//                0x1000_000C  rx status: load a word -> bit 0 a byte is waiting,
//                             bit 1 a byte was dropped, bit 2 a byte had a framing
//                             error (no side effect). 1 and 2 are sticky: store a
//                             word with that bit set to clear it (write 1 to clear)
//   others                                unmapped: stores dropped, loads read 0

`ifndef SOC_MAP_VH
`define SOC_MAP_VH

`define REGION_RAM    4'h0
`define REGION_IO     4'h1

`define CONSOLE_ADDR  32'h1000_0000
`define EXIT_ADDR     32'h1000_0004
`define RX_DATA_ADDR  32'h1000_0008
`define RX_STAT_ADDR  32'h1000_000C

`endif
