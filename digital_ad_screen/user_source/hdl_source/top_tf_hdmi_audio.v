
module top(
    inout wire light_scl,light_sda, // M1/L1: ADS1115 3.3V open-drain
    output wire buzzer_n, // H11: low-active onboard buzzer
    input wire uart_rx,    // L10: FPGA RX <- ESP8266 TXD, 115200 8N1
    output wire uart_tx,   // M10: FPGA TX -> ESP8266 RXD
    output wire esp8266_en, // P11: active-high enable
    inout wire GPIOA_0, // M14: DHT11 open-drain data
    input                       clk,
    input                       GPIOB_0,       // N1: active-low fire sensor
    input                       GPIOB_1,       // M2: active-high noise sensor
    input                       key3,
    input                       key4,
    input [3:0]                 sw,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

wire board_rst_n;
wire fire_flag;
reg [14:0] buzzer_count;
always @(posedge clk or negedge board_rst_n)
 if(!board_rst_n) buzzer_count<=0;
 else if(!fire_flag) buzzer_count<=0;
 else if(buzzer_count==15'd24999) buzzer_count<=0;
 else buzzer_count<=buzzer_count+1'b1;
// Passive buzzer: 50 MHz / 25000 = 2 kHz, 50% duty cycle.
// Continuous tone during fire. High (silent) during reset or no fire.
assign buzzer_n=!(board_rst_n && fire_flag && buzzer_count<15'd12500);
wire frame_start; // Declare before all consumers.
assign esp8266_en = 1'b1;

parameter MEM_DATA_BITS=32;
parameter ADDR_BITS=21;
parameter FRAME_PIXELS=307200;
parameter AUDIO_ENABLE=1;
parameter integer NOISE_HOLD_SECONDS=10; // Board clock is 50 MHz
parameter [7:0] AUDIO_VOLUME=128;
parameter FORCE_ARPEGGIO=0;
parameter FADE_FRAMES=16; // 0 bypass; 1..256 frames per fade leg/reveal
wire sd_card_clk,ext_mem_clk,ext_mem_clk_sft,video_clk,hdmi_5x_clk;
wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,Sdr_rd_en;
wire [31:0] Sdr_rd_dout,App_wr_din;
wire App_rd_en,App_wr_en;
wire [20:0] App_rd_addr,App_wr_addr;
wire [3:0] App_wr_dm;
wire hs,vs,de;
wire [23:0] vout_data;
wire [9:0] tmds_ch0_data,tmds_ch1_data,tmds_ch2_data,tmds_clk_data;
// Lesson 5: POR, PLL qualification, and per-domain reset release.
// Audio is generated in video_clk in this project (no separate audio PLL).
wire sys_pll_lock, video_pll_lock;
wire sdcard_rst_n, mem_rst_n, video_rst_n;
wire pixel_rst_n = video_rst_n;
(* keep="true" *) wire esp8266_connected;
(* keep="true" *) wire [3:0] esp8266_stage;
(* keep="true" *) wire [7:0] esp8266_last_error;
wire automatic_brightness,light_sensor_ok,adc_healthy,adc_valid;
wire [15:0] light_adc;
wire [7:0] effective_brightness,requested_brightness;
ads1115_light u_light_adc(.clk(clk),.rst_n(board_rst_n),.scl(light_scl),.sda(light_sda),.sample(light_adc),.sample_valid(adc_valid),.healthy(adc_healthy));
ambient_brightness u_auto_brightness(.clk(clk),.rst_n(board_rst_n),.auto_mode(automatic_brightness),.healthy(adc_healthy),.sample_valid(adc_valid),.sample(light_adc),.manual(requested_brightness),.brightness(effective_brightness),.sensor_ok(light_sensor_ok));
wire [3:0] control_request,control_request_sd;
wire [10:0] control_reply,control_reply_sd;
wire [7:0] brightness_video,applied_brightness,brightness_sd;
wire remote_muted,muted_video,muted_applied_sd;
reg muted_applied_video;
wire remote_next,remote_prev,remote_auto_valid,remote_auto_value,remote_busy;
wire [2:0] remote_display_sd;
dht_snapshot_cdc #(.WIDTH(4)) u_control_request_cdc(.src_clk(clk),.src_rst_n(board_rst_n),.src_data(control_request),.dst_clk(sd_card_clk),.dst_rst_n(sdcard_rst_n),.dst_data(control_request_sd));
dht_snapshot_cdc #(.WIDTH(11)) u_control_reply_cdc(.src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),.src_data(control_reply_sd),.dst_clk(clk),.dst_rst_n(board_rst_n),.dst_data(control_reply));
dht_snapshot_cdc #(.WIDTH(8)) u_brightness_cdc(.src_clk(clk),.src_rst_n(board_rst_n),.src_data(effective_brightness),.dst_clk(video_clk),.dst_rst_n(video_rst_n),.dst_data(brightness_video));
dht_snapshot_cdc #(.WIDTH(8)) u_brightness_ack(.src_clk(video_clk),.src_rst_n(video_rst_n),.src_data(applied_brightness),.dst_clk(sd_card_clk),.dst_rst_n(sdcard_rst_n),.dst_data(brightness_sd));
wire [7:0] brightness_ack;
dht_snapshot_cdc #(.WIDTH(8)) u_brightness_uart(.src_clk(video_clk),.src_rst_n(video_rst_n),.src_data(applied_brightness),.dst_clk(clk),.dst_rst_n(board_rst_n),.dst_data(brightness_ack));
sync_2ff u_mute_video(.clk(video_clk),.rst_n(video_rst_n),.async_in(remote_muted),.sync_out(muted_video));
sync_2ff u_mute_ack(.clk(sd_card_clk),.rst_n(sdcard_rst_n),.async_in(muted_applied_video),.sync_out(muted_applied_sd));
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n) muted_applied_video<=0;else muted_applied_video<=muted_video;
wire [7:0] requested_volume,volume_video,applied_volume;
wire requested_notice,notice_video,applied_notice;
reg notice_applied_video;
dht_snapshot_cdc #(.WIDTH(1)) u_notice_to_video(
 .src_clk(clk),.src_rst_n(board_rst_n),.dst_clk(video_clk),.dst_rst_n(video_rst_n),
 .src_data(requested_notice),.dst_data(notice_video));
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n) notice_applied_video<=0;
 else if(frame_start) notice_applied_video<=notice_video;
