`timescale 1ns/1ps

module media_frame_loader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer BURST_SIZE = 128,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer BURST_GAP_CYCLES = 12
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load_start,
    input  wire [2:0]            image_index,
    input  wire                  pixel_valid,
    input  wire [23:0]           pixel_rgb,
    input  wire                  frame_commit,
    input  wire [7:0]            decode_error,
    output wire                  load_busy,
    output reg                   load_done,
    output reg  [5:0]            image_complete,
    output reg  [7:0]            memory_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    input wire read_bus_busy,
    output wire write_bus_busy,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [3:0]            app_wr_mask,
    output reg  [31:0]           app_wr_data
);
    localparam ERR_NONE          = 8'h00;
    localparam ERR_NOT_ACTIVE    = 8'h41;
    localparam ERR_FIFO_OVERFLOW = 8'h42;
    localparam ERR_PIXEL_COUNT   = 8'h43;
    localparam ERR_DECODE        = 8'h44;
    localparam ERR_SHORT_FRAME   = 8'h45;
    localparam ERR_WRITE_STALL   = 8'h46;

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [PTR_WIDTH:0] EFFECTIVE_BURST =
        (BURST_SIZE < FIFO_DEPTH) ? BURST_SIZE : FIFO_DEPTH;
    localparam [ADDR_WIDTH-1:0] BANK0_BASE = 0;
    localparam [ADDR_WIDTH-1:0] BANK1_BASE = IMAGE_WORDS;
    localparam [ADDR_WIDTH-1:0] BANK2_BASE = IMAGE_WORDS * 2;
    localparam [ADDR_WIDTH-1:0] BANK3_BASE = IMAGE_WORDS * 3;

    localparam XW=(FRAME_WIDTH<2)?1:$clog2(FRAME_WIDTH);
    localparam PW=(IMAGE_WORDS<1)?1:$clog2(IMAGE_WORDS+1);
    localparam SW=(STALL_TIMEOUT<1)?1:$clog2(STALL_TIMEOUT+1);
    reg [XW-1:0] write_x;
    reg [ADDR_WIDTH-1:0] write_offset;
    reg [7:0] burst_gap;
    reg [7:0] deferred_error;
    reg active;
    reg [2:0] active_image;
    reg commit_seen;
    reg [PW-1:0] pixels_received;
    reg [PW-1:0] pixels_written;
    reg [SW-1:0] stall_count;
    reg [31:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    reg burst_active;
    reg [PTR_WIDTH:0] burst_remaining;
    wire pop_allowed;
    wire push_allowed;
    wire start_burst;
    wire [PTR_WIDTH:0] next_burst_words;
    wire [7:0] input_fault=(decode_error!=0)?ERR_DECODE:
        ((pixel_valid && pixels_received>=IMAGE_WORDS)?ERR_PIXEL_COUNT:
         ((pixel_valid && !push_allowed)?ERR_FIFO_OVERFLOW:ERR_NONE));
    wire accept_pixel=push_allowed && input_fault==0 && deferred_error==0;

    assign load_busy = active;
    assign write_bus_busy=burst_active || app_wr_en || (burst_gap!=0) || start_burst;
    // The inherited controller consumes a continuous App_wr_en burst and
    // handles busy/refresh internally. Those status outputs are not per-word
    // ready signals and must not split an active write burst.
    assign start_burst = active && controller_init_done && !controller_busy && !refresh_active &&
                         !read_bus_busy && burst_gap==0 && !burst_active &&
                         fifo_count != 0 &&
                         (fifo_count >= EFFECTIVE_BURST || commit_seen);
    wire [PTR_WIDTH:0] fifo_burst_words=(fifo_count>=EFFECTIVE_BURST)?EFFECTIVE_BURST:fifo_count;
    assign next_burst_words=(fifo_burst_words > FRAME_WIDTH-write_x) ?
                             FRAME_WIDTH-write_x : fifo_burst_words;
    assign pop_allowed = active && controller_init_done && burst_active &&
                         fifo_count != 0;
    assign push_allowed = active && pixel_valid &&
                          (fifo_count < FIFO_DEPTH || pop_allowed);

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = BANK0_BASE;
                3'd1: bank_base = BANK1_BASE;
                3'd2: bank_base = BANK2_BASE;
                3'd3: bank_base = BANK3_BASE;
                3'd4: bank_base = IMAGE_WORDS * 4;
                3'd5: bank_base = IMAGE_WORDS * 5;
                default: bank_base = BANK0_BASE;
            endcase
        end
    endfunction

    task fail_load;
        input [7:0] code;
        begin
            memory_error <= code;
            active <= 1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_x<=0; write_offset<=0; burst_gap<=0; deferred_error<=0;
            active <= 1'b0;
            active_image <= 2'd0;
            commit_seen <= 1'b0;
            pixels_received <= 32'd0;
            pixels_written <= 32'd0;
            stall_count <= 32'd0;
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            fifo_count <= {(PTR_WIDTH+1){1'b0}};
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b0;
            image_complete <= 6'd0;
            memory_error <= ERR_NONE;
            app_wr_en <= 1'b0;
            app_wr_addr <= {ADDR_WIDTH{1'b0}};
            app_wr_mask <= 4'b0000;
            app_wr_data <= 32'd0;
        end else begin
            load_done <= 1'b0;
            app_wr_en <= 1'b0;
            if (burst_gap!=0) burst_gap<=burst_gap-1'b1;

            if (load_start && !active) begin
                write_x<=0; write_offset<=(FRAME_HEIGHT-1)*FRAME_WIDTH; deferred_error<=0;
                active <= 1'b1;
                active_image <= image_index;
                commit_seen <= 1'b0;
                pixels_received <= 32'd0;
                pixels_written <= 32'd0;
                stall_count <= 32'd0;
                wr_ptr <= {PTR_WIDTH{1'b0}};
                rd_ptr <= {PTR_WIDTH{1'b0}};
                fifo_count <= {(PTR_WIDTH+1){1'b0}};
                burst_active <= 1'b0;
                burst_remaining <= 0;
                memory_error <= ERR_NONE;
                if(image_index<6) image_complete[image_index] <= 1'b0;
            end

            if (active) begin
                if (input_fault!=0 && deferred_error==0) deferred_error<=input_fault;
                if ((input_fault!=0 || deferred_error!=0) && !burst_active && !app_wr_en) begin
                    fail_load(deferred_error!=0?deferred_error:input_fault);
                end else begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_remaining <= next_burst_words;
                    end

                    if (accept_pixel) begin
                        fifo_mem[wr_ptr] <= {8'h00, pixel_rgb};
                        wr_ptr <= wr_ptr + 1'b1;
                        pixels_received <= pixels_received + 1'b1;
                    end

                    if (pop_allowed) begin
                        app_wr_en <= 1'b1;
                        app_wr_addr <= bank_base(active_image) + write_offset;
                        app_wr_data <= fifo_mem[rd_ptr];
                        app_wr_mask <= 4'b0000;
                        rd_ptr <= rd_ptr + 1'b1;
                        pixels_written <= pixels_written + 1'b1;
                        if (write_x==FRAME_WIDTH-1) begin
                            write_x<=0;
                            write_offset<=write_offset-(2*FRAME_WIDTH-1);
                        end else begin write_x<=write_x+1'b1; write_offset<=write_offset+1'b1; end
                        stall_count <= 32'd0;
                        if (burst_remaining == 1) begin
                            burst_gap<=BURST_GAP_CYCLES;
                            burst_active <= 1'b0;
                            burst_remaining <= 0;
                        end else begin
                            burst_remaining <= burst_remaining - 1'b1;
                        end
                    end else if (fifo_count != 0 &&
                                 (commit_seen || fifo_count >= EFFECTIVE_BURST)) begin
                        if (stall_count == STALL_TIMEOUT)
                            fail_load(ERR_WRITE_STALL);
                        else
                            stall_count <= stall_count + 1'b1;
                    end else begin
                        stall_count <= 32'd0;
                    end

                    case ({accept_pixel, pop_allowed})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: fifo_count <= fifo_count;
                    endcase

                    if (frame_commit)
                        commit_seen <= 1'b1;

                    if (commit_seen && fifo_count == 0 && !pop_allowed &&
                        !burst_active && !app_wr_en && burst_gap==0 && !controller_busy &&
                        !pixel_valid && decode_error==0 && deferred_error==0) begin
                        if (pixels_received != IMAGE_WORDS || pixels_written != IMAGE_WORDS) begin
                            fail_load(ERR_SHORT_FRAME);
                        end else begin
                            if(active_image<6) image_complete[active_image] <= 1'b1;
                            active <= 1'b0;
                            load_done <= 1'b1;
                        end
                    end
                end
            end else if (pixel_valid) begin
                memory_error <= ERR_NOT_ACTIVE;
            end
        end
    end
endmodule
