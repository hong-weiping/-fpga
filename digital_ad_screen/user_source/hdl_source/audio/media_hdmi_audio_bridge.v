`timescale 1ns/1ps

// Player-owned boundary between the registered video bundle and the verified
// Route B HDMI packet/symbol chain. The EG4 DDR PHY remains in the board Top so
// this bridge can be exercised in ordinary RTL simulation without vendor pads.
// media_id drives the per-image tone selection and volume scales the output,
// turning the tone source into the audio half of the AV-linked feature.
module media_hdmi_audio_bridge #(parameter EXTERNAL_AUDIO=0, parameter PAIRED_AUDIO=0, parameter PIXEL_HZ=25000000, parameter H_ACTIVE=640, parameter H_TOTAL=800) (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    input  wire [10:0]  video_x,
    input  wire [23:0] video_rgb,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    input  wire wav_active,wav_valid,force_arpeggio,
    input  wire signed [15:0] wav_sample,
    input  wire [7:0] fade_gain,
    output wire wav_ready,sample_tick,
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol,
    output wire        sequence_error,
    output wire        tone_overflow,
    output wire        pcm_contract_error,
    output wire        blip_active,
    output wire        pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left
);
    wire source_valid;
    wire source_ready;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;

    reg video_hsync_q;
    reg video_vsync_q;
    reg video_de_q;
    reg [10:0] video_x_q;
    reg [23:0] video_rgb_q;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            video_hsync_q <= 1'b1;
            video_vsync_q <= 1'b1;
            video_de_q <= 1'b0;
            video_x_q <= 10'd0;
            video_rgb_q <= 24'h000000;
        end else begin
            video_hsync_q <= video_hsync;
            video_vsync_q <= video_vsync;
            video_de_q <= video_de;
            video_x_q <= video_x;
            video_rgb_q <= video_de ? video_rgb : 24'h000000;
        end
    end

    wire tone_valid,tone_ready,arp_ready;
    wire signed [15:0] tone_left,tone_right;
    wire use_wav=EXTERNAL_AUDIO ? (wav_active && !force_arpeggio) : 1'b0;
    reg [25:0] rate_accumulator;
    assign sample_tick=rate_accumulator >= PIXEL_HZ-48000;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) rate_accumulator<=0;
        else if(sample_tick) rate_accumulator<=rate_accumulator+48000-PIXEL_HZ;
        else rate_accumulator<=rate_accumulator+48000;
    end
    // Keep the unselected oscillator drained. Backpressuring a free-running
    // tone forever would fill its eight-sample FIFO and assert overflow.
    assign tone_ready=use_wav ? 1'b1 : arp_ready;
    pcm_media_tone #(.CLOCK_HZ(PIXEL_HZ)) u_tone (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .media_id(media_id), .volume(EXTERNAL_AUDIO ? 8'd255 : volume),
        .sample_valid(tone_valid), .sample_ready(tone_ready),
        .sample_left(tone_left), .sample_right(tone_right),
        .overflow(tone_overflow), .blip_active(blip_active)
    );
    generate if(EXTERNAL_AUDIO) begin : g_stream
        wire raw_valid,raw_ready;
        wire signed [15:0] raw_left,raw_right;
        audio_source_mux mux (
            .clk(pixel_clk),.rst_n(pixel_rst_n),
            .wav_active(wav_active),.wav_valid(wav_valid),.wav_ready(wav_ready),
            .wav_left(wav_sample),.wav_right(wav_sample),
            .arp_valid(tone_valid),.arp_ready(arp_ready),
            // Paired mode uses timed silence while loading or after completion.
            .arp_left(PAIRED_AUDIO && !force_arpeggio ? 16'sd0 : tone_left),
            .arp_right(PAIRED_AUDIO && !force_arpeggio ? 16'sd0 : tone_right),
            .force_arpeggio(force_arpeggio),.out_valid(raw_valid),.out_ready(raw_ready),
            .out_left(raw_left),.out_right(raw_right)
        );
        pcm_gain_pipeline scaler (
            .clk(pixel_clk),.rst_n(pixel_rst_n),
            .in_valid(raw_valid),.in_ready(raw_ready),.in_left(raw_left),.in_right(raw_right),
            .volume(volume),.fade_gain(fade_gain),
            .out_valid(source_valid),.out_ready(source_ready),.out_left(source_left),.out_right(source_right)
        );
    end else begin : g_legacy
        assign wav_ready=1'b0;
        assign source_valid=tone_valid;
        assign source_left=tone_left;
        assign source_right=tone_right;
        assign arp_ready=source_ready;
    end endgenerate

    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(source_valid), .source_ready(source_ready),
        .source_left(source_left), .source_right(source_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    hdmi_audio_symbol_core #(.PIXEL_HZ(PIXEL_HZ),.H_ACTIVE(H_ACTIVE),.H_TOTAL(H_TOTAL),.ACR_INTERVAL_CYCLES(PIXEL_HZ/1000)) u_symbol_core (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n),
        .video_hsync(video_hsync_q), .video_vsync(video_vsync_q),
        .video_de(video_de_q), .video_x(video_x_q), .video_rgb(video_rgb_q),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .channel0_symbol(channel0_symbol),
        .channel1_symbol(channel1_symbol),
        .channel2_symbol(channel2_symbol),
        .sequence_error(sequence_error)
    );

    assign pcm_tap_valid = sample_valid && sample_ready;
    assign pcm_tap_left = sample_left;
endmodule
