`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE       = 4'd0;
    localparam ST_DATA_REQ   = 4'd1;
    localparam ST_DATA_WAIT  = 4'd2;
    localparam ST_FAT_REQ    = 4'd3;
    localparam ST_FAT_WAIT   = 4'd4;
    localparam ST_FAT_PARSE  = 4'd5;
    localparam ST_FINISH     = 4'd7;
    localparam ST_CLUSTER_SUB = 4'd8;
    localparam ST_CLUSTER_MUL = 4'd9;
    localparam ST_CLUSTER_ADD = 4'd10;
    localparam ST_VALIDATE = 4'd11;
    localparam ST_FAT_DECIDE = 4'd12;
    reg next_eof, next_bad, next_same, chain_full;

    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] next_cluster;
    reg [31:0] remaining_bytes;
    reg bytes_available;
    reg [7:0] sector_in_cluster;
    // FAT32 entries are aligned four-byte words in a 512-byte sector.
    // Decode the word once, then select its byte using only index[1:0].
    reg [6:0] fat_entry_index;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;
    reg [31:0] cluster_offset,cluster_sectors;

    assign file_busy = (state != ST_IDLE);

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task advance_to_next_cluster;
        input [31:0] cluster_value;
        begin
            chain_count <= chain_count + 1'b1;
            current_cluster <= cluster_value;
            state <= ST_CLUSTER_SUB;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            next_eof<=0; next_bad<=0; next_same<=0; chain_full<=0;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            next_cluster <= 32'd0;
            remaining_bytes <= 32'd0;
            bytes_available <= 1'b0;
            sector_in_cluster <= 8'd0;
            fat_entry_index <= 7'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
            cluster_offset <= 0;
            cluster_sectors <= 0;
        end else begin
            file_done <= 1'b0;
            file_valid <= 1'b0;
            sector_req <= 1'b0;

            if (state == ST_DATA_WAIT && sector_valid && bytes_available) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                file_byte_offset <= file_size - remaining_bytes;
                remaining_bytes <= remaining_bytes - 1'b1;
                bytes_available <= remaining_bytes != 1;
            end

            if (state == ST_FAT_WAIT && sector_valid &&
                sector_byte_index[8:2] == fat_entry_index) begin
                case (sector_byte_index[1:0])
                    2'd0: fat_byte0 <= sector_byte;
                    2'd1: fat_byte1 <= sector_byte;
                    2'd2: fat_byte2 <= sector_byte;
                    2'd3: fat_byte3 <= sector_byte;
                endcase
            end

            case (state)
                ST_IDLE: if (file_start) begin
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    bytes_available <= file_size != 0;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    current_cluster <= first_cluster;
                    state <= ST_VALIDATE;
                end
                ST_VALIDATE: begin
                    if (remaining_bytes == 0) begin
                        state <= ST_FINISH;
                    end else if (current_cluster < 2 || current_cluster > max_cluster ||
                                 sectors_per_cluster == 0 ||
                                 (sectors_per_cluster & (sectors_per_cluster-1'b1))!=0 ||
                                 current_cluster>=32'h0ffffff0) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else begin
                        state <= ST_CLUSTER_SUB;
                    end
                end
                ST_CLUSTER_SUB: begin
                    cluster_offset <= current_cluster - 32'd2;
                    state <= ST_CLUSTER_MUL;
                end
                ST_CLUSTER_MUL: begin
                    cluster_sectors <= cluster_offset * sectors_per_cluster;
                    state <= ST_CLUSTER_ADD;
                end
                ST_CLUSTER_ADD: begin
                    sector_lba <= data_start_lba + cluster_sectors;
                    state <= ST_DATA_REQ;
                end
                ST_DATA_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (remaining_bytes == 0 ||
                                 (remaining_bytes == 1 && sector_valid)) begin
                        final_chain_check <= 1'b1;
                        sector_in_cluster <= 8'd0;
                        fat_entry_index <= current_cluster[6:0];
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_DATA_REQ;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        fat_entry_index <= current_cluster[6:0];
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PARSE;
                end
                ST_FAT_PARSE: begin
                    next_cluster <= {4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0};
                    next_eof <= {fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}>=28'hffffff8;
                    next_bad <= {4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}<2 ||
                                {4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}>max_cluster ||
                                {fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}>=28'hffffff0;
                    next_same <= {4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}==current_cluster;
                    chain_full <= chain_count>=MAX_VISITED_CLUSTERS;
                    state <= ST_FAT_DECIDE;
                end
                ST_FAT_DECIDE: begin
                    if(final_chain_check) begin
                        final_chain_check<=0;
                        if(next_eof) state<=ST_FINISH;
                        else if(next_bad) finish_with_error(ERR_CLUSTER_RANGE);
                        else finish_with_error(ERR_FAT_LOOP);
                    end else if(next_eof) finish_with_error(ERR_EARLY_EOF);
                    else if(next_bad) finish_with_error(ERR_CLUSTER_RANGE);
                    else if(chain_full) finish_with_error(ERR_VISITED_EXHAUSTED);
                    else if(next_same) finish_with_error(ERR_FAT_LOOP);
                    else advance_to_next_cluster(next_cluster);
                end
                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
