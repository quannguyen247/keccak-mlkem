`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_top_axi4 #(
    parameter integer AXIS_DATA_WIDTH = 32,
    parameter integer AXI_ID_WIDTH = 16
)(
    input wire aclk,
    input wire aresetn,

    // AXI4 control slave write channels (AW, W, B)
    input wire [AXI_ID_WIDTH-1:0] s_axi_ctrl_awid,
    input wire [11:0] s_axi_ctrl_awaddr,
    input wire [7:0] s_axi_ctrl_awlen,
    input wire [2:0] s_axi_ctrl_awsize,
    input wire [1:0] s_axi_ctrl_awburst,
    input wire s_axi_ctrl_awlock,
    input wire s_axi_ctrl_awvalid,
    output wire s_axi_ctrl_awready,
    input wire [31:0] s_axi_ctrl_wdata,
    input wire [3:0] s_axi_ctrl_wstrb,
    input wire s_axi_ctrl_wlast,
    input wire s_axi_ctrl_wvalid,
    output wire s_axi_ctrl_wready,
    output reg [AXI_ID_WIDTH-1:0] s_axi_ctrl_bid,
    output reg [1:0] s_axi_ctrl_bresp,
    output reg s_axi_ctrl_bvalid,
    input wire s_axi_ctrl_bready,

    // AXI4 control slave read channels (AR, R)
    input wire [AXI_ID_WIDTH-1:0] s_axi_ctrl_arid,
    input wire [11:0] s_axi_ctrl_araddr,
    input wire [7:0] s_axi_ctrl_arlen,
    input wire [2:0] s_axi_ctrl_arsize,
    input wire [1:0] s_axi_ctrl_arburst,
    input wire s_axi_ctrl_arlock,
    input wire s_axi_ctrl_arvalid,
    output wire s_axi_ctrl_arready,
    output reg [AXI_ID_WIDTH-1:0] s_axi_ctrl_rid,
    output reg [31:0] s_axi_ctrl_rdata,
    output reg [1:0] s_axi_ctrl_rresp,
    output reg s_axi_ctrl_rlast,
    output reg s_axi_ctrl_rvalid,
    input wire s_axi_ctrl_rready,

    // AXI4-Stream payload from/to DataMover
    input wire [AXIS_DATA_WIDTH-1:0] s_axis_dma_tdata,
    input wire [(AXIS_DATA_WIDTH/8)-1:0] s_axis_dma_tkeep,
    input wire s_axis_dma_tvalid,
    output wire s_axis_dma_tready,
    input wire s_axis_dma_tlast,
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_dma_tdata,
    output wire [(AXIS_DATA_WIDTH/8)-1:0] m_axis_dma_tkeep,
    output wire m_axis_dma_tvalid,
    input wire m_axis_dma_tready,
    output wire m_axis_dma_tlast,

    // DataMover command/status interface
    output reg [71:0] m_axis_mm2s_cmd_tdata,
    output wire m_axis_mm2s_cmd_tvalid,
    input wire m_axis_mm2s_cmd_tready,
    input wire [7:0] s_axis_mm2s_sts_tdata,
    input wire s_axis_mm2s_sts_tvalid,
    output wire s_axis_mm2s_sts_tready,
    output reg [71:0] m_axis_s2mm_cmd_tdata,
    output wire m_axis_s2mm_cmd_tvalid,
    input wire m_axis_s2mm_cmd_tready,
    input wire [7:0] s_axis_s2mm_sts_tdata,
    input wire s_axis_s2mm_sts_tvalid,
    output wire s_axis_s2mm_sts_tready,

    // DataMover control signals & IRQ
    output wire dma_halt,
    input wire mm2s_halt_complete,
    input wire s2mm_halt_complete,
    output wire dma_aresetn,
    output wire irq
);

    // Register map
    localparam [9:0] REG_CONTROL       = 10'd0;
    localparam [9:0] REG_STATUS        = 10'd1;
    localparam [9:0] REG_MODE          = 10'd2;
    localparam [9:0] REG_MESSAGE_BYTES = 10'd3;
    localparam [9:0] REG_OUTPUT_BYTES  = 10'd4;
    localparam [9:0] REG_SOURCE        = 10'd5;
    localparam [9:0] REG_DESTINATION   = 10'd6;
    localparam [9:0] REG_VERSION       = 10'd7;
    
    // AXI4 burst types & responses
    localparam [1:0] BURST_FIXED = 2'b00;
    localparam [1:0] BURST_INCR  = 2'b01;
    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;
    localparam [1:0] RESP_DECERR = 2'b11;

    // Address decoder check
    function [1:0] decode_error(input [9:0] reg_addr);
        decode_error = (reg_addr <= REG_VERSION) ? RESP_OKAY : RESP_DECERR;
    endfunction
    
    // AXI4 burst rule validation
    function [1:0] burst_error(input [11:0] addr, input [7:0] len, input [2:0] size, input [1:0] burst, input lock);
        if (addr[1:0] != 0 || size != 3'd2 || burst[1] || lock)
            burst_error = RESP_SLVERR; // Wrong alignment, size, burst type, or atomic lock
        else if (burst == BURST_FIXED && len > 15)
            burst_error = RESP_SLVERR; // Fixed burst length exceeds 16 beats
        else if (burst == BURST_INCR && {1'b0, addr} + {3'd0, len, 2'd0} > 13'hffc)
            burst_error = RESP_SLVERR; // Incrementing burst crosses 4KB boundary
        else
            burst_error = decode_error(addr[11:2]);
    endfunction

    // Pack 72-bit DataMover command
    function [71:0] datamover_cmd(input [3:0] tag, input [31:0] addr, input [22:0] btt);
        datamover_cmd = {
            4'd0,   // [71:68] Reserved
            tag,    // [67:64] Command tag 
            addr,   // [63:32] Buffer start address
            1'b1,   // [31]    DRR (Data Realignment Request enabled)
            1'b1,   // [30]    EOF (End of Frame enabled)
            6'd0,   // [29:24] DSA (Data Stream Alignment offset)
            1'b1,   // [23]    Type: 1 = INCR burst, 0 = FIXED
            btt     // [22:0]  Bytes to transfer (max 8MB)
        };
    endfunction

    // AXI4 slave transaction control
    reg write_active, read_active, write_incr, read_incr;
    reg [11:0] write_addr, read_addr;
    reg [7:0] write_left, read_left;
    reg [1:0] write_error, read_error;
    reg [31:0] read_data;
    wire [1:0] aw_error = burst_error(s_axi_ctrl_awaddr, s_axi_ctrl_awlen, s_axi_ctrl_awsize, s_axi_ctrl_awburst, s_axi_ctrl_awlock);
    wire [1:0] ar_error = burst_error(s_axi_ctrl_araddr, s_axi_ctrl_arlen, s_axi_ctrl_arsize, s_axi_ctrl_arburst, s_axi_ctrl_arlock);
    wire write_commit = write_active && s_axi_ctrl_wvalid && s_axi_ctrl_wready;
    wire wlast_error = (s_axi_ctrl_wlast != (write_left == 0));
    wire [1:0] write_response = (write_error != RESP_OKAY) ? write_error : wlast_error ? RESP_SLVERR : decode_error(write_addr[11:2]);
    wire write_ok = write_commit && (write_response == RESP_OKAY);
    wire [31:0] write_mask = {{8{s_axi_ctrl_wstrb[3]}}, {8{s_axi_ctrl_wstrb[2]}}, {8{s_axi_ctrl_wstrb[1]}}, {8{s_axi_ctrl_wstrb[0]}}};

    // Control & status registers (CSR)
    reg [`KECCAK_MODE_WIDTH-1:0] mode_reg;
    reg [31:0] message_bytes_reg, output_bytes_reg, source_reg, destination_reg;
    reg irq_enable_reg, done_reg, error_reg;
    reg [7:0] error_code_reg;
    wire control_write = write_ok && (write_addr[11:2] == REG_CONTROL) && s_axi_ctrl_wstrb[0];
    wire start_request = control_write && s_axi_ctrl_wdata[0];
    wire reset_request = control_write && s_axi_ctrl_wdata[1];
    wire clear_request = control_write && s_axi_ctrl_wdata[2];

    // Output length & overflow checks
    wire [31:0] output_length = (mode_reg == `KECCAK_MODE_SHA3_256) ? 32'd32 : (mode_reg == `KECCAK_MODE_SHA3_512) ? 32'd64 : output_bytes_reg;
    wire btt_overflow = (message_bytes_reg[31:23] != 0) || (output_length[31:23] != 0); // Exceeds DataMover 8 MB limit

    // DataMover status
    wire mm2s_status_fire = s_axis_mm2s_sts_tvalid && s_axis_mm2s_sts_tready;
    wire s2mm_status_fire = s_axis_s2mm_sts_tvalid && s_axis_s2mm_sts_tready;
    wire mm2s_status_error = mm2s_status_fire && (s_axis_mm2s_sts_tdata != 8'h80); // 0x80 is OKAY for MM2S
    wire s2mm_status_error = s2mm_status_fire && (s_axis_s2mm_sts_tdata != 8'h81); // 0x81 is OKAY for S2MM

    // Job control & DMA state
    reg job_active, abort_pending;
    reg [2:0] reset_cycles;
    reg mm2s_pending, s2mm_pending, core_finished, mm2s_finished, s2mm_finished;
    wire core_busy, core_done, core_error;
    wire [7:0] core_error_code;
    wire dma_resetting = (reset_cycles != 0);
    wire busy = job_active || core_busy || abort_pending || dma_resetting;
    wire [7:0] start_error = busy ? 8'h01 : (output_length == 0) ? 8'h02 : btt_overflow ? 8'h12 : 8'h00; // busy, zero output, too long
    wire [7:0] transfer_error = core_error ? core_error_code : s2mm_status_error ? 8'h11 : mm2s_status_error ? 8'h10 : 8'h00; // keccak core, S2MM, MM2S
    wire job_done = job_active && core_finished && mm2s_finished && s2mm_finished && !abort_pending && (transfer_error == 0);
    wire abort_done = abort_pending && mm2s_halt_complete && s2mm_halt_complete;

    // Interface flow control
    assign s_axi_ctrl_awready = !write_active && !s_axi_ctrl_bvalid;
    assign s_axi_ctrl_wready = write_active;
    assign s_axi_ctrl_arready = !read_active;
    assign m_axis_s2mm_cmd_tvalid = s2mm_pending && dma_aresetn;
    assign m_axis_mm2s_cmd_tvalid = mm2s_pending && !s2mm_pending && dma_aresetn; // Start S2MM before MM2S
    assign s_axis_mm2s_sts_tready = job_active && !abort_pending;
    assign s_axis_s2mm_sts_tready = job_active && !abort_pending;
    assign dma_halt = abort_pending;
    assign dma_aresetn = aresetn && !dma_resetting;
    assign irq = irq_enable_reg && (done_reg || error_reg);

    keccak_top_axi4stream #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) u_stream (
        .clk(aclk),
        .rst_n(aresetn),
        .cfg_start(start_request && (start_error == 0)),
        .cfg_reset(reset_request || abort_pending || dma_resetting),
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

    always @(posedge aclk) begin
        if (!aresetn) begin
            write_active <= 0;
            s_axi_ctrl_bvalid <= 0;
        end else begin
            if (s_axi_ctrl_awvalid && s_axi_ctrl_awready) begin
                write_active <= 1;
                write_addr <= s_axi_ctrl_awaddr;
                write_left <= s_axi_ctrl_awlen;
                write_incr <= (s_axi_ctrl_awburst == BURST_INCR);
                write_error <= aw_error;
                s_axi_ctrl_bid <= s_axi_ctrl_awid;
            end
            if (write_commit) begin
                write_error <= write_response;
                if (write_left == 0) begin
                    write_active <= 0;
                    s_axi_ctrl_bresp <= write_response;
                    s_axi_ctrl_bvalid <= 1;
                end else begin
                    write_left <= write_left - 8'd1;
                    if (write_incr) write_addr <= write_addr + 12'd4;
                end
            end
            if (s_axi_ctrl_bvalid && s_axi_ctrl_bready) s_axi_ctrl_bvalid <= 0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            read_active <= 0;
            s_axi_ctrl_rvalid <= 0;
        end else begin
            if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
                read_active <= 1;
                read_addr <= s_axi_ctrl_araddr;
                read_left <= s_axi_ctrl_arlen;
                read_incr <= (s_axi_ctrl_arburst == BURST_INCR);
                read_error <= ar_error;
                s_axi_ctrl_rid <= s_axi_ctrl_arid;
            end
            if (read_active && !s_axi_ctrl_rvalid) begin
                s_axi_ctrl_rdata <= read_data;
                s_axi_ctrl_rresp <= (read_error != RESP_OKAY) ? read_error : decode_error(read_addr[11:2]);
                s_axi_ctrl_rlast <= (read_left == 0);
                s_axi_ctrl_rvalid <= 1;
            end else if (s_axi_ctrl_rvalid && s_axi_ctrl_rready) begin
                s_axi_ctrl_rvalid <= 0;
                if (read_left == 0)
                    read_active <= 0;
                else begin
                    read_left <= read_left - 8'd1;
                    if (read_incr) read_addr <= read_addr + 12'd4;
                end
            end
        end
    end

    always @(*) begin
        case (read_addr[11:2])
            REG_CONTROL: read_data = {23'd0, irq_enable_reg, 8'd0};
            REG_STATUS: read_data = {16'd0, error_code_reg, 2'd0, irq, 2'd0, error_reg, done_reg, busy};
            REG_MODE: read_data = {{(32-`KECCAK_MODE_WIDTH){1'b0}}, mode_reg};
            REG_MESSAGE_BYTES: read_data = message_bytes_reg;
            REG_OUTPUT_BYTES: read_data = output_bytes_reg;
            REG_VERSION: read_data = 32'h4b444d33;
            REG_SOURCE: read_data = source_reg;
            REG_DESTINATION: read_data = destination_reg;
            default: read_data = 0;
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            mode_reg <= `KECCAK_MODE_SHAKE256;
            message_bytes_reg <= 0;
            output_bytes_reg <= 0;
            source_reg <= 0;
            destination_reg <= 0;
            irq_enable_reg <= 0;
        end else if (write_ok) begin
            case (write_addr[11:2])
                REG_CONTROL: if (s_axi_ctrl_wstrb[1]) irq_enable_reg <= s_axi_ctrl_wdata[8];
                REG_MODE: if (s_axi_ctrl_wstrb[0]) mode_reg <= s_axi_ctrl_wdata[`KECCAK_MODE_WIDTH-1:0];
                REG_MESSAGE_BYTES: message_bytes_reg <= (message_bytes_reg & ~write_mask) | (s_axi_ctrl_wdata & write_mask);
                REG_OUTPUT_BYTES: output_bytes_reg <= (output_bytes_reg & ~write_mask) | (s_axi_ctrl_wdata & write_mask);
                REG_SOURCE: source_reg <= (source_reg & ~write_mask) | (s_axi_ctrl_wdata & write_mask);
                REG_DESTINATION: destination_reg <= (destination_reg & ~write_mask) | (s_axi_ctrl_wdata & write_mask);
            endcase
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            done_reg <= 0;
            error_reg <= 0;
            error_code_reg <= 0;
            job_active <= 0;
            mm2s_pending <= 0;
            s2mm_pending <= 0;
            abort_pending <= 0;
            reset_cycles <= 4;
        end else begin
            if (dma_resetting) reset_cycles <= reset_cycles - 3'd1;
            if (clear_request || reset_request || (start_request && !busy)) begin
                done_reg <= 0;
                error_reg <= 0;
                error_code_reg <= 0;
            end
            if (start_request) begin
                if (start_error != 0) begin
                    error_reg <= 1;
                    error_code_reg <= start_error;
                end else begin
                    job_active <= 1;
                    core_finished <= 0;
                    mm2s_finished <= (message_bytes_reg == 0);
                    s2mm_finished <= 0;
                    mm2s_pending <= (message_bytes_reg != 0);
                    s2mm_pending <= 1;
                    m_axis_mm2s_cmd_tdata <= datamover_cmd(4'd0, source_reg, message_bytes_reg[22:0]);
                    m_axis_s2mm_cmd_tdata <= datamover_cmd(4'd1, destination_reg, output_length[22:0]);
                end
            end
            if (m_axis_mm2s_cmd_tvalid && m_axis_mm2s_cmd_tready) mm2s_pending <= 0;
            if (m_axis_s2mm_cmd_tvalid && m_axis_s2mm_cmd_tready) s2mm_pending <= 0;
            if (core_done) core_finished <= 1;
            if (mm2s_status_fire) mm2s_finished <= 1;
            if (s2mm_status_fire) s2mm_finished <= 1;
            if (job_done) begin
                job_active <= 0;
                done_reg <= 1;
            end
            if (transfer_error != 0) begin
                error_reg <= 1;
                error_code_reg <= transfer_error;
                abort_pending <= 1;
            end
            if (reset_request) abort_pending <= 1;
            if (abort_done) begin
                job_active <= 0;
                abort_pending <= 0;
                mm2s_pending <= 0;
                s2mm_pending <= 0;
                reset_cycles <= 4;
            end
        end
    end

endmodule