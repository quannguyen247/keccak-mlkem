`timescale 1ns / 1ps
`include "keccak_defs.vh"

module keccak_ip_tb;

    // Testbench parameters
    localparam integer MAX_IN = 400;
    localparam integer MAX_OUT = 400;
    localparam integer MAX_VEC = 1024;
    localparam integer TIMEOUT_CYCLES = 5000;
    localparam integer VEC_BITS = 40 + 8 * (MAX_IN + MAX_OUT);

    // DUT signals
    reg clk, rst_n, start;
    reg absorb_valid, absorb_last;
    reg [`KECCAK_RATE_BITS-1:0] msg_block_in;
    reg [7:0] msg_len_bytes;
    reg squeeze_ready, squeeze_last;
    reg [31:0] output_blocks;
    wire absorb_ready, squeeze_valid, done;
    wire [`KECCAK_RATE_BITS-1:0] squeeze_out;
    wire [7:0] squeeze_bytes;

    // Vector: exp_out | msg | out_len | msg_len | mode
    reg [VEC_BITS-1:0] vec_all [0:MAX_VEC-1];
    reg [8*MAX_OUT-1:0] exp_out;        // [6439:3240]
    reg [8*MAX_IN-1:0] msg;             // [3239:40]
    reg [15:0] out_len;                 // [39:24]
    reg [15:0] msg_len;                 // [23:8]
    reg [`KECCAK_MODE_WIDTH-1:0] mode;  // [7:0]

    // Testbench control and monitoring
    integer rate, offset;
    integer case_idx, tv_count, error_count, report_fd, spec_fd;
    integer out_cnt, mismatch, watchdog, j;
    reg done_seen;

    // Testbench file and directory path
    reg [8*512-1:0] tb_file;
    reg [8*512-1:0] tb_dir;

    keccak_top u_dut (
        .clk(clk), .rst_n(rst_n), .mode(mode),
        .absorb_valid(absorb_valid), .absorb_last(absorb_last),
        .msg_block_in(msg_block_in), .msg_len_bytes(msg_len_bytes), .absorb_ready(absorb_ready),
        .squeeze_ready(squeeze_ready), .squeeze_last(squeeze_last),
        .squeeze_valid(squeeze_valid), .squeeze_out(squeeze_out), .squeeze_bytes(squeeze_bytes),
        .start(start), .done(done), .output_blocks(output_blocks)
    );

    initial begin
        clk = 1'b0;
        forever #2.5 clk = ~clk;
    end

    // Return the block size (rate_bytes) of the selected mode
    function integer rate_bytes(input [1:0] m);
        case (m)
            2'd0: rate_bytes = 168;
            2'd3: rate_bytes = 72;
            default: rate_bytes = 136;
        endcase
    endfunction

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

    // Compare each output byte with the expected byte, count mismatches
    always @(posedge clk) begin
        if (start) begin
            out_cnt = 0;
            done_seen = 1'b0;
        end
        if (squeeze_valid && squeeze_ready) begin
            for (j = 0; j < squeeze_bytes; j = j + 1)
                if (out_cnt + j < out_len && squeeze_out[8*j +: 8] !== exp_out[8*(out_cnt+j) +: 8])
                    mismatch = mismatch + 1;
            out_cnt = out_cnt + squeeze_bytes;
        end
        if (done)
            done_seen = 1'b1;
    end

    // Back-pressure test: output side randomly drops squeeze_ready
    always @(negedge clk) squeeze_ready = ($random & 3) != 0;

    // Watchdog: if one case runs too long, print a timeout error and stop the simulation
    always @(posedge clk) begin
        if (start)
            watchdog <= 0;
        else
            watchdog <= watchdog + 1;
        if (watchdog > TIMEOUT_CYCLES) begin
            $display("[%0t] FAIL: Case %0d - Timeout", $time, case_idx);
            $finish;
        end
    end

    task send_block(input integer len, input last);
    begin
        @(negedge clk);
        repeat ($random & 3) @(negedge clk); // random idle gap before absorb_valid
        msg_block_in = msg >> (8 * offset);
        msg_len_bytes = len;
        absorb_last = last;
        absorb_valid = 1'b1;
        while (!absorb_ready) @(negedge clk);
        @(negedge clk);
        absorb_valid = 1'b0;
    end
    endtask

    task run_one_case(input integer idx);
    begin
        mode     = vec_all[idx][7:0];
        msg_len  = vec_all[idx][23:8];
        out_len  = vec_all[idx][39:24];
        msg      = vec_all[idx][40 +: 8*MAX_IN];       
        exp_out  = vec_all[idx][40 + 8*MAX_IN +: 8*MAX_OUT]; 

        rate = rate_bytes(mode);
        output_blocks = (out_len + rate - 1) / rate;
        mismatch = 0;

        // Start the IP (pulse)
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        // Send all full blocks first, then the last block
        offset = 0;
        while (offset + rate <= msg_len) begin
            send_block(rate, 1'b0);
            offset = offset + rate;
        end
        send_block(msg_len - offset, 1'b1);

        // Wait for done, then check the result
        while (!done_seen) @(negedge clk);
        if (mismatch != 0 || out_cnt < out_len) begin
            $display("[%0t] FAIL: Case %0d - mode %0d, msg_len %0d, out_len %0d", $time, idx, mode, msg_len, out_len);
            error_count = error_count + 1;
        end
        if (report_fd != 0)
            $fwrite(report_fd, "Case %0d - mode: %0d, msg_len: %0d, out_len: %0d | %s\n",
                    idx, mode, msg_len, out_len, (mismatch == 0 && out_cnt >= out_len) ? "PASS" : "FAIL");
        repeat (2) @(posedge clk);
    end
    endtask

    initial begin
        $sformat(tb_file, "%s", `__FILE__);
        tb_dir = dirname(tb_file);

        error_count = 0; rst_n = 1'b0; start = 1'b0; mode = 0; case_idx = 0;
        absorb_valid = 1'b0; absorb_last = 1'b0; msg_block_in = 0; msg_len_bytes = 0;
        squeeze_ready = 1'b1; squeeze_last = 1'b0; output_blocks = 0;
        out_cnt = 0; mismatch = 0; done_seen = 1'b0; out_len = 0;

        report_fd = $fopen({tb_dir, "keccak_ip_result.log"}, "w");
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
        @(negedge clk); rst_n = 1'b1;
        repeat (5) @(posedge clk);

        for (case_idx = 0; case_idx < tv_count; case_idx = case_idx + 1)
            run_one_case(case_idx);

        $display("KECCAK IP PASSED: %0d/%0d CASES (%0d ERRORS)", tv_count - error_count, tv_count, error_count);

        if (report_fd != 0) $fclose(report_fd);
        #100;
        $finish;
    end

endmodule