`timescale 1ns/1ps
// Four clock pipeline including DE. Neutral B=255,C=128,S=128 is bit exact.
module picture_adjust(
 input wire clk,rst_n,in_de,input wire [23:0] rgb_in,
 input wire [7:0] brightness,contrast,saturation,
 output wire out_de,output reg [23:0] rgb_out
);
 reg [3:0] de_pipe;
 reg [7:0] bright[0:2],contr[0:2];
 reg [7:0] contrast_s1,sat_s1,sat_s2,luma_s3;
 reg signed [17:0] sat_product[0:2];
 wire [15:0] weighted_gray=contr[0]*16'd77+contr[1]*16'd150+contr[2]*16'd29;
 wire [7:0] gray=weighted_gray[15:8];
 integer i;
 function [7:0] brighten;
  input [7:0] x,b;reg [15:0] product;
  begin product=x*b;brighten=(b==255)?x:product[15:8];end
 endfunction
 function [7:0] clip;
  input signed [17:0] x;
  begin clip=(x<0)?8'd0:(x>255)?8'd255:x[7:0];end
 endfunction
 function [7:0] contrast_pixel;
  input [7:0] x,c;reg signed [8:0] center;reg signed [17:0] product;
  begin center=$signed({1'b0,x})-9'sd128;product=center*$signed({1'b0,c});
   contrast_pixel=clip((product>>>7)+18'sd128);end
 endfunction
 function signed [17:0] saturate_product;
  input [7:0] x,y,s;reg signed [8:0] delta;
  begin delta=$signed({1'b0,x})-$signed({1'b0,y});saturate_product=delta*$signed({1'b0,s});end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   de_pipe<=0;rgb_out<=0;contrast_s1<=128;sat_s1<=128;sat_s2<=128;luma_s3<=0;
   for(i=0;i<3;i=i+1) begin bright[i]<=0;contr[i]<=0;sat_product[i]<=0;end
  end else begin
   de_pipe<={de_pipe[2:0],in_de};
   bright[0]<=brighten(rgb_in[23:16],brightness);
   bright[1]<=brighten(rgb_in[15:8],brightness);
   bright[2]<=brighten(rgb_in[7:0],brightness);
   contrast_s1<=contrast;sat_s1<=saturation;sat_s2<=sat_s1;
   for(i=0;i<3;i=i+1) begin
    contr[i]<=contrast_pixel(bright[i],contrast_s1);
    sat_product[i]<=saturate_product(contr[i],gray,sat_s2);
   end
   luma_s3<=gray;
   rgb_out<={clip((sat_product[0]>>>7)+$signed({10'd0,luma_s3})),
             clip((sat_product[1]>>>7)+$signed({10'd0,luma_s3})),
             clip((sat_product[2]>>>7)+$signed({10'd0,luma_s3}))};
  end
 end
 assign out_de=de_pipe[3];
endmodule
