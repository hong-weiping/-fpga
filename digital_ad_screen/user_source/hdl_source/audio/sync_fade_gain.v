`timescale 1ns/1ps
// This project's PCM and video logic share video_clk. Sample the envelope
// two clocks after VS: the transition controller commits on VS and may see
// index_commit a clock later. No asynchronous byte-bus sampling is needed.
module sync_fade_gain (
    input wire clk,rst_n,frame_start,
    input wire [7:0] alpha_pix,
    input wire fade_active,
    output reg [7:0] gain_aud
);
    reg frame_q,frame_qq;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin frame_q<=0;frame_qq<=0;gain_aud<=255;end
        else begin
            frame_q<=frame_start;frame_qq<=frame_q;
            if(frame_qq) gain_aud<=fade_active?alpha_pix:8'd255;
        end
    end
endmodule
