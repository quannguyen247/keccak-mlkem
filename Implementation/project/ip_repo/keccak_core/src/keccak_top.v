`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_top (
    input wire clk,
    input wire rst_n,

    // Mode select: 0 = SHAKE128, 1 = SHAKE256, 2 = SHA3-256, 3 = SHA3-512
    input wire [`KECCAK_MODE_WIDTH-1:0] mode,

    // Absorb side (message in)
    input wire absorb_valid,
    output wire absorb_ready,
    input wire absorb_last,
    input wire [`KECCAK_RATE_BITS-1:0] msg_block_in,
    input wire [7:0] msg_len_bytes,

    // Squeeze side (hash/XOF out)
    input wire squeeze_ready,
    output wire squeeze_valid,
    input wire squeeze_last,
    output wire [`KECCAK_RATE_BITS-1:0] squeeze_out,
    output wire [7:0] squeeze_bytes,

    // Control and status
    input wire start,                               
    output wire done,
    input wire [31:0] output_blocks // SHAKE only
);

    // Padding unit outputs
    wire [`KECCAK_RATE_BITS-1:0] padded_block0;
    wire [`KECCAK_RATE_BITS-1:0] padded_block1_unused;
    wire need_block2_unused;

    // Job config
    reg [`KECCAK_MODE_WIDTH-1:0] mode_reg;

    keccak_pad_block u_pad (
        .mode(mode_reg),
        .msg_block_in(msg_block_in),
        .msg_len_bytes(msg_len_bytes),
        .pad_block0_out(padded_block0),
        .pad_block1_out(padded_block1_unused),
        .need_block2(need_block2_unused)
    );

    keccak_sponge u_sponge (
        .clk(clk),
        .rst_n(rst_n),
        .mode(mode),
        .absorb_valid(absorb_valid),
        .absorb_last(absorb_last),
        .absorb_in(padded_block0),
        .absorb_ready(absorb_ready),
        .squeeze_ready(squeeze_ready),
        .squeeze_last(squeeze_last),
        .squeeze_valid(squeeze_valid),
        .squeeze_out(squeeze_out),
        .squeeze_bytes(squeeze_bytes),
        .start(start),
        .done(done),
        .output_blocks(output_blocks)
    );

    // Job config update
    always @(posedge clk) begin
        if (!rst_n)
            mode_reg <= `KECCAK_MODE_SHAKE256;
        else if (start)
            mode_reg <= mode;
    end

endmodule