dht_snapshot_cdc #(.WIDTH(1)) u_notice_applied(
 .src_clk(video_clk),.src_rst_n(video_rst_n),.dst_clk(clk),.dst_rst_n(board_rst_n),
 .src_data(notice_applied_video),.dst_data(applied_notice));
reg [7:0] runtime_gain,volume_applied_video;
// Match 50% to the original gain 128; 100% maps to 255 and 0% is silent.
// Handshakes transfer complete bytes between the board and audio clock domains.
dht_snapshot_cdc #(.WIDTH(8)) u_volume_to_audio(
 .src_clk(clk),.src_rst_n(board_rst_n),.dst_clk(video_clk),.dst_rst_n(video_rst_n),
 .src_data(requested_volume),.dst_data(volume_video));
function [7:0] percent_gain;
 input [7:0] percent;
 begin case(percent)
  8'd0: percent_gain=8'd0;
  8'd1: percent_gain=8'd3;
  8'd2: percent_gain=8'd5;
  8'd3: percent_gain=8'd8;
  8'd4: percent_gain=8'd10;
  8'd5: percent_gain=8'd13;
  8'd6: percent_gain=8'd15;
  8'd7: percent_gain=8'd18;
  8'd8: percent_gain=8'd20;
  8'd9: percent_gain=8'd23;
  8'd10: percent_gain=8'd26;
  8'd11: percent_gain=8'd28;
  8'd12: percent_gain=8'd31;
  8'd13: percent_gain=8'd33;
  8'd14: percent_gain=8'd36;
  8'd15: percent_gain=8'd38;
  8'd16: percent_gain=8'd41;
  8'd17: percent_gain=8'd43;
  8'd18: percent_gain=8'd46;
  8'd19: percent_gain=8'd48;
  8'd20: percent_gain=8'd51;
  8'd21: percent_gain=8'd54;
  8'd22: percent_gain=8'd56;
  8'd23: percent_gain=8'd59;
  8'd24: percent_gain=8'd61;
  8'd25: percent_gain=8'd64;
  8'd26: percent_gain=8'd66;
  8'd27: percent_gain=8'd69;
  8'd28: percent_gain=8'd71;
  8'd29: percent_gain=8'd74;
  8'd30: percent_gain=8'd77;
  8'd31: percent_gain=8'd79;
  8'd32: percent_gain=8'd82;
  8'd33: percent_gain=8'd84;
  8'd34: percent_gain=8'd87;
  8'd35: percent_gain=8'd89;
  8'd36: percent_gain=8'd92;
  8'd37: percent_gain=8'd94;
  8'd38: percent_gain=8'd97;
  8'd39: percent_gain=8'd99;
  8'd40: percent_gain=8'd102;
  8'd41: percent_gain=8'd105;
  8'd42: percent_gain=8'd107;
  8'd43: percent_gain=8'd110;
  8'd44: percent_gain=8'd112;
  8'd45: percent_gain=8'd115;
  8'd46: percent_gain=8'd117;
  8'd47: percent_gain=8'd120;
  8'd48: percent_gain=8'd122;
  8'd49: percent_gain=8'd125;
  8'd50: percent_gain=8'd128;
  8'd51: percent_gain=8'd130;
  8'd52: percent_gain=8'd133;
  8'd53: percent_gain=8'd135;
  8'd54: percent_gain=8'd138;
  8'd55: percent_gain=8'd140;
  8'd56: percent_gain=8'd143;
  8'd57: percent_gain=8'd145;
  8'd58: percent_gain=8'd148;
  8'd59: percent_gain=8'd150;
  8'd60: percent_gain=8'd153;
  8'd61: percent_gain=8'd156;
  8'd62: percent_gain=8'd158;
  8'd63: percent_gain=8'd161;
  8'd64: percent_gain=8'd163;
  8'd65: percent_gain=8'd166;
  8'd66: percent_gain=8'd168;
  8'd67: percent_gain=8'd171;
  8'd68: percent_gain=8'd173;
  8'd69: percent_gain=8'd176;
  8'd70: percent_gain=8'd179;
  8'd71: percent_gain=8'd181;
  8'd72: percent_gain=8'd184;
  8'd73: percent_gain=8'd186;
  8'd74: percent_gain=8'd189;
  8'd75: percent_gain=8'd191;
  8'd76: percent_gain=8'd194;
  8'd77: percent_gain=8'd196;
  8'd78: percent_gain=8'd199;
  8'd79: percent_gain=8'd201;
  8'd80: percent_gain=8'd204;
  8'd81: percent_gain=8'd207;
  8'd82: percent_gain=8'd209;
  8'd83: percent_gain=8'd212;
  8'd84: percent_gain=8'd214;
  8'd85: percent_gain=8'd217;
  8'd86: percent_gain=8'd219;
  8'd87: percent_gain=8'd222;
  8'd88: percent_gain=8'd224;
  8'd89: percent_gain=8'd227;
  8'd90: percent_gain=8'd230;
  8'd91: percent_gain=8'd232;
  8'd92: percent_gain=8'd235;
  8'd93: percent_gain=8'd237;
  8'd94: percent_gain=8'd240;
  8'd95: percent_gain=8'd242;
  8'd96: percent_gain=8'd245;
  8'd97: percent_gain=8'd247;
  8'd98: percent_gain=8'd250;
  8'd99: percent_gain=8'd252;
  8'd100: percent_gain=8'd255;
  default: percent_gain=8'd128;
 endcase end
endfunction
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n) begin runtime_gain<=AUDIO_VOLUME;volume_applied_video<=50;end
 else begin runtime_gain<=muted_video ? 8'd0 : percent_gain(volume_video);volume_applied_video<=volume_video;end
dht_snapshot_cdc #(.WIDTH(8)) u_volume_applied(
 .src_clk(video_clk),.src_rst_n(video_rst_n),.dst_clk(clk),.dst_rst_n(board_rst_n),
 .src_data(volume_applied_video),.dst_data(applied_volume));
wire [16:0] dht_status_uart;
wire [7:0] mqtt_reject_byte;
wire mqtt_reject_valid,mqtt_reject_start,mqtt_reject_done;
wire [27:0] mqtt_reject_length;
wire [2:0] mqtt_feedback_status;
wire [15:0] mqtt_feedback_code;
wire [19:0] mqtt_status_pix;
dht_snapshot_cdc #(.WIDTH(20)) u_mqtt_snapshot(
 .src_clk(clk),.src_rst_n(board_rst_n),.dst_clk(video_clk),.dst_rst_n(video_rst_n),
 .src_data({esp8266_connected,mqtt_feedback_status,mqtt_feedback_code}),.dst_data(mqtt_status_pix));
