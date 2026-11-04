`timescale 1ns/1ps

// Fade controller adapted from the lesson reference. Manual next/previous
// runs the full fade-out -> black dwell -> fade-in sequence and only releases
// the switch request to media_player_control at the fully black frame, so the
// SDRAM never has to serve two frames at once. Automatic slideshow switches
// cannot be anticipated (media_player_control issues them internally), so the
// idle state follows index_commit with a left-to-right reveal from black.
// FADE_FRAMES = 0 bypasses the whole machine: next_event passes straight
// through (including previous) and alpha stays 255. Legal range is 0..256.
module video_fade_transition #(
    parameter integer FADE_FRAMES = 0
) (
    input  wire       ctrl_clk,
    input  wire       ctrl_rst_n,
    input  wire       next_event_in,
    input  wire       prev_event_in,
    input  wire       player_request_busy,
    output wire       prev_event_out,
    output wire       next_event_out,
    output wire       fade_busy,

    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       player_active,
    input  wire       frame_start,
    input  wire       index_commit,
    input  wire [1:0] active_index,
    output wire [7:0] alpha_out,
    output wire       fade_active,
    // Wipe reveal: automatic slideshow switches recover with a left-to-right
    // reveal instead of an alpha ramp. wipe_active gates the pixel-domain
    // coordinate compare; ramp_out drives the reveal boundary counter.
    output wire       wipe_active,
    output wire [8:0] ramp_out,
    output wire [1:0] transition_kind
);
    generate
        if (FADE_FRAMES == 0) begin : g_bypass
            assign next_event_out = next_event_in;
            assign prev_event_out = prev_event_in;
            assign fade_busy = 1'b0;
            assign alpha_out = 8'd255;
            assign fade_active = 1'b0;
            assign wipe_active = 1'b0;
            assign ramp_out = 9'd0;
            assign transition_kind = 2'd0;
        end else begin : g_fade
            // Supported: 1..256 frames; non-powers of two also span 0..255.

            // ramp holds FADE_FRAMES while unaligned, so it needs one more
            // value than a plain 0..FADE_FRAMES-1 counter.
            localparam integer CNT_W = (FADE_FRAMES <= 2) ? 2 : $clog2(FADE_FRAMES + 1);

            localparam [1:0] S_IDLE = 2'd0;
            localparam [1:0] S_OUT  = 2'd1;
            localparam [1:0] S_HOLD = 2'd2;
            localparam [1:0] S_IN   = 2'd3;

            // ---- shared registers (declared before both always blocks) ----
            reg req_toggle;
            reg request_pending, request_prev;
            (* async_reg="true" *) reg active_sync1, active_sync2;

            reg ack_seen;
            (* async_reg="true" *) reg commit_sync1, commit_sync2;
            (* async_reg="true" *) reg busy_sync1, busy_sync2;

            wire accept_request = (next_event_in || prev_event_in) &&
                active_sync2 && !player_request_busy && !request_pending && !busy_sync2;

            // ---- pixel-domain sequencer ----
            reg [1:0] state;
            reg [CNT_W-1:0] ramp;
            (* async_reg="true" *) reg req_sync1, req_sync2;
            reg req_seen;
            reg commit_toggle;
            reg wipe_mode;
            reg [1:0] wipe_kind;

            wire fade_running = (state != S_IDLE);
            assign fade_active = fade_running;
            // Nine bits include 256. The reference five-bit output cannot
            // represent the documented FADE_FRAMES=32 startup value.
            assign ramp_out = ramp;
            assign wipe_active = (state == S_IN) && wipe_mode;
            assign transition_kind = wipe_kind;

            wire [31:0] ramp_alpha = (ramp * 256) / FADE_FRAMES;
            wire [7:0] ramp_alpha8 = ramp_alpha[7:0];
            // ramp == FADE_FRAMES means the request arrived mid-frame and the
            // current frame must still display untouched full brightness; the
            // fade visibly starts with the next complete frame.
            assign alpha_out = ((state == S_IDLE) ||
                               ((state == S_IN) && wipe_mode)) ? 8'd255 :
                               (state == S_HOLD)  ? 8'd0   :
                               (ramp == FADE_FRAMES) ? 8'd255 : ramp_alpha8;

            always @(posedge pix_clk or negedge pix_rst_n) begin
                if (!pix_rst_n) begin
                    state <= S_IDLE;
                    ramp <= {CNT_W{1'b0}};
                    req_sync1 <= 1'b0;
                    req_sync2 <= 1'b0;
                    req_seen <= 1'b0;
                    commit_toggle <= 1'b0;
                    wipe_mode <= 1'b0;
                    wipe_kind <= 2'd0;
                end else begin
                    req_sync1 <= req_toggle;
                    req_sync2 <= req_sync1;

                    case (state)
                    S_IDLE: begin
                        if (req_sync2 != req_seen) begin
                            req_seen <= req_sync2;
                            if (player_active) begin
                                state <= S_OUT;
                                ramp <= FADE_FRAMES[CNT_W-1:0];
                            end
                        end else if (index_commit && player_active) begin
                            // Automatic slideshow switch: the old frame is
                            // already committed away; reveal the new one
                            // left-to-right over a black background.
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b1;
                            wipe_kind <= active_index;
                        end
                    end
                    S_OUT: begin
                        if (frame_start) begin
                            if (ramp == 0) begin
                                state <= S_HOLD;
                                commit_toggle <= ~commit_toggle;
                            end else begin
                                ramp <= ramp - 1'b1;
                            end
                        end
                        // Track the request handshake even mid-fade so a
                        // second early event cannot desync req_seen.
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                    end
                    S_HOLD: begin
                        if (index_commit) begin
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b0;
                        end
                    end
                    S_IN: begin
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                        if (frame_start) begin
                            if (ramp >= FADE_FRAMES - 1)
                                state <= S_IDLE;
                            else
                                ramp <= ramp + 1'b1;
                        end
                    end
                    endcase
                end
            end

            // ---- control-domain bookkeeping ----
            // Assert immediately, including the outbound request CDC latency.
            assign fade_busy = busy_sync2 || request_pending || accept_request;
            assign next_event_out = (commit_sync2 != ack_seen) && !request_prev;
            assign prev_event_out = (commit_sync2 != ack_seen) && request_prev;

            always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
                if (!ctrl_rst_n) begin
                    req_toggle <= 1'b0;
                    request_pending <= 1'b0;
                    request_prev <= 1'b0;
                    active_sync1 <= 1'b0;
                    active_sync2 <= 1'b0;
                    ack_seen <= 1'b0;
                    commit_sync1 <= 1'b0;
                    commit_sync2 <= 1'b0;
                    busy_sync1 <= 1'b0;
                    busy_sync2 <= 1'b0;
                end else begin
                    active_sync1 <= player_active;
                    active_sync2 <= active_sync1;
                    if (busy_sync2) request_pending <= 1'b0;
                    busy_sync1 <= fade_running;
                    busy_sync2 <= busy_sync1;
                    commit_sync1 <= commit_toggle;
                    commit_sync2 <= commit_sync1;
                    // Events during an active fade are dropped; the display
                    // is already transitioning and control cannot accept a
                    // second request before the black dwell anyway.
                    if (accept_request) begin
                        req_toggle <= ~req_toggle;
                        request_pending <= 1'b1;
                        request_prev <= !next_event_in && prev_event_in;
                    end
                    if (commit_sync2 != ack_seen)
                        ack_seen <= commit_sync2;
                end
            end
        end
    endgenerate
endmodule
