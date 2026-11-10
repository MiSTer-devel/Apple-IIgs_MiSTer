// video_geom: hardware border geometry for every video mode.
//
// On a real IIgs every line is 6 Mega II cycles of left border, 40 of picture
// and 6 of right border. The Apple II modes draw 14 dots per cycle and Super
// Hi-Res draws 16, so 640 SHR pixels fill the same 40 cycles as 560 Apple II
// dots and the border is the same width in every mode (MAME's apple2gs notes;
// GSSquared VideoScannerIIgs). The VGC here draws everything at 14.318 MHz,
// so its SHR line is 640 dots wide and the border shrinks by 40 dots a side.
//
// This module sits between the VGC stream and video_mixer, on CLK_VIDEO:
//   * Every visible VGC pixel goes into a one-line buffer at its DE index
//     (x = 0..743). The VGC (after its centring delay) puts the Apple II
//     picture at x = 92..651 and SHR at x = 52..691.
//   * The output plays the buffer back L machine pixels later, with sync and
//     blank delayed by the same L, so sync timing is identical in every mode.
//   * The visible window is x = 8..735: 728 dots = 52 cycles, 84-dot borders.
//   * Apple II frames play back 1:1 at 14.318 MHz (728 x lines).
//   * SHR frames (shr_frame) play back at 16.36 MHz, 8 pixels per 7 dots:
//     96 border + 640 picture + 96 border = 832 pixels in the same 52 cycles.
//     The SHR pixels are read 1:1, the border is resampled by time. An Apple
//     II line inside an SHR frame is resampled by time (8:7) so it still
//     lands in the right place.
// shr_frame is chosen at each vsync from shr_in and stretch_en, so the pixel
// rate only changes between frames. With stretch_en off, SHR lines play back
// 1:1 (640 dots, 44-dot borders), centred.
//
// Clocking: CLK_VIDEO = 114.55 MHz, 8 x the machine pixel rate; ce_in fires
// once per machine pixel (every 8 clocks). SHR frames emit a pixel every 7
// clocks (16.36 MHz, 16 per 14 machine pixels exactly), restarted at x = 8 on
// every line, so every SHR pixel is the same width. That leaves the
// scandoubler (pixsz = 7) and gamma (needs 4 clocks a pixel) working in SHR.
//
// Buffer timing: SHR pixel p is written at x = 52+p and read at about
// 92 + L + 7p/8 (machine pixels), so L must be > 41 for p = 639. L = 48.

module video_geom #(
	parameter [9:0] L = 10'd48
) (
	input             clk,
	input             ce_in,
	input      [23:0] rgb_in,
	input             hs_in,        // positive syncs
	input             vs_in,
	input             hb_in,
	input             vb_in,
	input             shr_in,       // NEWVIDEO[7], synchronised to clk
	input             stretch_en,

	output reg        ce_out,
	output reg [23:0] rgb_out,
	output reg        hs_out,
	output reg        vs_out,
	output reg        hb_out,
	output reg        vb_out,
	output reg        shr_frame
);

localparam [9:0] WIN_L   = 10'd8;    // first visible x
localparam [9:0] WIN_R   = 10'd736;  // first x after the window
localparam [9:0] SHR_X0  = 10'd52;   // VGC x of SHR pixel 0
localparam [9:0] SHR_END = 10'd692;  // VGC x after SHR pixel 639
localparam [9:0] SHR_W   = 10'd832;  // SHR frame visible width
localparam [9:0] SHR_PL  = 10'd96;   // SHR frame border width
localparam [9:0] SHR_PR  = 10'd736;  // SHR frame: first right-border pixel

// ---------------- write side: one line, indexed by DE position ----------------
reg [23:0] lbuf [0:1023];
reg  [9:0] wx;
reg        hb_in_d;
reg        line_shr_w;
wire [9:0] wx_now = (hb_in_d & ~hb_in) ? 10'd0 : wx + 10'd1;

