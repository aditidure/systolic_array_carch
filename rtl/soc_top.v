// soc_top.v - minimal SoC: PicoRV32 + RAM + GPIO + systolic accelerator
//
//                      +-----------+   native memory interface
//                      | PicoRV32  |---- mem_valid/addr/wdata/wstrb ----+
//                      +-----------+<--- mem_ready/rdata ---------------+
//                                                                       |
//                              address decoder (mem_addr[31:28])        |
//                        +-------------+-------------+------------------+
//                        |             |             |
//                   0x0000_0000    0x1000_0000   0x2000_0000
//                      RAM            GPIO        accelerator
//
// ADDRESS MAP
//   0x0000_0000 ...  RAM (code + data + stack). Program is loaded from a hex file.
//   0x1000_0000      GPIO register, write 32 bits, drives 'gpio_out' (LEDs on the board).
//                    In simulation the testbench also watches writes to
//                    0x1000_0000 (print a character) and 0x1000_0004 (end of test).
//   0x2000_0000 ...  Accelerator (see accel_wrapper.v for its register map)
//
// Every slave answers with 'ready' one cycle after 'valid' (1 wait state).

module soc_top #(
    parameter AW       = 2,                  // accelerator is N x N, N = 2**AW
    parameter RAM_AW   = 12,                 // RAM = 2**RAM_AW words (12 -> 16 KB)
    parameter FAST_MUL = 1,                  // 1: PicoRV32 fast multiplier, 0: slow serial multiplier
    parameter FIRMWARE = "sw/firmware.hex"   // one 32-bit hex word per line
) (
    input  wire        clk,
    input  wire        resetn,               // active low
    output wire        trap,
    output wire [31:0] gpio_out
);

    // ------------------------------------------------------------------
    // CPU
    // ------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .STACKADDR       ((1 << RAM_AW) * 4),     // stack pointer starts at the top of RAM
        .PROGADDR_RESET  (32'h0000_0000),
        .ENABLE_COUNTERS (1),                     // rdcycle / rdinstret, used for benchmarking
        .ENABLE_COUNTERS64(1),
        .COMPRESSED_ISA  (0),
        .ENABLE_MUL      (FAST_MUL ? 0 : 1),
        .ENABLE_FAST_MUL (FAST_MUL ? 1 : 0),
        .ENABLE_DIV      (0),
        .ENABLE_IRQ      (0),
        .ENABLE_PCPI     (0)
    ) cpu (
        .clk       (clk),
        .resetn    (resetn),
        .trap      (trap),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .pcpi_wr   (1'b0),
        .pcpi_rd   (32'b0),
        .pcpi_wait (1'b0),
        .pcpi_ready(1'b0),
        .irq       (32'b0)
    );

    // ------------------------------------------------------------------
    // Address decoder
    // ------------------------------------------------------------------
    wire sel_ram  = (mem_addr[31:28] == 4'h0);
    wire sel_gpio = (mem_addr[31:28] == 4'h1);
    wire sel_acc  = (mem_addr[31:28] == 4'h2);

    // ------------------------------------------------------------------
    // RAM (word array, byte write enables, 1 wait state)
    // ------------------------------------------------------------------
    reg [31:0] ram [0:(1<<RAM_AW)-1];
    reg [31:0] ram_rdata;
    reg        ram_ready;

    initial $readmemh(FIRMWARE, ram);

    always @(posedge clk) begin
        if (!resetn) ram_ready <= 1'b0;
        else begin
            ram_ready <= 1'b0;
            if (mem_valid && sel_ram && !ram_ready) begin
                ram_ready <= 1'b1;
                ram_rdata <= ram[mem_addr[RAM_AW+1:2]];
                if (mem_wstrb[0]) ram[mem_addr[RAM_AW+1:2]][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) ram[mem_addr[RAM_AW+1:2]][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) ram[mem_addr[RAM_AW+1:2]][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) ram[mem_addr[RAM_AW+1:2]][31:24] <= mem_wdata[31:24];
            end
        end
    end

    // ------------------------------------------------------------------
    // GPIO register
    // ------------------------------------------------------------------
    reg [31:0] gpio_reg;
    reg        gpio_ready;

    assign gpio_out = gpio_reg;

    always @(posedge clk) begin
        if (!resetn) begin
            gpio_reg   <= 32'b0;
            gpio_ready <= 1'b0;
        end else begin
            gpio_ready <= 1'b0;
            if (mem_valid && sel_gpio && !gpio_ready) begin
                gpio_ready <= 1'b1;
                if (mem_wstrb != 4'b0 && mem_addr[3:2] == 2'd0)
                    gpio_reg <= mem_wdata;
            end
        end
    end

    // ------------------------------------------------------------------
    // Accelerator
    // ------------------------------------------------------------------
    wire        acc_ready;
    wire [31:0] acc_rdata;

    accel_wrapper #(.AW(AW)) u_acc (
        .clk   (clk),
        .resetn(resetn),
        .valid (mem_valid && sel_acc),
        .addr  (mem_addr),
        .wdata (mem_wdata),
        .wstrb (mem_wstrb),
        .ready (acc_ready),
        .rdata (acc_rdata)
    );

    // ------------------------------------------------------------------
    // Return path to the CPU: only the selected slave raises its ready flag
    // ------------------------------------------------------------------
    assign mem_ready = ram_ready | gpio_ready | acc_ready;
    assign mem_rdata = ram_ready  ? ram_rdata :
                       gpio_ready ? gpio_reg  :
                       acc_ready  ? acc_rdata : 32'h0000_0000;

endmodule