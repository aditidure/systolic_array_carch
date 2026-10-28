// pe.v - one Processing Element (PE) of the systolic array
//
// Every clock cycle a PE does two things:
//   1. MAC:  acc <= acc + a_in * b_in      (multiply-accumulate)
//   2. Pass: a_out <= a_in, b_out <= b_in  (hand the inputs to the neighbours)
//
// Output-stationary: acc stays inside the PE and ends up holding one
// element of the result matrix C.
//
// Data types: INT8 inputs (signed), INT32 accumulator (signed).

module pe (
    input  wire               clk,
    input  wire               rst,     // synchronous reset, clears everything
    input  wire               clear,   // synchronous clear of acc only (start of a new matmul)
    input  wire signed [7:0]  a_in,    // comes from the left neighbour
    input  wire signed [7:0]  b_in,    // comes from the neighbour above
    output reg  signed [7:0]  a_out,   // goes to the right neighbour
    output reg  signed [7:0]  b_out,   // goes to the neighbour below
    output reg  signed [31:0] acc      // running sum = one element of C
);

    always @(posedge clk) begin
        if (rst) begin
            a_out <= 8'sd0;
            b_out <= 8'sd0;
            acc   <= 32'sd0;
        end else begin
            a_out <= a_in;             // one cycle of delay per PE
            b_out <= b_in;
            if (clear)
                acc <= 32'sd0;
            else
                acc <= acc + a_in * b_in;
        end
    end

endmodule