`timescale 1ns/1ps
// Combinational path: HS/VS/DE/X need no extra delay. rgb_video_adapter
// registers the entire output bundle, including these pixels and the OSD.
module video_transition_rgb #(
    parameter integer FADE_FRAMES=16,
    parameter integer FRAME_WIDTH=640
)(
    input wire [23:0] rgb_in,
    input wire [11:0] pixel_x,
    input wire [7:0] alpha,
    input wire wipe_active,
    input wire [8:0] ramp,
    output wire [23:0] rgb_out
);
    generate if(FADE_FRAMES==0) begin : g_bypass
        assign rgb_out=rgb_in;
    end else begin : g_effect
        wire [15:0] red_product=rgb_in[23:16]*alpha;
        wire [15:0] green_product=rgb_in[15:8]*alpha;
        wire [15:0] blue_product=rgb_in[7:0]*alpha;
        // Full brightness is bit-exact, including the low RGB bits.
        wire [23:0] faded=(alpha==8'd255)?rgb_in:
            {red_product[15:8],green_product[15:8],blue_product[15:8]};
        wire [31:0] boundary=(ramp*FRAME_WIDTH)/FADE_FRAMES;
        assign rgb_out=wipe_active ? ((pixel_x<boundary)?rgb_in:24'd0) : faded;
    end endgenerate
endmodule