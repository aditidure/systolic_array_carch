// tb_accel_core.v - self-checking testbench for accel_core.v
// Run:
//   iverilog -o sim_core rtl/pe.v rtl/systolic_array.v rtl/ram_sdp.v rtl/accel_core.v tb/tb_accel_core.v
//   vvp sim_core
//
// The testbench behaves like the CPU will in Step 5:
//   1. write A and B into the buffers
//   2. pulse start
//   3. wait for done
//   4. read C back and compare with a software golden model
// Several matmuls run back to back WITHOUT a reset, to check the controller restarts cleanly.

`timescale 1ns/1ps

module tb_accel_core;

    parameter AW = 2;                    // 4x4
    localparam N = 1 << AW;

    reg                clk = 0;
    reg                rst = 1;
    reg                a_we = 0, b_we = 0;
    reg  [2*AW-1:0]    a_waddr = 0, b_waddr = 0, c_raddr = 0;
    reg  [7:0]         a_wdata = 0, b_wdata = 0;
    reg                start = 0;
    wire               busy, done;
    wire [31:0]        c_rdata;

    reg signed [7:0]   A     [0:N*N-1];
    reg signed [7:0]   B     [0:N*N-1];
    reg signed [31:0]  C_exp [0:N*N-1];

    integer errors  = 0;
    integer test_no = 0;
    integer ii, rr;

    accel_core #(.AW(AW)) dut (
        .clk(clk), .rst(rst),
        .a_we(a_we), .a_waddr(a_waddr), .a_wdata(a_wdata),
        .b_we(b_we), .b_waddr(b_waddr), .b_wdata(b_wdata),
        .start(start), .busy(busy), .done(done),
        .c_raddr(c_raddr), .c_rdata(c_rdata)
    );

    always #5 clk = ~clk;

    task run_and_check;
        integer i, j, k, idx, cycles, local_err;
        reg signed [31:0] sum, got;
        begin
            // ---- golden model ----
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    sum = 0;
                    for (k = 0; k < N; k = k + 1)
                        sum = sum + A[i*N+k] * B[k*N+j];
                    C_exp[i*N+j] = sum;
                end

            // ---- 1. load A and B (one element of each per cycle) ----
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                @(negedge clk);
                a_we = 1;  a_waddr = idx;  a_wdata = A[idx];
                b_we = 1;  b_waddr = idx;  b_wdata = B[idx];
            end
            @(negedge clk);
            a_we = 0;
            b_we = 0;

            // ---- 2. start pulse ----
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;

            // ---- 3. wait for done (with timeout) ----
            cycles = 0;
            while (!done && cycles < 500) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done) begin
                $display("FAIL: timeout waiting for done");
                errors = errors + 1;
            end

            // ---- 4. read C back (1 cycle read latency) and compare ----
            local_err = 0;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                @(negedge clk);
                c_raddr = idx;
                @(negedge clk);
                got = c_rdata;
                if (got !== C_exp[idx]) begin
                    $display("  MISMATCH C[%0d][%0d]: got %0d, expected %0d",
                             idx/N, idx%N, got, C_exp[idx]);
                    local_err = local_err + 1;
                end
            end

            test_no = test_no + 1;
            if (local_err == 0)
                $display("PASS: test %0d  (start -> done took %0d cycles)", test_no, cycles);
            else begin
                $display("FAIL: test %0d (%0d wrong elements)", test_no, local_err);
                errors = errors + local_err;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_accel_core.vcd");
        $dumpvars(0, tb_accel_core);

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;

        $display("N = %0d. Compute alone needs 3N-2 = %0d cycles; controller adds a %0d-cycle copy-out.",
                 N, 3*N-2, N*N);

        // Test 1: identity * B = B
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 0;
            B[ii] = ii + 1;
        end
        for (ii = 0; ii < N; ii = ii + 1) A[ii*N+ii] = 1;
        run_and_check;

        // Test 2: all ones
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 1;
            B[ii] = 1;
        end
        run_and_check;

        // Test 3: extremes, -128 * -128
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = -128;
            B[ii] = -128;
        end
        run_and_check;

        // Test 4: extremes, 127 * -128
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 127;
            B[ii] = -128;
        end
        run_and_check;

        // Tests 5..24: random signed INT8 matrices, back to back
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