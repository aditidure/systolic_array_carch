// tb_systolic_array.v - self-checking testbench for systolic_array.v
// Run:  iverilog -o sim_arr rtl/pe.v rtl/systolic_array.v tb/tb_systolic_array.v && vvp sim_arr
//
// The testbench plays the role of the (future) controller: it applies the
// skewed inputs   A[i][k] -> row i at cycle i+k,   B[k][j] -> column j at cycle j+k
// and then compares the array output with a software golden model.

`timescale 1ns/1ps

module tb_systolic_array;

    parameter N = 4;

    reg                clk = 0;
    reg                rst = 1;
    reg                clear = 0;
    reg  [8*N-1:0]     a_in = 0;
    reg  [8*N-1:0]     b_in = 0;
    wire [32*N*N-1:0]  c_out;

    // Matrices stored row-major: element (r,c) is at index r*N + c
    reg signed [7:0]   A     [0:N*N-1];
    reg signed [7:0]   B     [0:N*N-1];
    reg signed [31:0]  C_exp [0:N*N-1];

    integer errors  = 0;
    integer test_no = 0;
    integer ii, rr;

    systolic_array #(.N(N)) dut (
        .clk(clk), .rst(rst), .clear(clear),
        .a_in(a_in), .b_in(b_in),
        .c_out(c_out)
    );

    // 10 ns clock
    always #5 clk = ~clk;

    // Computes the golden result, runs the array with skewed inputs, compares.
    task run_and_check;
        integer t, i, j, k, idx, local_err;
        reg signed [31:0] sum, got;
        begin
            // ---- golden model: plain triple loop ----
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    sum = 0;
                    for (k = 0; k < N; k = k + 1)
                        sum = sum + A[i*N+k] * B[k*N+j];
                    C_exp[i*N+j] = sum;
                end

            // ---- one cycle of clear with zero inputs ----
            @(negedge clk);
            clear = 1;
            a_in  = 0;
            b_in  = 0;

            // ---- feed for 3N-2 cycles (t = 0 .. 3N-3) ----
            for (t = 0; t < 3*N-2; t = t + 1) begin
                @(negedge clk);
                clear = 0;
                for (i = 0; i < N; i = i + 1) begin
                    k = t - i;                         // which element of row i is due now
                    if (k >= 0 && k < N) a_in[8*i +: 8] = A[i*N+k];
                    else                 a_in[8*i +: 8] = 8'sd0;
                end
                for (j = 0; j < N; j = j + 1) begin
                    k = t - j;                         // which element of column j is due now
                    if (k >= 0 && k < N) b_in[8*j +: 8] = B[k*N+j];
                    else                 b_in[8*j +: 8] = 8'sd0;
                end
            end

            // the clock edge that consumes the last inputs
            @(posedge clk);
            #1;

            // ---- compare ----
            local_err = 0;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                got = c_out[32*idx +: 32];
                if (got !== C_exp[idx]) begin
                    $display("  MISMATCH C[%0d][%0d]: got %0d, expected %0d",
                             idx/N, idx%N, got, C_exp[idx]);
                    local_err = local_err + 1;
                end
            end

            test_no = test_no + 1;
            if (local_err == 0)
                $display("PASS: test %0d", test_no);
            else begin
                $display("FAIL: test %0d (%0d wrong elements)", test_no, local_err);
                errors = errors + local_err;
            end

            // park the inputs at zero
            @(negedge clk);
            a_in = 0;
            b_in = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_systolic_array.vcd");
        $dumpvars(0, tb_systolic_array);

        // reset
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;

        $display("N = %0d, each matmul uses %0d feed cycles (3N-2)", N, 3*N-2);

        // Test 1: A = identity, so C must equal B (B = 1,2,3,...)
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 0;
            B[ii] = ii + 1;
        end
        for (ii = 0; ii < N; ii = ii + 1) A[ii*N+ii] = 1;
        run_and_check;

        // Test 2: all ones, so every C element equals N
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 1;
            B[ii] = 1;
        end
        run_and_check;

        // Test 3: extreme values, -128 * -128 summed N times
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = -128;
            B[ii] = -128;
        end
        run_and_check;

        // Test 4: extreme mixed signs, 127 * -128
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 127;
            B[ii] = -128;
        end
        run_and_check;

        // Tests 5..24: random signed INT8 matrices
        for (rr = 0; rr < 20; rr = rr + 1) begin
            for (ii = 0; ii < N*N; ii = ii + 1) begin
                A[ii] = $random;
                B[ii] = $random;
            end
            run_and_check;
        end

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d ERROR(S)", errors);

        $finish;
    end

endmodule