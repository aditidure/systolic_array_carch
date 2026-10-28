// ram_sdp.v - simple dual-port RAM: one write port, one read port, same clock
//
// Both the write and the read are SYNCHRONOUS (they happen on the clock edge).
// That is exactly the pattern FPGA tools recognise and map to Block RAM (BRAM).
// Read latency = 1 cycle: set raddr in cycle t, rdata is valid in cycle t+1.
//
// DW = data width in bits, AW = address width (depth = 2**AW words)

module ram_sdp #(
    parameter DW = 8,
    parameter AW = 2
) (
    input  wire            clk,
    input  wire            we,
    input  wire [AW-1:0]   waddr,
    input  wire [DW-1:0]   wdata,
    input  wire [AW-1:0]   raddr,
    output reg  [DW-1:0]   rdata
);

    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata <= mem[raddr];     // synchronous read -> BRAM, not LUT-RAM
    end

endmodule