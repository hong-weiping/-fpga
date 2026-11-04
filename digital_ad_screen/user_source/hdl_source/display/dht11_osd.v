`timescale 1ns/1ps
// Two 2x-scaled 5x7 text rows; combinational RGB, no video latency.
module dht11_osd (
 input wire clk,rst_n,frame_start,
 input wire [16:0] status,
 input wire de,
 input wire [11:0] pixel_x,pixel_y,
 input wire [23:0] rgb_in,
 output reg [23:0] rgb_out
);
 reg valid_q;
 reg [7:0] temp_q,hum_q;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) begin valid_q<=0;temp_q<=0;hum_q<=0; end
  else if(frame_start) begin
   valid_q<=status[16];temp_q<=status[15:8];hum_q<=status[7:0];
  end
 function [34:0] glyph;
 input [7:0] c;
 begin case(c)
  8'd37: glyph=35'b11001110100001000100010000101110011;
  8'd45: glyph=35'b00000000000000011111000000000000000;
  8'd48: glyph=35'b01110100011001110101110011000101110;
  8'd49: glyph=35'b00100011000010000100001000010001110;
  8'd50: glyph=35'b01110100010000100010001000100011111;
  8'd51: glyph=35'b11110000010000101110000010000111110;
  8'd52: glyph=35'b00010001100101010010111110001000010;
  8'd53: glyph=35'b11111100001000011110000010000111110;
  8'd54: glyph=35'b01110100001000011110100011000101110;
  8'd55: glyph=35'b11111000010001000100010000100001000;
  8'd56: glyph=35'b01110100011000101110100011000101110;
  8'd57: glyph=35'b01110100011000101111000010000101110;
  8'd58: glyph=35'b00000001000010000000001000010000000;
  8'd67: glyph=35'b01111100001000010000100001000001111;
  8'd69: glyph=35'b11111100001000011110100001000011111;
  8'd72: glyph=35'b10001100011000111111100011000110001;
  8'd77: glyph=35'b10001110111010110101100011000110001;
  8'd80: glyph=35'b11110100011000111110100001000010000;
  8'd84: glyph=35'b11111001000010000100001000010000100;
  8'd85: glyph=35'b10001100011000110001100011000101110;
  default: glyph=0;
 endcase end
 endfunction
 integer dx,dy,col,row,index;
 reg second_line;
 reg [7:0] c,value;
 reg [34:0] bits;
 always @* begin
  rgb_out=rgb_in;
  dx=0;dy=0;col=0;row=0;index=0;
  second_line=0;c=32;value=0;bits=0;
  if(de && pixel_x>=496 && pixel_x<632 && pixel_y>=8 && pixel_y<52) begin
   rgb_out=24'h102030;
   dx=pixel_x-502;dy=pixel_y-14;
   if(dx>=0 && dx<120 && dy>=0 && dy<34) begin
    second_line=(dy>=20);
    if(second_line) dy=dy-20;
    index=dx/12;col=(dx%12)/2;row=dy/2;
    value=second_line ? hum_q : temp_q;
    case(index)
     0:c=second_line ? "H" : "T";
     1:c=second_line ? "U" : "E";
     2:c="M";
     3:c=second_line ? " " : "P";
     4:c=":";
     5:c=" ";
     6:c=valid_q ? (8'd48+((value/10)%10)) : "-";
     7:c=valid_q ? (8'd48+(value%10)) : "-";
     8:c=" ";
     9:c=second_line ? "%" : "C";
     default:c=" ";
    endcase
    bits=glyph(c);
    if(col<5 && row<7)
     if(bits[34-row*5-col]) rgb_out=valid_q ? 24'hffffff : 24'hffcc66;
   end
  end
 end
endmodule
