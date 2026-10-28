// tb_pe.v - self-checking testbench for pe.v
// Run:  iverilog -o sim_pe pe.v tb_pe.v && vvp sim_pe

`timescale 1ns/1ps

module tb_pe;

    reg                clk = 0;
    reg                rst = 1;
    reg                clear = 0;
    reg  signed [7:0]  a_in = 0;
    reg  signed [7:0]  b_in = 0;
    wire signed [7:0]  a_out, b_out;
    wire signed [31:0] acc;

    integer errors = 0;

    pe dut (
        .clk(clk), .rst(rst), .clear(clear),
        .a_in(a_in), .b_in(b_in),
        .a_out(a_out), .b_out(b_out),
        .acc(acc)
    );

    // 10 ns clock
    always #5 clk = ~clk;

    // Drive one pair of inputs, wait for the clock edge, then check the outputs.
    // Inputs change on the falling edge, outputs are sampled just after the rising edge.
    task step_and_check(
        input signed [7:0]  a,
        input signed [7:0]  b,
        input signed [31:0] expected_acc
    );
        begin
            @(negedge clk);
            a_in = a;
            b_in = b;
            @(posedge clk);
            #1;
            if (acc !== expected_acc) begin
                $display("FAIL: a=%0d b=%0d -> acc=%0d, expected %0d", a, b, acc, expected_acc);
                errors = errors + 1;
            end else begin
                $display("PASS: a=%0d b=%0d -> acc=%0d", a, b, acc);
            end
            if (a_out !== a || b_out !== b) begin
                $display("FAIL: pass-through a_out=%0d b_out=%0d, expected %0d %0d", a_out, b_out, a, b);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_pe.vcd");
        $dumpvars(0, tb_pe);

        // 1. Reset
        repeat (2) @(posedge clk);
        #1;
        if (acc !== 32'sd0) begin
            $display("FAIL: acc not zero after reset");
            errors = errors + 1;
        end else $display("PASS: acc is 0 after reset");
        @(negedge clk);
        rst = 0;

        // 2. Accumulate a sequence of products
        //    3*4 = 12 ; 12 + (-2*5) = 2 ; 2 + (7*-6) = -40
        step_and_check(  8'sd3,    8'sd4,       32'sd12);
        step_and_check( -8'sd2,    8'sd5,        32'sd2);
        step_and_check(  8'sd7,   -8'sd6,      -32'sd40);

        // 3. Extreme INT8 values (checks sign handling and no overflow in the INT32 acc)
        //    -40 + 127*127 = 16089 ; 16089 + (-128*-128) = 32473
        step_and_check(  8'sd127,  8'sd127,   32'sd16089);
        step_and_check(-8'sd128, -8'sd128,    32'sd32473);

        // 4. Zero inputs must not change acc
        step_and_check(  8'sd0,    8'sd0,     32'sd32473);

        // 5. Clear: acc goes to 0 even though the inputs are non-zero
        @(negedge clk);
        clear = 1;
        a_in  = 8'sd9;
        b_in  = 8'sd9;
        @(posedge clk);
        #1;
        if (acc !== 32'sd0) begin
            $display("FAIL: clear did not zero acc (acc=%0d)", acc);
            errors = errors + 1;
        end else $display("PASS: clear zeroed acc");
        @(negedge clk);
        clear = 0;
        a_in  = 8'sd0;   // zero the inputs, otherwise 9*9 gets accumulated
        b_in  = 8'sd0;   // on the next clock edge before test 6 starts

        // 6. Accumulation restarts from zero after clear: 0 + 5*5 = 25
        step_and_check(8'sd5, 8'sd5, 32'sd25);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

endmodule