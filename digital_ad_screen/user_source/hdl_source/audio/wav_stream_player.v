`timescale 1ns/1ps
// 48 kHz mono s16le stream buffer. The FAT32 source replaces the reference's
// contiguous-LBA reader; sector_ready reserves space for a full 512-byte burst.
// One playback session per system reset. No pointer is reset independently.
module wav_stream_player #(
    parameter integer ADDR_WIDTH=12,
    parameter integer PREFILL_SAMPLES=256
)(
    input wire wr_clk,wr_rst_n,
    input wire play_enable,source_done,
    input wire byte_valid,
    input wire [7:0] byte_data,
    input wire [31:0] byte_offset,
    output wire sector_ready,
    output reg overflow,
    input wire rd_clk,rd_rst_n,sample_tick,sample_ready,
    output wire signed [15:0] sample_out,
    output reg sample_valid,
    output reg [31:0] sample_counter,
    output wire stream_active,stream_end,buffer_low,
    output reg underflow
);
    localparam integer DEPTH=1<<ADDR_WIDTH;
    reg [15:0] buffer [0:DEPTH-1];
    // The extra wrap bit makes full/empty and modular subtraction unambiguous.
    reg [ADDR_WIDTH:0] wr_ptr,rd_ptr,wr_gray,rd_gray;
    (* async_reg="true" *) reg [ADDR_WIDTH:0] rd_sync1,rd_sync2,wr_sync1,wr_sync2;
    (* async_reg="true" *) reg enable_sync1,enable_sync2,done_sync1,done_sync2;
    reg done_sync3;
    reg [7:0] low_byte;
    reg low_pending;
    reg primed,silence;
    reg [15:0] ram_q;
    function [ADDR_WIDTH:0] from_gray;
        input [ADDR_WIDTH:0] gray;
        integer i;
        begin
            from_gray[ADDR_WIDTH]=gray[ADDR_WIDTH];
            for(i=ADDR_WIDTH-1;i>=0;i=i-1)
                from_gray[i]=from_gray[i+1]^gray[i];
        end
    endfunction
    wire [ADDR_WIDTH:0] level_wr=wr_ptr-from_gray(rd_sync2);
    wire [ADDR_WIDTH:0] level_rd=from_gray(wr_sync2)-rd_ptr;
    wire [ADDR_WIDTH:0] wr_next=wr_ptr+1'b1;
    wire [ADDR_WIDTH:0] rd_next=rd_ptr+1'b1;
    wire write_sample=play_enable && byte_valid && byte_offset[0] && low_pending && level_wr<DEPTH;
    wire slot_free=!sample_valid || sample_ready;
    wire can_read=(primed || level_rd>=PREFILL_SAMPLES || done_sync3) && level_rd!=0;
    wire read_sample=stream_active && sample_tick && slot_free && can_read;
    assign sector_ready=!overflow && level_wr<=DEPTH-256;
    assign stream_end=enable_sync2 && done_sync3 && level_rd==0 && !sample_valid;
    assign stream_active=enable_sync2 && !stream_end;
    assign buffer_low=level_rd<DEPTH/4;
    assign sample_out=silence?16'sd0:$signed(ram_q);

    // Separate synchronous RAM ports allow true dual-clock BRAM inference.
    always @(posedge wr_clk)
        if(write_sample) buffer[wr_ptr[ADDR_WIDTH-1:0]]<={byte_data,low_byte};
    always @(posedge rd_clk)
        if(read_sample) ram_q<=buffer[rd_ptr[ADDR_WIDTH-1:0]];

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if(!wr_rst_n) begin
            wr_ptr<=0;wr_gray<=0;rd_sync1<=0;rd_sync2<=0;
            low_byte<=0;low_pending<=0;overflow<=0;
        end else begin
            rd_sync1<=rd_gray;rd_sync2<=rd_sync1;
            if(play_enable && byte_valid) begin
                if(!byte_offset[0]) begin low_byte<=byte_data;low_pending<=1;end
                else begin
                    low_pending<=0;
                    if(write_sample) begin wr_ptr<=wr_next;wr_gray<=wr_next^(wr_next>>1);end
                    else overflow<=1;
                end
            end
        end
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if(!rd_rst_n) begin
            rd_ptr<=0;rd_gray<=0;wr_sync1<=0;wr_sync2<=0;
            enable_sync1<=0;enable_sync2<=0;done_sync1<=0;done_sync2<=0;done_sync3<=0;
            sample_valid<=0;sample_counter<=0;primed<=0;silence<=1;underflow<=0;
        end else begin
            wr_sync1<=wr_gray;wr_sync2<=wr_sync1;
            enable_sync1<=play_enable;enable_sync2<=enable_sync1;
            done_sync1<=source_done;done_sync2<=done_sync1;done_sync3<=done_sync2;
            if(sample_valid && sample_ready) begin
                sample_valid<=0;
                if(!silence) sample_counter<=sample_counter+1'b1;
            end
            if(stream_active && sample_tick && slot_free) begin
                sample_valid<=1;
                silence<=!can_read;
                if(can_read) begin
                    rd_ptr<=rd_next;rd_gray<=rd_next^(rd_next>>1);primed<=1;
                end else if(primed && !done_sync3) begin
                    primed<=0;underflow<=1;
                end
            end
        end
    end
endmodule
