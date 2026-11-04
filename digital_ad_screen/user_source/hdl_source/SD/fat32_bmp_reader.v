`timescale 1ns/1ps
// FAT32 backend for the existing display controller. ready is an idle LEVEL;
// load_done is a successful validated-file PULSE. They are not interchangeable.
module fat32_bmp_reader #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer SD_READ_TIMEOUT_MS=500,
    parameter integer PIXEL_COUNT_WIDTH=32
)(
    input wire clk, rst, scan_start, load_start,
    output wire ready,
    output reg scan_done,
    output wire [5:0] resource_valid,
    output wire [31:0] resource0_cluster, resource1_cluster, resource2_cluster, resource3_cluster, resource4_cluster, resource5_cluster,
    output wire [31:0] resource0_size, resource1_size, resource2_size, resource3_size, resource4_size, resource5_size,
    input wire [31:0] load_cluster, load_file_size,
    input wire [15:0] bmp_width, bmp_height,
    output reg write_req,
    input wire write_req_ack,
    output reg bmp_data_wr_en,
    output reg [23:0] bmp_data,
    output reg load_done, load_error,
    output reg [2:0] bmp_error,
    output reg [7:0] fs_error,
    output wire transport_reset,
    output wire sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid, sd_sec_read_end
);
wire [6:0] scanner_resources;
assign resource_valid=scanner_resources[5:0];
wire scan_busy, scan_done_pulse;
wire [7:0] scan_error, stream_error, spc;
wire [31:0] fat_lba, data_lba, max_cluster;
wire scanner_req, streamer_req, sector_busy, sector_valid, sector_done;
wire [31:0] scanner_lba, streamer_lba;
wire [7:0] sector_byte, sector_error;
wire [8:0] sector_index;
reg use_streamer, file_start, abort_stream;
wire file_busy, file_done, file_valid;
wire [7:0] file_byte;
wire [31:0] file_offset;
wire adapter_reset;
localparam IDLE=0, WAIT_ACK=1, STREAM=2;
reg [1:0] state;
reg ack_meta, ack_sync;

localparam [63:0] RAW=(64'd1*CLK_FREQ_HZ*SD_READ_TIMEOUT_MS)/1000;
localparam [31:0] LIMIT=(RAW<1)?1:RAW;
localparam integer ACK_W=(LIMIT<=1)?1:$clog2(LIMIT);
reg [ACK_W-1:0] ack_timer;
reg [7:0] signature0, signature1;
reg [31:0] file_len, pixel_offset, dib_size, width, height, compression;
reg [15:0] planes, bits;
reg header_ok;
// Header offsets are sequential; saturate after byte 53 to avoid 32-bit decoding.
reg [5:0] header_index;
reg [1:0] rgb_phase;
reg [7:0] blue, green;
reg [PIXEL_COUNT_WIDTH-1:0] pixel_count;
wire [31:0] expected_pixels={16'd0,bmp_width}*{16'd0,bmp_height};
wire [63:0] pixel_end={32'd0,pixel_offset}+64'd3*expected_pixels;
wire header_match_comb=signature0=="B" && signature1=="M" &&
    width=={16'd0,bmp_width} && height=={16'd0,bmp_height} &&
    bmp_width!=0 && bmp_height!=0 && bmp_width[1:0]==0 &&
    bits==24 && compression==0 && dib_size>=40 && planes==1 &&
    pixel_offset>=54 && {32'd0,pixel_offset}>=64'd14+dib_size &&
    pixel_end<={32'd0,file_len} && file_len<=load_file_size;
// All header fields finish at byte 33; validation is consumed at byte 53.
reg header_match;
always @(posedge clk or posedge rst)
 if(rst) header_match<=0; else header_match<=header_match_comb;
assign ready=state==IDLE && !scan_busy && !file_busy && !abort_stream && !sector_busy;
assign transport_reset=adapter_reset | abort_stream;

fat32_volume_scanner u_scanner (
    .clk(clk), .rst_n(~rst), .scan_start(scan_start && ready),
    .scan_busy(scan_busy), .scan_done(scan_done_pulse), .fs_error(scan_error),
    .partition_lba(), .sectors_per_cluster(spc), .fat_start_lba(fat_lba),
    .data_start_lba(data_lba), .max_cluster(max_cluster),
    .resource_valid(scanner_resources),
    .resource0_cluster(resource0_cluster), .resource1_cluster(resource1_cluster),
    .resource2_cluster(resource2_cluster), .resource3_cluster(resource3_cluster),
    .resource4_cluster(resource4_cluster), .resource5_cluster(resource5_cluster),
    .resource0_size(resource0_size), .resource1_size(resource1_size),
    .resource2_size(resource2_size), .resource3_size(resource3_size),
    .resource4_size(resource4_size), .resource5_size(resource5_size),
    .sector_req(scanner_req), .sector_lba(scanner_lba),
    .sector_busy(sector_busy | use_streamer),
    .sector_valid(sector_valid && !use_streamer), .sector_byte(sector_byte),
    .sector_byte_index(sector_index), .sector_done(sector_done && !use_streamer),
    .sector_error(sector_error)
);
fat32_file_streamer u_streamer (
    .clk(clk), .rst_n(~rst && !abort_stream), .file_start(file_start),
    .first_cluster(load_cluster), .file_size(load_file_size), .sectors_per_cluster(spc),
    .fat_start_lba(fat_lba), .data_start_lba(data_lba), .max_cluster(max_cluster),
    .file_busy(file_busy), .file_done(file_done), .file_valid(file_valid),
    .file_byte(file_byte), .file_byte_offset(file_offset), .fs_error(stream_error),
    .sector_req(streamer_req), .sector_lba(streamer_lba),
    .sector_busy(sector_busy | !use_streamer),
    .sector_valid(sector_valid && use_streamer), .sector_byte(sector_byte),
    .sector_byte_index(sector_index), .sector_done(sector_done && use_streamer),
    .sector_error(sector_error)
);
sd_sector_adapter #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .SD_READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS)) u_adapter (
    .clk(clk), .rst_n(~rst), .cancel(abort_stream),
    .sector_req(use_streamer ? streamer_req : scanner_req),
    .sector_lba(use_streamer ? streamer_lba : scanner_lba),
    .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
    .sector_byte_index(sector_index), .sector_done(sector_done), .sector_error(sector_error),
    .transport_reset(adapter_reset), .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end)
);
always @(posedge clk or posedge rst) begin
    if (rst) begin ack_meta<=0; ack_sync<=0; end
    else begin ack_meta<=write_req_ack; ack_sync<=ack_meta; end
end
task fail_load;
    input [2:0] code;
    begin
        bmp_error<=code; load_error<=1; write_req<=0;
        abort_stream<=1; state<=IDLE;
    end
endtask
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_done<=0; load_done<=0; load_error<=0; bmp_error<=0; fs_error<=0;
        use_streamer<=0; file_start<=0; abort_stream<=0; state<=IDLE;
        write_req<=0; ack_timer<=0; bmp_data_wr_en<=0; bmp_data<=0;
        signature0<=0; signature1<=0; file_len<=0; pixel_offset<=0;
        dib_size<=0; width<=0; height<=0; compression<=0; planes<=0; bits<=0;
        header_index<=0; header_ok<=0; rgb_phase<=0; blue<=0; green<=0; pixel_count<=0;
    end else begin
        file_start<=0; abort_stream<=0; load_done<=0; load_error<=0; bmp_data_wr_en<=0;
        if (scan_start && ready) begin
            use_streamer<=0; scan_done<=0; fs_error<=0; bmp_error<=0;
        end
        if (scan_done_pulse) begin
            fs_error<=scan_error;
            // Missing files are not fatal if at least one named resource exists.
            if ((scan_error==0 || scan_error==8'h22) && resource_valid!=0)
                scan_done<=1;
            else begin load_error<=1; bmp_error<=4; scan_done<=0; end
        end
        case (state)
            IDLE: if (load_start && ready && scan_done) begin
                use_streamer<=1; bmp_error<=0; fs_error<=0;
                write_req<=1; ack_timer<=0; state<=WAIT_ACK;
                header_index<=0; header_ok<=0; rgb_phase<=0; pixel_count<=0;
                signature0<=0; signature1<=0; file_len<=0; pixel_offset<=0;
                dib_size<=0; width<=0; height<=0; compression<=0; planes<=0; bits<=0;
            end
            WAIT_ACK: begin
                // Reserve/reset the SDRAM write FIFO BEFORE reading any bytes.
                // The SPI transport has no byte-level backpressure.
                if (ack_sync) begin write_req<=0; file_start<=1; state<=STREAM; end
                else if (ack_timer>=LIMIT-1) fail_load(3'd2);
                else ack_timer<=ack_timer+1'b1;
            end
            STREAM: begin
                if (file_valid) begin
                    if (header_index<54) header_index<=header_index+1'b1;
                    case (header_index)
                        0: signature0<=file_byte;
                        1: signature1<=file_byte;
                        2: file_len[7:0]<=file_byte;
                        3: file_len[15:8]<=file_byte;
                        4: file_len[23:16]<=file_byte;
                        5: file_len[31:24]<=file_byte;
                        10: pixel_offset[7:0]<=file_byte;
                        11: pixel_offset[15:8]<=file_byte;
                        12: pixel_offset[23:16]<=file_byte;
                        13: pixel_offset[31:24]<=file_byte;
                        14: dib_size[7:0]<=file_byte;
                        15: dib_size[15:8]<=file_byte;
                        16: dib_size[23:16]<=file_byte;
                        17: dib_size[31:24]<=file_byte;
                        18: width[7:0]<=file_byte;
                        19: width[15:8]<=file_byte;
                        20: width[23:16]<=file_byte;
                        21: width[31:24]<=file_byte;
                        22: height[7:0]<=file_byte;
                        23: height[15:8]<=file_byte;
                        24: height[23:16]<=file_byte;
                        25: height[31:24]<=file_byte;
                        26: planes[7:0]<=file_byte;
                        27: planes[15:8]<=file_byte;
                        28: bits[7:0]<=file_byte;
                        29: bits[15:8]<=file_byte;
                        30: compression[7:0]<=file_byte;
                        31: compression[15:8]<=file_byte;
                        32: compression[23:16]<=file_byte;
                        33: compression[31:24]<=file_byte;
                        53: if (!header_match) fail_load(3'd1); else header_ok<=1;
                        default: ;
                    endcase
                    if (header_ok && file_offset>=pixel_offset &&
                        {32'd0,file_offset}<pixel_end && pixel_count<expected_pixels) begin
                        case (rgb_phase)
                            0: begin blue<=file_byte; rgb_phase<=1; end
                            1: begin green<=file_byte; rgb_phase<=2; end
                            2: begin
                                bmp_data<={file_byte,green,blue}; bmp_data_wr_en<=1;
                                pixel_count<=pixel_count+1'b1; rgb_phase<=0;
                            end
                            default: rgb_phase<=0;
                        endcase
                    end
                end
                if (file_done) begin
                    fs_error<=stream_error;
                    if (stream_error!=0) fail_load(3'd4);
                    else if (!header_ok || pixel_count!=expected_pixels || rgb_phase!=0)
                        fail_load(3'd3);
                    else begin load_done<=1; state<=IDLE; end
                end
            end
            default: state<=IDLE;
        endcase
    end
end
endmodule
