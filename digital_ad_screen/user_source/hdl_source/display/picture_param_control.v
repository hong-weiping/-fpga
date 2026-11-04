`timescale 1ns/1ps
// Pixel-clock controller. All visible parameters are committed together.
module picture_param_control #(parameter integer DEBOUNCE_CYCLES=500000)(
 input wire clk,rst_n,frame_start,input wire [3:0] sw,input wire key3_n,key4_n,
 output reg [7:0] brightness,contrast,saturation,output reg [1:0] selection,step_code
);
 localparam CW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
 (* async_reg="true" *) reg [3:0] sw_meta,sw_sync;
 (* async_reg="true" *) reg [1:0] key_meta,key_sync;
 reg [3:0] sw_stable,sw_candidate;
 reg [1:0] key_stable,key_candidate;
 reg [CW-1:0] sw_count,key_count;
 reg [7:0] pending_b,pending_c,pending_s;
 wire key_accept=(key_sync==key_candidate) && (key_count==DEBOUNCE_CYCLES-1);
 wire increase=key_accept && key_stable==3 && key_candidate==2;
 wire decrease=key_accept && key_stable==3 && key_candidate==1;
 wire [7:0] step=(sw_stable[3:2]==0)?8'd1:(sw_stable[3:2]==1)?8'd4:(sw_stable[3:2]==2)?8'd16:8'd32;
 function [7:0] adjust;
  input [7:0] value,amount;input up;reg [8:0] sum;
  begin sum={1'b0,value}+{1'b0,amount};
   adjust=up?(sum[8]?8'hff:sum[7:0]):((value<amount)?8'd0:value-amount);end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   sw_meta<=0;sw_sync<=0;sw_candidate<=0;sw_stable<=0;sw_count<=0;
   key_meta<=3;key_sync<=3;key_candidate<=3;key_stable<=3;key_count<=0;
   pending_b<=255;pending_c<=128;pending_s<=128;
   brightness<=255;contrast<=128;saturation<=128;selection<=0;step_code<=0;
  end else begin
   sw_meta<=sw;sw_sync<=sw_meta;key_meta<={key4_n,key3_n};key_sync<=key_meta;
   if(sw_sync!=sw_candidate) begin sw_candidate<=sw_sync;sw_count<=0;end
   else if(sw_count==DEBOUNCE_CYCLES-1) sw_stable<=sw_candidate;
   else sw_count<=sw_count+1'b1;
   if(key_sync!=key_candidate) begin key_candidate<=key_sync;key_count<=0;end
   else if(key_count==DEBOUNCE_CYCLES-1) key_stable<=key_candidate;
   else key_count<=key_count+1'b1;
   if(sw_stable[1:0]==3) begin pending_b<=255;pending_c<=128;pending_s<=128;end
   else if(increase || decrease) begin
    case(sw_stable[1:0])
     0: pending_b<=adjust(pending_b,step,increase);
     1: pending_c<=adjust(pending_c,step,increase);
     2: pending_s<=adjust(pending_s,step,increase);
     default: ;
    endcase
   end
   if(frame_start) begin
    brightness<=pending_b;contrast<=pending_c;saturation<=pending_s;
    selection<=sw_stable[1:0];step_code<=sw_stable[3:2];
   end
  end
 end
endmodule
