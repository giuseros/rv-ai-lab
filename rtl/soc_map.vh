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
//                0x1000_0000  console: store a byte  -> print it
//                0x1000_0004  exit:    store a word  -> end the simulation
//   others                                unmapped: stores dropped, loads read 0

`ifndef SOC_MAP_VH
`define SOC_MAP_VH

`define REGION_RAM    4'h0
`define REGION_IO     4'h1

`define CONSOLE_ADDR  32'h1000_0000
`define EXIT_ADDR     32'h1000_0004

`endif
