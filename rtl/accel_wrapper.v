// accel_wrapper.v - memory-mapped interface between PicoRV32 and accel_core
//
// The CPU talks to this block with ordinary 32-bit loads/stores (PicoRV32
// "native memory interface": valid / ready handshake). This wrapper:
//   - decodes the address,
//   - turns a store into a one-cycle write strobe for the right buffer,
//   - turns a load into the right read data,
//   - answers every access with 'ready' one cycle after 'valid' (1 wait state).
//
// REGISTER MAP (offsets from the accelerator base address, e.g. 0x2000_0000)
//   0x000  CTRL    write: bit0 = 1 -> start (a pulse, nothing is stored)
//   0x004  STATUS  read : bit0 = done, bit1 = busy
//   0x100  A[0..N*N-1]  write only, one element per 32-bit word (low 8 bits used)
//   0x200  B[0..N*N-1]  write only, one element per 32-bit word (low 8 bits used)
//   0x300  C[0..N*N-1]  read  only, one 32-bit signed result per word
//   element index = row*N + col, word address = base + 4*index
//
// Use 32-bit stores (sw) for A and B. Do not write A/B while busy.

module accel_wrapper #(
    parameter AW = 2                  // N = 2**AW, up to AW=3 (8x8) with this address map
) (
    input  wire        clk,
    input  wire        resetn,        // active low, same as PicoRV32

    // PicoRV32-style bus slave port (already filtered: valid only for our address range)
    input  wire        valid,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,         // 0 = read, non-zero = write
    output reg         ready,
    output reg  [31:0] rdata
);

    wire rst = ~resetn;

    // ---- address decode ----
    wire [3:0]      region = addr[11:8];            // 0 = regs, 1 = A, 2 = B, 3 = C
    wire [2*AW-1:0] idx    = addr[2 +: 2*AW];       // element index for A/B/C
    wire [1:0]      reg_no = addr[3:2];             // 0 = CTRL, 1 = STATUS

    // ---- ready: one wait state, pulses for exactly one cycle ----
    always @(posedge clk) begin
        if (!resetn) ready <= 1'b0;
        else         ready <= valid && !ready;
    end

    // ---- write strobes: active only in the FIRST cycle of an access (valid && !ready) ----
    wire wr    = valid && !ready && (wstrb != 4'b0000);
    wire a_we  = wr && (region == 4'h1);
    wire b_we  = wr && (region == 4'h2);
    wire start = wr && (region == 4'h0) && (reg_no == 2'd0) && wdata[0];

    // ---- the accelerator ----
    wire        busy, done;
    wire [31:0] c_rdata;

    accel_core #(.AW(AW)) u_core (
        .clk    (clk),
        .rst    (rst),
        .a_we   (a_we),
        .a_waddr(idx),
        .a_wdata(wdata[7:0]),
        .b_we   (b_we),
        .b_waddr(idx),
        .b_wdata(wdata[7:0]),
        .start  (start),
        .busy   (busy),
        .done   (done),
        .c_raddr(idx),                 // stable for the whole access, so c_rdata is valid when ready=1
        .c_rdata(c_rdata)
    );

    // ---- read data mux ----
    always @* begin
        case (region)
            4'h0:    rdata = (reg_no == 2'd1) ? {30'b0, busy, done} : 32'b0;
            4'h3:    rdata = c_rdata;
            default: rdata = 32'b0;
        endcase
    end

endmodule