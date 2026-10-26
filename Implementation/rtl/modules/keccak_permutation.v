`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_permutation (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire in_valid,
    input wire [`KECCAK_STATE_WIDTH-1:0] xor_in,
    output wire last_round,
    output reg [`KECCAK_STATE_WIDTH-1:0] state_out
);

    `include "keccak_funcs.vh"

    localparam ST_IDLE = 2'b01;
    localparam ST_ROUND = 2'b10;

    // Round counter, round output and FSM
    reg [4:0] round_ctr;
    (* keep = "true" *) reg [`KECCAK_STATE_WIDTH-1:0] round_out;
    reg [1:0] curr_state, next_state;

    // Variables for the keccak permutation
    reg [63:0] A [0:`KECCAK_NUM_LANES-1];
    reg [63:0] B [0:`KECCAK_NUM_LANES-1];
    reg [63:0] C [0:4];
    reg [63:0] D [0:4];
    integer x, y, i;

    // Determine if the current round is the last round
    assign last_round = (curr_state == ST_ROUND) && (round_ctr == (`KECCAK_NUM_ROUNDS - 1));

    always @(*) begin
        // A[x,y] = state[64*(x+5y) +: 64] (Load lanes)
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            A[i] = state_out[(i * 64) +: 64];
        end

        // C[x] = A[x,0] ^ A[x,1] ^ A[x,2] ^ A[x,3] ^ A[x,4] (Theta)
        for (x = 0; x < 5; x = x + 1) begin
            C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
        end

        // D[x] = C[x-1] ^ ROT(C[x+1], 1)
        for (x = 0; x < 5; x = x + 1) begin
            D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 6'd1);
        end

        // A'[x,y] = A[x,y] ^ D[x]
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                A[x + (5 * y)] = A[x + (5 * y)] ^ D[x];
            end
        end

        // A''[x,y] = ROT(A'[x,y], r[x,y]) (Rho)
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            A[i] = rotl64(A[i], rho_offset(i[4:0]));
        end

        // B[y,2x+3y] = A''[x,y] (Pi)
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                i = ((x + 3 * y) % 5) + 5 * x;
                B[x + (5 * y)] = A[i];
            end
        end

        // A'''[x,y] = B[x,y] ^ ((~B[x+1,y]) & B[x+2,y]) (Chi)
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                A[x + (5 * y)] = B[x + (5 * y)] ^ ((~B[((x + 1) % 5) + (5 * y)]) & B[((x + 2) % 5) + (5 * y)]);
            end
        end

        // A''''[0,0] = A'''[0,0] ^ RC[r] (Iota)
        A[0] = A[0] ^ round_constant(round_ctr);
        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            round_out[(i * 64) +: 64] = A[i];
        end
    end

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
            state_out <= {`KECCAK_STATE_WIDTH{1'b0}};
            round_ctr <= 5'd0;
        end else begin
            curr_state <= next_state;
            case (curr_state)
                ST_IDLE: begin
                    if (in_valid) begin
                        state_out <= state_out ^ xor_in;
                        round_ctr <= 5'd0;
                    end else if (clear) begin
                        state_out <= {`KECCAK_STATE_WIDTH{1'b0}};
                    end
                end
                default: begin
                    state_out <= round_out;
                    if (!last_round)
                        round_ctr <= round_ctr + 5'd1;
                end
            endcase
        end
    end

endmodule