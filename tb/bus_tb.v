// bus_tb.v — self-checking testbench for the address-decoding bus.
// Run: make sim MOD=bus
//
// The bus is combinational. Each check drives one request on the initiator
// side plus the two targets' answers, waits a delta, and checks every output.
//
// The two targets answer with DIFFERENT data and can disagree about ready, so a
// bus that steers the wrong target's answer back gives a visibly wrong result.
`timescale 1ns/1ps
`include "soc_map.vh"

module bus_tb;

    // initiator side
    reg         d_valid;
    reg  [31:0] d_addr, d_wdata;
    reg  [3:0]  d_wstrb;
    wire [31:0] d_rdata;
    wire        d_ready;

    // target side
    wire        ram_valid, io_valid;
    wire [31:0] ram_addr, ram_wdata, io_addr, io_wdata;
    wire [3:0]  ram_wstrb, io_wstrb;
    reg  [31:0] ram_rdata, io_rdata;
    reg         ram_ready, io_ready;

    localparam [31:0] RAM_DATA = 32'hAAAA_0000;   // what "the RAM" answers
    localparam [31:0] IO_DATA  = 32'h0000_1111;   // what "the I/O device" answers
    localparam [31:0] WDATA    = 32'hCAFE_F00D;

    integer errors = 0, checks = 0;

    bus dut (
        .d_valid(d_valid), .d_addr(d_addr), .d_wstrb(d_wstrb), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .ram_valid(ram_valid), .ram_addr(ram_addr), .ram_wstrb(ram_wstrb),
        .ram_wdata(ram_wdata), .ram_rdata(ram_rdata), .ram_ready(ram_ready),
        .io_valid(io_valid), .io_addr(io_addr), .io_wstrb(io_wstrb),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_ready(io_ready)
    );

    task chk(input [31:0] got, input [31:0] exp, input [8*44:1] what);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            $display("FAIL: %0s = 0x%0h, expected 0x%0h", what, got, exp);
            errors = errors + 1;
        end
    end
    endtask

    // Drive one request and both targets' answers, then check every output.
    //   e_ram / e_io : which target should see the request (valid)
    //   e_rdata/e_ready : what should come back to the CPU
    task access(input [8*30:1] name,
                input valid, input [31:0] addr, input [3:0] strb,
                input rr, input ir,                     // ram_ready, io_ready
                input e_ram, input e_io, input [31:0] e_rdata, input e_ready);
        reg [3:0] e_ram_strb, e_io_strb;
        integer   before;
    begin
        before = errors;
        d_valid = valid; d_addr = addr; d_wstrb = strb; d_wdata = WDATA;
        ram_ready = rr; io_ready = ir;
        #1;
        e_ram_strb = e_ram ? strb : 4'b0000;
        e_io_strb  = e_io  ? strb : 4'b0000;
        chk(ram_valid, e_ram,      {name, ": ram_valid"});
        chk(io_valid,  e_io,       {name, ": io_valid"});
        chk(ram_wstrb, e_ram_strb, {name, ": ram_wstrb"});
        chk(io_wstrb,  e_io_strb,  {name, ": io_wstrb"});
        chk(d_rdata,   e_rdata,    {name, ": d_rdata"});
        chk(d_ready,   e_ready,    {name, ": d_ready"});
        // the selected target receives the address and data unchanged
        if (e_ram) begin chk(ram_addr, addr, {name, ": ram_addr"}); chk(ram_wdata, WDATA, {name, ": ram_wdata"}); end
        if (e_io)  begin chk(io_addr,  addr, {name, ": io_addr"});  chk(io_wdata,  WDATA, {name, ": io_wdata"});  end
        if (errors == before) $display("  ok: %0s", name);
        else                  $display("      ^ in: %0s", name);
    end
    endtask

    initial begin
        $dumpfile("build/bus.vcd");
        $dumpvars(0, bus_tb);
        ram_rdata = RAM_DATA; io_rdata = IO_DATA;

        //      name                          valid addr          strb    rr ir   ram io   rdata     ready
        $display("--- routing ------------------------------------------------");
        access("ram load               ",     1, 32'h0000_0100, 4'b0000, 1, 1,   1,  0,  RAM_DATA, 1);
        access("ram store (sh)         ",     1, 32'h0000_0104, 4'b1100, 1, 1,   1,  0,  RAM_DATA, 1);
        access("console store (sb)     ",     1, `CONSOLE_ADDR, 4'b0001, 1, 1,   0,  1,  IO_DATA,  1);
        access("exit store (sw)        ",     1, `EXIT_ADDR,    4'b1111, 1, 1,   0,  1,  IO_DATA,  1);
        access("io load                ",     1, 32'h1000_0008, 4'b0000, 1, 1,   0,  1,  IO_DATA,  1);

        $display("--- region boundaries (only addr[31:28] decides) -----------");
        access("last ram word          ",     1, 32'h0FFF_FFFC, 4'b1111, 1, 1,   1,  0,  RAM_DATA, 1);
        access("first io word          ",     1, 32'h1000_0000, 4'b1111, 1, 1,   0,  1,  IO_DATA,  1);
        access("last io word           ",     1, 32'h1FFF_FFFC, 4'b1111, 1, 1,   0,  1,  IO_DATA,  1);
        access("first unmapped word    ",     1, 32'h2000_0000, 4'b1111, 1, 1,   0,  0,  32'd0,    1);
        access("region 3: bit 28 set   ",     1, 32'h3000_0000, 4'b1111, 1, 1,   0,  0,  32'd0,    1);
        access("top of address space   ",     1, 32'hFFFF_FFFC, 4'b1111, 1, 1,   0,  0,  32'd0,    1);

        $display("--- unmapped: the bus answers itself ------------------------");
        // both targets say "not ready": the bus must still complete the request
        access("unmapped load, tgts busy",    1, 32'h2000_0040, 4'b0000, 0, 0,   0,  0,  32'd0,    1);
        access("unmapped store, tgts busy",   1, 32'h8000_0000, 4'b1111, 0, 0,   0,  0,  32'd0,    1);

        $display("--- no request: nobody may act ------------------------------");
        // strobes set but d_valid low (the CPU never does this, but the bus must
        // not turn it into a write)
        access("no req, ram address    ",     0, 32'h0000_0100, 4'b1111, 1, 1,   0,  0,  RAM_DATA, 1);
        access("no req, io address     ",     0, `CONSOLE_ADDR, 4'b1111, 1, 1,   0,  0,  IO_DATA,  1);

        $display("--- ready comes from the selected target only ---------------");
        access("ram busy               ",     1, 32'h0000_0100, 4'b0000, 0, 1,   1,  0,  RAM_DATA, 0);
        access("ram ok, io busy        ",     1, 32'h0000_0100, 4'b0000, 1, 0,   1,  0,  RAM_DATA, 1);
        access("io busy                ",     1, `CONSOLE_ADDR, 4'b0001, 1, 0,   0,  1,  IO_DATA,  0);
        access("io ok, ram busy        ",     1, `CONSOLE_ADDR, 4'b0001, 0, 1,   0,  1,  IO_DATA,  1);

        $display("--------------------------------------------------");
        if (errors == 0) $display("BUS: ALL TESTS PASSED (%0d checks)", checks);
        else             $display("BUS: %0d/%0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
