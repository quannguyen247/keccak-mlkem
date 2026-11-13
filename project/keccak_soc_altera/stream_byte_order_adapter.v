module stream_byte_order_adapter #(
    parameter integer DATA_WIDTH = 64
)(
    input wire clk,
    input wire reset_n,
    input wire [DATA_WIDTH-1:0] in_data,
    input wire [$clog2(DATA_WIDTH/8)-1:0] in_empty,
    input wire in_valid,
    output wire in_ready,
    input wire in_startofpacket,
    input wire in_endofpacket,
    output wire [DATA_WIDTH-1:0] out_data,
    output wire [$clog2(DATA_WIDTH/8)-1:0] out_empty,
    output wire out_valid,
    input wire out_ready,
    output wire out_startofpacket,
    output wire out_endofpacket
);
    // Combinational lane wiring between high-first SGDMA and low-first Keccak.
    genvar lane;
    generate
        for (lane = 0; lane < DATA_WIDTH/8; lane = lane + 1) begin : lanes
            assign out_data[8*lane +: 8] = in_data[DATA_WIDTH-8*(lane+1) +: 8];
        end
    endgenerate
    assign out_empty = in_empty;
    assign out_valid = in_valid;
    assign in_ready = out_ready;
    assign out_startofpacket = in_startofpacket;
    assign out_endofpacket = in_endofpacket;
endmodule
