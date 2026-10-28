// accel_core.v - systolic array + BRAM buffers + controller FSM
//
// This is the whole accelerator EXCEPT the bus interface (that is Step 4).
//
//   load A, B  ->  start  ->  [ RUN ] -> [ COPY ] -> done  ->  read C
//
// MEMORY ORGANISATION (why the buffers are banked)
//   The array needs one new A value for EVERY row and one new B value for
//   EVERY column in the same cycle, i.e. 2N reads per cycle. A BRAM gives
//   only 1-2 reads per cycle, so A is split into N banks (bank i = row i)
//   and B into N banks (bank j = column j). Each bank is read independently.
//
// INDEXING (flat, row-major): index = row*N + col, N = 2**AW (power of two)
//   A[r][c] is written with a_waddr = r*N + c  (goes to bank r, address c)
//   B[r][c] is written with b_waddr = r*N + c  (goes to bank c, address r)
//   C[r][c] is read    with c_raddr = r*N + c  (c_rdata valid 1 cycle later)
//
// CONTROLLER FSM
//   IDLE/DONE : wait for 'start'
//   RUN       : 3N-1 cycles. cnt = 0..3N-2
//                 - cycle cnt==0 : 'clear' the accumulators
//                 - row i issues a read of A[i][cnt-i]  when 0 <= cnt-i < N
//                 - col j issues a read of B[cnt-j][j]  when 0 <= cnt-j < N
//                 - bank data arrives one cycle later (synchronous read) and is
//                   applied to the array; invalid slots are replaced by 0
//                 This is exactly the skew from Step 2.
//   COPY      : N*N cycles, copies the finished accumulators into the C buffer
//   DONE      : 'done' = 1 until the next 'start'
//
// Do not write A or B while 'busy' is high.

module accel_core #(
    parameter AW = 2                       // N = 2**AW  (AW=2 -> 4x4 array)
) (
    input  wire              clk,
    input  wire              rst,

    // load interface for A and B
    input  wire              a_we,
    input  wire [2*AW-1:0]   a_waddr,
    input  wire [7:0]        a_wdata,
    input  wire              b_we,
    input  wire [2*AW-1:0]   b_waddr,
    input  wire [7:0]        b_wdata,

    // control / status
    input  wire              start,        // pulse for one cycle
    output wire              busy,
    output wire              done,

    // read interface for C (1 cycle read latency)
    input  wire [2*AW-1:0]   c_raddr,
    output wire [31:0]       c_rdata
);

    localparam N = 1 << AW;

    // ------------------------------------------------------------------
    // Controller FSM
    // ------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1,
                     S_COPY = 2'd2,
                     S_DONE = 2'd3;

    reg [1:0] state;
    reg [9:0] cnt;          // cycle counter in RUN, element index in COPY
    reg       done_r;

    wire run   = (state == S_RUN);
    wire copy  = (state == S_COPY);
    wire clear = run && (cnt == 0);

    assign busy = run | copy;
    assign done = done_r;

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            cnt    <= 10'd0;
            done_r <= 1'b0;
        end else begin
            case (state)
                S_IDLE, S_DONE: begin
                    if (start) begin
                        state  <= S_RUN;
                        cnt    <= 10'd0;
                        done_r <= 1'b0;
                    end
                end
                S_RUN: begin
                    if (cnt == 3*N-2) begin
                        state <= S_COPY;
                        cnt   <= 10'd0;
                    end else begin
                        cnt <= cnt + 10'd1;
                    end
                end
                S_COPY: begin
                    if (cnt == N*N-1) begin
                        state  <= S_DONE;
                        done_r <= 1'b1;
                    end else begin
                        cnt <= cnt + 10'd1;
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Banked A and B buffers, read side
    // ------------------------------------------------------------------
    wire [N-1:0]      a_en, b_en;     // "this bank has valid data due" (issue cycle)
    reg  [N-1:0]      a_vld, b_vld;   // same flags, delayed 1 cycle to match the RAM latency
    wire [8*N-1:0]    a_rd, b_rd;     // raw bank outputs
    wire [8*N-1:0]    a_arr, b_arr;   // values applied to the array (zero when invalid)

    always @(posedge clk) begin
        if (rst) begin
            a_vld <= {N{1'b0}};
            b_vld <= {N{1'b0}};
        end else begin
            a_vld <= a_en;
            b_vld <= b_en;
        end
    end

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_bank

            // ---- A bank i  (row i) ----
            wire signed [10:0] ka = $signed({1'b0, cnt}) - i;      // which element of row i is due
            assign a_en[i] = run && (ka >= 0) && (ka < N);

            ram_sdp #(.DW(8), .AW(AW)) u_a (
                .clk  (clk),
                .we   (a_we && (a_waddr[2*AW-1:AW] == i)),
                .waddr(a_waddr[AW-1:0]),
                .wdata(a_wdata),
                .raddr(ka[AW-1:0]),
                .rdata(a_rd[8*i +: 8])
            );
            assign a_arr[8*i +: 8] = a_vld[i] ? a_rd[8*i +: 8] : 8'd0;

            // ---- B bank i  (column i) ----
            wire signed [10:0] kb = $signed({1'b0, cnt}) - i;      // which element of column i is due
            assign b_en[i] = run && (kb >= 0) && (kb < N);

            ram_sdp #(.DW(8), .AW(AW)) u_b (
                .clk  (clk),
                .we   (b_we && (b_waddr[AW-1:0] == i)),
                .waddr(b_waddr[2*AW-1:AW]),
                .wdata(b_wdata),
                .raddr(kb[AW-1:0]),
                .rdata(b_rd[8*i +: 8])
            );
            assign b_arr[8*i +: 8] = b_vld[i] ? b_rd[8*i +: 8] : 8'd0;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Systolic array (from Step 2)
    // ------------------------------------------------------------------
    wire [32*N*N-1:0] c_out;

    systolic_array #(.N(N)) u_array (
        .clk  (clk),
        .rst  (rst),
        .clear(clear),
        .a_in (a_arr),
        .b_in (b_arr),
        .c_out(c_out)
    );

    // ------------------------------------------------------------------
    // C buffer: one element copied per cycle during COPY
    // ------------------------------------------------------------------
    ram_sdp #(.DW(32), .AW(2*AW)) u_c (
        .clk  (clk),
        .we   (copy),
        .waddr(cnt[2*AW-1:0]),
        .wdata(c_out[32*cnt +: 32]),
        .raddr(c_raddr),
        .rdata(c_rdata)
    );

endmodule