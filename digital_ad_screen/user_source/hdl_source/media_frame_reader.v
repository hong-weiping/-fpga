`timescale 1ns/1ps

module media_frame_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer THUMBNAILS = 0,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12,
    parameter integer MAX_INFLIGHT_BURSTS = 2,
    parameter integer DIAG_RETURN_PATTERN = 0,
    parameter integer DIAG_SYNTH_STREAM = 0,
    parameter integer RETURN_TIMEOUT = 65535
) (
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    input wire write_bus_busy,
    output wire read_bus_busy,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input wire display_valid,
    input wire thumbnail_mode,
    input  wire [2:0]            active_index,
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [2:0]            reader_index,
    output reg  [7:0]            reader_error
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer BURST_COUNT_W =
        (BURST_SIZE < 2) ? 1 : $clog2(BURST_SIZE + 1);
    localparam integer INFLIGHT_COUNT_W =
        (MAX_INFLIGHT_BURSTS * BURST_SIZE < 2) ? 1 :
        $clog2(MAX_INFLIGHT_BURSTS * BURST_SIZE + 1);

    reg frame_bad_pix;
    reg fatal_mem;
    localparam RTW=(RETURN_TIMEOUT<1)?1:$clog2(RETURN_TIMEOUT+1);
    reg [RTW-1:0] return_timer;
    reg request_pending_pix;
    reg request_toggle_pix;
    reg [2:0] request_index_pix;
    reg request_thumb_pix, armed_thumb_pix;
    reg thumb_sync1_mem, thumb_sync2_mem, reload_thumb_mem, thumb_mem;
    // 128-word aligned block address. The active burst only concatenates
    // this register with its 7-bit word offset (no coordinate arithmetic).
    reg [13:0] thumb_block_mem;
    reg [2:0] thumb_burst_mem;
    reg [6:0] thumb_row_mem;
    reg thumb_right_mem;
    // Each bank is 2400 blocks; each source row is 5 blocks. Sampled rows
    // are 20 blocks apart. Offsets below start at the last block of a row:
    // left -> right: 2400-4; right -> next left: 20-2400-4.
    // After row119 of a pair, advance to bank2 (or past the completed frame).
    wire [13:0] thumb_block_step = (thumb_burst_mem!=4) ? 14'd1 :
        !thumb_right_mem ? 14'd2396 :
        (thumb_row_mem==119) ? 14'd16 : 14'd14000; // -2384 modulo 2^14
    wire [ADDR_WIDTH:0] expected_consumed = armed_thumb_pix ? 76800 : IMAGE_WORDS;
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    reg request_sync1_mem;
    reg request_sync2_mem;
    reg request_seen_mem;
    reg [2:0] index_sync1_mem;
    reg [2:0] index_sync2_mem;
    reg reload_pending_mem;
    reg [2:0] reload_index_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    wire keep_return = !thumb_mem || returned_count_mem[1:0]==0;
    reg [INFLIGHT_COUNT_W-1:0] inflight_count_mem;
    reg inflight_empty_mem /* fehdl keep="true" */;
    reg burst_active_mem;
    reg [BURST_COUNT_W-1:0] burst_issued_mem;
    reg [BURST_COUNT_W-1:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;
    reg [ADDR_WIDTH:0] diag_written_count_mem;
    reg [9:0] diag_column_mem;
    reg [23:0] diag_rgb_mem;
    reg [1:0] fifo_release_mem;
    reg [1:0] fifo_release_pix;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              (fifo_reset_count_mem != 0);
    wire fifo_reset = fifo_reset_request ||
                      !fifo_release_mem[1] || !fifo_release_pix[1];
    // Functional memory enables must not use pixel-domain reset release directly.
    wire fifo_mem_ready;
    reset_sync u_fifo_mem_gate(.clk(mem_clk),.ext_rst_n(~fifo_reset),.rst_n_sync(fifo_mem_ready));
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire pixel_pop = pixel_consume && prefetch_valid && !frame_bad_pix;
    wire [ADDR_WIDTH:0] inflight_words =
        {{(ADDR_WIDTH+1-INFLIGHT_COUNT_W){1'b0}}, inflight_count_mem};
    wire final_return = returned_count_mem == IMAGE_WORDS - 1;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_words};
    localparam integer FULL_BURSTS_ONLY = (IMAGE_WORDS % BURST_SIZE) == 0;
    wire [ADDR_WIDTH:0] remaining_words = IMAGE_WORDS - issued_count_mem;
    wire [ADDR_WIDTH:0] next_burst_words =
        FULL_BURSTS_ONLY ? BURST_SIZE :
        ((remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words);
    wire [ADDR_WIDTH+2:0] reserved_after_burst =
        {{1{1'b0}}, reserved_words} + {{2{1'b0}}, next_burst_words};
    wire inflight_window_ok = (MAX_INFLIGHT_BURSTS == 1) ?
        inflight_empty_mem :
        ((inflight_words + next_burst_words) <=
         (MAX_INFLIGHT_BURSTS * BURST_SIZE));
    wire fifo_reservation_ok =
        reserved_after_burst <= (FIFO_DEPTH - FIFO_MARGIN);
    reg inflight_window_ok_q;
    reg fifo_reservation_ok_q;
    assign read_bus_busy=burst_active_mem || app_rd_en || !inflight_empty_mem || burst_gap_count_mem!=0;
    wire start_burst = !DIAG_SYNTH_STREAM && reader_busy && controller_init_done &&
                       !controller_busy && !refresh_active && !write_bus_busy &&
                       !reload_pending_mem && request_sync2_mem==request_seen_mem && !fatal_mem &&
                       fifo_mem_ready && fifo_reset_count_mem == 0 && !burst_active_mem &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem != IMAGE_WORDS &&
                       inflight_window_ok_q && fifo_reservation_ok_q;
    wire issue_allowed = !DIAG_SYNTH_STREAM && reader_busy && burst_active_mem;
    wire diag_stream_write = DIAG_SYNTH_STREAM && reader_busy &&
                             fifo_mem_ready && !fifo_full;
    wire fifo_write_enable = DIAG_SYNTH_STREAM ? diag_stream_write :
                             (sdram_rd_valid && keep_return && !inflight_empty_mem && fifo_mem_ready && !fifo_full && !fatal_mem);
    wire [31:0] fifo_write_data = (DIAG_RETURN_PATTERN || DIAG_SYNTH_STREAM) ?
                                  {8'h00, diag_rgb_mem} : sdram_rd_data;

    always @* begin
        if (diag_column_mem < 10'd80)
            diag_rgb_mem = 24'hffffff;
        else if (diag_column_mem < 10'd160)
            diag_rgb_mem = 24'hffff00;
        else if (diag_column_mem < 10'd240)
            diag_rgb_mem = 24'h00ffff;
        else if (diag_column_mem < 10'd320)
            diag_rgb_mem = 24'h00ff00;
        else if (diag_column_mem < 10'd400)
            diag_rgb_mem = 24'hff00ff;
        else if (diag_column_mem < 10'd480)
            diag_rgb_mem = 24'hff0000;
        else if (diag_column_mem < 10'd560)
            diag_rgb_mem = 24'h0000ff;
        else
            diag_rgb_mem = 24'h000000;
    end

    function [ADDR_WIDTH-1:0] bank_base;
        input [2:0] index;
        begin
            case (index)
                3'd0: bank_base = {ADDR_WIDTH{1'b0}};
                3'd1: bank_base = IMAGE_WORDS;
                3'd2: bank_base = IMAGE_WORDS * 2;
                3'd3: bank_base = IMAGE_WORDS * 3;
                3'd4: bank_base = IMAGE_WORDS * 4;
                3'd5: bank_base = IMAGE_WORDS * 5;
                default: bank_base = 0;
            endcase
        end
    endfunction

    // Delay the request by one pixel clock so media_player_control can commit
    // active_index on the frame_start edge before this module captures it.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            frame_bad_pix<=0;
            request_pending_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 2'd0;
            request_thumb_pix <= 0;
            armed_thumb_pix <= 0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
        end else begin
            if (frame_start) begin
                frame_bad_pix<=0;
                if (frame_armed_pix && consumed_count_pix != expected_consumed) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
            end else if (request_pending_pix) begin
                request_index_pix <= active_index;
                request_thumb_pix <= THUMBNAILS && thumbnail_mode && !DIAG_SYNTH_STREAM;
                armed_thumb_pix <= THUMBNAILS && thumbnail_mode && !DIAG_SYNTH_STREAM;
                if (display_valid) request_toggle_pix <= ~request_toggle_pix;
                request_pending_pix <= 1'b0;
                frame_armed_pix <= display_valid;
            end

            if (pixel_consume && frame_armed_pix && !frame_bad_pix) begin
                if (prefetch_valid)
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                else if (frame_armed_pix) begin
                    underflow <= 1'b1; frame_bad_pix<=1;
                end
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            fatal_mem<=0; return_timer<=0;
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 2'd0;
            index_sync2_mem <= 2'd0;
            reload_pending_mem <= 1'b0;
            reload_index_mem <= 2'd0;
            thumb_sync1_mem<=0; thumb_sync2_mem<=0;
            reload_thumb_mem<=0; thumb_mem<=0;
            thumb_block_mem<=0; thumb_burst_mem<=0;
            thumb_row_mem<=0; thumb_right_mem<=0;
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            inflight_count_mem <= 0;
            inflight_empty_mem <= 1'b1;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            diag_written_count_mem <= 0;
            diag_column_mem <= 0;
            inflight_window_ok_q <= 1'b1;
            fifo_reservation_ok_q <= 1'b1;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 2'd0;
            reader_error <= ERR_NONE;
        end else begin
            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            thumb_sync1_mem <= request_thumb_pix;
            thumb_sync2_mem <= thumb_sync1_mem;
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;
            inflight_window_ok_q <= inflight_window_ok;
            fifo_reservation_ok_q <= fifo_reservation_ok;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            case ({issue_allowed, sdram_rd_valid})
                2'b10: begin
                    inflight_count_mem <= inflight_count_mem + 1'b1;
                    inflight_empty_mem <= 1'b0;
                end
                2'b01: begin
                    if (!inflight_empty_mem) begin
                        inflight_count_mem <= inflight_count_mem - 1'b1;
                        if (inflight_count_mem == 1)
                            inflight_empty_mem <= 1'b1;
                    end
                end
                default: begin
                    inflight_count_mem <= inflight_count_mem;
                    inflight_empty_mem <= inflight_empty_mem;
                end
            endcase

            if (request_sync2_mem != request_seen_mem) begin
                request_seen_mem <= request_sync2_mem;
                reload_pending_mem <= 1'b1;
                reload_index_mem <= index_sync2_mem;
                reload_thumb_mem <= thumb_sync2_mem;
                if (reader_busy || !inflight_empty_mem) begin
                    // Finish an active burst; drain all outstanding replies before reset.
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end

            if (reload_pending_mem && inflight_empty_mem && !burst_active_mem && !app_rd_en && !fatal_mem) begin
                reload_pending_mem <= 1'b0;
                reader_index <= reload_index_mem;
                thumb_mem <= reload_thumb_mem;
                thumb_block_mem<=0; thumb_burst_mem<=0;
                thumb_row_mem<=0; thumb_right_mem<=0;
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                inflight_count_mem <= 0;
                inflight_empty_mem <= 1'b1;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                diag_written_count_mem <= 0;
                diag_column_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                reader_busy <= 1'b1;
                reader_error <= ERR_NONE;
            end

            if (start_burst) begin
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= next_burst_words[BURST_COUNT_W-1:0];
            end

            if (issue_allowed) begin
                app_rd_en <= 1'b1;
                if (thumb_mem)
                    app_rd_addr <= {thumb_block_mem,burst_issued_mem[6:0]};
                else
                    app_rd_addr <= bank_base(reader_index) + issued_count_mem[ADDR_WIDTH-1:0];
                issued_count_mem <= issued_count_mem + 1'b1;
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    if (thumb_mem) begin
                        thumb_block_mem <= thumb_block_mem + thumb_block_step;
                        if (thumb_burst_mem==4) begin
                            thumb_burst_mem<=0;
                            thumb_right_mem<=~thumb_right_mem;
                            if (thumb_right_mem)
                                thumb_row_mem <= (thumb_row_mem==119) ? 0 : thumb_row_mem+1'b1;
                        end else thumb_burst_mem<=thumb_burst_mem+1'b1;
                    end
                    burst_active_mem <= 1'b0;
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            if (!DIAG_SYNTH_STREAM && sdram_rd_valid && !inflight_empty_mem && !fatal_mem) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (fifo_full && keep_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (final_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end

            // Replies have no transaction tags: a missing return cannot safely
            // be "forgotten" before starting another frame. Fail closed until reset.
            if (inflight_empty_mem || sdram_rd_valid) return_timer<=0;
            else if (return_timer>=RETURN_TIMEOUT) begin
                fatal_mem<=1; reader_busy<=0; reader_error<=ERR_SHORT_FRAME;
            end else return_timer<=return_timer+1'b1;

            if (DIAG_SYNTH_STREAM && diag_stream_write) begin
                diag_written_count_mem <= diag_written_count_mem + 1'b1;
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
                if (diag_written_count_mem == IMAGE_WORDS - 1) begin
                    reader_busy <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end else if (!DIAG_SYNTH_STREAM && DIAG_RETURN_PATTERN &&
                         sdram_rd_valid) begin
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
            end
        end
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(fifo_write_enable), .di(fifo_write_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    // The memory-domain flush pulse may be shorter than one pixel period.
    // Assert asynchronously in both domains, then release on local clocks.
    always @(posedge mem_clk or posedge fifo_reset_request)
        if (fifo_reset_request) fifo_release_mem<=0;
        else fifo_release_mem<={fifo_release_mem[0],1'b1};
    always @(posedge pix_clk or posedge fifo_reset_request)
        if (fifo_reset_request) fifo_release_pix<=0;
        else fifo_release_pix<={fifo_release_pix[0],1'b1};
    wire prefetch_rst_n;
    reset_sync u_prefetch_reset (
        .clk(pix_clk),.ext_rst_n(~fifo_reset),.rst_n_sync(prefetch_rst_n)
    );
    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(~prefetch_rst_n), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(pixel_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    assign pixel_rgb = prefetch_data[23:0];
    assign pixel_valid = prefetch_valid && frame_armed_pix && !frame_bad_pix;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            // The memory-domain error remains authoritative for controller faults.
        end else if (underflow) begin
            // underflow is exported separately; the Top may merge it as 8'h63.
        end
    end

endmodule
