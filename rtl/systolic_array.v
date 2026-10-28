// systolic_array.v - N x N output-stationary systolic array
//
//              b_in[0]   b_in[1]   b_in[2]  ...   (columns, from the top)
//                 |         |         |
//   a_in[0] --> PE(0,0) -> PE(0,1) -> PE(0,2) ...
//                 |         |         |
//   a_in[1] --> PE(1,0) -> PE(1,1) -> PE(1,2) ...
//                 |         |         |
//   a_in[2] --> PE(2,0) -> PE(2,1) -> PE(2,2) ...
//
//   A values flow left -> right, B values flow top -> bottom.
//   PE(i,j) accumulates C[i][j] = sum over k of A[i][k] * B[k][j].
//
// INPUT TIMING (the "skew") - this is done by whoever drives the array:
//   A[i][k] must be applied to row i    at cycle (i + k)
//   B[k][j] must be applied to column j at cycle (j + k)
//   Then A[i][k] and B[k][j] arrive at PE(i,j) in the same cycle (i + j + k).
//   Cycle 0 is the first cycle after 'clear'. Apply 0 when there is no data.
//   All results are final after 3N-2 cycles.
//
// Ports are flattened vectors (plain Verilog-2001):
//   a_in [8*i +: 8]        = value for row i
//   b_in [8*j +: 8]        = value for column j
//   c_out[32*(i*N+j) +: 32] = C[i][j]  (signed)

module systolic_array #(
    parameter N = 4
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 clear,
    input  wire [8*N-1:0]       a_in,
    input  wire [8*N-1:0]       b_in,
    output wire [32*N*N-1:0]    c_out
);

    // a_bus: input of PE(i,j) is a_bus[i*(N+1)+j]; PE(i,j) drives a_bus[i*(N+1)+j+1]
    wire [8*N*(N+1)-1:0] a_bus;
    // b_bus: input of PE(i,j) is b_bus[i*N+j];     PE(i,j) drives b_bus[(i+1)*N+j]
    wire [8*N*(N+1)-1:0] b_bus;

    genvar i, j;
    generate
        // left edge: feed A into column 0 of every row
        for (i = 0; i < N; i = i + 1) begin : a_edge
            assign a_bus[8*(i*(N+1)) +: 8] = a_in[8*i +: 8];
        end

        // top edge: feed B into row 0 of every column
        for (j = 0; j < N; j = j + 1) begin : b_edge
            assign b_bus[8*j +: 8] = b_in[8*j +: 8];
        end

        // the grid of PEs
        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                pe u_pe (
                    .clk  (clk),
                    .rst  (rst),
                    .clear(clear),
                    .a_in (a_bus[8*(i*(N+1)+j)     +: 8]),
                    .b_in (b_bus[8*(i*N+j)         +: 8]),
                    .a_out(a_bus[8*(i*(N+1)+j+1)   +: 8]),
                    .b_out(b_bus[8*((i+1)*N+j)     +: 8]),
                    .acc  (c_out[32*(i*N+j)        +: 32])
                );
            end
        end
    endgenerate

endmodule