`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_sponge #(
    parameter BLOCK_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,

    // Mode control
    input wire [`KECCAK_MODE_WIDTH-1:0] mode,

    // Absorb control
    input wire absorb_valid,
    input wire absorb_last,
    input wire [`KECCAK_RATE_BITS-1:0] absorb_in,
    output wire absorb_ready,

    // Squeeze control
    input wire squeeze_ready,
    input wire squeeze_last,
    output wire squeeze_valid,
    output wire [`KECCAK_RATE_BITS-1:0] squeeze_out,
    output wire [7:0] squeeze_bytes,

    // Global control
    input wire start,
    output wire done,
    input wire [BLOCK_WIDTH-1:0] output_blocks
);

    `include "keccak_funcs.vh"

    // Sponge FSM states
    localparam [5:0] ST_IDLE    = 6'b000001;
    localparam [5:0] ST_ABSORB  = 6'b000010;
    localparam [5:0] ST_START   = 6'b000100;
    localparam [5:0] ST_PERMUTE = 6'b001000;
    localparam [5:0] ST_SQUEEZE = 6'b010000;
    localparam [5:0] ST_DONE    = 6'b100000;

    reg [5:0] curr_state, next_state;

    // Job config
    reg [`KECCAK_MODE_WIDTH-1:0] mode_reg;
    reg [BLOCK_WIDTH-1:0] squeeze_left_reg;
    reg xof_stream_reg;           
    reg absorb_last_reg;
    reg absorb_mid_en_reg; // rate > 576 bits (all modes except SHA3-512)
    reg absorb_hi_en_reg;  // rate > 1088 bits (SHAKE128 only)

    // Rate-masked datapath
    reg [`KECCAK_STATE_WIDTH-1:0] absorb_block;
    reg [`KECCAK_RATE_BITS-1:0] squeeze_data;

    // Absorb/squeeze handshake flags
    wire absorb_fire = (curr_state == ST_ABSORB) && absorb_valid;
    wire squeeze_more = xof_stream_reg || (squeeze_left_reg > 0);
    wire squeeze_fire = (curr_state == ST_SQUEEZE) && squeeze_ready && squeeze_more;
    wire squeeze_end = (xof_stream_reg && squeeze_last) || (!xof_stream_reg && squeeze_left_reg == 1);

    // Keccak permutation interface
    wire [`KECCAK_STATE_WIDTH-1:0] keccak_state;
    wire perm_start = absorb_fire || (curr_state == ST_START);
    wire perm_last;

    keccak_permutation u_keccak_perm (
        .clk(clk),
        .rst_n(rst_n),
        .clear(curr_state == ST_IDLE),
        .in_valid(perm_start),
        .xor_in((curr_state == ST_ABSORB) ? absorb_block : {`KECCAK_STATE_WIDTH{1'b0}}),
        .last_round(perm_last),
        .state_out(keccak_state)
    );

    always @(*) begin
        next_state = curr_state;

        case (curr_state)
            ST_IDLE: if (start)
                next_state = ST_ABSORB;
            ST_ABSORB: if (absorb_fire)
                next_state = ST_PERMUTE;
            ST_START: next_state = ST_PERMUTE;
            ST_PERMUTE: if (perm_last)
                next_state = !absorb_last_reg ? ST_ABSORB : (squeeze_more ? ST_SQUEEZE : ST_DONE);
            ST_SQUEEZE: if (squeeze_fire)
                next_state = squeeze_end ? ST_DONE : ST_START;
            ST_DONE: next_state = ST_IDLE;
            default: next_state = ST_IDLE;
        endcase
    end

    // Absorb mask
    always @(*) begin
        absorb_block = {`KECCAK_STATE_WIDTH{1'b0}};
        absorb_block[`SHA3_512_RATE_BITS-1:0] = absorb_in[`SHA3_512_RATE_BITS-1:0];

        if (absorb_mid_en_reg)
            absorb_block[`SHAKE256_RATE_BITS-1:`SHA3_512_RATE_BITS] = absorb_in[`SHAKE256_RATE_BITS-1:`SHA3_512_RATE_BITS];
        if (absorb_hi_en_reg)
            absorb_block[`SHAKE128_RATE_BITS-1:`SHAKE256_RATE_BITS] = absorb_in[`SHAKE128_RATE_BITS-1:`SHAKE256_RATE_BITS];
    end

    // Squeeze mask
    always @(*) begin
        squeeze_data = {`KECCAK_RATE_BITS{1'b0}};

        case (mode_reg)
            `KECCAK_MODE_SHAKE128: begin
                squeeze_data = keccak_state[`SHAKE128_RATE_BITS-1:0];
            end
            `KECCAK_MODE_SHA3_256: begin
                squeeze_data[(`SHA3_256_DIGEST * 8)-1:0] = keccak_state[(`SHA3_256_DIGEST * 8)-1:0];
            end
            `KECCAK_MODE_SHA3_512: begin
                squeeze_data[(`SHA3_512_DIGEST * 8)-1:0] = keccak_state[(`SHA3_512_DIGEST * 8)-1:0];
            end
            default: begin
                squeeze_data[`SHAKE256_RATE_BITS-1:0] = keccak_state[`SHAKE256_RATE_BITS-1:0];
            end
        endcase
    end

    // Sponge FSMD update
    always @(posedge clk) begin
        if (!rst_n) begin
            mode_reg <= `KECCAK_MODE_SHAKE256;
            absorb_mid_en_reg <= 1'b1;
            absorb_hi_en_reg <= 1'b0;
            curr_state <= ST_IDLE;
        end else begin
            curr_state <= next_state;
            case (curr_state)
                ST_IDLE: begin
                    if (start) begin
                        mode_reg <= mode;
                        absorb_mid_en_reg <= (mode != `KECCAK_MODE_SHA3_512);
                        absorb_hi_en_reg <= (mode == `KECCAK_MODE_SHAKE128);
                        squeeze_left_reg <= keccak_is_xof(mode) ? output_blocks : 1;
                        xof_stream_reg <= keccak_is_xof(mode) && (output_blocks == 0);
                    end
                end
                ST_ABSORB: begin
                    if (absorb_fire)
                        absorb_last_reg <= absorb_last;
                end
                ST_SQUEEZE: begin
                    if (squeeze_fire && !xof_stream_reg)
                        squeeze_left_reg <= squeeze_left_reg - 1'b1;
                end
                default: ;
            endcase
        end
    end

    assign absorb_ready = (curr_state == ST_ABSORB);
    assign squeeze_valid = (curr_state == ST_SQUEEZE) && squeeze_more;
    assign squeeze_out = squeeze_data;
    assign squeeze_bytes = keccak_output_bytes(mode_reg);
    assign done = (curr_state == ST_DONE);

endmodule
