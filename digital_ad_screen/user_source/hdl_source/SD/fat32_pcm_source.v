`timescale 1ns/1ps
// After BMP preload releases the transport, scan AUDIO.PCM and follow its FAT
// chain. Buffer space is reserved before each non-backpressurable SD sector.
module fat32_pcm_source #(
    parameter integer CLK_FREQ_HZ=100000000,
    parameter integer SD_READ_TIMEOUT_MS=500,
    parameter PAIRED_AUDIO=0
)(
    input wire clk,rst_n,enable,sd_init_done,buffer_ready,
    input wire [2:0] image_index,
    input wire quiesce,
    output wire transfer_busy,
    output reg play_enable,source_done,
    output wire byte_valid,
    output wire [7:0] byte_data,
    output wire [31:0] byte_offset,
    output reg [7:0] audio_error,
    output wire transport_reset,sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid,sd_sec_read_end
);
    localparam WAIT=0,SCAN=1,PLAY=2,END=3;
    reg [1:0] state;
    reg scan_start,file_start;
    wire scan_done,file_done;
    wire [7:0] scan_error,file_error,spc;
    wire [6:0] resources;
    wire [31:0] cluster,size,fat_lba,data_lba,max_cluster;
    wire [31:0] c0,c1,c2,c3,c4,c5,c6,s0,s1,s2,s3,s4,s5,s6;
    wire [2:0] index=PAIRED_AUDIO ? image_index : 3'd0;
    assign cluster=index==0 ? c0 : index==1 ? c1 : index==2 ? c2 : index==3 ? c3 : index==4 ? c4 : index==5 ? c5 : c6;
    assign size=index==0 ? s0 : index==1 ? s1 : index==2 ? s2 : index==3 ? s3 : index==4 ? s4 : index==5 ? s5 : s6;
    wire pause_requests=PAIRED_AUDIO ? quiesce : 1'b0;
    wire scan_req,file_req,sector_busy,sector_valid,sector_done;
    assign transfer_busy=sector_busy;
    wire [31:0] scan_lba,file_lba;
    wire [7:0] sector_byte,sector_error;
    wire [8:0] sector_index;
    wire use_file=state==PLAY;
    fat32_volume_scanner #(.AUDIO_ONLY(PAIRED_AUDIO ? 2 : 1)) scanner (
        .clk(clk),.rst_n(rst_n),.scan_start(scan_start),.scan_busy(),.scan_done(scan_done),.fs_error(scan_error),
        .partition_lba(),.sectors_per_cluster(spc),.fat_start_lba(fat_lba),.data_start_lba(data_lba),.max_cluster(max_cluster),
        .resource_valid(resources),.resource0_cluster(c0),.resource0_size(s0),
        .resource1_cluster(c1),.resource2_cluster(c2),.resource3_cluster(c3),
        .resource1_size(s1),.resource2_size(s2),.resource3_size(s3),
        .resource6_cluster(c6),.resource6_size(s6),
        .resource4_cluster(c4),.resource5_cluster(c5),.resource4_size(s4),.resource5_size(s5),
        .sector_req(scan_req),.sector_lba(scan_lba),.sector_busy(sector_busy || !sd_init_done || use_file),
        .sector_valid(sector_valid && !use_file),.sector_byte(sector_byte),.sector_byte_index(sector_index),
        .sector_done(sector_done && !use_file),.sector_error(sector_error)
    );
    fat32_file_streamer #(.MAX_VISITED_CLUSTERS(1048576)) streamer (
        .clk(clk),.rst_n(rst_n),.file_start(file_start),.first_cluster(cluster),.file_size(size),
        .sectors_per_cluster(spc),.fat_start_lba(fat_lba),.data_start_lba(data_lba),.max_cluster(max_cluster),
        .file_busy(),.file_done(file_done),.file_valid(byte_valid),.file_byte(byte_data),.file_byte_offset(byte_offset),.fs_error(file_error),
        .sector_req(file_req),.sector_lba(file_lba),
        .sector_busy(sector_busy || !sd_init_done || !buffer_ready || !use_file),
        .sector_valid(sector_valid && use_file),.sector_byte(sector_byte),.sector_byte_index(sector_index),
        .sector_done(sector_done && use_file),.sector_error(sector_error)
    );
    sd_sector_adapter #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.SD_READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS)) adapter (
        .clk(clk),.rst_n(rst_n),.cancel(1'b0),.sector_req(!pause_requests && (use_file?file_req:scan_req)),
        .sector_lba(use_file?file_lba:scan_lba),.sector_busy(sector_busy),.sector_valid(sector_valid),
        .sector_byte(sector_byte),.sector_byte_index(sector_index),.sector_done(sector_done),.sector_error(sector_error),
        .transport_reset(transport_reset),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT;scan_start<=0;file_start<=0;play_enable<=0;source_done<=0;audio_error<=0;
        end else begin
            scan_start<=0;file_start<=0;
            case(state)
                WAIT: if(enable && sd_init_done) begin scan_start<=1;state<=SCAN;end
                SCAN: if(scan_done) begin
                    if(scan_error!=0 && !(PAIRED_AUDIO && scan_error==8'h22)) begin audio_error<=scan_error;state<=END;end
                    else if(index>=7 || !resources[index]) state<=END; // selected optional file absent
                    else if(size==0 || size[0]) begin audio_error<=8'h71;state<=END;end
                    else begin play_enable<=1;file_start<=1;state<=PLAY;end
                end
                PLAY: if(file_done) begin source_done<=1;audio_error<=file_error;state<=END;end
                END: ; // single-shot session; system reset starts a new scan/play
                default: state<=WAIT;
            endcase
        end
    end
endmodule
