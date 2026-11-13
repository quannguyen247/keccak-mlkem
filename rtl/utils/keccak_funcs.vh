// 64-bit rotate-left
function [63:0] rotl64;
    input [63:0] value;
    input [5:0] amount;
    begin
        if (amount == 0)
            rotl64 = value;
        else
            rotl64 = (value << amount) | (value >> (64 - amount));
    end
endfunction

// Rho offsets, indexed by lane = x + 5*y
function [5:0] rho_offset;
    input [4:0] lane;
    begin
        case (lane)
            5'd0: rho_offset = 6'd0;
            5'd1: rho_offset = 6'd1;
            5'd2: rho_offset = 6'd62;
            5'd3: rho_offset = 6'd28;
            5'd4: rho_offset = 6'd27;
            5'd5: rho_offset = 6'd36;
            5'd6: rho_offset = 6'd44;
            5'd7: rho_offset = 6'd6;
            5'd8: rho_offset = 6'd55;
            5'd9: rho_offset = 6'd20;
            5'd10: rho_offset = 6'd3;
            5'd11: rho_offset = 6'd10;
            5'd12: rho_offset = 6'd43;
            5'd13: rho_offset = 6'd25;
            5'd14: rho_offset = 6'd39;
            5'd15: rho_offset = 6'd41;
            5'd16: rho_offset = 6'd45;
            5'd17: rho_offset = 6'd15;
            5'd18: rho_offset = 6'd21;
            5'd19: rho_offset = 6'd8;
            5'd20: rho_offset = 6'd18;
            5'd21: rho_offset = 6'd2;
            5'd22: rho_offset = 6'd61;
            5'd23: rho_offset = 6'd56;
            5'd24: rho_offset = 6'd14;
            default: rho_offset = 6'd0;
        endcase
    end
endfunction

// Round constants 
function [63:0] round_constant;
    input [4:0] idx;
    begin
        case (idx)
            5'd0: round_constant = 64'h0000000000000001;
            5'd1: round_constant = 64'h0000000000008082;
            5'd2: round_constant = 64'h800000000000808a;
            5'd3: round_constant = 64'h8000000080008000;
            5'd4: round_constant = 64'h000000000000808b;
            5'd5: round_constant = 64'h0000000080000001;
            5'd6: round_constant = 64'h8000000080008081;
            5'd7: round_constant = 64'h8000000000008009;
            5'd8: round_constant = 64'h000000000000008a;
            5'd9: round_constant = 64'h0000000000000088;
            5'd10: round_constant = 64'h0000000080008009;
            5'd11: round_constant = 64'h000000008000000a;
            5'd12: round_constant = 64'h000000008000808b;
            5'd13: round_constant = 64'h800000000000008b;
            5'd14: round_constant = 64'h8000000000008089;
            5'd15: round_constant = 64'h8000000000008003;
            5'd16: round_constant = 64'h8000000000008002;
            5'd17: round_constant = 64'h8000000000000080;
            5'd18: round_constant = 64'h000000000000800a;
            5'd19: round_constant = 64'h800000008000000a;
            5'd20: round_constant = 64'h8000000080008081;
            5'd21: round_constant = 64'h8000000000008080;
            5'd22: round_constant = 64'h0000000080000001;
            5'd23: round_constant = 64'h8000000080008008;
            default: round_constant = 64'h0;
        endcase
    end
endfunction

// Block rate for each mode
function [7:0] keccak_rate_bytes;
    input [`KECCAK_MODE_WIDTH-1:0] mode;
    localparam integer SHAKE128_BYTES = `SHAKE128_RATE_BITS / 8;
    localparam integer SHAKE256_BYTES = `SHAKE256_RATE_BITS / 8;
    localparam integer SHA3_256_BYTES = `SHA3_256_RATE_BITS / 8;
    localparam integer SHA3_512_BYTES = `SHA3_512_RATE_BITS / 8;
    begin
        case (mode)
            `KECCAK_MODE_SHAKE128: keccak_rate_bytes = SHAKE128_BYTES[7:0];
            `KECCAK_MODE_SHAKE256: keccak_rate_bytes = SHAKE256_BYTES[7:0];
            `KECCAK_MODE_SHA3_256: keccak_rate_bytes = SHA3_256_BYTES[7:0];
            `KECCAK_MODE_SHA3_512: keccak_rate_bytes = SHA3_512_BYTES[7:0];
            default: keccak_rate_bytes = SHAKE256_BYTES[7:0];
        endcase
    end
endfunction

// Padding suffix
function [7:0] keccak_suffix;
    input [`KECCAK_MODE_WIDTH-1:0] mode;
    begin
        case (mode)
            `KECCAK_MODE_SHAKE128, `KECCAK_MODE_SHAKE256: keccak_suffix = `KECCAK_SUFFIX_SHAKE;
            `KECCAK_MODE_SHA3_256, `KECCAK_MODE_SHA3_512: keccak_suffix = `KECCAK_SUFFIX_SHA3;
            default: keccak_suffix = `KECCAK_SUFFIX_SHAKE;
        endcase
    end
endfunction

// Default output length
function [7:0] keccak_output_bytes;
    input [`KECCAK_MODE_WIDTH-1:0] mode;
    begin
        case (mode)
            `KECCAK_MODE_SHAKE128, `KECCAK_MODE_SHAKE256: keccak_output_bytes = keccak_rate_bytes(mode);
            `KECCAK_MODE_SHA3_256: keccak_output_bytes = `SHA3_256_DIGEST;
            `KECCAK_MODE_SHA3_512: keccak_output_bytes = `SHA3_512_DIGEST;
            default: keccak_output_bytes = keccak_rate_bytes(`KECCAK_MODE_SHAKE256);
        endcase
    end
endfunction

// Check XOF
function keccak_is_xof;
    input [`KECCAK_MODE_WIDTH-1:0] mode;
    keccak_is_xof = (mode == `KECCAK_MODE_SHAKE128) || (mode == `KECCAK_MODE_SHAKE256);
endfunction