always @(posedge clk) if (ce_in) begin
	hb_in_d <= hb_in;
	wx      <= wx_now;
	lbuf[wx_now] <= rgb_in;
	if (wx_now == 10'd0) line_shr_w <= shr_in;
end

// ---------------- sync / blank delay, L machine pixels ----------------
reg  [3:0] sd [0:1023];      // small; Quartus maps it to MLAB/M10K or regs
reg  [9:0] sd_w;
reg  [3:0] sync_d;           // {hs, vs, hb, vb} as of L pixels ago
always @(posedge clk) if (ce_in) begin
	sd[sd_w] <= {hs_in, vs_in, hb_in, vb_in};
	sync_d   <= sd[sd_w - L];
	sd_w     <= sd_w + 10'd1;
end
wire d_hs = sync_d[3], d_vs = sync_d[2], d_hb = sync_d[1], d_vb = sync_d[0];

// read-side position: x of the delayed stream, restarted by the delayed hblank
reg  [9:0] rx;
reg        d_hb_prev, d_vs_prev;
reg        line_shr_r;
reg        shr_req;
wire       rx_start = d_hb_prev & ~d_hb;
wire [9:0] rx_now   = rx_start ? 10'd0 : rx + 10'd1;

// SHR tick generator: one tick every 7 clocks, restarted at x = 8.
reg  [2:0] t7;               // clocks since the last tick
reg  [9:0] n = 10'd1023;     // next SHR output pixel on this line (saturates)

// stage 0 -> 1: a pixel to emit, its buffer address and its sync/blank
reg        s1_fire;
reg  [9:0] s1_addr;
reg  [3:0] s1_sync;          // {hs, vs, hb, vb}
reg        s1_blank;         // outside the window

// A line is 7296 clocks, not a whole number of ticks, so the last tick before
// the restart can land a few clocks before it. video_mixer's gamma needs 4
// clocks a pixel and finds pixels by the rising edge of ce, so ticks in the
// last 5 clocks before the restart (in blanking) are skipped.
reg  [2:0] cc;               // clocks since ce_in
wire       pre_rst  = (rx == WIN_L - 10'd1) && (cc >= 3'd3);
wire       shr_rst  = ce_in && (rx_now == WIN_L);
wire       shr_tick = shr_rst || (t7 == 3'd6 && !pre_rst);
wire [9:0] n_emit   = shr_rst ? 10'd0 : n;

// SHR address for output pixel n_emit: the picture is read 1:1, the border is
// resampled by time, and an Apple II line in an SHR frame is resampled by time.
wire [12:0] n7    = {3'd0, n_emit} * 13'd7;
wire  [9:0] t_x   = WIN_L + n7[12:3];            // VGC x at the same moment
wire  [9:0] shr_a = (n_emit < SHR_PL) ? ((t_x < SHR_X0) ? t_x : SHR_X0 - 10'd1) :
                    (n_emit < SHR_PR) ? (n_emit - (SHR_PL - SHR_X0)) :
                                        ((t_x >= SHR_END) ? t_x : SHR_END);
wire  [9:0] line_a = line_shr_r ? shr_a : t_x;

always @(posedge clk) begin
	s1_fire <= 1'b0;
	cc <= ce_in ? 3'd0 : cc + 3'd1;

	if (ce_in) begin
		d_hb_prev <= d_hb;
		d_vs_prev <= d_vs;
		rx        <= rx_now;
		if (rx_now == 10'd0) line_shr_r <= line_shr_w;
		shr_req   <= stretch_en & shr_in;
		if (d_vs & ~d_vs_prev) shr_frame <= shr_req;   // frame type changes in vsync
	end

	if (!shr_frame) begin
		// Apple II frames: 1:1, one output pixel per machine pixel
		if (ce_in) begin
			s1_fire  <= 1'b1;
			s1_addr  <= rx_now;
			s1_sync  <= {d_hs, d_vs, d_hb, d_vb};
			s1_blank <= (rx_now < WIN_L) || (rx_now >= WIN_R);
		end
		n <= 10'd1023;
	end else begin
		// SHR frames: 8 output pixels per 7 machine pixels
		t7 <= (shr_rst || t7 == 3'd6) ? 3'd0 : t7 + 3'd1;
		if (shr_tick) begin
			s1_fire  <= 1'b1;
			s1_addr  <= line_a;
			s1_sync  <= {d_hs, d_vs, d_hb, d_vb};
			s1_blank <= (n_emit >= SHR_W);
			if (n_emit != 10'd1023) n <= n_emit + 10'd1;
		end
	end
end

// ---------------- stage 1 -> 2: buffer read, output ----------------
reg [23:0] rd;
reg        s2_fire;
reg  [3:0] s2_sync;
reg        s2_blank;
always @(posedge clk) begin
	rd       <= lbuf[s1_addr];
	s2_fire  <= s1_fire;
	s2_sync  <= s1_sync;
	s2_blank <= s1_blank;

	ce_out <= s2_fire;
	if (s2_fire) begin
		rgb_out <= rd;
		hs_out  <= s2_sync[3];
		vs_out  <= s2_sync[2];
		hb_out  <= s2_sync[1] | s2_blank;
		vb_out  <= s2_sync[0];
	end
end

endmodule
