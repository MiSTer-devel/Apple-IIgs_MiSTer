//============================================================================
//  uthernet2 -- a2RetroSystems Uthernet II (WIZnet W5100) slot card, FPGA half.
//
//  The card has no ROM. The Apple sees four slot I/O addresses (W5100
//  "indirect bus" mode):
//    $C0n4  mode register (MR): bit 7 soft reset, bit 1 auto-increment
//    $C0n5  address pointer, high byte
//    $C0n6  address pointer, low byte
//    $C0n7  data port: reads/writes W5100 memory at the pointer
//
//  The W5100's 32 KB address space (common and socket registers at
//  $0000-$07FF, TX buffers $4000-$5FFF, RX buffers $6000-$7FFF) lives in a
//  DDR3 window that Main maps with /dev/mem. The chip model (sockets, MAC raw
//  frames, the network) runs in Main (support/a2/iigs_uthernet2*.cpp). This
//  block keeps only what has to answer inside an Apple bus cycle:
//
//    * MR and the address pointer, with the W5100 auto-increment wrap rules
//      ($5FFF -> $4000, $7FFF -> $6000);
//    * data-port reads: one 64-bit DDR3 read fills an 8-byte line; the next
//      read of the following address is served from the line. That makes
//      buffer copies cost one DDR3 read per 8 bytes, and it latches 16-bit
//      registers (Sn_TX_FSR, Sn_RX_RSR) so the upper-then-lower read the
//      datasheet asks for sees one value. Any other read fetches again, so a
//      polled register is always fresh;
//    * data-port writes are posted to DDR3 (byte enables);
//    * a write to a socket command register (Sn_CR, $0n01) or an MR soft
//      reset also pushes a doorbell entry into a ring for Main. Main clears
//      Sn_CR in DDR3 when the command is done, which is what drivers poll.
//      MR reads back bit 7 set until Main acknowledges the reset.
//
//  The CPU is held (stall -> RDY) only while a data-port read waits for DDR3
//  or a write waits for the previous one to drain. Slot I/O runs at 1 MHz, so
//  a DDR3 read normally lands inside the cycle.
//
//  DDR3 window (ARM physical 0x1FF00000, shared with the other cores' Ethernet
//  bridges; only one core runs at a time). Offsets in bytes:
//    $0000-$7FFF  W5100 memory image, byte a at offset a
//    $8000  MAGIC  FPGA -> ARM  "IIGSU2E1" once the card is up
//    $8008  GEN    FPGA -> ARM  bumps at every core reset
//    $8010  WPTR   FPGA -> ARM  doorbell entries written (count)
//    $8018  ACK    ARM -> FPGA  doorbell entries applied (count)
//    $8800  RING   256 x 64-bit entries, entry k at $8800 + 8*(k & 255):
//                  [7:0] value, [23:8] W5100 address, [31:24] kind
//                  (0 = register write, 1 = soft reset), [63:32] k
//============================================================================

module uthernet2 #(
    parameter [28:0] DDR_BASE = 29'h03FE0000   // 0x1FF00000 >> 3
) (
    input             clk,
    input             reset,
    input             enable,       // card present (OSD slot != off)

    // CPU side
    input             sel,          // this cycle addresses $C0n4-$C0n7, VDA/VPA valid
    input       [1:0] reg_a,        // address bits [1:0]
    input             we,           // write cycle
    input       [7:0] din,
    output reg  [7:0] dout,
    input             cycle_end,    // CPU cycle completes on this clock (phi2 & RDY)
    output            stall,

    // DDR3 (Avalon-MM, 64-bit, same clock)
    input             DDRAM_BUSY,
    output      [7:0] DDRAM_BURSTCNT,
    output reg [28:0] DDRAM_ADDR,
    input      [63:0] DDRAM_DOUT,
    input             DDRAM_DOUT_READY,
    output reg        DDRAM_RD,
    output reg [63:0] DDRAM_DIN,
    output reg  [7:0] DDRAM_BE,
    output reg        DDRAM_WE
);

assign DDRAM_BURSTCNT = 8'd1;

localparam [28:0] CTL_MAGIC = 29'h1000;   // ($8000 >> 3)
localparam [28:0] CTL_GEN   = 29'h1001;
localparam [28:0] CTL_WPTR  = 29'h1002;
localparam [28:0] CTL_ACK   = 29'h1003;
localparam [28:0] CTL_RING  = 29'h1100;   // ($8800 >> 3)
localparam [63:0] MAGIC     = 64'h3145325553474949;  // "IIGSU2E1" little-endian

// ---------------------------------------------------------------- registers
reg  [6:0]  mr;              // MR bits 6:0 (bit 7 is rst_pending)
reg         rst_pending;
reg [31:0]  rst_target;      // ACK value that completes the reset
reg [15:0]  ptr;
reg [31:0]  wptr;
reg [15:0]  gen = 16'd0;

