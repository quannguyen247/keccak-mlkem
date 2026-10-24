`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_top_axi4stream_wrapper #(
    parameter integer AXIS_DATA_WIDTH = 32
)(
    input wire aclk,
    input wire aresetn,

    // AXI4-Lite control slave write channels (AW, W, B)
    input wire [11:0] s_axi_ctrl_awaddr,
    input wire [2:0] s_axi_ctrl_awprot,
    input wire s_axi_ctrl_awvalid,
    output wire s_axi_ctrl_awready,
    input wire [31:0] s_axi_ctrl_wdata,
    input wire [3:0] s_axi_ctrl_wstrb,
    input wire s_axi_ctrl_wvalid,
    output wire s_axi_ctrl_wready,
    output reg [1:0] s_axi_ctrl_bresp,
    output reg s_axi_ctrl_bvalid,
    input wire s_axi_ctrl_bready,

    // AXI4-Lite control slave read channels (AR, R)
    input wire [11:0] s_axi_ctrl_araddr,
    input wire [2:0] s_axi_ctrl_arprot,
    input wire s_axi_ctrl_arvalid,
    output wire s_axi_ctrl_arready,
    output reg [31:0] s_axi_ctrl_rdata,
    output reg [1:0] s_axi_ctrl_rresp,
    output reg s_axi_ctrl_rvalid,
    input wire s_axi_ctrl_rready,

    // AXI4-Stream input from DMA MM2S
    input wire [AXIS_DATA_WIDTH-1:0] s_axis_dma_tdata,
    input wire [(AXIS_DATA_WIDTH/8)-1:0] s_axis_dma_tkeep,
    input wire s_axis_dma_tvalid,
    output wire s_axis_dma_tready,
    input wire s_axis_dma_tlast,

    // AXI4-Stream output to DMA S2MM
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_dma_tdata,
    output wire [(AXIS_DATA_WIDTH/8)-1:0] m_axis_dma_tkeep,
    output wire m_axis_dma_tvalid,
    input wire m_axis_dma_tready,
    output wire m_axis_dma_tlast,
    output wire irq
);

    // Register map (32-bit words)
    localparam [9:0] REG_CONTROL       = 10'd0; // [0] START, [1] RESET, [2] CLEAR, [8] IRQ_EN
    localparam [9:0] REG_STATUS        = 10'd1; // [0] BUSY, [1] DONE, [2] ERROR, [5] IRQ, [15:8] CODE
    localparam [9:0] REG_MODE          = 10'd2;
    localparam [9:0] REG_MESSAGE_BYTES = 10'd3;
    localparam [9:0] REG_OUTPUT_BYTES  = 10'd4;
    localparam [9:0] REG_VERSION       = 10'd5;

    // AXI4-Lite responses
    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;
    localparam [1:0] RESP_DECERR = 2'b11;

    // AXI4-Lite address decoding check
    function [1:0] address_response(input [11:0] addr, input write_access);
        if (addr[1:0] != 0)
            address_response = RESP_SLVERR; // Unaligned access
        else if (addr[11:2] > REG_VERSION)
            address_response = RESP_DECERR; // Out-of-range access
        else if (write_access && (addr[11:2] == REG_STATUS || addr[11:2] == REG_VERSION))
            address_response = RESP_SLVERR; // Write to read-only register
        else
            address_response = RESP_OKAY;
    endfunction

    // AXI4-Lite transaction control
    reg write_active;
    reg [11:0] write_addr;
    reg [31:0] read_data;
    wire write_commit = s_axi_ctrl_wvalid && s_axi_ctrl_wready;
    wire [1:0] write_response = address_response(write_addr, 1'b1);
    wire write_ok = write_commit && (write_response == RESP_OKAY);
    wire [31:0] write_mask = {{8{s_axi_ctrl_wstrb[3]}}, {8{s_axi_ctrl_wstrb[2]}}, {8{s_axi_ctrl_wstrb[1]}}, {8{s_axi_ctrl_wstrb[0]}}};

    // Control & status registers (CSR)
    reg [`KECCAK_MODE_WIDTH-1:0] mode_reg;
    reg [31:0] message_bytes_reg, output_bytes_reg;
    reg irq_enable_reg, done_reg, error_reg;
    reg [7:0] error_code_reg;
    wire control_write = write_ok && (write_addr[11:2] == REG_CONTROL) && s_axi_ctrl_wstrb[0];
    wire reset_request = control_write && s_axi_ctrl_wdata[1];
    wire start_request = control_write && s_axi_ctrl_wdata[0] && !reset_request;
    wire clear_request = control_write && s_axi_ctrl_wdata[2];

    // Stream core control
    wire core_busy, core_done, core_error;
    wire [7:0] core_error_code;
    wire busy = core_busy || core_error;
    wire [31:0] output_length = (mode_reg == `KECCAK_MODE_SHA3_256) ? 32'd32 : (mode_reg == `KECCAK_MODE_SHA3_512) ? 32'd64 : output_bytes_reg;
    wire [7:0] start_error = busy ? 8'h01 : (output_length == 0) ? 8'h02 : 8'h00;
    wire core_start = start_request && (start_error == 0);

    // AXI4-Lite handshake control & IRQ
    assign s_axi_ctrl_awready = !write_active && !s_axi_ctrl_bvalid;
    assign s_axi_ctrl_wready = write_active;
    assign s_axi_ctrl_arready = !s_axi_ctrl_rvalid;
    assign irq = irq_enable_reg && (done_reg || error_reg);

    keccak_top_axi4stream #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) u_stream (
        .clk(aclk),
        .rst_n(aresetn),
        .cfg_start(core_start),
        .cfg_reset(reset_request),
        .cfg_mode(mode_reg),
        .cfg_message_bytes(message_bytes_reg),
        .cfg_output_bytes(output_length),
        .busy(core_busy),
        .done_pulse(core_done),
        .error_pulse(core_error),
        .error_code(core_error_code),
        .s_axis_tdata(s_axis_dma_tdata),
        .s_axis_tkeep(s_axis_dma_tkeep),
        .s_axis_tvalid(s_axis_dma_tvalid),
        .s_axis_tready(s_axis_dma_tready),
        .s_axis_tlast(s_axis_dma_tlast),
        .m_axis_tdata(m_axis_dma_tdata),
        .m_axis_tkeep(m_axis_dma_tkeep),
        .m_axis_tvalid(m_axis_dma_tvalid),
        .m_axis_tready(m_axis_dma_tready),
        .m_axis_tlast(m_axis_dma_tlast)
    );

    // AXI4-Lite write channel handshake & response
    always @(posedge aclk) begin
        if (!aresetn) begin
            write_active <= 1'b0;
            s_axi_ctrl_bvalid <= 1'b0;
        end else begin
            if (s_axi_ctrl_awvalid && s_axi_ctrl_awready) begin
                write_active <= 1'b1;
                write_addr <= s_axi_ctrl_awaddr;
            end
            if (write_commit) begin
                write_active <= 1'b0;
                s_axi_ctrl_bresp <= write_response;
                s_axi_ctrl_bvalid <= 1'b1;
            end
            if (s_axi_ctrl_bvalid && s_axi_ctrl_bready)
                s_axi_ctrl_bvalid <= 1'b0;
        end
    end

    // AXI4-Lite read channel handshake & response
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_ctrl_rvalid <= 1'b0;
        end else begin
            if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
                s_axi_ctrl_rdata <= read_data;
                s_axi_ctrl_rresp <= address_response(s_axi_ctrl_araddr, 1'b0);
                s_axi_ctrl_rvalid <= 1'b1;
            end else if (s_axi_ctrl_rvalid && s_axi_ctrl_rready) begin
                s_axi_ctrl_rvalid <= 1'b0;
            end
        end
    end

    // Config registers
    always @(posedge aclk) begin
        if (!aresetn) begin
            mode_reg <= `KECCAK_MODE_SHAKE256;
            message_bytes_reg <= 32'd0;
            output_bytes_reg <= 32'd0;
            irq_enable_reg <= 1'b0;
        end else if (write_ok) begin
            case (write_addr[11:2])
                REG_CONTROL: if (s_axi_ctrl_wstrb[1]) irq_enable_reg <= s_axi_ctrl_wdata[8];
                REG_MODE: if (s_axi_ctrl_wstrb[0]) mode_reg <= s_axi_ctrl_wdata[`KECCAK_MODE_WIDTH-1:0];
                REG_MESSAGE_BYTES: message_bytes_reg <= (message_bytes_reg & ~write_mask) | (s_axi_ctrl_wdata & write_mask);
                REG_OUTPUT_BYTES: output_bytes_reg <= (output_bytes_reg & ~write_mask) | (s_axi_ctrl_wdata & write_mask);
            endcase
        end
    end

    // Status register update
    always @(posedge aclk) begin
        if (!aresetn || reset_request || core_start) begin
            done_reg <= 1'b0;
            error_reg <= 1'b0;
            error_code_reg <= 8'h00;
        end else begin
            if (clear_request) begin
                done_reg <= 1'b0;
                error_reg <= 1'b0;
                error_code_reg <= 8'h00;
            end
            if (core_done)
                done_reg <= 1'b1;
            if (start_request && (start_error != 0)) begin
                error_reg <= 1'b1;
                error_code_reg <= start_error;
            end
            if (core_error) begin
                error_reg <= 1'b1;
                error_code_reg <= core_error_code;
            end
        end
    end

    // Read registers
    always @(*) begin
        read_data = 32'd0;
        case (s_axi_ctrl_araddr[11:2])
            REG_CONTROL: read_data[8] = irq_enable_reg;
            REG_STATUS: begin
                read_data[0]    = busy;
                read_data[1]    = done_reg;
                read_data[2]    = error_reg;
                read_data[5]    = irq;
                read_data[15:8] = error_code_reg;
            end
            REG_MODE: read_data[`KECCAK_MODE_WIDTH-1:0] = mode_reg;
            REG_MESSAGE_BYTES: read_data = message_bytes_reg;
            REG_OUTPUT_BYTES: read_data = output_bytes_reg;
            REG_VERSION: read_data = 32'h4b534c31;
            default: read_data = 32'd0;
        endcase
    end

endmodule