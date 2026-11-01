`timescale 1ns / 1ps
module keccak_soc_tb_pipeline;

    // Testbench parameters
    localparam integer PIPELINE_EN = 1;
    localparam integer MESSAGE_BYTES = 448;
    localparam integer RATE_BYTES = 136;
    localparam integer BEAT_BYTES = 8;
    localparam integer BLOCK_BEATS = RATE_BYTES / BEAT_BYTES;
    localparam integer CLOCK_NS = 4;

    // Clock & reset
    reg aclk = 0, aresetn = 0;
    always #(CLOCK_NS / 2) aclk = ~aclk;

    // AXI4-Lite write channels (AW, W, B)
    reg  [11:0] awaddr = 0;
    reg  [31:0] wdata = 0;
    reg         awvalid = 0, wvalid = 0;
    wire        awready, wready, bvalid;

    // AXI4-Stream input & output
    reg  s_tvalid = 0;
    wire s_tready, m_tvalid, m_tlast;
    integer beat = 0;

    keccak_top_wrapper #(.AXIS_DATA_WIDTH(64)) u_dut (
        .aclk(aclk), .aresetn(aresetn),
        // AXI4-Lite: AW, W, B
        .s_axi_ctrl_awaddr(awaddr), .s_axi_ctrl_awprot(3'b0),
        .s_axi_ctrl_awvalid(awvalid), .s_axi_ctrl_awready(awready),
        .s_axi_ctrl_wdata(wdata), .s_axi_ctrl_wstrb(4'hf),
        .s_axi_ctrl_wvalid(wvalid), .s_axi_ctrl_wready(wready),
        .s_axi_ctrl_bresp(), .s_axi_ctrl_bvalid(bvalid), .s_axi_ctrl_bready(1'b1),
        // AXI4-Lite: AR, R (unused)
        .s_axi_ctrl_araddr(12'b0), .s_axi_ctrl_arprot(3'b0),
        .s_axi_ctrl_arvalid(1'b0), .s_axi_ctrl_arready(),
        .s_axi_ctrl_rdata(), .s_axi_ctrl_rresp(), .s_axi_ctrl_rvalid(), .s_axi_ctrl_rready(1'b1),
        // AXI4-Stream input (DMA MM2S)
        .s_axis_dma_tdata(64'b0), .s_axis_dma_tkeep(8'hff),
        .s_axis_dma_tvalid(s_tvalid), .s_axis_dma_tready(s_tready),
        .s_axis_dma_tlast(beat == MESSAGE_BYTES / BEAT_BYTES - 1),
        // AXI4-Stream output (DMA S2MM)
        .m_axis_dma_tdata(), .m_axis_dma_tkeep(),
        .m_axis_dma_tvalid(m_tvalid), .m_axis_dma_tready(1'b1), .m_axis_dma_tlast(m_tlast),
        .irq()
    );

    // Waveform signals
    wire core_busy = (u_dut.u_keccak.u_sponge.curr_state == 6'b001000); // sponge ST_PERMUTE
    wire [4:0] round_idx = u_dut.u_keccak.u_sponge.u_keccak_perm.round_ctr;
    wire overlap = s_tvalid && s_tready && core_busy;
    wire [31:0] load_block = (u_dut.message_left_reg == MESSAGE_BYTES) ? 0 :
                             (MESSAGE_BYTES - 1 - u_dut.message_left_reg) / RATE_BYTES + 1;
    wire [31:0] load_beat = u_dut.block_bytes_reg / BEAT_BYTES;

    integer core_block, cycle_count;
    time start_time;

    // Count blocks absorbed by the core & cycles from START to last output beat
    always @(posedge aclk) begin
        if (u_dut.core_start) begin
            start_time <= $time;
            core_block <= 0;
        end else if (u_dut.u_keccak.u_sponge.absorb_fire)
            core_block <= core_block + 1;

        if (m_tvalid && m_tlast)
            cycle_count <= ($time - start_time) / CLOCK_NS;
    end

    // AXI4-Lite write
    task axi_write(input [11:0] addr, input [31:0] data);
    begin
        @(negedge aclk); awaddr = addr; awvalid = 1'b1;
        while (!awready) @(negedge aclk);
        @(negedge aclk); awvalid = 1'b0; wdata = data; wvalid = 1'b1;
        while (!wready) @(negedge aclk);
        @(negedge aclk); wvalid = 1'b0;
        while (!bvalid) @(negedge aclk);
    end
    endtask

    // Send one message
    task run_case(input integer mode);
    begin
        axi_write(12'h08, 2);               // MODE = SHA3-256
        axi_write(12'h0c, MESSAGE_BYTES);   // MESSAGE_BYTES
        axi_write(12'h00, 1);               // CONTROL.START

        for (beat = 0; beat < MESSAGE_BYTES / BEAT_BYTES; beat = beat + 1) begin
            if (!mode && beat != 0 && beat % BLOCK_BEATS == 0) begin
                s_tvalid = 0;
                wait (core_busy);
                wait (!core_busy);
                @(negedge aclk);
            end
            s_tvalid = 1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
            @(negedge aclk);
        end
        s_tvalid = 0;

        wait (u_dut.done_reg);
        $display("mode %0d: %0d cycles", mode, cycle_count);
    end
    endtask

    // Run the selected mode
    initial begin
        repeat (5) @(negedge aclk);
        aresetn = 1;
        run_case(PIPELINE_EN);
        run_case(0);
        #100 $finish;
    end

endmodule
