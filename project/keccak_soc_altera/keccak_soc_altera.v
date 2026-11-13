module keccak_soc_altera (
    input wire CLOCK_50,
    input wire [0:0] KEY
);
    system u_system (
        .clk_clk(CLOCK_50),
        .reset_reset_n(KEY[0])
    );
endmodule
