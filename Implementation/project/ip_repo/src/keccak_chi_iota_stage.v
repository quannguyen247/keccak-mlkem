`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_chi_iota_stage(
    input wire [`KECCAK_STATE_WIDTH-1:0] state_in,
    input wire [63:0] round_const,
    output reg [`KECCAK_STATE_WIDTH-1:0] state_out
);

    reg [63:0] A [0:`KECCAK_NUM_LANES-1]; 
    reg [63:0] B [0:`KECCAK_NUM_LANES-1]; 
    integer x, y, i;

    always @(*) begin
        state_out = {`KECCAK_STATE_WIDTH{1'b0}};

        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            B[i] = state_in[(i * 64) +: 64];
            A[i] = 64'h0;
        end

        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                // Chi step: A'''[x,y] = B[x,y] ^ ((~B[x+1,y]) & B[x+2,y])
                A[x + (5 * y)] = B[x + (5 * y)] ^ ((~B[((x + 1) % 5) + (5 * y)]) & B[((x + 2) % 5) + (5 * y)]);
            end
        end

        // Iota step: A''''[0,0] = A'''[0,0] ^ RC[r]
        A[0] = A[0] ^ round_const;

        for (i = 0; i < `KECCAK_NUM_LANES; i = i + 1) begin
            state_out[(i * 64) +: 64] = A[i];
        end
    end

endmodule