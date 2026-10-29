`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_soc_tb;

    // Testbench parameters
    localparam integer AXIS_DATA_WIDTH = 64;
    localparam integer BEAT = AXIS_DATA_WIDTH / 8;
    localparam integer MAX_IN = 400;
    localparam integer MAX_OUT = 400;
    localparam integer VEC_BITS = 40 + 8 * (MAX_IN + MAX_OUT);
    localparam integer MAX_VEC = 1024;
    localparam integer TIMEOUT_CYCLES = 10000;
    localparam integer FAULT_CASE = -1;

    // Register map
    localparam [11:0] REG_CONTROL       = 12'h00; // [0] START, [1] RESET, [2] CLEAR
    localparam [11:0] REG_STATUS        = 12'h04; // [0] BUSY, [1] DONE, [2] ERROR, [15:8] CODE
    localparam [11:0] REG_MODE          = 12'h08;
    localparam [11:0] REG_MESSAGE_BYTES = 12'h0C;
    localparam [11:0] REG_OUTPUT_BYTES  = 12'h10;
    localparam [11:0] REG_VERSION       = 12'h14;

    // Clock, reset & interrupt
    reg aclk, aresetn;
    wire irq;

    // AXI4-Lite signals
    // AW, W, B channels
    reg [11:0] awaddr;
    reg        awvalid;
    wire       awready;

    reg [31:0] wdata;
    reg        wvalid;
    wire       wready;

    wire [1:0] bresp;
    wire       bvalid;
    reg        bready;

    // AR, R channels
    reg [11:0]  araddr;
    reg         arvalid;
    wire        arready;

    wire [31:0] rdata;
    wire        rvalid;
    reg         rready;
    wire [1:0]  rresp;

    // AXI4-Stream signals
    // Slave stream (input data)
    reg [AXIS_DATA_WIDTH-1:0] s_tdata;
    reg [BEAT-1:0]            s_tkeep;
    reg                       s_tvalid;
    reg                       s_tlast;
    wire                      s_tready;

    // Master stream (output data)
    wire [AXIS_DATA_WIDTH-1:0] m_tdata;
    wire [BEAT-1:0]            m_tkeep;
    wire                       m_tvalid;
    wire                       m_tlast;
    reg                        m_tready;

    // Vector: exp_out | msg | out_len | msg_len | mode
    reg [VEC_BITS-1:0] vec_all [0:MAX_VEC-1];
    reg [8*MAX_OUT-1:0] exp_out;        // [6439:3240]
    reg [8*MAX_IN-1:0] msg;             // [3239:40]
    reg [15:0] out_len;                 // [39:24]
    reg [15:0] msg_len;                 // [23:8]
    reg [`KECCAK_MODE_WIDTH-1:0] mode;  // [7:0]
    
    // Testbench buffers & AXI status
    reg [8*MAX_OUT-1:0] out_buf;    // S2MM receive buffer
    reg [31:0] status;              // AXI-Lite STATUS register

    // Testbench control & monitoring
    integer offset, n;
    integer case_idx, tv_count, error_count, report_fd, spec_fd;
    integer out_cnt, watchdog, j;
    reg tlast_seen, case_pass;

    // Testbench file & directory path
    reg [8*512-1:0] tb_file;
    reg [8*512-1:0] tb_dir;

    keccak_top_wrapper #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH)
    ) u_dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_ctrl_awaddr(awaddr), .s_axi_ctrl_awprot(3'b000), .s_axi_ctrl_awvalid(awvalid), .s_axi_ctrl_awready(awready),
        .s_axi_ctrl_wdata(wdata), .s_axi_ctrl_wstrb(4'hF), .s_axi_ctrl_wvalid(wvalid), .s_axi_ctrl_wready(wready),
        .s_axi_ctrl_bresp(bresp), .s_axi_ctrl_bvalid(bvalid), .s_axi_ctrl_bready(bready),
        .s_axi_ctrl_araddr(araddr), .s_axi_ctrl_arprot(3'b000), .s_axi_ctrl_arvalid(arvalid), .s_axi_ctrl_arready(arready),
        .s_axi_ctrl_rdata(rdata), .s_axi_ctrl_rresp(rresp), .s_axi_ctrl_rvalid(rvalid), .s_axi_ctrl_rready(rready),
        .s_axis_dma_tdata(s_tdata), .s_axis_dma_tkeep(s_tkeep), .s_axis_dma_tvalid(s_tvalid),
        .s_axis_dma_tready(s_tready), .s_axis_dma_tlast(s_tlast),
        .m_axis_dma_tdata(m_tdata), .m_axis_dma_tkeep(m_tkeep), .m_axis_dma_tvalid(m_tvalid),
        .m_axis_dma_tready(m_tready), .m_axis_dma_tlast(m_tlast),
        .irq(irq)
    );

    // AXI4-Lite monitor
    axi_protocol_checker_0 u_pc_axi (
        .aclk(aclk), .aresetn(aresetn),
        .pc_axi_awaddr(awaddr), .pc_axi_awprot(3'b000), .pc_axi_awvalid(awvalid), .pc_axi_awready(awready),
        .pc_axi_wdata(wdata), .pc_axi_wstrb(4'hF), .pc_axi_wvalid(wvalid), .pc_axi_wready(wready),
        .pc_axi_bresp(bresp), .pc_axi_bvalid(bvalid), .pc_axi_bready(bready),
        .pc_axi_araddr(araddr), .pc_axi_arprot(3'b000), .pc_axi_arvalid(arvalid), .pc_axi_arready(arready),
        .pc_axi_rdata(rdata), .pc_axi_rresp(rresp), .pc_axi_rvalid(rvalid), .pc_axi_rready(rready),
        .pc_asserted(), .pc_status()
    );

    // AXI4-Stream input monitor
    axis_protocol_checker_0 u_pc_in (
        .aclk(aclk), .aresetn(aresetn),
        .pc_axis_tdata(s_tdata), .pc_axis_tkeep(s_tkeep), .pc_axis_tvalid(s_tvalid),
        .pc_axis_tready(s_tready), .pc_axis_tlast(s_tlast),
        .pc_asserted(), .pc_status()
    );

    // AXI4-Stream output monitor
    axis_protocol_checker_0 u_pc_out (
        .aclk(aclk), .aresetn(aresetn),
        .pc_axis_tdata(m_tdata), .pc_axis_tkeep(m_tkeep), .pc_axis_tvalid(m_tvalid),
        .pc_axis_tready(m_tready), .pc_axis_tlast(m_tlast),
        .pc_asserted(), .pc_status()
    );

    initial begin
        aclk = 1'b0;
        forever #2.5 aclk = ~aclk;
    end

    // Return the folder part of a file path, used to locate the vector folder
    function [8*512-1:0] dirname(input [8*512-1:0] path);
        integer k, found;
        begin
            dirname = 0;
            found = 0;
            for (k = 0; k < 512; k = k + 1)
                if (!found && (path[8*k +: 8] == "/" || path[8*k +: 8] == "\\")) begin
                    dirname = path >> (8 * k);
                    found = 1;
                end
        end
    endfunction

    // Receive output digest from AXI4-Stream (emulate DMA S2MM channel)
    always @(posedge aclk) begin
        if (m_tvalid && m_tready) begin
            for (j = 0; j < BEAT; j = j + 1)
                if (m_tkeep[j]) begin
                    out_buf[8*out_cnt +: 8] = m_tdata[8*j +: 8];
                    out_cnt = out_cnt + 1;
                end
            if (m_tlast)
                tlast_seen = 1'b1;
        end
    end

    // Back-pressure: DMA S2MM channel randomly drops tready
    always @(negedge aclk) m_tready = ($random & 3) != 0;

    // Watchdog: if one case runs too long, print a timeout error & stop the simulation
    always @(posedge aclk) begin
        if (u_dut.core_start)
            watchdog <= 0;
        else
            watchdog <= watchdog + 1;
        if (watchdog > TIMEOUT_CYCLES) begin
            $display("[%0t] FAIL: Case %0d - Timeout", $time, case_idx);
            $finish;
        end
    end

    // Host CPU emulation:
    // AXI4-Lite write (Xil_Out32)
    task axi_write(input [11:0] addr, input [31:0] data);
    begin
        @(negedge aclk); awaddr = addr; awvalid = 1'b1;
        while (!awready) @(negedge aclk);
        @(negedge aclk); awvalid = 1'b0; wdata = data; wvalid = 1'b1;
        while (!wready) @(negedge aclk);
        @(negedge aclk); wvalid = 1'b0;
        while (!bvalid) @(negedge aclk);
        if (bresp != 2'b00) $display("[%0t] WARN: write 0x%h bresp=%0d", $time, addr, bresp);
        @(negedge aclk);
    end
    endtask

    // AXI4-Lite read (Xil_In32)
    task axi_read(input [11:0] addr, output [31:0] data);
    begin
        @(negedge aclk); araddr = addr; arvalid = 1'b1;
        while (!arready) @(negedge aclk);
        @(negedge aclk); arvalid = 1'b0;
        while (!rvalid) @(negedge aclk);
        data = rdata;
        @(negedge aclk);
    end
    endtask

    // Send one beat (8 bytes) (emulate DMA MM2S channel)
    task send_beat(input integer bytes, input tlast);
    begin
        @(negedge aclk);
        repeat ($random & 3) @(negedge aclk); // random idle gap before tvalid
        s_tdata = msg >> (8 * offset);
        s_tkeep = (1 << bytes) - 1;
        s_tlast = tlast;
        s_tvalid = 1'b1;

        // Intentionally change TDATA while waiting for TREADY
        if (case_idx == FAULT_CASE) begin
            force s_tready = 1'b0;
            @(negedge aclk);
            s_tdata = s_tdata ^ 64'h1;
            repeat (3) @(negedge aclk);
            release s_tready;
        end

        while (!s_tready) @(negedge aclk);
        @(negedge aclk);
        s_tvalid = 1'b0;
        s_tlast = 1'b0;
    end
    endtask

    // Execute one full testcase: configure IP, stream message, poll status & verify
    task run_one_case(input integer idx);
    begin
        mode    = vec_all[idx][7:0];
        msg_len = vec_all[idx][23:8];
        out_len = vec_all[idx][39:24];
        msg     = vec_all[idx][40 +: 8*MAX_IN];
        exp_out = vec_all[idx][40 + 8*MAX_IN +: 8*MAX_OUT];

        out_buf = 0;
        out_cnt = 0;
        tlast_seen = 1'b0;
        case_pass = 1'b1;

        // Configure IP registers via AXI4-Lite & start core
        axi_write(REG_CONTROL, 32'h4);
        axi_write(REG_MODE, mode);
        axi_write(REG_MESSAGE_BYTES, msg_len);
        axi_write(REG_OUTPUT_BYTES, out_len);
        axi_write(REG_CONTROL, 32'h1);

        // Stream the message into IP (8 bytes per beat)
        for (offset = 0; offset < msg_len; offset = offset + BEAT) begin
            n = (msg_len - offset < BEAT) ? (msg_len - offset) : BEAT;
            send_beat(n, offset + BEAT >= msg_len);
        end

        // Poll STATUS register until DONE or ERROR
        status = 0;
        while ((status & 32'h6) == 0) axi_read(REG_STATUS, status);

        // Verify & report PASS/FAIL
        if (status[2] || !status[1]) begin
            $display("[%0t] FAIL: Case %0d - STATUS 0x%h (error code 0x%h)", $time, idx, status, status[15:8]);
            case_pass = 1'b0;
        end
        if (out_cnt != out_len || !tlast_seen) begin
            $display("[%0t] FAIL: Case %0d - got %0d/%0d bytes, tlast %0d", $time, idx, out_cnt, out_len, tlast_seen);
            case_pass = 1'b0;
        end
        for (j = 0; j < out_len; j = j + 1)
            if (out_buf[8*j +: 8] !== exp_out[8*j +: 8])
                case_pass = 1'b0;
        if (!case_pass) begin
            $display("[%0t] FAIL: Case %0d - mode %0d, msg_len %0d, out_len %0d", $time, idx, mode, msg_len, out_len);
            error_count = error_count + 1;
        end
        if (report_fd != 0)
            $fwrite(report_fd, "Case %0d - mode: %0d, msg_len: %0d, out_len: %0d | %s\n",
                    idx, mode, msg_len, out_len, case_pass ? "PASS" : "FAIL");
    end
    endtask

    initial begin
        $sformat(tb_file, "%s", `__FILE__);
        tb_dir = dirname(tb_file);

        error_count = 0; aresetn = 1'b0; case_idx = 0; out_cnt = 0; tlast_seen = 1'b0;
        awaddr = 0; awvalid = 1'b0; wdata = 0; wvalid = 1'b0; bready = 1'b1;
        araddr = 0; arvalid = 1'b0; rready = 1'b1;
        s_tdata = 0; s_tkeep = 0; s_tvalid = 1'b0; s_tlast = 1'b0; m_tready = 1'b1;

        report_fd = $fopen({tb_dir, "keccak_soc_result.log"}, "w");
        spec_fd = $fopen({tb_dir, "../vector/keccak_tv_spec.txt"}, "r");
        if (spec_fd == 0) begin
            $display("ERROR: Cannot open vector/keccak_tv_spec.txt, run keccak_vector.py first");
            $finish;
        end
        j = $fscanf(spec_fd, "tv_count=%d", tv_count);
        $fclose(spec_fd);

        if (tv_count > MAX_VEC) begin
            $display("ERROR: tv_count exceeds MAX_VEC");
            $finish;
        end
        $readmemh({tb_dir, "../vector/keccak_tv.mem"}, vec_all, 0, tv_count - 1);

        // Reset
        #100;
        @(negedge aclk); aresetn = 1'b1;
        repeat (5) @(posedge aclk);

        for (case_idx = 0; case_idx < tv_count; case_idx = case_idx + 1)
            run_one_case(case_idx);

        $display("KECCAK SOC PASSED: %0d/%0d CASES (%0d ERRORS)",
                 tv_count - error_count, tv_count, error_count);

        if (report_fd != 0) $fclose(report_fd);
        #100;
        $finish;
    end

endmodule
