`timescale 1ns/1ps
// Inputs are synchronized to pix_clk upstream. Change alarm mode only in blanking.
// Advertisements retain their own two-bit controller and four-item navigation.
module alarm_media_select (
 input wire pix_clk, rst_n, frame_start,
 input wire fire_alarm, noise_alarm, child_notice,
 input wire [1:0] ad_index,
 input wire ad_valid,
 input wire [5:0] image_complete,
 output wire [2:0] media_index,
 output wire display_valid, audio_valid, alarm_active
);
 reg [1:0] mode;
 always @(posedge pix_clk or negedge rst_n)
  if(!rst_n) mode<=0;
  else if(frame_start) mode<=fire_alarm ? 2'd1 : child_notice ? 2'd3 : noise_alarm ? 2'd2 : 2'd0;
 assign alarm_active=(mode!=0);
 assign media_index=(mode==1) ? 3'd4 : (mode==2) ? 3'd5 : (mode==3) ? 3'd6 : {1'b0,ad_index};
 // Never substitute an advertisement for a missing emergency image.
 assign display_valid=(mode==3) ? 1'b0 : alarm_active ? image_complete[media_index] : ad_valid;
 // Emergency audio remains available even if its BMP is missing or invalid.
 assign audio_valid=alarm_active || ad_valid;
endmodule
