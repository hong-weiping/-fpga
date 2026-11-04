`timescale 1ns/1ps
module media_player_control #(
 parameter TRANSITION_GATING=0,
 parameter [31:0] DEFAULT_PERIOD_CYCLES=300000000,
 parameter [31:0] MIN_PERIOD_CYCLES=1,
 parameter [31:0] MAX_PERIOD_CYCLES=32'd3000000000
)(
 input sys_clk,sys_rst_n,next_event,prev_event,toggle_auto_event,
 input transition_busy, input suspend,
 input period_cfg_valid,input [31:0] period_cfg_cycles,
 input auto_cfg_valid,auto_cfg_enabled,input [3:0] image_complete,
 output reg auto_enabled,output reg [31:0] active_period_cycles,
 output reg [1:0] pending_index,output reg [7:0] control_error,
 output request_busy,
 input pix_clk,pix_rst_n,frame_start,
 output reg [1:0] active_index,output reg index_commit,output reg display_valid
);
reg [31:0] counter;
reg request_toggle,ack_toggle,started,queued_next,queued_prev;
(* async_reg="true" *) reg ack1,ack2,req1,req2;
reg [1:0] index1,index2,requested;
reg seen,pending;
wire pause_auto=TRANSITION_GATING ? transition_busy : 1'b0;
wire advance=next_event || queued_next;
wire reverse=prev_event || queued_prev;
assign request_busy=request_toggle!=ack2;
function [2:0] select_index;
 input [1:0] current;input [3:0] mask;input backwards;
 integer k;reg [1:0] candidate;
 begin
  select_index={1'b0,current};
  for(k=1;k<=4;k=k+1) begin
   candidate=backwards?current-k:current+k;
   if(!select_index[2] && mask[candidate]) select_index={1'b1,candidate};
  end
 end
endfunction
wire [2:0] choice=select_index(started?pending_index:2'd3,image_complete,started && !advance && reverse);
always @(posedge sys_clk or negedge sys_rst_n) begin
 if(!sys_rst_n) begin
  auto_enabled<=0;active_period_cycles<=DEFAULT_PERIOD_CYCLES;pending_index<=0;
  control_error<=0;counter<=0;request_toggle<=0;ack1<=0;ack2<=0;
  started<=0;queued_next<=0;queued_prev<=0;
 end else begin
  ack1<=ack_toggle;ack2<=ack1;
  if(suspend) begin queued_next<=0;queued_prev<=0;end
  if(next_event && !suspend) queued_next<=1;
  if(prev_event && !suspend) queued_prev<=1;
  if(!suspend && !request_busy && choice[2] && (!started || advance || reverse ||
      (auto_enabled && !pause_auto && counter>=active_period_cycles-1 && !toggle_auto_event))) begin
   pending_index<=choice[1:0];request_toggle<=~request_toggle;started<=1;
   counter<=0;queued_next<=0;queued_prev<=0;
  end else if(suspend || request_busy || pause_auto || !auto_enabled || !started) counter<=0;
  else if(counter<active_period_cycles-1) counter<=counter+1'b1;
  if(period_cfg_valid) begin
   if(period_cfg_cycles<MIN_PERIOD_CYCLES || period_cfg_cycles>MAX_PERIOD_CYCLES)
    control_error<=8'h51;
   else begin active_period_cycles<=period_cfg_cycles;counter<=0;end
  end
  if(auto_cfg_valid) begin auto_enabled<=auto_cfg_enabled;counter<=0;end
  if(toggle_auto_event && !suspend) begin auto_enabled<=~auto_enabled;counter<=0;end
 end
end
always @(posedge pix_clk or negedge pix_rst_n) begin
 if(!pix_rst_n) begin
  req1<=0;req2<=0;index1<=0;index2<=0;seen<=0;requested<=0;pending<=0;
  active_index<=0;index_commit<=0;ack_toggle<=0;display_valid<=0;
 end else begin
  req1<=request_toggle;req2<=req1;index1<=pending_index;index2<=index1;index_commit<=0;
  if(req2!=seen && !pending) begin seen<=req2;requested<=index2;pending<=1;end
  if(frame_start && pending) begin
   active_index<=requested;index_commit<=1;pending<=0;ack_toggle<=seen;display_valid<=1;
  end
 end
end
endmodule

// Separate frame-index launch and capture edges. The player commits at the
// rising frame edge; the reader consumes one rising edge later. This falling
// edge snapshot gives both transfers half a pixel period and supplies a common
// index to the reader, thumbnail focus and status OSD. Time both half-cycle paths.
module frame_index_snapshot (
 input wire pix_clk,pix_rst_n,
 input wire [2:0] active_index,
 output wire [2:0] frame_index
);
 (* keep="true" *) reg [2:0] settled_index;
 always @(negedge pix_clk or negedge pix_rst_n) begin
  if(!pix_rst_n) settled_index<=3'd0;
  else settled_index<=active_index;
 end
 assign frame_index=settled_index;
endmodule

// Debounced active-low key. Period output is the next value captured on step.
module carousel_period_key #(parameter integer CLK_HZ=100000000,parameter integer HOLD_CYCLES=CLK_HZ)(input clk,rst_n,button_stable,output wire short_press,period_step,output reg [31:0] period_cycles,output wire [1:0] current_period_gray);
localparam integer CW=(HOLD_CYCLES<2)?1:$clog2(HOLD_CYCLES);
reg [CW-1:0] held;
reg previous,long_seen;
reg [1:0] period_index;
assign current_period_gray={period_index[1],period_index[1]^period_index[0]};
assign short_press=button_stable && !previous && !long_seen;
assign period_step=!button_stable && !long_seen && held==HOLD_CYCLES-1;
always @* case(period_index)
0:period_cycles=CLK_HZ*10;
1:period_cycles=CLK_HZ*20;
2:period_cycles=CLK_HZ*30;
default:period_cycles=CLK_HZ*5;
endcase
always @(posedge clk or negedge rst_n)
if(!rst_n) begin held<=0;previous<=1;long_seen<=0;period_index<=0;end
else begin
previous<=button_stable;
if(button_stable) begin held<=0;long_seen<=0;end
else if(!long_seen) begin
if(period_step) begin long_seen<=1;period_index<=period_index+1'b1;end
else held<=held+1'b1;
end
end
endmodule
