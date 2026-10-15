`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_theta_rho_pi_stage (
    input wire [`KECCAK_STATE_WIDTH-1:0] state_in,
    output reg [`KECCAK_STATE_WIDTH-1:0] state_out
);

    `include "keccak_funcs.vh"

    reg [63:0] A [0:24]; 
    reg [63:0] B [0:24]; 
    reg [63:0] C [0:4]; 
    reg [63:0] D [0:4];
    integer x, y, i;
    
    always @(*) begin
        state_out = {`KECCAK_STATE_WIDTH{1'b0}};

        // Nap lane cho A va set gia tri cho B
        for (i = 0; i < 25; i = i + 1) begin
            A[i] = state_in[(i * 64) +: 64];
            B[i] = 64'h0;
        end

        // Theta step: 
        // Tinh C[x] = A[x,0] ^ A[x,1] ^ A[x,2] ^ A[x,3] ^ A[x,4]
        for (x = 0; x < 5; x = x + 1) begin
            C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
        end

        // Tinh D[x] = C[x-1] ^ ROT(C[x+1], 1)
        for (x = 0; x < 5; x = x + 1) begin
            D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 6'd1);
        end

        // Tinh A'[x,y] = A[x,y] ^ D[x]
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                A[x + (5 * y)] = A[x + (5 * y)] ^ D[x];
            end
        end

        // Rho step
        // Tinh A''[x,y] = ROT(A'[x,y], r[x,y])
        for (i = 0; i < 25; i = i + 1) begin
            A[i] = rotl64(A[i], rho_offset(i[4:0]));
        end

        // Pi step
        // Tinh B[y,2x+3y] = A''[x,y]
        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                i = ((x + 3 * y) % 5) + 5 * x;
                B[x + (5 * y)] = A[i];
            end
        end

        for (i = 0; i < 25; i = i + 1) begin
            state_out[(i * 64) +: 64] = B[i];
        end
    end

endmodule