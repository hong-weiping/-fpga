`timescale 1ns/1ps
// Register each selected sample. Source/volume changes cannot alter a sample
// that is already stalled at the HDMI valid/ready boundary.
module audio_source_mux (
    input wire clk,rst_n,
    input wire wav_valid,wav_active,
    output wire wav_ready,
    input wire signed [15:0] wav_left,wav_right,
    input wire arp_valid,
    output wire arp_ready,
    input wire signed [15:0] arp_left,arp_right,
    input wire force_arpeggio,
    output reg out_valid,
    input wire out_ready,
    output reg signed [15:0] out_left,out_right
);
    wire use_wav=wav_active && !force_arpeggio;
    wire room=!out_valid || out_ready;
    assign wav_ready=room && use_wav;
    assign arp_ready=room && !use_wav;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin out_valid<=0;out_left<=0;out_right<=0;end
        else if(room) begin
            out_valid<=use_wav?wav_valid:arp_valid;
            if(use_wav?wav_valid:arp_valid) begin
                out_left<=use_wav?wav_left:arp_left;
                out_right<=use_wav?wav_right:arp_right;
            end
        end
    end
endmodule
