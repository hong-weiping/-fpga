`timescale 1ns/1ps
// Stop new requests and drain the outstanding sector before restarting.
// Reset both FIFO domains together to discard the old track safely.
module paired_audio_session (
    input wire clk, rst_n, enable,
    input wire [3:0] requested,
    input wire transfer_busy,
    input wire replay,
    output wire quiesce, source_reset_n, fifo_reset_n, running,
    output reg [2:0] session_index
);
    localparam HOLD=0, RUN=1, DRAIN=2;
    reg [1:0] state;
    reg [5:0] hold_count;
    wire changed=!enable || !requested[3] || requested[2:0]!=session_index || replay;
    assign running=state==RUN;
    assign quiesce=state!=RUN || changed;
    assign source_reset_n=rst_n && state!=HOLD;
    assign fifo_reset_n=rst_n && state==RUN;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin state<=HOLD;hold_count<=0;session_index<=0;end
        else case(state)
            HOLD: begin
                session_index<=requested[2:0];
                if(!enable || !requested[3]) hold_count<=0;
                else if(hold_count==31) begin hold_count<=0;state<=RUN;end
                else hold_count<=hold_count+1'b1;
            end
            RUN: if(changed) state<=DRAIN;
            DRAIN: if(!transfer_busy) begin state<=HOLD;hold_count<=0;end
            default: state<=HOLD;
        endcase
    end
endmodule
