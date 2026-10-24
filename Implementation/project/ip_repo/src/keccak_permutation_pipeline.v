`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_permutation_pipeline (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire in_valid,
    input wire [`KECCAK_STATE_WIDTH-1:0] xor_in,
    output wire last_round,
    output wire [`KECCAK_STATE_WIDTH-1:0] state_out
);

    `include "keccak_funcs.vh"
    
    localparam ST_IDLE = 2'b01;
    localparam ST_ROUND = 2'b10;

    reg [`KECCAK_STATE_WIDTH-1:0] state_reg;
    wire [`KECCAK_STATE_WIDTH-1:0] trp_next, ci_next;
    reg [4:0] round_ctr;
    reg [1:0] curr_state, next_state;

    assign last_round = (curr_state == ST_ROUND) && (round_ctr == (`KECCAK_NUM_ROUNDS - 1));
    assign state_out = state_reg;

    keccak_theta_rho_pi_stage u_stage_trp (
        .state_in(state_reg),
        .state_out(trp_next)
    );

    keccak_chi_iota_stage u_stage_ci (
        .state_in(trp_next),
        .round_const(round_constant(round_ctr)),
        .state_out(ci_next)
    );

    always @(*) begin
        next_state = curr_state;
        case (curr_state)
            ST_IDLE: if (in_valid) next_state = ST_ROUND;
            ST_ROUND: next_state = last_round ? ST_IDLE : ST_ROUND;
            default: next_state = ST_IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            curr_state <= ST_IDLE;
            state_reg <= {`KECCAK_STATE_WIDTH{1'b0}};
            round_ctr <= 5'd0;
        end else begin
            curr_state <= next_state;
            case (curr_state)
                ST_IDLE: begin
                    if (in_valid) begin
                        state_reg <= state_reg ^ xor_in;
                        round_ctr <= 5'd0;
                    end else if (clear) begin
                        state_reg <= {`KECCAK_STATE_WIDTH{1'b0}};
                    end
                end
                ST_ROUND: begin
                    state_reg <= ci_next;
                    if (!last_round)
                        round_ctr <= round_ctr + 5'd1;
                end
            endcase
        end
    end

endmodule