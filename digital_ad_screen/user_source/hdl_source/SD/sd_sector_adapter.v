`timescale 1ns/1ps
// One outstanding sector. Completion follows the last byte by at least one
// cycle, including transports that assert end with byte 511.
module sd_sector_adapter #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer SD_READ_TIMEOUT_MS=500
)(
    input wire clk, rst_n, cancel,
    input wire sector_req,
    input wire [31:0] sector_lba,
    output wire sector_busy,
    output reg sector_valid,
    output reg [7:0] sector_byte,
    output reg [8:0] sector_byte_index,
    output reg sector_done,
    output reg [7:0] sector_error,
    output reg transport_reset,
    output reg sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input wire sd_sec_read_data_valid,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_end
);
localparam [63:0] RAW=(64'd1*CLK_FREQ_HZ*SD_READ_TIMEOUT_MS)/1000;
localparam [31:0] LIMIT=(RAW<1)?1:RAW;
reg busy, pending_done;
reg [9:0] count;
localparam integer TIMER_W=(LIMIT<=1)?1:$clog2(LIMIT);
reg [TIMER_W-1:0] timer;
wire [10:0] received={1'b0,count}+sd_sec_read_data_valid;
assign sector_busy=busy | pending_done | sector_done;
// Register the complete byte bundle to break the transport -> scanner path.
// pending_done keeps completion one cycle behind the final registered byte.
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin sector_valid<=0;sector_byte<=0;sector_byte_index<=0;end
    else begin
        sector_valid<=busy && !cancel && sd_sec_read_data_valid && count<512;
        sector_byte<=sd_sec_read_data;
        sector_byte_index<=count[8:0];
    end
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy<=0; pending_done<=0; count<=0; timer<=0;
        sector_done<=0; sector_error<=0; transport_reset<=0;
        sd_sec_read<=0; sd_sec_read_addr<=0;
    end else begin
        sector_done<=pending_done; pending_done<=0; transport_reset<=0;
        if (cancel) begin
            busy<=0; pending_done<=0; sector_done<=0; sd_sec_read<=0;
            transport_reset<=busy; timer<=0;
        end else if (sector_req && !sector_busy) begin
            busy<=1; count<=0; timer<=0; sector_error<=0;
            sd_sec_read<=1; sd_sec_read_addr<=sector_lba;
        end else if (busy) begin
            if (sd_sec_read_end) begin
                busy<=0; sd_sec_read<=0; pending_done<=1;
                if (received!=512) begin
                    sector_error<=8'h12; transport_reset<=1;
                end
            end else if (sd_sec_read_data_valid) begin
                timer<=0;
                if (count<512) count<=count+1'b1;
                else begin
                    busy<=0; sd_sec_read<=0; pending_done<=1;
                    sector_error<=8'h12; transport_reset<=1;
                end
            end else if (timer>=LIMIT-1) begin
                busy<=0; sd_sec_read<=0; pending_done<=1;
                sector_error<=8'h11; transport_reset<=1;
            end else timer<=timer+1'b1;
        end
    end
end
endmodule
