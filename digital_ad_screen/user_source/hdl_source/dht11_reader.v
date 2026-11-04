`timescale 1ns/1ps
// Open-drain DHT11 host. Timings below are in microseconds.
module dht11_reader #(
    parameter integer CLK_HZ=50000000,
    parameter integer POWERUP_US=1000000,
    parameter integer POLL_US=2000000
)(
    input wire clk, rst_n,
    inout wire data,
    output reg [7:0] temperature, humidity,
    output reg valid,
    output reg [1:0] error_code
);
    localparam IDLE=0, START=1, RELEASE=2, RESP_LOW=3,
               RESP_HIGH=4, BIT_LOW=5, BIT_HIGH=6, CHECK=7;
    localparam integer DIV=CLK_HZ/1000000;
    localparam integer DW=(DIV<2)?1:$clog2(DIV);
    localparam integer MAX_WAIT=(POWERUP_US>POLL_US)?POWERUP_US:POLL_US;
    localparam integer TW=$clog2(((MAX_WAIT>20000)?MAX_WAIT:20000)+1);
    reg [DW-1:0] divider;
    reg [TW-1:0] timer,wait_us;
    reg [3:0] state;
    reg [5:0] bit_count;
    reg [39:0] shift;
    (* async_reg="true" *) reg data_meta, data_sync;
    wire [7:0] checksum=shift[39:32]+shift[31:24]+shift[23:16]+shift[15:8];
    assign data=(state==START) ? 1'b0 : 1'bz;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin data_meta<=1; data_sync<=1; end
        else begin data_meta<=data; data_sync<=data_meta; end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            divider<=0; timer<=0; wait_us<=POWERUP_US; state<=IDLE;
            bit_count<=0; shift<=0; temperature<=0; humidity<=0;
            valid<=0; error_code<=0;
        end else if(divider==DIV-1) begin
            divider<=0;
            timer<=timer+1'b1;
            case(state)
                IDLE: if(timer>=wait_us-1) begin
                    timer<=0; state<=START; shift<=0; bit_count<=0;
                end
                START: if(timer==20000-1) begin timer<=0; state<=RELEASE; end
                // Ignore synchronizer latency immediately after releasing DATA.
                RELEASE: if(timer>=10 && !data_sync) begin timer<=0; state<=RESP_LOW; end
                    else if(timer>=200) begin
                        state<=IDLE; timer<=0; wait_us<=POLL_US; valid<=0; error_code<=1;
                    end
                RESP_LOW: if(data_sync) begin timer<=0; state<=RESP_HIGH; end
                    else if(timer>=150) begin
                        state<=IDLE; timer<=0; wait_us<=POLL_US; valid<=0; error_code<=1;
                    end
                RESP_HIGH: if(!data_sync) begin timer<=0; state<=BIT_LOW; end
                    else if(timer>=150) begin
                        state<=IDLE; timer<=0; wait_us<=POLL_US; valid<=0; error_code<=1;
                    end
                BIT_LOW: if(data_sync) begin timer<=0; state<=BIT_HIGH; end
                    else if(timer>=120) begin
                        state<=IDLE; timer<=0; wait_us<=POLL_US; valid<=0; error_code<=1;
                    end
                BIT_HIGH: if(!data_sync) begin
                        shift<={shift[38:0],(timer>=45)};
                        timer<=0;
                        if(bit_count==39) state<=CHECK;
                        else begin bit_count<=bit_count+1'b1; state<=BIT_LOW; end
                    end else if(timer>=120) begin
                        state<=IDLE; timer<=0; wait_us<=POLL_US; valid<=0; error_code<=1;
                    end
                CHECK: begin
                    state<=IDLE; timer<=0; wait_us<=POLL_US;
                    if(checksum==shift[7:0]) begin
                        humidity<=shift[39:32]; temperature<=shift[23:16];
                        valid<=1; error_code<=0;
                    end else begin valid<=0; error_code<=2; end
                end
                default: begin state<=IDLE; timer<=0; valid<=0; end
            endcase
        end else divider<=divider+1'b1;
    end
endmodule
