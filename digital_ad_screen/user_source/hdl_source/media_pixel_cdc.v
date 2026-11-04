`timescale 1ns/1ps
// Ordered event FIFO: START, RGB pixels, COMMIT/ERROR all use the same CDC.
// A completion mailbox is held stable until the source starts another file.
module media_pixel_cdc (
 input src_clk,src_rst_n,mem_clk,mem_rst_n,
 input load_start, input [2:0] image_index,
 input pixel_valid,input [23:0] pixel_rgb,input frame_commit,input [7:0] decode_error,
 output source_ready,output reg source_done,output reg [7:0] source_error,
 output reg mem_load_start,output reg [2:0] mem_image_index,
 output reg mem_pixel_valid,output reg [23:0] mem_pixel_rgb,
 output reg mem_frame_commit,output reg [7:0] mem_decode_error,
 input mem_load_done,input [7:0] mem_memory_error,
 output reg overflow
);
wire rst=!src_rst_n || !mem_rst_n;
wire full,empty,valid;
wire [31:0] data;
wire event_valid=load_start || pixel_valid || frame_commit || decode_error!=0;
wire [31:0] event_data=load_start ? {2'b01,27'd0,image_index} :
                       decode_error!=0 ? {2'b11,22'd0,decode_error} :
                       frame_commit ? {2'b10,30'd0} : {8'd0,pixel_rgb};
wire read_en;
wire [31:0] queued_data;
wire queued_valid;
wire prefetch_rst_n;
reset_sync u_prefetch_reset (
 .clk(mem_clk),.ext_rst_n(src_rst_n && mem_rst_n),.rst_n_sync(prefetch_rst_n)
);
assign source_ready=!full && !overflow;
rfifo_32_32_512 u_events (
 .rst(rst),.clkw(src_clk),.clkr(mem_clk),.we(event_valid && !full),.di(event_data),
 .re(read_en),.dout(data),.valid(valid),.full_flag(full),.empty_flag(empty),
 .afull(),.aempty(),.wrusedw(),.rdusedw()
);
fifo_prefetch_2 u_prefetch (
 .clk(mem_clk),.rst(~prefetch_rst_n),.raw_empty(empty),.raw_valid(valid),.raw_data(data),
 .raw_read_en(read_en),.consume(queued_valid),.out_valid(queued_valid),
 .out_empty(),.out_data(queued_data)
);
(* async_reg="true" *) reg overflow_m1,overflow_m2;
reg done_toggle;
reg [7:0] error_hold;
(* async_reg="true" *) reg done_s1,done_s2;
reg done_seen;
reg [7:0] error_s1,error_s2;
// Decode into registers before the loader; preserve event order and payload.
always @(posedge mem_clk or negedge prefetch_rst_n) begin
 if(!prefetch_rst_n) begin
  mem_load_start<=0;mem_image_index<=0;mem_pixel_valid<=0;mem_pixel_rgb<=0;
  mem_frame_commit<=0;mem_decode_error<=0;
 end else begin
  mem_load_start<=queued_valid && queued_data[31:30]==1;
  mem_image_index<=queued_data[2:0];
  mem_pixel_valid<=queued_valid && queued_data[31:30]==0;
  mem_pixel_rgb<=queued_data[23:0];
  mem_frame_commit<=queued_valid && queued_data[31:30]==2;
  mem_decode_error<=overflow_m2 ? 8'h42 :
                   ((queued_valid && queued_data[31:30]==3)?queued_data[7:0]:8'd0);
 end
end
always @(posedge src_clk or negedge src_rst_n) begin
 if(!src_rst_n) begin
  overflow<=0;done_s1<=0;done_s2<=0;done_seen<=0;error_s1<=0;error_s2<=0;
  source_done<=0;source_error<=0;
 end else begin
  if(event_valid && full) overflow<=1;
  done_s1<=done_toggle;done_s2<=done_s1;error_s1<=error_hold;error_s2<=error_s1;
  source_done<=0;
  if(done_s2!=done_seen) begin
   done_seen<=done_s2;source_done<=1;source_error<=error_s2;
  end
 end
end
always @(posedge mem_clk or negedge mem_rst_n) begin
 if(!mem_rst_n) begin done_toggle<=0;error_hold<=0;overflow_m1<=0;overflow_m2<=0;end
 else begin
  overflow_m1<=overflow;overflow_m2<=overflow_m1;
  if(mem_load_done) begin done_toggle<=~done_toggle;error_hold<=mem_memory_error;end
 end
end
endmodule
