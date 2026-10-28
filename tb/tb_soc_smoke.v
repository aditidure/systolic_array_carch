// tb_soc_smoke.v - boots PicoRV32 inside soc_top with a tiny hand-assembled program
// Run (from the project folder, with picorv32.v in rtl/ and smoke.hex in sw/):
//   iverilog -o sim_soc rtl/picorv32.v rtl/pe.v rtl/systolic_array.v rtl/ram_sdp.v \
//            rtl/accel_core.v rtl/accel_wrapper.v rtl/soc_top.v tb/tb_soc_smoke.v
//   vvp sim_soc
//
// smoke.hex does:   lui x1,0x10000 ; store 'H','i','\n' to 0x1000_0000 ; store 0 to 0x1000_0004 ; loop forever
// Expected output:  Hi
//                   SMOKE TEST DONE after <n> cycles

`timescale 1ns/1ps

module tb_soc_smoke;

    reg         clk = 0;
    reg         resetn = 0;
    wire        trap;
    wire [31:0] gpio_out;
    integer     cycles = 0;

    soc_top #(.FIRMWARE("sw/smoke.hex")) dut (
        .clk(clk), .resetn(resetn), .trap(trap), .gpio_out(gpio_out)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("tb_soc_smoke.vcd");
        $dumpvars(0, tb_soc_smoke);
        repeat (10) @(posedge clk);
        @(negedge clk);
        resetn = 1;
    end

    // Watch the CPU's bus: a completed write to the GPIO region acts as a "console"
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (dut.mem_valid && dut.mem_ready && (dut.mem_wstrb != 4'b0000)) begin
            if (dut.mem_addr == 32'h1000_0000)
                $write("%c", dut.mem_wdata[7:0]);
            if (dut.mem_addr == 32'h1000_0004) begin
                $display("SMOKE TEST DONE after %0d cycles", cycles);
                $finish;
            end
        end
        if (trap) begin
            $display("FAIL: CPU trapped (illegal instruction or bad access)");
            $finish;
        end
    end

    // safety net
    initial begin
        #200000;
        $display("FAIL: timeout - CPU never reached the end of the program");
        $finish;
    end

endmodule