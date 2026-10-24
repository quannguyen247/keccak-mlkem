`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_top_axi4stream #(
    parameter integer AXIS_DATA_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,

    // Control & configuration
    input wire cfg_start,
    input wire cfg_reset,
    input wire [`KECCAK_MODE_WIDTH-1:0] cfg_mode,
    input wire [31:0] cfg_message_bytes,
    input wire [31:0] cfg_output_bytes,

    // Status
    output wire busy,
    output reg done_pulse,
    output reg error_pulse,
    output reg [7:0] error_code,

    // AXI4-Stream Slave (Input)
    input wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input wire [(AXIS_DATA_WIDTH/8)-1:0] s_axis_tkeep,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire s_axis_tlast,

    // AXI4-Stream Master (Output)
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [(AXIS_DATA_WIDTH/8)-1:0] m_axis_tkeep,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast
);

    `include "keccak_funcs.vh"

    localparam integer AXIS_BYTES = AXIS_DATA_WIDTH / 8;
    localparam integer RATE_WORDS = `KECCAK_RATE_BITS / AXIS_DATA_WIDTH;

    localparam [7:0] ST_IDLE    = 8'b00000001;
    localparam [7:0] ST_START   = 8'b00000010;
    localparam [7:0] ST_INPUT   = 8'b00000100;
    localparam [7:0] ST_PAD     = 8'b00001000;
    localparam [7:0] ST_ABSORB  = 8'b00010000;
    localparam [7:0] ST_OUTPUT  = 8'b00100000;
    localparam [7:0] ST_FINISH  = 8'b01000000;
    localparam [7:0] ST_RECOVER = 8'b10000000;

    // FSM & internal registers
    reg [7:0] state;
    reg [`KECCAK_MODE_WIDTH-1:0] mode_reg;
    reg [31:0] message_left;
    reg [31:0] output_left;
    reg [`KECCAK_RATE_BITS-1:0] block_buffer;
    reg [7:0] block_bytes;
    reg [5:0] word_index;
    reg last_block;
    reg block_buffer_valid;
    reg sponge_done_seen;
    reg [31:0] input_bytes;
    reg [AXIS_DATA_WIDTH-1:0] input_word;
    reg [7:0] input_error;
    integer lane, word;

    // Sponge interface
    wire [`KECCAK_RATE_BITS-1:0] padding;
    wire [`KECCAK_RATE_BITS-1:0] squeeze_data;
    wire [7:0] squeeze_bytes;
    wire absorb_ready;
    wire squeeze_valid;
    wire squeeze_ready = (state == ST_OUTPUT) && !block_buffer_valid;
    wire sponge_done;

    // Input beat
    wire [7:0] rate_bytes = keccak_rate_bytes(mode_reg);
    wire last_beat = (message_left == input_bytes);
    wire block_full = (block_bytes + input_bytes[7:0] == rate_bytes);

    // Output beat
    wire last_output = (output_left <= AXIS_BYTES);
    wire [31:0] output_bytes = last_output ? {28'd0, output_left[3:0]} : AXIS_BYTES;
    wire [7:0] output_offset = {2'b00, word_index} * AXIS_BYTES[7:0];
    wire last_word = (output_offset + AXIS_BYTES[7:0] >= squeeze_bytes);

    // Status & AXI4-Stream output logic
    assign busy = (state != ST_IDLE) && (state != ST_RECOVER);
    assign s_axis_tready = (state == ST_INPUT);
    assign m_axis_tvalid = (state == ST_OUTPUT) && (block_buffer_valid || squeeze_valid);
    assign m_axis_tdata = block_buffer_valid ? block_buffer[word_index*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] : squeeze_data[word_index*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH];
    assign m_axis_tkeep = {AXIS_BYTES{1'b1}} >> (AXIS_BYTES - output_bytes);
    assign m_axis_tlast = m_axis_tvalid && last_output;

    // Decode TKEEP to input bytes & mask invalid byte lanes
    always @(*) begin
        case (s_axis_tkeep)
            8'h01: input_bytes = 1;
            8'h03: input_bytes = 2;
            8'h07: input_bytes = 3;
            8'h0f: input_bytes = 4;
            8'h1f: input_bytes = 5;
            8'h3f: input_bytes = 6;
            8'h7f: input_bytes = 7;
            8'hff: input_bytes = 8;
            default: input_bytes = 0;
        endcase
        for (lane = 0; lane < AXIS_BYTES; lane = lane + 1)
            input_word[lane*8 +: 8] = s_axis_tdata[lane*8 +: 8] & {8{s_axis_tkeep[lane]}};
    end

    // AXI4-Stream input protocol error checking
    always @(*) begin
        input_error = 8'h00;
        if (input_bytes == 0 || (s_axis_tkeep != {AXIS_BYTES{1'b1}} && message_left > input_bytes))
            input_error = 8'h03; // bad TKEEP
        else if (input_bytes > message_left)
            input_error = 8'h06; // beyond message
        else if (s_axis_tlast && !last_beat)
            input_error = 8'h04; // early TLAST
        else if (!s_axis_tlast && last_beat)
            input_error = 8'h05; // missing TLAST
    end

    keccak_pad_block u_pad (
        .mode(mode_reg),
        .msg_block_in({`KECCAK_RATE_BITS{1'b0}}),
        .msg_len_bytes(block_bytes),
        .pad_block0_out(padding),
        .pad_block1_out(),
        .need_block2()
    );

    keccak_sponge u_sponge (
        .clk(clk),
        .rst_n(rst_n && !cfg_reset && (state != ST_RECOVER)),
        .mode(mode_reg),
        .absorb_valid(state == ST_ABSORB),
        .absorb_last(last_block),
        .absorb_in(block_buffer),
        .absorb_ready(absorb_ready),
        .squeeze_ready(squeeze_ready),
        .squeeze_last(output_left <= {24'd0, squeeze_bytes}),
        .squeeze_valid(squeeze_valid),
        .squeeze_out(squeeze_data),
        .squeeze_bytes(squeeze_bytes),
        .start(state == ST_START),
        .done(sponge_done),
        .output_blocks(32'd0)
    );

    always @(posedge clk) begin
        if (!rst_n || cfg_reset) begin
            state <= ST_IDLE;
            output_left <= 32'd0;
            word_index <= 6'd0;
            block_buffer_valid <= 1'b0;
            sponge_done_seen <= 1'b0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
            error_code <= 8'h00;
        end else begin
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
            if (sponge_done)
                sponge_done_seen <= 1'b1;
            case (state)
                ST_IDLE: begin
                    if (cfg_start) begin
                        mode_reg <= cfg_mode;
                        message_left <= cfg_message_bytes;
                        output_left <= cfg_output_bytes;
                        block_buffer <= {`KECCAK_RATE_BITS{1'b0}};
                        block_bytes <= 8'd0;
                        word_index <= 6'd0;
                        last_block <= 1'b0;
                        block_buffer_valid <= 1'b0;
                        sponge_done_seen <= 1'b0;
                        state <= ST_START;
                    end
                end
                ST_START: state <= (message_left == 0) ? ST_PAD : ST_INPUT;
                ST_INPUT: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (input_error != 0) begin
                            error_code <= input_error;
                            error_pulse <= 1'b1;
                            state <= ST_RECOVER;
                        end else begin
                            for (word = 0; word < RATE_WORDS; word = word + 1) begin
                                if (block_bytes == word * AXIS_BYTES)
                                    block_buffer[word*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] <= input_word;
                            end
                            message_left <= message_left - input_bytes;
                            block_bytes <= block_bytes + input_bytes[7:0];
                            if (block_full)
                                state <= ST_ABSORB;
                            else if (last_beat)
                                state <= ST_PAD;
                        end
                    end
                end
                ST_PAD: begin
                    block_buffer <= block_buffer | padding;
                    last_block <= 1'b1;
                    state <= ST_ABSORB;
                end
                ST_ABSORB: begin
                    if (absorb_ready) begin
                        block_buffer <= {`KECCAK_RATE_BITS{1'b0}};
                        block_bytes <= 8'd0;
                        if (last_block)
                            state <= ST_OUTPUT;
                        else if (message_left == 0)
                            state <= ST_PAD;
                        else
                            state <= ST_INPUT;
                    end
                end
                ST_OUTPUT: begin
                    if (squeeze_valid && squeeze_ready) begin
                        block_buffer <= squeeze_data;
                        block_buffer_valid <= 1'b1;
                    end
                    if (m_axis_tvalid && m_axis_tready) begin
                        output_left <= output_left - output_bytes;
                        if (last_output) begin
                            block_buffer_valid <= 1'b0;
                            state <= ST_FINISH;
                        end else if (last_word) begin
                            block_buffer_valid <= 1'b0;
                            word_index <= 6'd0;
                        end else begin
                            word_index <= word_index + 6'd1;
                        end
                    end
                end
                ST_FINISH: begin
                    if (sponge_done || sponge_done_seen) begin
                        done_pulse <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
                ST_RECOVER: state <= ST_IDLE;
                default: begin
                    error_code <= 8'h06;
                    error_pulse <= 1'b1;
                    state <= ST_RECOVER;
                end
            endcase
        end
    end

endmodule