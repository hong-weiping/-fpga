`timescale 1ns/1ps

module fat32_volume_scanner #(parameter AUDIO_ONLY=0) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [6:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource6_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg  [31:0] resource6_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    localparam ST_ROOT_FAT_REQ=4'd12, ST_ROOT_FAT_WAIT=4'd13;
    reg [15:0] root_hops;
    localparam ST_BOOT_COUNT=5'd14, ST_BOOT_CHECK=5'd15;
    localparam ST_ROOT_SUB=5'd16, ST_ROOT_SHIFT=5'd17, ST_ROOT_ADD=5'd18;
    localparam ST_HEADER=5'd19, ST_MBR_LOAD=5'd20, ST_MBR_CHECK=5'd21,
        ST_MBR_COMMIT=5'd22, ST_BOOT_SIGNATURE=5'd23,
        ST_LAYOUT_PREP=5'd24, ST_FAT_SELECT=5'd25;
    reg [1:0] partition_index;
    reg [7:0] candidate_type;
    reg [31:0] candidate_lba;
    reg active_second_fat;
    reg [32:0] layout_span_reg, volume_end_reg;
    reg [4:0] state;
    reg [31:0] cluster_count,root_offset,root_sector_offset;
    reg [7:0] root_sector;
    reg directory_end;
    reg [7:0] sector_buffer [0:511];
    reg [31:0] root_cluster;
    reg [27:0] root_fat_next;
    wire [31:0] root_next={4'd0,root_fat_next};
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg [6:0] entry_commit;
    reg entry_qualified;
    reg       dir_entry_match;
    reg [2:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;
    wire [32:0] layout_span={17'd0,reserved_sectors}+{1'b0,fat_span};
    wire [32:0] volume_end={1'b0,partition_lba}+{1'b0,total_sectors};
    wire [31:0] entry_cluster={4'd0,dir_cluster_high[11:0],dir_cluster_low};
    wire [31:0] entry_size={sector_byte,dir_file_size[23:0]};

    assign scan_busy = (state != ST_IDLE);

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            entry_commit <= 0; entry_qualified <= 0;
            partition_index <= 0; candidate_type <= 0; candidate_lba <= 0;
            active_second_fat <= 0; layout_span_reg <= 0; volume_end_reg <= 0;
            root_sector <= 0; directory_end <= 0; root_hops<=0; root_fat_next<=0;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 7'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource5_cluster <= 32'd0;
            resource6_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            resource5_size <= 32'd0;
            resource6_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            cluster_count <= 0;
            root_offset <= 0;
            root_sector_offset <= 0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 2'd3;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            if (sector_valid && state != ST_ROOT_WAIT && state != ST_ROOT_FAT_WAIT)
                sector_buffer[sector_byte_index] <= sector_byte;

            if(sector_valid && state==ST_ROOT_FAT_WAIT && sector_byte_index[8:2]==root_cluster[6:0]) begin
                case(sector_byte_index[1:0])
                    0:root_fat_next[7:0]<=sector_byte;
                    1:root_fat_next[15:8]<=sector_byte;
                    2:root_fat_next[23:16]<=sector_byte;
                    3:root_fat_next[27:24]<=sector_byte[3:0];
                endcase
            end

            // The entry payload is held until the following directory entry.
            // Register one-hot writes to remove byte decode from 64-bit bank enables.
            entry_commit <= 0;
            if(entry_commit[0]) begin resource0_cluster<=entry_cluster; resource0_size<=dir_file_size; resource_valid[0]<=1'b1; end
            if(entry_commit[1]) begin resource1_cluster<=entry_cluster; resource1_size<=dir_file_size; resource_valid[1]<=1'b1; end
            if(entry_commit[2]) begin resource2_cluster<=entry_cluster; resource2_size<=dir_file_size; resource_valid[2]<=1'b1; end
            if(entry_commit[3]) begin resource3_cluster<=entry_cluster; resource3_size<=dir_file_size; resource_valid[3]<=1'b1; end
            if(entry_commit[4]) begin resource4_cluster<=entry_cluster; resource4_size<=dir_file_size; resource_valid[4]<=1'b1; end
            if(entry_commit[5]) begin resource5_cluster<=entry_cluster; resource5_size<=dir_file_size; resource_valid[5]<=1'b1; end
            if(entry_commit[6]) begin resource6_cluster<=entry_cluster; resource6_size<=dir_file_size; resource_valid[6]<=1'b1; end
            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        if (sector_byte==0) directory_end<=1;
                        dir_entry_match <= 1'b0;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        if (AUDIO_ONLY==1 && !directory_end && (sector_byte & 8'hd8)==0 &&
                            {dir_name0,dir_name1,dir_name2,dir_name3,dir_name4,dir_name5,
                             dir_name6,dir_name7,dir_name8,dir_name9,dir_name10}=="AUDIO   PCM") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= 0;
                        end else if (AUDIO_ONLY==2 && !directory_end && (sector_byte & 8'hd8)==0 &&
                            {dir_name0,dir_name1,dir_name2,dir_name3,dir_name4}=="AUDIO" &&
                            dir_name5 >= "1" && dir_name5 <= "7" &&
                            dir_name6==" " && dir_name7==" " &&
                            {dir_name8,dir_name9,dir_name10}=="PCM") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name5 - "1";
                        end else if (!AUDIO_ONLY && !directory_end && (sector_byte & 8'hd8)==0 &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                            dir_name3 <= "6" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name3 - "1";
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: begin
                        dir_file_size[23:16] <= sector_byte;
                        entry_qualified <= dir_entry_match && !directory_end &&
                            entry_cluster>=2 && entry_cluster<=max_cluster &&
                            !resource_valid[dir_resource_index];
                    end
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if(entry_qualified && entry_size!=0)
                            entry_commit <= 7'b0000001 << dir_resource_index;
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 7'd0;
                    root_sector<=0; directory_end<=0; root_hops<=0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                // Parse only after the last byte has entered the buffer.
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0) finish_with_error(ERR_SECTOR);
                    else state <= ST_HEADER;
                end
                ST_HEADER: begin
                    if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if ((sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) &&
                             le16(11)==512 && le16(17)==0 && le16(22)==0) begin
                        partition_lba <= 0;
                        state <= ST_BOOT_PARSE;
                    end else begin
                        partition_index <= 0;
                        state <= ST_MBR_LOAD;
                    end
                end
                // Register one entry, then validate it, then commit its address.
                // Avoid the former four-entry priority mux on the 100 MHz path.
                ST_MBR_LOAD: begin
                    case (partition_index)
                        0: begin candidate_type<=sector_buffer[450]; candidate_lba<=le32(454); end
                        1: begin candidate_type<=sector_buffer[466]; candidate_lba<=le32(470); end
                        2: begin candidate_type<=sector_buffer[482]; candidate_lba<=le32(486); end
                        3: begin candidate_type<=sector_buffer[498]; candidate_lba<=le32(502); end
                    endcase
                    state <= ST_MBR_CHECK;
                end
                ST_MBR_CHECK: begin
                    if ((candidate_type==8'h0b || candidate_type==8'h0c) && candidate_lba!=0)
                        state <= ST_MBR_COMMIT;
                    else if (partition_index==3) finish_with_error(ERR_UNSUPPORTED_BPB);
                    else begin partition_index<=partition_index+1'b1; state<=ST_MBR_LOAD; end
                end
                ST_MBR_COMMIT: begin
                    partition_lba <= candidate_lba;
                    sector_lba <= candidate_lba;
                    state <= ST_BOOT_REQ;
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else state <= ST_BOOT_SIGNATURE;
                end
                ST_BOOT_SIGNATURE: begin
                    if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(sector_buffer[13]) ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(36)>32'h007fffff || le32(44) < 2 ||
                        le16(42)!=0 || (sector_buffer[40][7] && sector_buffer[40][3:0]>=sector_buffer[16])) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        active_second_fat <= sector_buffer[40][7] && sector_buffer[40][3:0]==1;
                        state <= ST_LAYOUT_PREP;
                    end
                end
                ST_LAYOUT_PREP: begin
                    layout_span_reg <= layout_span;
                    volume_end_reg <= volume_end;
                    fat_start_lba <= partition_lba + reserved_sectors;
                    state <= ST_FAT_SELECT;
                end
                ST_FAT_SELECT: begin
                    if (active_second_fat) fat_start_lba <= fat_start_lba + fat_sectors;
                    state <= ST_BOOT_LAYOUT;
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + layout_span_reg[31:0];
                    data_sector_count <= total_sectors - layout_span_reg[31:0];
                    if (layout_span_reg>=total_sectors || volume_end_reg>33'h100000000)
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    else state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    cluster_count <= data_sector_count >> sectors_per_cluster_shift;
                    state <= ST_BOOT_COUNT;
                end
                ST_BOOT_COUNT: begin
                    max_cluster <= cluster_count + 1'b1;
                    state <= ST_BOOT_CHECK;
                end
                ST_BOOT_CHECK: begin
                    if (cluster_count<65525 || cluster_count>32'h0fffffee ||
                        root_cluster>max_cluster ||
                        {1'b0,cluster_count}+2 > ({1'b0,fat_sectors} << 7))
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    else state <= ST_ROOT_SUB;
                end
                ST_ROOT_SUB: begin
                    root_offset <= root_cluster - 32'd2;
                    state <= ST_ROOT_SHIFT;
                end
                ST_ROOT_SHIFT: begin
                    root_sector_offset <= root_offset << sectors_per_cluster_shift;
                    state <= ST_ROOT_ADD;
                end
                ST_ROOT_ADD: begin
                    root_lba <= data_start_lba + root_sector_offset;
                    sector_lba <= data_start_lba + root_sector_offset;
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    dir_entry_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                                    state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: if(entry_commit==0) begin
                    if (resource_valid == (AUDIO_ONLY==1 ? 7'h01 : AUDIO_ONLY==2 ? 7'h7f : 7'h3f))
                        state <= ST_FINISH;
                    else if (!directory_end && root_sector+1 < sectors_per_cluster) begin
                        root_sector<=root_sector+1'b1;
                        sector_lba<=root_lba+root_sector+1'b1;
                        state<=ST_ROOT_REQ;
                    end else if(directory_end) finish_with_error(ERR_RESOURCE_MISSING);
                    else begin
                        sector_lba<=fat_start_lba+(root_cluster>>7);
                        state<=ST_ROOT_FAT_REQ;
                    end
                end
                ST_ROOT_FAT_REQ: if(!sector_busy) begin
                    sector_req<=1;state<=ST_ROOT_FAT_WAIT;
                end
                ST_ROOT_FAT_WAIT: if(sector_done) begin
                    if(sector_error!=0) finish_with_error(ERR_SECTOR);
                    else if(root_next>=32'h0ffffff8) finish_with_error(ERR_RESOURCE_MISSING);
                    else if(root_next<2 || root_next>max_cluster || root_next==root_cluster || root_hops==16'hffff)
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    else begin
                        root_cluster<=root_next;root_hops<=root_hops+1'b1;root_sector<=0;
                        state<=ST_ROOT_SUB;
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
