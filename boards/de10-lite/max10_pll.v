`timescale 1ns/1ps
// max10_pll.v — a clock divided down by one of the MAX 10's PLLs
//
// clk = inclk / DIV, on the FPGA's dedicated clock network, phase-aligned to
// inclk. locked goes high once the PLL has settled; until then clk is not to be
// trusted, so whoever uses it holds its logic in reset.
//
// Two implementations, chosen by who reads the file:
//   - Quartus: altpll, the PLL primitive, instantiated directly (no IP wizard;
//     these parameters are what the wizard would write for a plain divider)
//   - iverilog: a behavioural model. Quartus's own model (eda/sim_lib/altera_mf.v)
//     doesn't compile in iverilog, and only the divided clock and locked matter
//     to the design around it. `__ICARUS__ is predefined by iverilog only.
// So the real PLL is never simulated: Quartus checks it, and the timing analyser
// (derive_pll_clocks in timing.sdc) derives the output clock from these parameters.

module max10_pll #(
    parameter IN_PS = 20_000,          // inclk period in picoseconds (50 MHz)
    parameter DIV   = 2                // clk = inclk / DIV; the model needs it even
) (
    input  wire inclk,
    output wire clk,
    output wire locked
);
`ifdef __ICARUS__
    // Model: the divided clock, and locked rising after 16 input cycles.
    reg       c = 1'b0;
    reg [7:0] n = 8'd0;                // input cycles since the last toggle
    reg [4:0] settle = 5'd0;
    always @(posedge inclk) begin
        if (n == DIV / 2 - 1) begin
            c <= !c;
            n <= 8'd0;
        end else
            n <= n + 8'd1;
        if (!settle[4]) settle <= settle + 5'd1;
    end
    assign clk    = c;
    assign locked = settle[4];
`else
    wire [4:0] clks;                   // altpll has five outputs; clk0 is ours
    altpll #(
        .intended_device_family ("MAX 10"),
        .lpm_type               ("altpll"),
        .pll_type               ("AUTO"),
        .operation_mode         ("NORMAL"),     // clk0 phase-aligned with inclk
        .compensate_clock       ("CLK0"),
        .inclk0_input_frequency (IN_PS),
        .clk0_multiply_by       (1),
        .clk0_divide_by         (DIV),
        .clk0_duty_cycle        (50),
        .clk0_phase_shift       ("0"),
        .width_clock            (5)
    ) u_pll (
        .inclk  ({1'b0, inclk}),       // two inputs (for switchover); one used
        .clk    (clks),
        .locked (locked)
    );
    assign clk = clks[0];
`endif
endmodule