wire env_time_set,env_weather_set;
wire [55:0] env_time_bcd;wire [23:0] env_weather_bcd;
wire [83:0] env_status,env_status_pix;
environment_clock u_environment_clock(.clk(clk),.rst_n(board_rst_n),.time_set(env_time_set),.weather_set(env_weather_set),.time_bcd(env_time_bcd),.weather_bcd(env_weather_bcd),.status(env_status));
dht_snapshot_cdc #(.WIDTH(84)) u_environment_cdc(.src_clk(clk),.src_rst_n(board_rst_n),.dst_clk(video_clk),.dst_rst_n(video_rst_n),.src_data(env_status),.dst_data(env_status_pix));
esp8266_controller #(.CLK_HZ(50000000), .BAUD(115200), .UPLOAD_MS(10000)) u_esp8266 (
    .clk(clk), .rst_n(board_rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .time_set(env_time_set),.weather_set(env_weather_set),.time_bcd(env_time_bcd),.weather_bcd(env_weather_bcd),
    .automatic_brightness(automatic_brightness),.light_sensor_ok(light_sensor_ok),
    .control_request(control_request),.control_reply(control_reply),.requested_brightness(requested_brightness),.applied_brightness(brightness_ack),
    .requested_notice(requested_notice),.applied_notice(applied_notice),.applied_volume(applied_volume),.requested_volume(requested_volume),.temperature(dht_status_uart[15:8]), .humidity(dht_status_uart[7:0]), .sensor_valid(dht_status_uart[16]), .fire_active(fire_flag),
    .reject_byte(mqtt_reject_byte),.reject_valid(mqtt_reject_valid),.reject_start(mqtt_reject_start),.reject_done(mqtt_reject_done),.reject_length(mqtt_reject_length),.feedback_status(mqtt_feedback_status),.feedback_code(mqtt_feedback_code),.connected(esp8266_connected), .stage(esp8266_stage), .last_error(esp8266_last_error)
);
// Internal flag reserved for alarm/control logic.
// fire_flag declared before controller and buzzer consumers.
fire_detector u_fire_detector (
    .clk(clk), .rst_n(board_rst_n),
    .fire_n(GPIOB_0), .fire_flag(fire_flag)
);
(* keep="true" *) wire noise_flag /* synthesis keep */;
wire noise_alarm;
noise_detector #(.HOLD_CYCLES(50000000 * NOISE_HOLD_SECONDS)) u_noise_detector (
    .clk(clk), .rst_n(board_rst_n),
    .noise_in(GPIOB_1), .fire_active(fire_flag), .noise_flag(noise_flag), .noise_alarm(noise_alarm)
);
wire [7:0] dht_temperature,dht_humidity;
wire dht_valid;
wire [1:0] dht_error;
wire [16:0] dht_status_pix;
// Run the low-rate sensor in the pixel domain to avoid an unnecessary
// status handshake between the 50 MHz board and 25 MHz video clocks.
dht11_reader #(.CLK_HZ(40000000)) u_dht11 (
 .clk(video_clk),.rst_n(video_rst_n),.data(GPIOA_0),
 .temperature(dht_temperature),.humidity(dht_humidity),
 .valid(dht_valid),.error_code(dht_error)
);
assign dht_status_pix={dht_valid,dht_temperature,dht_humidity};
dht_snapshot_cdc u_dht_snapshot (
 .src_clk(video_clk),.src_rst_n(video_rst_n),.dst_clk(clk),.dst_rst_n(board_rst_n),
 .src_data(dht_status_pix),.dst_data(dht_status_uart)
);
reg [15:0] startup_count = 16'd0;
always @(posedge clk) begin
    if (!(&startup_count))
        startup_count <= startup_count + 16'd1;
end
// Keep PLL reset independent of its own lock, avoiding a reset/lock deadlock.
wire pll_reset = ~(&startup_count);
wire ext_rst_n = ~pll_reset & sys_pll_lock & video_pll_lock;
reset_sync u_board_reset (
    .clk(clk), .ext_rst_n(ext_rst_n), .rst_n_sync(board_rst_n)
);
reset_sync u_sdcard_reset (
    .clk(sd_card_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(sdcard_rst_n)
);
reset_sync u_mem_reset (
    .clk(ext_mem_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(mem_rst_n)
);
reset_sync u_video_reset (
    .clk(video_clk), .ext_rst_n(ext_rst_n), .rst_n_sync(video_rst_n)
);
wire Sdr_init_done_sd;
sync_2ff u_sdram_init_sync (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n),
    .async_in(Sdr_init_done), .sync_out(Sdr_init_done_sd)
);
// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .extlock    (sys_pll_lock),
    .reset      (pll_reset)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .extlock    (video_pll_lock),
    .reset      (pll_reset)
);

