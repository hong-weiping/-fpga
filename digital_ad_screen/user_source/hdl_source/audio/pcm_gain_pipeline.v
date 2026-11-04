`timescale 1ns/1ps
// Four-stage PCM scaler. One common enable freezes the complete pipeline
// under backpressure, including the volume captured with each sample.
module pcm_gain_pipeline (
 input wire clk,rst_n,in_valid,
 output wire in_ready,
 input wire signed [15:0] in_left,in_right,
 input wire [7:0] volume,fade_gain,
 output wire out_valid,
 input wire out_ready,
 output reg signed [15:0] out_left,out_right
);
 reg [3:0] valid;
 reg [15:0] gain_product;
 reg [7:0] gain;
 reg signed [15:0] left1,right1,left2,right2;
 reg signed [24:0] left_product,right_product;
 wire advance=!valid[3] || out_ready;
 assign in_ready=advance;
 assign out_valid=valid[3];
 // Exact floor(x/255), 0 <= x <= 65025.
 wire [16:0] gain_sum={1'b0,gain_product}+17'd1+{9'd0,gain_product[15:8]};
 // 256 == 1 (mod 255). Fold the three bytes to get the quotient
// without a general divider; signed division truncates toward zero.
 function signed [15:0] divide255;
  input signed [24:0] value;
  reg [24:0] magnitude;
  reg [9:0] folded;
  reg [16:0] quotient;
  begin
   magnitude=value[24] ? -value : value;
   folded={2'b0,magnitude[23:16]}+{2'b0,magnitude[15:8]}+{2'b0,magnitude[7:0]};
   quotient={1'b0,magnitude[23:16],8'b0}+magnitude[23:16]+magnitude[15:8]
            +((folded>=510)?17'd2:(folded>=255)?17'd1:17'd0);
   divide255=value[24] ? -$signed(quotient[15:0]) : $signed(quotient[15:0]);
  end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   valid<=0;gain_product<=0;gain<=0;
   left1<=0;right1<=0;left2<=0;right2<=0;
   left_product<=0;right_product<=0;out_left<=0;out_right<=0;
  end else if(advance) begin
   valid<={valid[2:0],in_valid};
   if(in_valid) begin
    gain_product<=volume*fade_gain;left1<=in_left;right1<=in_right;
   end
   if(valid[0]) begin gain<=gain_sum[15:8];left2<=left1;right2<=right1;end
   if(valid[1]) begin
    left_product<=left2*$signed({1'b0,gain});
    right_product<=right2*$signed({1'b0,gain});
   end
   if(valid[2]) begin out_left<=divide255(left_product);out_right<=divide255(right_product);end
  end
 end
endmodule
