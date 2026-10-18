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

    localparam [5:0] ST_IDLE    = 6'b000001;
    localparam [5:0] ST_ABSORB  = 6'b000010;
    localparam [5:0] ST_START   = 6'b000100;
    localparam [5:0] ST_PERMUTE = 6'b001000;
    localparam [5:0] ST_SQUEEZE = 6'b010000;
    localparam [5:0] ST_DONE    = 6'b100000;

    reg [5:0] curr_state, next_state;
    reg [`KECCAK_MODE_WIDTH-1:0] mode_r;
    reg [`KECCAK_STATE_WIDTH-1:0] keccak_state;
    reg [BLOCK_WIDTH-1:0] squeeze_cnt;
    reg xof_stream_r;
    reg absorb_last_r;
    reg [7:0] squeeze_bytes_r;
    reg [`KECCAK_RATE_BITS-1:0] squeeze_data;

    wire perm_start;
    wire perm_done;
    wire [`KECCAK_STATE_WIDTH-1:0] perm_out;

    keccak_permutation_pipeline u_keccak_perm (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(perm_start),
        .state_in(keccak_state),
        .out_valid(perm_done),
        .state_out(perm_out)
    );

    always @(*) begin
        next_state = curr_state;

        case (curr_state)
            ST_IDLE: if (start)
                next_state = ST_ABSORB;
            ST_ABSORB: if (absorb_valid)
                next_state = ST_START;
            ST_START: next_state = ST_PERMUTE;
            ST_PERMUTE: begin
                if (perm_done) begin
                    if (!absorb_last_r)
                        next_state = ST_ABSORB;
                    else if (xof_stream_r || squeeze_cnt > 0)
                        next_state = ST_SQUEEZE;
                    else
                        next_state = ST_DONE;
                end
            end
            ST_SQUEEZE: begin
                if (squeeze_ready && (xof_stream_r || squeeze_cnt > 0)) begin
                    if ((xof_stream_r && squeeze_last) || (!xof_stream_r && squeeze_cnt == 1))
                        next_state = ST_DONE;
                    else
                        next_state = ST_START;
                end
            end
            ST_DONE: next_state = ST_IDLE;
            default: next_state = ST_IDLE;
        endcase
    end

    always @(*) begin
        squeeze_data = {`KECCAK_RATE_BITS{1'b0}};

        case (mode_r)
            `KECCAK_MODE_SHAKE128: begin
                squeeze_data = keccak_state[`SHAKE128_RATE_BITS-1:0];
            end
            `KECCAK_MODE_SHAKE256: begin
                squeeze_data[`SHAKE256_RATE_BITS-1:0] = keccak_state[`SHAKE256_RATE_BITS-1:0];
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

    always @(posedge clk) begin
        if (!rst_n) begin
            mode_r <= `KECCAK_MODE_SHAKE256;
            keccak_state <= {`KECCAK_STATE_WIDTH{1'b0}};
            curr_state <= ST_IDLE;
        end else begin
            curr_state <= next_state;
            case (curr_state)
                ST_IDLE: begin
                    if (start) begin
                        mode_r <= mode;
                        keccak_state <= {`KECCAK_STATE_WIDTH{1'b0}};
                        squeeze_cnt <= keccak_is_xof(mode) ? output_blocks : 1;
                        xof_stream_r <= keccak_is_xof(mode) && (output_blocks == 0);
                        absorb_last_r <= 1'b0;
                        squeeze_bytes_r <= keccak_output_bytes(mode);
                    end
                end
                ST_ABSORB: begin
                    if (absorb_valid) begin
                        absorb_last_r <= absorb_last;
                        case (mode_r)
                            `KECCAK_MODE_SHAKE128: begin
                                keccak_state[`SHAKE128_RATE_BITS-1:0] <= keccak_state[`SHAKE128_RATE_BITS-1:0] ^ absorb_in[`SHAKE128_RATE_BITS-1:0];
                            end
                            `KECCAK_MODE_SHAKE256, `KECCAK_MODE_SHA3_256: begin
                                keccak_state[`SHAKE256_RATE_BITS-1:0] <= keccak_state[`SHAKE256_RATE_BITS-1:0] ^ absorb_in[`SHAKE256_RATE_BITS-1:0];
                            end
                            `KECCAK_MODE_SHA3_512: begin
                                keccak_state[`SHA3_512_RATE_BITS-1:0] <= keccak_state[`SHA3_512_RATE_BITS-1:0] ^ absorb_in[`SHA3_512_RATE_BITS-1:0];
                            end
                            default: begin
                                keccak_state[`SHAKE256_RATE_BITS-1:0] <= keccak_state[`SHAKE256_RATE_BITS-1:0] ^ absorb_in[`SHAKE256_RATE_BITS-1:0];
                            end
                        endcase
                    end
                end
                ST_PERMUTE: begin
                    if (perm_done)
                        keccak_state <= perm_out;
                end
                ST_SQUEEZE: begin
                    if (squeeze_ready && !xof_stream_r && squeeze_cnt > 0)
                        squeeze_cnt <= squeeze_cnt - 1'b1;
                end
                ST_START: begin
                end
                ST_DONE: begin
                end
            endcase
        end
    end

    assign perm_start = (curr_state == ST_START);
    assign absorb_ready = (curr_state == ST_ABSORB);
    assign squeeze_valid = (curr_state == ST_SQUEEZE) && (xof_stream_r || squeeze_cnt > 0);
    assign squeeze_out = squeeze_data;
    assign squeeze_bytes = squeeze_bytes_r;
    assign done = (curr_state == ST_DONE);

endmodule