// Startup ingestion: each existing PIC file is loaded once into its own bank.
wire source_start,source_pixel_valid,source_commit,source_ready,source_done;
wire [2:0] source_index;
wire [23:0] source_pixel;
wire [7:0] source_decode_error,source_memory_error,fs_error;
wire preload_done,cdc_overflow;
wire [5:0] failed_images;
wire audio_sd_read,audio_transport_reset,audio_sd_init,audio_sd_valid,audio_sd_end;
wire [31:0] audio_sd_addr;
wire [7:0] audio_sd_data;
sd_card_bmp #(.AUDIO_STREAM_ENABLE(AUDIO_ENABLE)) sd_card_bmp_m0 (
 .audio_sd_read(audio_sd_read),.audio_transport_reset(audio_transport_reset),.audio_sd_addr(audio_sd_addr),
 .audio_sd_init(audio_sd_init),.audio_sd_data(audio_sd_data),.audio_sd_valid(audio_sd_valid),.audio_sd_end(audio_sd_end),
 .clk(sd_card_clk),.rst(~sdcard_rst_n),.sdram_ready(Sdr_init_done_sd),.sink_ready(source_ready),
 .loader_start(source_start),.image_index(source_index),.pixel_valid(source_pixel_valid),
 .pixel_rgb(source_pixel),.frame_commit(source_commit),.decode_error(source_decode_error),
 .loader_done(source_done),.loader_error(source_memory_error),.preload_done(preload_done),
 .failed_images(failed_images),.fs_error(fs_error),
 .SD_nCS(sd_ncs),.SD_DCLK(sd_dclk),.SD_MOSI(sd_mosi),.SD_MISO(sd_miso)
);
wire loader_start,loader_pixel_valid,loader_commit,loader_done,loader_busy;
wire [2:0] loader_index;
wire [23:0] loader_pixel;
wire [7:0] loader_decode_error,loader_memory_error;
wire [5:0] image_complete;
media_pixel_cdc u_write_cdc (
 .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),.mem_clk(ext_mem_clk),.mem_rst_n(mem_rst_n),
 .load_start(source_start),.image_index(source_index),.pixel_valid(source_pixel_valid),
 .pixel_rgb(source_pixel),.frame_commit(source_commit),.decode_error(source_decode_error),
 .source_ready(source_ready),.source_done(source_done),.source_error(source_memory_error),
 .mem_load_start(loader_start),.mem_image_index(loader_index),.mem_pixel_valid(loader_pixel_valid),
 .mem_pixel_rgb(loader_pixel),.mem_frame_commit(loader_commit),.mem_decode_error(loader_decode_error),
 .mem_load_done(loader_done),.mem_memory_error(loader_memory_error),.overflow(cdc_overflow)
);
wire read_bus_busy,write_bus_busy;
media_frame_loader #(.IMAGE_WORDS(FRAME_PIXELS)) u_loader (
 .clk(ext_mem_clk),.rst_n(mem_rst_n),.load_start(loader_start),.image_index(loader_index),
 .pixel_valid(loader_pixel_valid),.pixel_rgb(loader_pixel),.frame_commit(loader_commit),
 .decode_error(loader_decode_error),.load_busy(loader_busy),.load_done(loader_done),
 .image_complete(image_complete),.memory_error(loader_memory_error),
 .controller_init_done(Sdr_init_done),.controller_busy(Sdr_busy),.refresh_active(Sdr_init_ref_vld),
 .read_bus_busy(read_bus_busy),.write_bus_busy(write_bus_busy),
 .app_wr_en(App_wr_en),.app_wr_addr(App_wr_addr),.app_wr_mask(App_wr_dm),.app_wr_data(App_wr_din)
);
// Completed-bank bits only rise during this preload session. Synchronize each
// independent bit; a bank is never reloaded after it becomes displayable.
(* async_reg="true" *) reg [5:0] complete_s1,complete_s2;
always @(posedge sd_card_clk or negedge sdcard_rst_n)
 if(!sdcard_rst_n) begin complete_s1<=0;complete_s2<=0;end
 else begin complete_s1<=image_complete;complete_s2<=complete_s1;end

wire key_next_press,key_auto_stable;
wire key_next_stable,thumbnail_requested,thumbnail_mode;
reg key_auto_d,long_mark;
reg [26:0] long_count;
wire prev_event=!key_auto_stable && !long_mark && long_count>=100000000-1;
wire toggle_auto_event=key_auto_stable && !key_auto_d && !long_mark;
key_press_debounce u_key_next (.clk(sd_card_clk),.rst(~sdcard_rst_n),.button_in(key1),
 .press_pulse(),.button_stable_out(key_next_stable));
key_press_debounce u_key_auto (.clk(sd_card_clk),.rst(~sdcard_rst_n),.button_in(key2),
 .press_pulse(),.button_stable_out(key_auto_stable));
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
 if(!sdcard_rst_n) begin key_auto_d<=1;long_mark<=0;long_count<=0;end
 else begin
  key_auto_d<=key_auto_stable;
  
  if(key_auto_stable) begin long_count<=0;long_mark<=0;end
  else if(!long_mark) begin
   if(prev_event) long_mark<=1;else long_count<=long_count+1'b1;
  end
 end
end
wire display_valid,index_commit,auto_enabled;
wire ad_display_valid,alarm_active,audio_selection_valid;
wire [1:0] active_index,pending_index;
(* async_reg="true" *) reg [5:0] complete_p1,complete_p2;
reg [5:0] complete_frame;
wire fire_sd,noise_sd,fire_pix,noise_pix,notice_sd;
sync_2ff u_notice_sd (.clk(sd_card_clk),.rst_n(sdcard_rst_n),.async_in(requested_notice),.sync_out(notice_sd));
wire alarm_pending_sd=fire_sd || notice_sd || noise_sd;
wire alarm_display_sd;
wire ad_suspend=alarm_pending_sd || alarm_display_sd;
sync_2ff u_fire_sd (.clk(sd_card_clk),.rst_n(sdcard_rst_n),.async_in(fire_flag),.sync_out(fire_sd));
sync_2ff u_noise_sd (.clk(sd_card_clk),.rst_n(sdcard_rst_n),.async_in(noise_alarm),.sync_out(noise_sd));
sync_2ff u_fire_pix (.clk(video_clk),.rst_n(video_rst_n),.async_in(fire_flag),.sync_out(fire_pix));
// Registered, preserved source boundary for the noise-to-pixel CDC.
(* keep="true" *) reg noise_cdc_launch /* synthesis keep */;
always @(posedge clk or negedge board_rst_n)
 if(!board_rst_n) noise_cdc_launch<=1'b0; else noise_cdc_launch<=noise_alarm;
sync_2ff u_noise_pix (.clk(video_clk),.rst_n(video_rst_n),.async_in(noise_cdc_launch),.sync_out(noise_pix));
sync_2ff u_alarm_display_sd (.clk(sd_card_clk),.rst_n(sdcard_rst_n),.async_in(alarm_active),.sync_out(alarm_display_sd));
wire effective_thumbnail=thumbnail_mode && !alarm_active;
wire [2:0] media_index;
alarm_media_select u_alarm_select (
 .pix_clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
 .fire_alarm(fire_pix),.child_notice(notice_video),.noise_alarm(noise_pix),.ad_index(active_index),
 .ad_valid(ad_display_valid),.image_complete(complete_frame),
 .media_index(media_index),.display_valid(display_valid),
 .audio_valid(audio_selection_valid),.alarm_active(alarm_active)
);
// Thumbnail mode disabled in this copy to reserve FPGA resources for network time/weather.
assign thumbnail_requested=1'b0;
assign thumbnail_mode=1'b0;
wire period_step;
wire [31:0] carousel_period;
wire [1:0] period_gray;
carousel_period_key u_carousel_key (.clk(sd_card_clk),.rst_n(sdcard_rst_n),.button_stable(key_next_stable),.short_press(key_next_press),.period_step(period_step),.period_cycles(carousel_period),.current_period_gray(period_gray));
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n) begin complete_p1<=0;complete_p2<=0;complete_frame<=0;end
 else begin
  complete_p1<=image_complete;complete_p2<=complete_p1;
  if(frame_start) complete_frame<=complete_p2;
 end
wire [2:0] selected_frame_index;
frame_index_snapshot u_frame_index (
 .pix_clk(video_clk),.pix_rst_n(video_rst_n),
 .active_index(media_index),.frame_index(selected_frame_index)
);
wire [7:0] control_error;
wire fade_next_event,fade_prev_event,fade_busy,fade_active,wipe_active;
wire player_request_busy;
wire [7:0] fade_alpha;
wire [8:0] wipe_ramp;
wire [1:0] transition_kind;
dht_snapshot_cdc #(.WIDTH(3)) u_control_display(.src_clk(video_clk),.src_rst_n(video_rst_n),.src_data({ad_display_valid,active_index}),.dst_clk(sd_card_clk),.dst_rst_n(sdcard_rst_n),.dst_data(remote_display_sd));
remote_media_control u_remote_media(.clk(sd_card_clk),.rst_n(sdcard_rst_n),.request(control_request_sd),.reply(control_reply_sd),
 .suspend(ad_suspend),.blocked(fade_busy || player_request_busy || key_next_press || prev_event || toggle_auto_event),
 .image_complete(complete_s2[3:0]),.display_state(remote_display_sd),.auto_enabled(auto_enabled),.muted_applied(muted_applied_sd),.brightness(brightness_sd),
 .muted(remote_muted),.next_event(remote_next),.prev_event(remote_prev),.auto_valid(remote_auto_valid),.auto_value(remote_auto_value),.busy(remote_busy));
video_fade_transition #(.FADE_FRAMES(FADE_FRAMES)) u_fade_transition (
 .ctrl_clk(sd_card_clk),.ctrl_rst_n(sdcard_rst_n && !ad_suspend),
 .next_event_in(((key_next_press && !remote_busy) || remote_next) && !thumbnail_requested && !ad_suspend),.prev_event_in(((prev_event && !remote_busy) || remote_prev) && !thumbnail_requested && !ad_suspend),
 .player_request_busy(player_request_busy),
 .next_event_out(fade_next_event),.prev_event_out(fade_prev_event),.fade_busy(fade_busy),
 .pix_clk(video_clk),.pix_rst_n(video_rst_n && !alarm_active),.player_active(ad_display_valid),
 .frame_start(frame_start),.index_commit(index_commit),.active_index(active_index),
 .alpha_out(fade_alpha),.fade_active(fade_active),.wipe_active(wipe_active),
 .ramp_out(wipe_ramp),.transition_kind(transition_kind)
);
media_player_control #(.TRANSITION_GATING(1),.DEFAULT_PERIOD_CYCLES(500000000)) u_control (
 .transition_busy(fade_busy || thumbnail_requested),.suspend(ad_suspend),
 .sys_clk(sd_card_clk),.sys_rst_n(sdcard_rst_n),
 .next_event(fade_next_event || (thumbnail_requested && key_next_press)),
 .prev_event(fade_prev_event || (thumbnail_requested && prev_event)),
 .toggle_auto_event(toggle_auto_event && !remote_busy),.period_cfg_valid(period_step),.period_cfg_cycles(carousel_period),
 .auto_cfg_valid(remote_auto_valid),.auto_cfg_enabled(remote_auto_value),.image_complete(complete_s2[3:0]),
 .auto_enabled(auto_enabled),.active_period_cycles(),.pending_index(pending_index),
 .control_error(control_error),.request_busy(player_request_busy),.pix_clk(video_clk),.pix_rst_n(video_rst_n),
 .frame_start(frame_start),.active_index(active_index),.index_commit(index_commit),.display_valid(ad_display_valid)
);
wire raw_hs,raw_vs,raw_de;
wire [11:0] raw_x,raw_y;
// ACTIVE_FIRST preserves the audio symbol core's x=0..639 video convention.
wire [11:0] screen_x,screen_y;
assign raw_x=screen_x-12'd16;
assign raw_y=screen_y-12'd64;
video_timing_ctrl #(.H_ACT(800),.H_FP(40),.H_SYNC(128),.H_BP(88),.V_ACT(600),.V_FP(1),.V_SYNC(4),.V_BP(23)) u_timing (
 .pclk(video_clk),.rst_n(video_rst_n),.hsync(raw_hs),.vsync(raw_vs),.de(raw_de),.x(screen_x),.y(screen_y)
);
reg raw_vs_q;
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n) raw_vs_q<=1;else raw_vs_q<=raw_vs;
assign frame_start=raw_vs_q && !raw_vs;
wire [23:0] reader_pixel;
wire reader_pixel_valid,reader_underflow,reader_busy,frame_read_done;
wire [2:0] reader_index;
wire [7:0] reader_error;
wire thumb_de,focus_border;
wire [1:0] thumb_source_index;
wire [9:0] thumb_source_x,thumb_source_y;
thumbnail_layout u_thumbnail_layout (
 .in_de(raw_de),.pixel_x(raw_x),.pixel_y(raw_y),.focus_index(active_index),
 .image_complete(complete_frame[3:0]),.thumb_de(thumb_de),.source_index(thumb_source_index),
 .source_x(thumb_source_x),.source_y(thumb_source_y),.focus_border(focus_border)
);
// Consume every grid position, even an unavailable image or a border pixel.
// The memory stream has exactly 320*240 sampled words in raster order.
wire reader_consume=raw_de && raw_x<640 && raw_y<480 && display_valid &&
                    (!effective_thumbnail || (raw_x<320 && raw_y<240));
media_frame_reader #(.IMAGE_WORDS(FRAME_PIXELS),.THUMBNAILS(0)) u_reader (
 .mem_clk(ext_mem_clk),.mem_rst_n(mem_rst_n),.controller_init_done(Sdr_init_done),
 .controller_busy(Sdr_busy),.refresh_active(Sdr_init_ref_vld),
 .write_bus_busy(write_bus_busy),.read_bus_busy(read_bus_busy),
 .app_rd_en(App_rd_en),.app_rd_addr(App_rd_addr),.sdram_rd_valid(Sdr_rd_en),.sdram_rd_data(Sdr_rd_dout),
 .pix_clk(video_clk),.pix_rst_n(video_rst_n),.frame_start(frame_start),.display_valid(display_valid),
 .active_index(selected_frame_index),.thumbnail_mode(effective_thumbnail),.pixel_consume(reader_consume),
 .pixel_rgb(reader_pixel),.pixel_valid(reader_pixel_valid),.underflow(reader_underflow),
 .reader_busy(reader_busy),.frame_read_done(frame_read_done),.reader_index(reader_index),.reader_error(reader_error)
);
// Paired PCM playback follows the committed picture selection.
wire [3:0] audio_request_sd,audio_session_pix;
wire [2:0] audio_session_index;
wire audio_quiesce,audio_transfer_busy,audio_running;
wire audio_ended_sd;
wire audio_source_reset_raw,audio_fifo_reset_raw;
wire audio_source_rst_n,audio_wr_rst_n,audio_rd_rst_n;
osd_status_cdc #(.WIDTH(4)) u_audio_request_cdc (
 .src_clk(video_clk),.src_rst_n(video_rst_n),
 .src_status({audio_selection_valid,selected_frame_index}),
 .dst_clk(sd_card_clk),.dst_rst_n(sdcard_rst_n),.dst_status(audio_request_sd)
);
paired_audio_session u_audio_session (
 .clk(sd_card_clk),.rst_n(sdcard_rst_n),.enable(preload_done && AUDIO_ENABLE),
 .requested(audio_request_sd),.transfer_busy(audio_transfer_busy),
 .replay(audio_ended_sd),
 .quiesce(audio_quiesce),.source_reset_n(audio_source_reset_raw),
 .fifo_reset_n(audio_fifo_reset_raw),.running(audio_running),.session_index(audio_session_index)
);
reset_sync u_audio_source_reset (.clk(sd_card_clk),.ext_rst_n(audio_source_reset_raw),.rst_n_sync(audio_source_rst_n));
reset_sync u_audio_wr_reset (.clk(sd_card_clk),.ext_rst_n(audio_fifo_reset_raw),.rst_n_sync(audio_wr_rst_n));
reset_sync u_audio_rd_reset (.clk(video_clk),.ext_rst_n(audio_fifo_reset_raw && video_rst_n),.rst_n_sync(audio_rd_rst_n));
osd_status_cdc #(.WIDTH(4)) u_audio_session_cdc (
 .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
 .src_status({audio_running && !audio_quiesce,audio_session_index}),
 .dst_clk(video_clk),.dst_rst_n(video_rst_n),.dst_status(audio_session_pix)
);
wire audio_matches_picture=audio_selection_valid && audio_session_pix[3] &&
                          audio_session_pix[2:0]==selected_frame_index;
wire audio_play_enable,audio_source_done,audio_byte_valid,audio_sector_ready;
wire [7:0] audio_byte,audio_fs_error;
wire [31:0] audio_byte_offset,audio_sample_counter;
wire audio_overflow,audio_underflow,wav_active,wav_end,wav_low,wav_valid,wav_ready,audio_tick;
// Register combinational FIFO-end detection before its asynchronous crossing.
(* keep="true" *) reg audio_end_cdc_launch /* synthesis keep */;
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n) audio_end_cdc_launch<=1'b0; else audio_end_cdc_launch<=wav_end;
sync_2ff u_audio_end_sd (.clk(sd_card_clk),.rst_n(sdcard_rst_n),.async_in(audio_end_cdc_launch),.sync_out(audio_ended_sd));
wire signed [15:0] wav_sample;
wire [7:0] audio_fade_gain;
fat32_pcm_source #(.PAIRED_AUDIO(1)) u_audio_source (
 .clk(sd_card_clk),.rst_n(audio_source_rst_n),.enable(audio_running && AUDIO_ENABLE),
 .image_index(audio_session_index),.quiesce(audio_quiesce),.transfer_busy(audio_transfer_busy),
 .sd_init_done(audio_sd_init),.buffer_ready(audio_sector_ready),
 .play_enable(audio_play_enable),.source_done(audio_source_done),
 .byte_valid(audio_byte_valid),.byte_data(audio_byte),.byte_offset(audio_byte_offset),.audio_error(audio_fs_error),
 .transport_reset(audio_transport_reset),.sd_sec_read(audio_sd_read),.sd_sec_read_addr(audio_sd_addr),
 .sd_sec_read_data(audio_sd_data),.sd_sec_read_data_valid(audio_sd_valid),.sd_sec_read_end(audio_sd_end)
);
wav_stream_player u_wav_player (
 .wr_clk(sd_card_clk),.wr_rst_n(audio_wr_rst_n),.play_enable(audio_play_enable),.source_done(audio_source_done),
 .byte_valid(audio_byte_valid),.byte_data(audio_byte),.byte_offset(audio_byte_offset),
 .sector_ready(audio_sector_ready),.overflow(audio_overflow),
 .rd_clk(video_clk),.rd_rst_n(audio_rd_rst_n),.sample_tick(audio_tick),.sample_ready(wav_ready && audio_matches_picture),
 .sample_out(wav_sample),.sample_valid(wav_valid),.sample_counter(audio_sample_counter),
 .stream_active(wav_active),.stream_end(wav_end),.buffer_low(wav_low),.underflow(audio_underflow)
);
sync_fade_gain u_audio_gain (
 .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),.alpha_pix(fade_alpha),
 .fade_active(fade_active && !alarm_active),.gain_aud(audio_fade_gain)
);
// Lesson 9: transfer coherent diagnostic snapshots into the pixel domain.
// Priority: transport / filesystem / loader / decoder / control, then reader.
wire [7:0] osd_error_sd = cdc_overflow ? 8'h42 :
    (fs_error != 0) ? fs_error :
    (source_memory_error != 0) ? source_memory_error :
    (source_decode_error != 0) ? source_decode_error :
    (control_error != 0) ? control_error :
    audio_overflow ? 8'h72 : audio_fs_error;
wire [8:0] osd_status_pix;
wire [7:0] osd_reader_error_pix;
osd_status_cdc #(.WIDTH(9)) u_osd_control_cdc (
 .src_clk(sd_card_clk),.src_rst_n(sdcard_rst_n),
 .src_status({auto_enabled,osd_error_sd}),
 .dst_clk(video_clk),.dst_rst_n(video_rst_n),.dst_status(osd_status_pix)
);
osd_status_cdc #(.WIDTH(8)) u_osd_reader_cdc (
 .src_clk(ext_mem_clk),.src_rst_n(mem_rst_n),.src_status(reader_error),
 .dst_clk(video_clk),.dst_rst_n(video_rst_n),.dst_status(osd_reader_error_pix)
);
wire [7:0] osd_error_pix = (osd_status_pix[7:0] != 0) ? osd_status_pix[7:0] :
    (osd_reader_error_pix != 0) ? osd_reader_error_pix :
    reader_underflow ? 8'h63 : audio_underflow ? 8'h73 : 8'h00;
// Single read port: reveal from black; no second old-frame pixel stream exists.
// Effects precede OSD so status text stays legible during the black dwell.
wire [7:0] brightness_q,contrast_q,saturation_q;
wire [1:0] param_selection,param_step;
picture_param_control u_picture_control(
 .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),.sw(sw),
 .key3_n(key3),.key4_n(key4),.brightness(brightness_q),.contrast(contrast_q),
 .saturation(saturation_q),.selection(param_selection),.step_code(param_step)
);
wire [23:0] adjusted_rgb;
wire adjusted_de;
picture_adjust u_picture_adjust(
 .clk(video_clk),.rst_n(video_rst_n),.in_de(raw_de),.rgb_in(reader_pixel),
 .brightness(alarm_active ? 8'd255 : brightness_q),.contrast(alarm_active ? 8'd128 : contrast_q),.saturation(alarm_active ? 8'd128 : saturation_q),
 .out_de(adjusted_de),.rgb_out(adjusted_rgb)
);
// Every sideband follows the same four stages as RGB, including blanking.
reg [48:0] picture_meta[0:3];
integer meta_i;
always @(posedge video_clk or negedge video_rst_n) begin
 if(!video_rst_n) begin
  for(meta_i=0;meta_i<4;meta_i=meta_i+1) picture_meta[meta_i]<=0;
 end else begin
  picture_meta[0]<={raw_hs,raw_vs,raw_x,raw_y,display_valid,reader_pixel_valid,
                   effective_thumbnail,thumb_de,focus_border,(alarm_active ? 8'd255 : fade_alpha),
                   (wipe_active && !alarm_active),wipe_ramp};
  for(meta_i=1;meta_i<4;meta_i=meta_i+1) picture_meta[meta_i]<=picture_meta[meta_i-1];
 end
end
wire picture_hs,picture_vs,picture_valid,picture_pixel_valid;
wire picture_thumb,picture_thumb_de,picture_border,picture_wipe;
wire [11:0] picture_x,picture_y;
wire [7:0] picture_alpha;
wire [8:0] picture_ramp;
assign {picture_hs,picture_vs,picture_x,picture_y,picture_valid,picture_pixel_valid,
        picture_thumb,picture_thumb_de,picture_border,picture_alpha,picture_wipe,picture_ramp}=picture_meta[3];
wire [23:0] reader_rgb=(picture_valid && picture_pixel_valid)?adjusted_rgb:24'd0;
wire [23:0] transition_rgb,pre_osd_rgb;
video_transition_rgb #(.FADE_FRAMES(FADE_FRAMES),.FRAME_WIDTH(640)) u_transition_rgb(
 .rgb_in(reader_rgb),.pixel_x(picture_x),.alpha(picture_alpha),
 .wipe_active(picture_wipe),.ramp(picture_ramp),.rgb_out(transition_rgb)
);
assign pre_osd_rgb=picture_thumb ?
 ((picture_valid && picture_thumb_de)?(picture_border?24'hffff00:reader_rgb):24'd0):transition_rgb;
wire [23:0] osd_rgb_out,param_rgb_out,waveform_rgb_out;
wire osd_de_out,osd_active;
wire pcm_tap_valid;
wire signed [15:0] pcm_tap_left;
// Clean picture viewport: legacy status/parameter overlays were combinational.
assign osd_rgb_out=pre_osd_rgb;
assign osd_de_out=adjusted_de;
assign osd_active=1'b0;
assign param_rgb_out=osd_rgb_out;
// Audio peak bars are now drawn in the right sidebar.
assign waveform_rgb_out=param_rgb_out;
wire [23:0] dht_rgb_out;
dht11_osd u_dht_osd (
 .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
 .status(dht_status_pix),.de(1'b0),.pixel_x(picture_x),.pixel_y(picture_y),
 .rgb_in(alarm_active ? reader_rgb : waveform_rgb_out),.rgb_out(dht_rgb_out)
);
wire [23:0] mqtt_rgb_out;
mqtt_feedback_osd u_mqtt_osd(
 .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),.status(mqtt_status_pix),
 .de(1'b0),.pixel_x(picture_x),.pixel_y(picture_y),.rgb_in(dht_rgb_out),.rgb_out(mqtt_rgb_out));
wire [23:0] mqtt_raw_rgb;
mqtt_raw_feedback_osd u_mqtt_raw(
 .src_clk(clk),.src_rst_n(board_rst_n),.data(mqtt_reject_byte),.valid(mqtt_reject_valid),.start(mqtt_reject_start),
 .done(mqtt_reject_done),.length(mqtt_reject_length),
 .clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
 .de(1'b0),.pixel_x(picture_x),.pixel_y(picture_y),.rgb_in(mqtt_rgb_out),.rgb_out(mqtt_raw_rgb));
// Match the single-cycle block-RAM latency of the raw platform-feedback overlay.
reg feedback_raw_hs,feedback_raw_vs,feedback_raw_de;reg [11:0] feedback_raw_x,feedback_raw_y;
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n)begin feedback_raw_hs<=0;feedback_raw_vs<=0;feedback_raw_de<=0;feedback_raw_x<=0;feedback_raw_y<=0;end
 else begin feedback_raw_hs<=picture_hs;feedback_raw_vs<=picture_vs;feedback_raw_de<=osd_de_out;feedback_raw_x<=picture_x;feedback_raw_y<=picture_y;end
// Old bottom weather panel is replaced by the mall header. Preserve its one-cycle latency.
reg env_hs,env_vs,env_de;reg [11:0] env_x,env_y;reg [23:0] env_rgb;
always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n)begin env_hs<=0;env_vs<=0;env_de<=0;env_x<=0;env_y<=0;env_rgb<=0;end
 else begin env_hs<=feedback_raw_hs;env_vs<=feedback_raw_vs;env_de<=feedback_raw_de;
 env_x<=feedback_raw_x;env_y<=feedback_raw_y;env_rgb<=mqtt_raw_rgb;end
wire notice_hs,notice_vs,notice_de;
wire [23:0] notice_rgb;
child_notice_screen u_notice_screen(.clk(video_clk),.rst_n(video_rst_n),.enabled(selected_frame_index==3'd6),
 .hs_in(env_hs),.vs_in(env_vs),.de_in(env_de),.x(env_x),.y(env_y),.rgb_in(env_rgb),
 .hs_out(notice_hs),.vs_out(notice_vs),.de_out(notice_de),.rgb_out(notice_rgb));
reg [11:0] layout_x1,layout_y1,layout_x2,layout_y2;
 always @(posedge video_clk) begin
 layout_x1<=env_x+12'd16;layout_y1<=env_y+12'd64;
 layout_x2<=layout_x1;layout_y2<=layout_y1;
 end
 wire layout_hs,layout_vs,layout_de;wire [23:0] layout_rgb;
 // Gray encoding: only one bit changes between adjacent period settings.
 // Period encoding comes directly from the existing key index.
 (* async_reg="true" *) reg [1:0] period_meta,period_sync;
 always @(posedge video_clk or negedge video_rst_n)
 if(!video_rst_n)begin period_meta<=0;period_sync<=0;end
 else begin period_meta<=period_gray;period_sync<=period_meta;end
 mall_layout_osd u_mall_layout(.clk(video_clk),.rst_n(video_rst_n),.frame_start(frame_start),
 .hs_in(notice_hs),.vs_in(notice_vs),.de_in(notice_de),.x(layout_x2),.y(layout_y2),.rgb_in(notice_rgb),
 .image_index(selected_frame_index),.environment(env_status_pix),.sensor(dht_status_pix),
 .online(mqtt_status_pix[19]),.auto_play(osd_status_pix[8]),.carousel_period_gray(period_sync),.volume(volume_applied_video),
 .picture_brightness(brightness_q),.contrast(contrast_q),.saturation(saturation_q),
 .screen_brightness(applied_brightness),.parameter_selection(param_selection),
 .pcm_valid(pcm_tap_valid),.pcm_sample(pcm_tap_left),
 .hs_out(layout_hs),.vs_out(layout_vs),.de_out(layout_de),.rgb_out(layout_rgb));
 wire bright_hs,bright_vs,bright_de;wire [23:0] bright_rgb;
 remote_video_brightness u_remote_brightness(.clk(video_clk),.rst_n(video_rst_n),.percent(brightness_video),.applied(applied_brightness),
 .hs_in(layout_hs),.vs_in(layout_vs),.de_in(layout_de),.rgb_in(layout_rgb),.hs_out(bright_hs),.vs_out(bright_vs),.de_out(bright_de),.rgb_out(bright_rgb));
 rgb_video_adapter u_video_adapter(
 .pclk(video_clk),.rst_n(video_rst_n),.hs_in(bright_hs),.vs_in(bright_vs),.de_in(bright_de),
 .rgb_in(bright_rgb),.video_clk(),.video_hs(hs),.video_vs(vs),.video_de(de),.video_rgb(vout_data)
);
// Transfer the complete display number using a request/acknowledge snapshot.
wire [3:0] number_display;
wire [3:0] number_pix=audio_selection_valid?{1'b0,selected_frame_index}+4'd1:4'd0;
dht_snapshot_cdc #(.WIDTH(4)) u_number_snapshot(
 .src_clk(video_clk),.src_rst_n(video_rst_n),.src_data(number_pix),
 .dst_clk(clk),.dst_rst_n(board_rst_n),.dst_data(number_display));
wire [6:0] seg_data_0;
seg_decoder seg_decoder_m0 (.bin_data(number_display),.seg_data(seg_data_0));
seg_scan seg_scan_m0 (
 .clk(clk),.rst_n(board_rst_n),.seg_sel(seg_sel),.seg_data(seg_data),
 .seg_data_0(8'hff),.seg_data_1(8'hff),.seg_data_2(8'hff),.seg_data_3(8'hff),.seg_data_4(8'hff),
 .seg_data_5({1'b1,seg_data_0})
);
sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Lesson 3: pixel-clock PCM source -> HDMI audio/video symbols -> existing PHY.
// x=0..639 is active video, x=640..799 is horizontal blanking.
// Falling HS occurs at x=656 (640 active + 16 front porch).
reg hs_previous;
reg [10:0] video_x_next;
wire [10:0] video_x = (hs_previous && !hs) ? 11'd840 : video_x_next;
always @(posedge video_clk or negedge pixel_rst_n) begin
    if (!pixel_rst_n) begin
        hs_previous <= 1'b0;
        video_x_next <= 11'd0;
    end else begin
        hs_previous <= hs;
        video_x_next <= (video_x == 11'd1055) ? 11'd0 : video_x + 11'd1;
    end
end

wire [1:0] media_id=active_index;

wire audio_sequence_error, audio_tone_overflow, audio_contract_error;
wire audio_blip_active;
media_hdmi_audio_bridge #(.EXTERNAL_AUDIO(1),.PAIRED_AUDIO(1),.PIXEL_HZ(40000000),.H_ACTIVE(800),.H_TOTAL(1056)) u_audio_bridge (
    .wav_active(wav_active && audio_matches_picture),.wav_valid(wav_valid && audio_matches_picture),.wav_sample(wav_sample),.wav_ready(wav_ready),
    .force_arpeggio(FORCE_ARPEGGIO != 0),.fade_gain(audio_fade_gain),.sample_tick(audio_tick),
    .pixel_clk(video_clk), .pixel_rst_n(pixel_rst_n),
    .video_hsync(hs), .video_vsync(vs), .video_de(de),
    .video_x(video_x), .video_rgb(vout_data),
    .media_id(media_id), .volume(runtime_gain),
    .channel0_symbol(tmds_ch0_data),
    .channel1_symbol(tmds_ch1_data),
    .channel2_symbol(tmds_ch2_data),
    .sequence_error(audio_sequence_error),
    .tone_overflow(audio_tone_overflow),
    .pcm_contract_error(audio_contract_error),
    .blip_active(audio_blip_active),
    .pcm_tap_valid(pcm_tap_valid), .pcm_tap_left(pcm_tap_left)
);
assign tmds_clk_data = 10'b1111100000;
// Supplied symbol core uses fixed 640x480/48kHz settings and has no EDID master.
assign HDMI_DDC_SCL = 1'bz;
assign HDMI_DDC_SDA = 1'bz;
hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~ext_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