// read line
reg  [63:0] line;
reg  [11:0] line_tag;        // address [14:3]
reg         line_valid;
reg  [14:0] last_rd;
reg         last_rd_ok;      // last_rd holds the previous data-port read
reg         fresh;           // line was fetched for the access in progress

wire [14:0] maddr   = ptr[14:0];               // $8000+ aliases $0000 (Uthernet II manual p.12)
wire        is_mr   = (maddr == 15'h0000);
wire        data_rd = sel & ~we & (reg_a == 2'd3) & ~is_mr;
wire        data_wr = sel &  we & (reg_a == 2'd3) & ~is_mr;
wire        mr_wr   = sel &  we & ((reg_a == 2'd0) | ((reg_a == 2'd3) & is_mr));

wire        tag_hit = line_valid & (line_tag == maddr[14:3]);
wire        seq_hit = tag_hit & last_rd_ok & (maddr == last_rd + 15'd1);
wire        rd_ready = tag_hit & (fresh | seq_hit);

// ---------------------------------------------------------------- DDR3 ops
// Pending work, drained in this order: byte write, ring entry, WPTR, then
// a line fill or an ACK poll. Init (core reset) writes WPTR, GEN, MAGIC.
reg         op_wbyte;  reg [14:0] wb_addr; reg [7:0] wb_data;
reg         op_ring;   reg [63:0] ring_entry; reg [7:0] ring_idx;
reg         op_wptr;
reg         op_fill;
reg         op_ack;
reg  [1:0]  op_init;   // 3 = WPTR, 2 = GEN, 1 = MAGIC, 0 = done

localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_WAIT = 2'd2;
reg  [1:0]  st;
reg  [2:0]  cur;       // 0 wbyte 1 ring 2 wptr 3 fill 4 ack 5 init
wire        writes_pending = op_wbyte | op_ring | op_wptr | (op_init != 2'd0);
wire        busy = (st != S_IDLE) | writes_pending | op_fill | op_ack;

// ACK polling while a soft reset is outstanding
reg  [9:0]  ack_timer;
reg [22:0]  rst_timeout;   // ~0.6 s at 14.3 MHz: give up if Main is absent

// The CPU waits on a data-port read until the line is valid for it, and on
// any data-port / MR write until the previous writes have drained.
assign stall = enable & ((data_rd & ~rd_ready) | ((data_wr | mr_wr) & writes_pending));

always @(*) begin
    case (reg_a)
        2'd0: dout = {rst_pending, mr};
        2'd1: dout = ptr[15:8];
        2'd2: dout = ptr[7:0];
        default: dout = is_mr ? {rst_pending, mr} : line[{maddr[2:0], 3'b000} +: 8];
    endcase
end

wire [15:0] ptr_inc  = ptr + 16'd1;
wire [15:0] ptr_next = (ptr_inc == 16'h6000) ? 16'h4000 :
                       (ptr_inc == 16'h8000) ? 16'h6000 : ptr_inc;

// MR write: a soft reset clears MR and asks Main to reset the chip model.
task automatic mr_write(input [7:0] v);
    if (v[7]) begin
        mr          <= 7'd0;
        rst_pending <= 1'b1;
        rst_target  <= wptr + 32'd1;
        rst_timeout <= 23'd0;
        ring_entry  <= {wptr, 8'd1, 16'h0000, v};
        ring_idx    <= wptr[7:0];
        op_ring     <= 1'b1;
        op_wptr     <= 1'b1;
        wptr        <= wptr + 32'd1;
    end else
        mr <= v[6:0];
endtask

always @(posedge clk) begin
    if (reset) begin
        mr          <= 7'd0;
        rst_pending <= 1'b0;
        ptr         <= 16'd0;
        wptr        <= 32'd0;
        gen         <= gen + 16'd1;
        line_valid  <= 1'b0;
        last_rd_ok  <= 1'b0;
        fresh       <= 1'b0;
        op_wbyte    <= 1'b0;
        op_ring     <= 1'b0;
        op_wptr     <= 1'b0;
        op_fill     <= 1'b0;
        op_ack      <= 1'b0;
        op_init     <= 2'd3;
        st          <= S_IDLE;
        DDRAM_RD    <= 1'b0;
        DDRAM_WE    <= 1'b0;
        ack_timer   <= 10'd0;
        rst_timeout <= 23'd0;
    end else begin
        // ------------------------------------------------ CPU side
        // A data-port read that misses asks for a line fill once.
        if (enable & data_rd & ~rd_ready & ~op_fill & (st == S_IDLE) & ~writes_pending)
            op_fill <= 1'b1;

        if (enable & sel & cycle_end) begin
            case (reg_a)
                2'd0: if (we) begin
                    mr_write(din);
                end
                2'd1: if (we) ptr <= {din, ptr[7:0]};
                2'd2: if (we) ptr <= {ptr[15:8], din};
                2'd3: begin
                    if (is_mr) begin
                        if (we) begin
                            mr_write(din);
                        end
                        last_rd_ok <= 1'b0;
                    end else if (we) begin
                        op_wbyte   <= 1'b1;
                        wb_addr    <= maddr;
                        wb_data    <= din;
                        line_valid <= 1'b0;
                        last_rd_ok <= 1'b0;
                        // Socket command registers: tell Main
                        if (maddr[14:10] == 5'b00001 && maddr[7:0] == 8'h01) begin
                            ring_entry <= {wptr, 8'd0, 1'b0, maddr, din};
                            ring_idx   <= wptr[7:0];
                            op_ring    <= 1'b1;
                            op_wptr    <= 1'b1;
                            wptr       <= wptr + 32'd1;
                        end
                    end else begin
                        last_rd    <= maddr;
                        last_rd_ok <= 1'b1;
                    end
                    fresh <= 1'b0;
                    if (mr[1]) ptr <= ptr_next;
                end
            endcase
        end

        // ------------------------------------------------ reset handshake
        if (rst_pending) begin
            rst_timeout <= rst_timeout + 23'd1;
            if (&rst_timeout) rst_pending <= 1'b0;
            ack_timer <= ack_timer + 10'd1;
            if (&ack_timer && !op_ack && st == S_IDLE) op_ack <= 1'b1;
        end

        // ------------------------------------------------ DDR3 sequencer
        case (st)
        S_IDLE: begin
            if (op_init != 2'd0) begin
                cur        <= 3'd5;
                DDRAM_ADDR <= DDR_BASE + (op_init == 2'd3 ? CTL_WPTR : op_init == 2'd2 ? CTL_GEN : CTL_MAGIC);
                DDRAM_DIN  <= (op_init == 2'd3) ? 64'd0 : (op_init == 2'd2) ? {48'd0, gen} : MAGIC;
                DDRAM_BE   <= 8'hFF;
                DDRAM_WE   <= 1'b1;
                st         <= S_REQ;
            end else if (op_wbyte) begin
                cur        <= 3'd0;
                DDRAM_ADDR <= DDR_BASE + {17'd0, wb_addr[14:3]};
                DDRAM_DIN  <= {8{wb_data}};
                DDRAM_BE   <= 8'd1 << wb_addr[2:0];
                DDRAM_WE   <= 1'b1;
                st         <= S_REQ;
            end else if (op_ring) begin
                cur        <= 3'd1;
                DDRAM_ADDR <= DDR_BASE + CTL_RING + {21'd0, ring_idx};
                DDRAM_DIN  <= ring_entry;
                DDRAM_BE   <= 8'hFF;
                DDRAM_WE   <= 1'b1;
                st         <= S_REQ;
            end else if (op_wptr) begin
                cur        <= 3'd2;
                DDRAM_ADDR <= DDR_BASE + CTL_WPTR;
                DDRAM_DIN  <= {32'd0, wptr};
                DDRAM_BE   <= 8'hFF;
                DDRAM_WE   <= 1'b1;
                st         <= S_REQ;
            end else if (op_fill) begin
                cur        <= 3'd3;
                DDRAM_ADDR <= DDR_BASE + {17'd0, maddr[14:3]};
                line_tag   <= maddr[14:3];
                DDRAM_RD   <= 1'b1;
                st         <= S_REQ;
            end else if (op_ack) begin
                cur        <= 3'd4;
                DDRAM_ADDR <= DDR_BASE + CTL_ACK;
                DDRAM_RD   <= 1'b1;
                st         <= S_REQ;
            end
        end
        S_REQ: if (~DDRAM_BUSY) begin
            DDRAM_WE <= 1'b0;
            DDRAM_RD <= 1'b0;
            if (DDRAM_WE) begin
                st <= S_IDLE;
                case (cur)
                    3'd0: op_wbyte <= 1'b0;
                    3'd1: op_ring  <= 1'b0;
                    3'd2: op_wptr  <= 1'b0;
                    3'd5: op_init  <= op_init - 2'd1;
                    default: ;
                endcase
            end else
                st <= S_WAIT;
        end
        S_WAIT: if (DDRAM_DOUT_READY) begin
            st <= S_IDLE;
            if (cur == 3'd3) begin
                line       <= DDRAM_DOUT;
                line_valid <= 1'b1;
                fresh      <= 1'b1;
                op_fill    <= 1'b0;
            end else begin
                op_ack <= 1'b0;
                if (DDRAM_DOUT[31:0] - rst_target < 32'h8000_0000) rst_pending <= 1'b0;
            end
        end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule
