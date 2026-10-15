`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_top (
    input wire clk,
    input wire rst_n,
    input wire [`KECCAK_MODE_WIDTH-1:0] mode,
    input wire absorb_valid,
    input wire [`KECCAK_MAX_RATE_BITS-1:0] msg_block_in,
    input wire [7:0] msg_len_bytes,
    output wire absorb_ready,
    input wire squeeze_ready,
    output wire squeeze_valid,
    output wire [`KECCAK_MAX_RATE_BITS-1:0] squeeze_out,
    output wire [7:0] squeeze_bytes,
    input wire start,
    output wire done,
    input wire [31:0] input_blocks,
    input wire [31:0] output_blocks
);

    wire [`KECCAK_MAX_RATE_BITS-1:0] padded_block0;
    wire [`KECCAK_MAX_RATE_BITS-1:0] padded_block1_unused;
    wire need_block2_unused;
    wire sponge_absorb_ready;
    reg [`KECCAK_MODE_WIDTH-1:0] mode_r;
    reg [`KECCAK_MAX_RATE_BITS-1:0] msg_block_r;
    reg [7:0] msg_len_bytes_r;
    reg block_valid_r;
    reg [`KECCAK_MAX_RATE_BITS-1:0] padded_block_r;
    reg padded_valid_r;

    keccak_pad_block u_pad (
        .mode(mode_r),
        .msg_block_in(msg_block_r),
        .msg_len_bytes(msg_len_bytes_r),
        .pad_block0_out(padded_block0),
        .pad_block1_out(padded_block1_unused),
        .need_block2(need_block2_unused)
    );

    keccak_sponge u_sponge (
        .clk(clk),
        .rst_n(rst_n),
        .mode(mode),
        .absorb_valid(padded_valid_r),
        .absorb_last(1'b0),
        .absorb_in(padded_block_r),
        .absorb_ready(sponge_absorb_ready),
        .squeeze_ready(squeeze_ready),
        .squeeze_last(1'b0),
        .squeeze_valid(squeeze_valid),
        .squeeze_out(squeeze_out),
        .squeeze_bytes(squeeze_bytes),
        .start(start),
        .done(done),
        .input_blocks(input_blocks),
        .output_blocks(output_blocks)
    );

    assign absorb_ready = !block_valid_r && !start;

    always @(posedge clk) begin
        if (!rst_n) begin
            mode_r <= `KECCAK_MODE_SHAKE256;
            block_valid_r <= 1'b0;
            padded_valid_r <= 1'b0;
        end else if (start) begin
            mode_r <= mode;
            block_valid_r <= 1'b0;
            padded_valid_r <= 1'b0;
        end else begin
            if (padded_valid_r && sponge_absorb_ready)
                padded_valid_r <= 1'b0;
            if (block_valid_r && !padded_valid_r) begin
                padded_block_r <= padded_block0;
                padded_valid_r <= 1'b1;
                block_valid_r <= 1'b0;
            end
            if (absorb_valid && absorb_ready) begin
                msg_block_r <= msg_block_in;
                msg_len_bytes_r <= msg_len_bytes;
                block_valid_r <= 1'b1;
            end
        end
    end

endmodule