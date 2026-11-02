`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_top_wrapper_avalon #(
    parameter integer AXIS_DATA_WIDTH = 64
)(
    input wire aclk,
    input wire aresetn,

    // Avalon-MM control slave
    input wire [11:0] avs_address,
    input wire avs_read,
    input wire avs_write,
    input wire [31:0] avs_writedata,
    input wire [3:0] avs_byteenable,
    output wire [31:0] avs_readdata,
    output wire avs_waitrequest,

    // Avalon-ST input from DMA MM2S channel
    input wire [AXIS_DATA_WIDTH-1:0] asi_data,
    input wire [$clog2(AXIS_DATA_WIDTH/8)-1:0] asi_empty,
    input wire asi_valid,
    output wire asi_ready,
    input wire asi_startofpacket,
    input wire asi_endofpacket,

    // Avalon-ST output to DMA S2MM channel
    output wire [AXIS_DATA_WIDTH-1:0] aso_data,
    output wire [$clog2(AXIS_DATA_WIDTH/8)-1:0] aso_empty,
    output wire aso_valid,
    input wire aso_ready,
    output wire aso_startofpacket,
    output wire aso_endofpacket,

    // Interrupt
    output wire irq
);

    `include "keccak_funcs.vh"

    // --- Local parameters & address check ---

    // Avalon-ST parameters
    localparam integer AXIS_BYTES = AXIS_DATA_WIDTH / 8;
    localparam integer RATE_WORDS = `KECCAK_RATE_BITS / AXIS_DATA_WIDTH;

    // Avalon-MM register map (byte offsets)
    localparam [11:0] REG_CONTROL       = 12'h000; // [0] START, [1] RESET, [2] CLEAR, [8] IRQ_EN
    localparam [11:0] REG_STATUS        = 12'h004; // [0] BUSY, [1] DONE, [2] ERROR, [5] IRQ, [15:8] CODE
    localparam [11:0] REG_MODE          = 12'h008;
    localparam [11:0] REG_MESSAGE_BYTES = 12'h00C;
    localparam [11:0] REG_OUTPUT_BYTES  = 12'h010;
    localparam [11:0] REG_VERSION       = 12'h014;

    // Avalon-MM responses
    localparam [1:0] RESP_OKAY = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;
    localparam [1:0] RESP_DECERR = 2'b11;

    // Stream adapter FSM states
    localparam [6:0] ST_IDLE    = 7'b0000001;
    localparam [6:0] ST_START   = 7'b0000010;
    localparam [6:0] ST_INPUT   = 7'b0000100;
    localparam [6:0] ST_ABSORB  = 7'b0001000;
    localparam [6:0] ST_OUTPUT  = 7'b0010000;
    localparam [6:0] ST_FINISH  = 7'b0100000;
    localparam [6:0] ST_RECOVER = 7'b1000000;

    // Avalon-MM address decoding check
    function [1:0] address_response(input [11:0] addr, input write_access);
        if (addr[1:0] != 0)
            address_response = RESP_SLVERR; // Unaligned access
        else if (addr > REG_VERSION)
            address_response = RESP_DECERR; // Out-of-range access
        else if (write_access && (addr == REG_STATUS || addr == REG_VERSION))
            address_response = RESP_SLVERR; // Write to read-only register
        else
            address_response = RESP_OKAY;
    endfunction

    // --- Internal signals ---

    // Avalon-MM CSR config (R/W)
    reg [`KECCAK_MODE_WIDTH-1:0] mode_reg;
    reg [31:0] message_bytes_reg, output_bytes_reg;
    reg irq_enable_reg;

    // Avalon-MM CSR status
    reg done_reg, error_reg;
    reg [7:0] error_code_reg;

    // Avalon-MM write & read access
    wire [11:0] write_addr_reg;
    wire write_commit, write_ok;
    wire [1:0] write_response;
    wire [31:0] write_mask;
    reg [31:0] read_data;

    // Avalon-MM control pulses
    wire control_write, reset_request, start_request, clear_request;

    // Avalon-ST input & output beat signals
    reg [31:0] input_bytes;
    reg [7:0] input_error;
    wire last_beat, block_full, last_output, last_word;
    wire [31:0] beat_bytes;
    integer lane;
    wire [AXIS_BYTES-1:0] input_keep;
    wire [31:0] output_empty;
    reg output_first_reg;

    // Stream adapter registers (DMA <-> keccak core)
    reg [6:0] state_reg;
    reg core_error_reg;
    reg [7:0] core_error_code_reg;
    reg [`KECCAK_MODE_WIDTH-1:0] run_mode_reg;
    reg [31:0] message_left_reg, output_left_reg;
    reg [`KECCAK_RATE_BITS-1:0] block_buffer_reg;
    reg [7:0] block_bytes_reg;
    reg [5:0] word_index_reg;
    reg last_block_reg, block_buffer_valid_reg, sponge_done_seen_reg;
    integer word;

    // Registered resets (soft reset, core reset)
    reg soft_reset_reg, core_rst_n_reg;

    // Start check (Avalon-MM -> stream adapter)
    wire busy, core_start;
    wire [31:0] output_length;
    wire [7:0] start_error;

    // Keccak core interface (keccak core <-> stream adapter)
    wire [`KECCAK_RATE_BITS-1:0] squeeze_data;
    wire [7:0] squeeze_bytes;
    wire absorb_ready, squeeze_valid, sponge_done, squeeze_ready, core_done;

    // --- Avalon-MM control slave ---

    // Avalon-MM handshakes
    assign write_addr_reg = avs_address;
    assign write_commit = avs_write && !avs_waitrequest;
    assign write_response = address_response(write_addr_reg, 1'b1);
    assign write_ok = write_commit && (write_response == RESP_OKAY);
    assign write_mask = {{8{avs_byteenable[3]}}, {8{avs_byteenable[2]}}, {8{avs_byteenable[1]}}, {8{avs_byteenable[0]}}};
    assign avs_waitrequest = 1'b0;
    assign avs_readdata = avs_read ? read_data : 32'd0;

    // Avalon-MM control pulses
    assign control_write = write_ok && (write_addr_reg == REG_CONTROL) && avs_byteenable[0];
    assign reset_request = control_write && avs_writedata[1];
    assign start_request = control_write && avs_writedata[0] && !reset_request;
    assign clear_request = control_write && avs_writedata[2];

    // Avalon-MM interrupt
    assign irq = irq_enable_reg && (done_reg || error_reg);

    // Avalon-MM read mux
    always @(*) begin
        read_data = 32'd0;
        case (avs_address)
            REG_CONTROL: read_data[8] = irq_enable_reg;
            REG_STATUS: read_data = {16'd0, error_code_reg, 2'b00, irq, 2'b00, error_reg, done_reg, busy};
            REG_MODE: read_data[`KECCAK_MODE_WIDTH-1:0] = mode_reg;
            REG_MESSAGE_BYTES: read_data = message_bytes_reg;
            REG_OUTPUT_BYTES: read_data = output_bytes_reg;
            REG_VERSION: read_data = 32'h4b534c31;
            default: read_data = 32'd0;
        endcase
    end

    // Avalon-MM CSR config write
    always @(posedge aclk) begin
        if (!aresetn) begin
            mode_reg <= `KECCAK_MODE_SHAKE256;
            message_bytes_reg <= 32'd0;
            output_bytes_reg <= 32'd0;
            irq_enable_reg <= 1'b0;
        end else if (write_ok) begin
            case (write_addr_reg)
                REG_CONTROL: if (avs_byteenable[1]) irq_enable_reg <= avs_writedata[8];
                REG_MODE: if (avs_byteenable[0]) mode_reg <= avs_writedata[`KECCAK_MODE_WIDTH-1:0];
                REG_MESSAGE_BYTES: message_bytes_reg <= (message_bytes_reg & ~write_mask) | (avs_writedata & write_mask);
                REG_OUTPUT_BYTES: output_bytes_reg <= (output_bytes_reg & ~write_mask) | (avs_writedata & write_mask);
                default: ;
            endcase
        end
    end

    // Avalon-MM CSR status update
    always @(posedge aclk) begin
        if (!aresetn || soft_reset_reg || core_start) begin
            done_reg <= 1'b0;
            error_reg <= 1'b0;
            error_code_reg <= 8'h00;
        end else begin
            if (core_done)
                done_reg <= 1'b1;
            else if (clear_request)
                done_reg <= 1'b0;

            if (core_error_reg) begin
                error_reg <= 1'b1;
                error_code_reg <= core_error_code_reg;
            end else if (start_request && (start_error != 0)) begin
                error_reg <= 1'b1;
                error_code_reg <= start_error;
            end else if (clear_request) begin
                error_reg <= 1'b0;
                error_code_reg <= 8'h00;
            end
        end
    end

    // --- Avalon-ST DMA interface ---

    // Avalon-ST input: count valid bytes from empty
    assign input_keep = {AXIS_BYTES{1'b1}} >> (asi_endofpacket ? asi_empty : 0);

    always @(*) begin
        input_bytes = 0;
        for (lane = 0; lane < AXIS_BYTES; lane = lane + 1)
            input_bytes = input_bytes + {31'd0, input_keep[lane]};
        if (input_keep != ({AXIS_BYTES{1'b1}} >> (AXIS_BYTES - input_bytes)))
            input_bytes = 0;
    end

    // Avalon-ST input beat flags (last beat, block full)
    assign last_beat = (message_left_reg == input_bytes);
    assign block_full = (block_bytes_reg + input_bytes[7:0] == keccak_rate_bytes(run_mode_reg));

    // Avalon-ST input protocol error checking
    always @(*) begin
        input_error = 8'h00;
        if (input_bytes == 0 || (input_keep != {AXIS_BYTES{1'b1}} && message_left_reg > input_bytes))
            input_error = 8'h03; // bad empty
        else if (input_bytes > message_left_reg)
            input_error = 8'h06; // beyond message
        else if (asi_endofpacket && !last_beat)
            input_error = 8'h04; // early EOP
        else if (!asi_endofpacket && last_beat)
            input_error = 8'h05; // missing EOP
    end

    // Avalon-ST output beat size & last flags
    assign last_output = (output_left_reg <= AXIS_BYTES);
    assign beat_bytes = last_output ? output_left_reg : AXIS_BYTES;
    assign last_word = ({2'b00, word_index_reg} * AXIS_BYTES[7:0] + AXIS_BYTES[7:0] >= squeeze_bytes);

    // Avalon-ST handshake & output data
    assign asi_ready = (state_reg == ST_INPUT);
    assign aso_valid = (state_reg == ST_OUTPUT) && (block_buffer_valid_reg || squeeze_valid);
    assign aso_data = block_buffer_valid_reg ? block_buffer_reg[word_index_reg*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] : squeeze_data[word_index_reg*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH];
    assign output_empty = AXIS_BYTES - beat_bytes;
    assign aso_empty = last_output ? output_empty[$clog2(AXIS_BYTES)-1:0] : {$clog2(AXIS_BYTES){1'b0}};
    assign aso_startofpacket = aso_valid && output_first_reg;
    assign aso_endofpacket = aso_valid && last_output;

    always @(posedge aclk) begin
        if (!aresetn || soft_reset_reg || core_start)
            output_first_reg <= 1'b1;
        else if (aso_valid && aso_ready)
            output_first_reg <= aso_endofpacket;
    end

    // --- Stream adapter & keccak core ---

    // Start check (Avalon-MM -> stream adapter)
    assign busy = (state_reg != ST_IDLE && state_reg != ST_RECOVER) || core_error_reg;
    assign output_length = (mode_reg == `KECCAK_MODE_SHA3_256) ? 32'd32 : (mode_reg == `KECCAK_MODE_SHA3_512) ? 32'd64 : output_bytes_reg;
    assign start_error = busy ? 8'h01 : (output_length == 0) ? 8'h02 : 8'h00; // 01: busy, 02: zero output length
    assign core_start = start_request && (start_error == 0);

    // Keccak core interface
    assign squeeze_ready = (state_reg == ST_OUTPUT) && !block_buffer_valid_reg;
    assign core_done = (state_reg == ST_FINISH) && (sponge_done || sponge_done_seen_reg);

    // Registered resets
    always @(posedge aclk) begin
        soft_reset_reg <= reset_request;
        core_rst_n_reg <= aresetn && !reset_request && (state_reg != ST_RECOVER);
    end

    keccak_top u_keccak (
        .clk(aclk),
        .rst_n(core_rst_n_reg),
        .mode(run_mode_reg),
        .absorb_valid(state_reg == ST_ABSORB),
        .absorb_ready(absorb_ready),
        .absorb_last(last_block_reg),
        .msg_block_in(block_buffer_reg),
        .msg_len_bytes(block_bytes_reg),
        .squeeze_ready(squeeze_ready),
        .squeeze_last(output_left_reg <= {24'd0, squeeze_bytes}),
        .squeeze_valid(squeeze_valid),
        .squeeze_out(squeeze_data),
        .squeeze_bytes(squeeze_bytes),
        .start(state_reg == ST_START),
        .done(sponge_done)
    );

    // Stream adapter FSM
    always @(posedge aclk) begin
        if (!aresetn || soft_reset_reg) begin
            state_reg <= ST_IDLE;
            output_left_reg <= 32'd0;
            word_index_reg <= 6'd0;
            block_buffer_valid_reg <= 1'b0;
            sponge_done_seen_reg <= 1'b0;
            core_error_reg <= 1'b0;
            core_error_code_reg <= 8'h00;
        end else begin
            core_error_reg <= 1'b0;
            if (sponge_done)
                sponge_done_seen_reg <= 1'b1;
            case (state_reg)
                ST_IDLE: begin
                    message_left_reg <= message_bytes_reg;
                    output_left_reg <= output_length;
                    block_bytes_reg <= 8'd0;
                    word_index_reg <= 6'd0;
                    last_block_reg <= 1'b0;
                    block_buffer_valid_reg <= 1'b0;
                    sponge_done_seen_reg <= 1'b0;
                    if (core_start) begin
                        run_mode_reg <= mode_reg;
                        state_reg <= ST_START;
                    end
                end
                ST_START: begin
                    last_block_reg <= (message_left_reg == 0);
                    state_reg <= (message_left_reg == 0) ? ST_ABSORB : ST_INPUT;
                end
                ST_INPUT: if (asi_valid && asi_ready) begin
                    for (word = 0; word < RATE_WORDS; word = word + 1)
                        if ({24'd0, block_bytes_reg} == word * AXIS_BYTES)
                            block_buffer_reg[word*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] <= asi_data;
                    if (input_error != 0) begin
                        core_error_code_reg <= input_error;
                        core_error_reg <= 1'b1;
                        state_reg <= ST_RECOVER;
                    end else begin
                        message_left_reg <= message_left_reg - input_bytes;
                        block_bytes_reg <= block_bytes_reg + input_bytes[7:0];
                        last_block_reg <= last_beat && !block_full;
                        if (block_full || last_beat)
                            state_reg <= ST_ABSORB;
                    end
                end
                ST_ABSORB: if (absorb_ready) begin
                    block_bytes_reg <= 8'd0;
                    last_block_reg <= (message_left_reg == 0);
                    state_reg <= last_block_reg ? ST_OUTPUT : (message_left_reg == 0) ? ST_ABSORB : ST_INPUT;
                end
                ST_OUTPUT: begin
                    if (squeeze_valid && squeeze_ready) begin
                        block_buffer_reg <= squeeze_data;
                        block_buffer_valid_reg <= 1'b1;
                    end
                    if (aso_valid && aso_ready) begin
                        output_left_reg <= output_left_reg - beat_bytes;
                        word_index_reg <= (last_output || last_word) ? 6'd0 : word_index_reg + 6'd1;
                        if (last_output || last_word)
                            block_buffer_valid_reg <= 1'b0;
                        if (last_output)
                            state_reg <= ST_FINISH;
                    end
                end
                ST_FINISH: if (core_done)
                    state_reg <= ST_IDLE;
                ST_RECOVER: state_reg <= ST_IDLE;
                default: begin
                    core_error_code_reg <= 8'h07;
                    core_error_reg <= 1'b1;
                    state_reg <= ST_RECOVER;
                end
            endcase
        end
    end

endmodule
