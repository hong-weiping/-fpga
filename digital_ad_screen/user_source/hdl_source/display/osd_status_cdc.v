`timescale 1ns/1ps
// Latest status snapshot, not an event queue. The source holds the entire
// bundle until the destination acknowledges it. Both resets must be asserted
// together (the top uses the shared PLL-qualified reset in all domains).
module osd_status_cdc #(parameter WIDTH = 8) (
    input wire src_clk, src_rst_n,
    input wire [WIDTH-1:0] src_status,
    input wire dst_clk, dst_rst_n,
    output reg [WIDTH-1:0] dst_status
);
    reg [WIDTH-1:0] held_status;
    reg request_toggle, acknowledge_toggle;
    (* async_reg="true" *) reg ack_meta, ack_sync;
    (* async_reg="true" *) reg req_meta, req_sync;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            held_status <= 0;
            request_toggle <= 0;
            ack_meta <= 0;
            ack_sync <= 0;
        end else begin
            ack_meta <= acknowledge_toggle;
            ack_sync <= ack_meta;
            if (request_toggle == ack_sync) begin
                held_status <= src_status;
                request_toggle <= ~request_toggle;
            end
        end
    end
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            req_meta <= 0;
            req_sync <= 0;
            acknowledge_toggle <= 0;
            dst_status <= 0;
        end else begin
            req_meta <= request_toggle;
            req_sync <= req_meta;
            if (req_sync != acknowledge_toggle) begin
                dst_status <= held_status;
                acknowledge_toggle <= req_sync;
            end
        end
    end
endmodule
