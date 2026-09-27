`timescale 1ns / 100ps

/*
 * Apple IIgs SCC Wrapper
 * 
 * Adapts the Zilog Z8530 SCC implementation for the Apple IIgs architecture.
 * 
 * Channel and Slot Mapping Reference:
 * - Apple IIgs Hardware Reference, Chapter 7 (Built-in I/O Ports) and Chapter 8 (Slot Register $C02D).
 *
 * NOTE ON MACINTOSH vs. APPLE IIGS DIFFERENCE:
 * - On the Macintosh: Channel A is the Modem port and Channel B is the Printer port.
 * - On the Apple IIgs: Apple assigned Channel A to Slot 1 (Printer Port) and Channel B to Slot 2 (Modem Port)
 *   to preserve classic Apple II slot conventions (Slot 1 = Printer, Slot 2 = Modem):
 *     $C038: SCC Channel B Control (Modem Port / Slot 2 Command/Status)
 *     $C039: SCC Channel A Control (Printer Port / Slot 1 Command/Status) 
 *     $C03A: SCC Channel B Data    (Modem Port / Slot 2 Data FIFO)
 *     $C03B: SCC Channel A Data    (Printer Port / Slot 1 Data FIFO)
 */

module scc_iigs_wrapper
(
    input               clk_14m,        // 14.32MHz IIgs master clock
    input               ph0_en,
    input               ph2_en,
    input               q3_en,
    input               reset,
    
    // IIgs CPU interface  
    input               cs,             // Chip select (C038-C03B range)
    input               we,             // Write enable
    input       [1:0]   rs,             // Register select (addr[1:0])
    input       [7:0]   wdata,          // Write data
    output      [7:0]   rdata,          // Read data
    output              irq_n,          // Interrupt request (active low)
    
    // Serial ports (stubbed for initial implementation)
    output              txd_a,          // Transmit data A (printer port)
    output              txd_b,          // Transmit data B (modem port)  
    input               rxd_a,          // Receive data A
    input               rxd_b,          // Receive data B
    output              rts_a,          // Request to send A
    output              rts_b,          // Request to send B
    input               cts_a,          // Clear to send A  
    input               cts_b,           // Clear to send B
	 input               dsr_a
);


// Clock divider: 14.32MHz -> ~1.79MHz (divide by 8) 
// This matches the Apple IIgs PCLK timing used by SCC and DOC systems
// Based on software emulator analysis: PCLK = 14.32MHz/8 ≈ 1.79MHz
reg [2:0] clk_div;

always @(posedge clk_14m or posedge reset) begin
    if (reset) begin
        clk_div <= 3'b000;
    end else begin
        clk_div <= clk_div + 1'b1;
    end
end

// Generate clock enable pulses
// Enable every 8th cycle to create ~1.79MHz PCLK timing from 14.32MHz

// Address decoding for SCC registers
// rs[1] = 0: Control registers, rs[1] = 1: Data registers  
// rs[0] = 0: Port B, rs[0] = 1: Port A

// Internal SCC interrupt signal (before masking)
wire scc_internal_irq_n;

//`define FAKESERIAL
`ifdef FAKESERIAL
reg [7:0] out_reg;
assign rdata = out_reg;

always @(posedge clk_14m) begin
     if (ph0_en && cs)
     begin
        if (we)
	begin
         $display("SCC: WR out_reg: %x  irq: %x wdata %x cs: %x",out_reg,scc_internal_irq_n,wdata,cs);
	end
	else
	begin
	case (rs)
          
      2'b00: begin $display("SCCB CTRL READ");out_reg <= 8'h04; end // Tx buffer empty = 1
      2'b01: begin $display("SCCA CTRL READ");out_reg <= 8'h04; end // Tx buffer empty = 1
      2'b10: begin $display("SCCB DATA READ");out_reg <= 8'h00; end
      2'b11: begin $display("SCCA DATA READ");out_reg <= 8'h00; end
endcase
         $display("SCC: RD out_reg: %x  irq: %x wdata %x cs: %x",out_reg,scc_internal_irq_n,wdata,cs);
      end
	end
end

`else

wire scc_out;

// Generate enable signal - use cs directly since it's already registered
// and indicates when an SCC access is active
// The SCC module expects cen to be high when an access is happening
wire scc_en = cs;  // Use cs as enable - it's high for one cycle during access

// Instantiate existing SCC with adapted clocking
scc scc_inst (
    .clk(clk_14m),                      // Master clock
    .cep( scc_en),                      // Positive edge enable - active during access
    .cen( scc_en),                      // Negative edge enable - active during access
    .reset_hw(reset),
    
    // Bus interface
    .cs(cs),
    .we(we), 
    .rs(rs),                            // [1] = data(1)/ctl(0), [0] = a_side(1)/b_side(0)
    .wdata(wdata),
`ifdef FAKESERIAL
    .rdata(scc_out),
`else
    .rdata(rdata),
`endif
    ._irq(scc_internal_irq_n),          // Internal SCC interrupt
    
    // Serial connections - Channel A (Printer Port / Slot 1)
    .rxd(rxd_a),                        // Channel A receive
    .txd(txd_a),                        // Channel A transmit
    .cts(cts_a),                        // Clear to send from external device (active low: 0 = clear)
    .rts(rts_a),                        // Request to send to external device (active low: 0 = ready)

    // Serial connections - Channel B (Modem Port / Slot 2)
    .rxd_b(rxd_b),                      // Channel B receive
    .txd_b_out(txd_b),                  // Channel B transmit
    .cts_b(cts_b),                      // Clear to send from external device (active low: 0 = clear)
    .rts_b(rts_b),                      // Request to send to external device (active low: 0 = ready)

    // DCD inputs (used for mouse on real IIgs, stubbed high = carrier detect)
    .dcd_a(1'b1),
    .dcd_b(1'b1),

    // Write request output (not used in IIgs)
    .wreq()
);
`endif

// Interrupt control: Enable SCC interrupts properly
// Connect the actual SCC interrupt signal so the SCC can function correctly
assign irq_n = scc_internal_irq_n;  // Use actual SCC interrupt signal

// Add some debug output for initial testing
`ifdef DEBUG_VERBOSE
always @(posedge clk_14m) begin
    if (cs && we) begin
        $display("SCC IIgs: WR %s%s <= %02h",
                 rs[0] ? "A" : "B",
                 rs[1] ? "DATA" : "CTRL",
                 wdata);
    end
    if (cs && !we) begin
        $display("SCC IIgs: RD %s%s => %02h",
                 rs[0] ? "A" : "B",
                 rs[1] ? "DATA" : "CTRL",
                 rdata);
    end
end
`endif

endmodule
