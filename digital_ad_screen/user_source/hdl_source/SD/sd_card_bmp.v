`timescale 1ns/1ps
module sd_card_bmp #(
 parameter AUDIO_STREAM_ENABLE=0,
 parameter integer CLK_FREQ_HZ=100000000,
 parameter integer SD_READ_TIMEOUT_MS=500,
 parameter integer FRAME_WIDTH=640,
 parameter integer FRAME_HEIGHT=480
)(
 input clk,rst,sdram_ready,sink_ready,
 output reg loader_start,output reg [2:0] image_index,
 output pixel_valid,output [23:0] pixel_rgb,
 output frame_commit,output [7:0] decode_error,
 input loader_done,input [7:0] loader_error,
 output reg preload_done,output reg [5:0] failed_images,
 output [7:0] fs_error,
 input audio_sd_read,audio_transport_reset,
 input [31:0] audio_sd_addr,
 output audio_sd_init,output [7:0] audio_sd_data,
 output audio_sd_valid,audio_sd_end,
 output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO
);
localparam SCAN=0,SCAN_WAIT=1,PICK=2,START=3,WAIT_RESULT=4,DONE=5;
reg [2:0] state;
reg scan_start_pulse,load_start_pulse;
reg [2:0] candidate;
reg retry_count,scan_retry;
reg source_seen,memory_seen,source_failed;
reg [7:0] memory_result;
wire bmp_ready,scan_done,load_done,load_error,write_req;
wire [2:0] bmp_error;
wire [5:0] resource_valid;
wire [31:0] img_cluster0,img_cluster1,img_cluster2,img_cluster3,img_cluster4,img_cluster5;
wire [31:0] img_size0,img_size1,img_size2,img_size3,img_size4,img_size5;
wire [31:0] load_cluster=(image_index==0)?img_cluster0:(image_index==1)?img_cluster1:
                           (image_index==2)?img_cluster2:(image_index==3)?img_cluster3:
                           (image_index==4)?img_cluster4:img_cluster5;
wire [31:0] load_file_size=(image_index==0)?img_size0:(image_index==1)?img_size1:
                             (image_index==2)?img_size2:(image_index==3)?img_size3:
                             (image_index==4)?img_size4:img_size5;
wire sd_init_done,sd_sec_read,sd_sec_read_data_valid,sd_sec_read_end,adapter_transport_reset;
wire [31:0] sd_sec_read_addr;
wire [7:0] sd_sec_read_data;
// Ownership changes only once, after the final BMP transaction has drained.
wire audio_owner=AUDIO_STREAM_ENABLE ? preload_done : 1'b0;
assign audio_sd_init=sd_init_done;
assign audio_sd_data=sd_sec_read_data;
assign audio_sd_valid=audio_owner && sd_sec_read_data_valid;
assign audio_sd_end=audio_owner && sd_sec_read_end;
wire bmp_data_wr_en;
wire [23:0] bmp_data;
wire [15:0] bmp_width=FRAME_WIDTH,bmp_height=FRAME_HEIGHT;
assign pixel_valid=bmp_data_wr_en;
assign pixel_rgb=bmp_data;
assign frame_commit=load_done;
assign decode_error=(state==WAIT_RESULT && load_error)?{5'd0,bmp_error}:8'd0;
always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=SCAN;scan_start_pulse<=0;load_start_pulse<=0;loader_start<=0;
  candidate<=0;image_index<=0;retry_count<=0;scan_retry<=0;
  source_seen<=0;memory_seen<=0;source_failed<=0;memory_result<=0;
  preload_done<=0;failed_images<=0;
 end else begin
  scan_start_pulse<=0;load_start_pulse<=0;loader_start<=0;
  case(state)
   SCAN: if(sd_init_done && sdram_ready && bmp_ready) begin scan_start_pulse<=1;state<=SCAN_WAIT;end
   SCAN_WAIT: begin
    if(scan_done) begin candidate<=0;state<=PICK;end
    else if(load_error) begin
     if(!scan_retry) begin scan_retry<=1;state<=SCAN;end
     else begin failed_images<=6'h3f;state<=DONE;end
    end
   end
   PICK: if(candidate==6) state<=DONE;
    else if(!resource_valid[candidate[2:0]]) begin failed_images[candidate[2:0]]<=1;candidate<=candidate+1'b1;end
    else if(sd_init_done && sdram_ready && bmp_ready && sink_ready) begin
     image_index<=candidate[2:0];loader_start<=1;state<=START;
     source_seen<=0;memory_seen<=0;source_failed<=0;memory_result<=0;
    end
   START: begin load_start_pulse<=1;state<=WAIT_RESULT;end
   WAIT_RESULT: begin
    if(load_done || load_error) begin source_seen<=1;source_failed<=load_error;end
    if(loader_done) begin memory_seen<=1;memory_result<=loader_error;end
    if(source_seen && memory_seen && bmp_ready) begin
     if(source_failed || memory_result!=0) begin
      if(!retry_count) begin retry_count<=1;state<=PICK;end
      else begin failed_images[candidate[2:0]]<=1;retry_count<=0;candidate<=candidate+1'b1;state<=PICK;end
     end else begin retry_count<=0;candidate<=candidate+1'b1;state<=PICK;end
    end
   end
   DONE: preload_done<=1;
   default:state<=SCAN;
  endcase
 end
end
fat32_bmp_reader #(
    .PIXEL_COUNT_WIDTH( (FRAME_WIDTH*FRAME_HEIGHT<1)?1:$clog2(FRAME_WIDTH*FRAME_HEIGHT+1)),
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .SD_READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS)
) u_fat32 (
    .clk(clk), .rst(rst), .ready(bmp_ready),
    .scan_start(scan_start_pulse), .scan_done(scan_done),
    .resource_valid(resource_valid),
    .resource0_cluster(img_cluster0), .resource1_cluster(img_cluster1),
    .resource2_cluster(img_cluster2), .resource3_cluster(img_cluster3),
    .resource4_cluster(img_cluster4), .resource5_cluster(img_cluster5),
    .resource0_size(img_size0), .resource1_size(img_size1),
    .resource2_size(img_size2), .resource3_size(img_size3),
    .resource4_size(img_size4), .resource5_size(img_size5),
    .load_start(load_start_pulse), .load_cluster(load_cluster), .load_file_size(load_file_size),
    .bmp_width(bmp_width), .bmp_height(bmp_height),
    .write_req(write_req), .write_req_ack(sink_ready),
    .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data),
    .load_done(load_done), .load_error(load_error), .bmp_error(bmp_error), .fs_error(fs_error),
    .transport_reset(adapter_transport_reset),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid && !audio_owner),
    .sd_sec_read_end(sd_sec_read_end && !audio_owner)
);

sd_card_top sd_card_top_m0(
 .clk(clk),.rst(rst | (audio_owner ? audio_transport_reset : adapter_transport_reset)),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),
 .SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),.sd_init_done(sd_init_done),
 .sd_sec_read(audio_owner ? audio_sd_read : sd_sec_read),
 .sd_sec_read_addr(audio_owner ? audio_sd_addr : sd_sec_read_addr),
 .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
 .sd_sec_read_end(sd_sec_read_end),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),
 .sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end()
);
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
assign button_stable_out = button_stable;
localparam integer CNT_BITS=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
reg [CNT_BITS-1:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
