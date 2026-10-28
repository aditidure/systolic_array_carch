// tb_accel_wrapper.v - tests the memory-mapped interface WITHOUT a CPU
// Run:
//   iverilog -o sim_wrap rtl/pe.v rtl/systolic_array.v rtl/ram_sdp.v rtl/accel_core.v rtl/accel_wrapper.v tb/tb_accel_wrapper.v
//   vvp sim_wrap
//
// The testbench imitates what PicoRV32 does on its native memory interface:
// raise 'valid' with address/data, wait for 'ready', then drop 'valid'.
// It then performs the same sequence the C firmware will perform in Step 5:
//   store A, store B, store START, poll STATUS, load C.

`timescale 1ns/1ps

module tb_accel_wrapper;

    parameter AW = 2;
    localparam N = 1 << AW;

    localparam [31:0] BASE   = 32'h2000_0000;
    localparam [31:0] CTRL   = BASE + 32'h000;
    localparam [31:0] STATUS = BASE + 32'h004;
    localparam [31:0] A_BASE = BASE + 32'h100;
    localparam [31:0] B_BASE = BASE + 32'h200;
    localparam [31:0] C_BASE = BASE + 32'h300;

    reg         clk = 0;
    reg         resetn = 0;
    reg         valid = 0;
    reg  [31:0] baddr = 0, bwdata = 0;
    reg  [3:0]  bwstrb = 0;
    wire        ready;
    wire [31:0] rdata;

    accel_wrapper #(.AW(AW)) dut (
        .clk(clk), .resetn(resetn),
        .valid(valid), .addr(baddr), .wdata(bwdata), .wstrb(bwstrb),
        .ready(ready), .rdata(rdata)
    );

    always #5 clk = ~clk;

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg signed [7:0]  A     [0:N*N-1];
    reg signed [7:0]  B     [0:N*N-1];
    reg signed [31:0] C_exp [0:N*N-1];
    reg        [31:0] rd_data;

    integer errors = 0;
    integer test_no = 0;
    integer ii, rr;

    // ---- bus tasks: valid/ready protocol like PicoRV32 ----
    task bus_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            valid = 1; baddr = addr; bwdata = data; bwstrb = 4'hF;
            @(posedge clk); #1;
            while (!ready) begin @(posedge clk); #1; end
            @(posedge clk); #1;               // the edge where the core would see mem_ready
            valid = 0; bwstrb = 0;
        end
    endtask

    task bus_read(input [31:0] addr);
        begin
            @(negedge clk);
            valid = 1; baddr = addr; bwstrb = 4'h0;
            @(posedge clk); #1;
            while (!ready) begin @(posedge clk); #1; end
            rd_data = rdata;                  // data is valid while ready = 1
            @(posedge clk); #1;
            valid = 0;
        end
    endtask

    task run_and_check;
        integer i, j, k, idx, polls, t0, t1, t2, t3, local_err;
        reg signed [31:0] sum, got;
        begin
            // golden model
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    sum = 0;
                    for (k = 0; k < N; k = k + 1)
                        sum = sum + A[i*N+k] * B[k*N+j];
                    C_exp[i*N+j] = sum;
                end

            t0 = cyc;
            // 1. store A and B
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                bus_write(A_BASE + 4*idx, A[idx]);
                bus_write(B_BASE + 4*idx, B[idx]);
            end
            t1 = cyc;

            // 2. start, then STATUS must show busy=1, done=0
            bus_write(CTRL, 32'd1);
            bus_read(STATUS);
            if (rd_data[1] !== 1'b1 || rd_data[0] !== 1'b0) begin
                $display("FAIL: STATUS right after start = %b (expected busy=1, done=0)", rd_data[1:0]);
                errors = errors + 1;
            end

            // 3. poll STATUS until done
            polls = 0;
            bus_read(STATUS);
            while (rd_data[0] !== 1'b1 && polls < 200) begin
                bus_read(STATUS);
                polls = polls + 1;
            end
            if (rd_data[0] !== 1'b1) begin
                $display("FAIL: timeout waiting for done");
                errors = errors + 1;
            end
            t2 = cyc;

            // 4. load C
            local_err = 0;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                bus_read(C_BASE + 4*idx);
                got = rd_data;
                if (got !== C_exp[idx]) begin
                    $display("  MISMATCH C[%0d][%0d]: got %0d, expected %0d",
                             idx/N, idx%N, got, C_exp[idx]);
                    local_err = local_err + 1;
                end
            end
            t3 = cyc;

            test_no = test_no + 1;
            if (local_err == 0)
                $display("PASS: test %0d  (load %0d cyc, start+wait %0d cyc, read %0d cyc, total %0d)",
                         test_no, t1-t0, t2-t1, t3-t2, t3-t0);
            else begin
                $display("FAIL: test %0d (%0d wrong elements)", test_no, local_err);
                errors = errors + local_err;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_accel_wrapper.vcd");
        $dumpvars(0, tb_accel_wrapper);

        repeat (3) @(posedge clk);
        @(negedge clk);
        resetn = 1;

        // Test 1: identity * B = B
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = 0;
            B[ii] = ii + 1;
        end
        for (ii = 0; ii < N; ii = ii + 1) A[ii*N+ii] = 1;
        run_and_check;

        // Test 2: extremes
        for (ii = 0; ii < N*N; ii = ii + 1) begin
            A[ii] = -128;
            B[ii] = 127;
        end
        run_and_check;

        // Tests 3..12: random, back to back without reset
        for (rr = 0; rr < 10; rr = rr + 1) begin
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