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
    reg [7:0] valid_bytes;
    reg [7:0] suffix;
    integer i;

    always @(*) begin
        pad_block0_out = {`KECCAK_RATE_BITS{1'b0}};
        pad_block1_out = {`KECCAK_RATE_BITS{1'b0}};
        need_block2 = 1'b0;

        rate_bytes = keccak_rate_bytes(mode);
        suffix = keccak_suffix(mode);

        // Clamp valid bytes to rate
        if (msg_len_bytes > rate_bytes) begin
            valid_bytes = rate_bytes;
        end else begin
            valid_bytes = msg_len_bytes;
        end

        // Copy valid bytes to block 0
        for (i = 0; i < (`KECCAK_RATE_BITS / 8); i = i + 1) begin
            if (i < valid_bytes) begin
                pad_block0_out[(8 * i) +: 8] = msg_block_in[(8 * i) +: 8];
            end
        end

        // Apply domain suffix & multi-rate padding
        if (valid_bytes < rate_bytes) begin
            pad_block0_out[(8 * valid_bytes) +: 8] = suffix;
            pad_block0_out[(8 * (rate_bytes - 1'b1)) +: 8] =
                pad_block0_out[(8 * (rate_bytes - 1'b1)) +: 8] | 8'h80;
        end else begin
            pad_block1_out[7:0] = suffix;
            pad_block1_out[(8 * (rate_bytes - 1'b1)) +: 8] = 8'h80;
            need_block2 = 1'b1;
        end
    end

endmodule