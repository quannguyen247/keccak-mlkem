`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_pad_block(
    input wire [`KECCAK_MODE_WIDTH-1:0] mode,
    input wire [`KECCAK_RATE_BITS-1:0] msg_block_in,
    input wire [7:0] msg_len_bytes,
    output reg [`KECCAK_RATE_BITS-1:0] pad_block0_out,
    output reg [`KECCAK_RATE_BITS-1:0] pad_block1_out,
    output reg need_block2
);

    `include "keccak_funcs.vh"

    reg [7:0] rate_bytes;
    reg [7:0] suffix;
    integer i;

    always @(*) begin
        pad_block0_out = {`KECCAK_RATE_BITS{1'b0}};
        pad_block1_out = {`KECCAK_RATE_BITS{1'b0}};
        rate_bytes = keccak_rate_bytes(mode);
        suffix = keccak_suffix(mode);
        need_block2 = (msg_len_bytes >= rate_bytes);

        // Copy valid message bytes and append domain suffix
        for (i = 0; i < (`KECCAK_RATE_BITS / 8); i = i + 1) begin
            if (i < rate_bytes) begin
                if (i < msg_len_bytes)
                    pad_block0_out[(8 * i) +: 8] = msg_block_in[(8 * i) +: 8];
                else if (i == msg_len_bytes)
                    pad_block0_out[(8 * i) +: 8] = suffix;
            end
            // Set pad10*1 terminal bit (0x80) at the end of the rate block
            if (i == (rate_bytes - 1'b1)) begin
                if (need_block2)
                    pad_block1_out[(8 * i) + 7] = 1'b1;
                else
                    pad_block0_out[(8 * i) + 7] = 1'b1;
            end
        end

        if (need_block2)
            pad_block1_out[7:0] = suffix;
    end

endmodule
