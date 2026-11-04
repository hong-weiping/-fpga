// 115200 8N1 by default. All logic stays in the board clock domain.
module uart_echo #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200
)(
    input wire clk, input wire rst_n,
    input wire uart_rx, output wire uart_tx,
    output reg overflow, output reg framing_error
);
    wire [7:0] rx_data;
    wire rx_valid, rx_error, tx_ready;
    reg [7:0] fifo [0:31];
    reg [4:0] wr_ptr, rd_ptr;
    reg [5:0] count;
    wire pop = (count != 0) && tx_ready;
    wire push = rx_valid && ((count < 32) || pop);
    uart_rx_8n1 #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx),
        .data(rx_data), .valid(rx_valid), .frame_error(rx_error));
    uart_tx_8n1 #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(fifo[rd_ptr]),
        .valid(count != 0), .ready(tx_ready), .tx(uart_tx));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; rd_ptr <= 0; count <= 0;
            overflow <= 0; framing_error <= 0;
        end else begin
            if (rx_error) framing_error <= 1;
            if (rx_valid && !push) overflow <= 1;
            if (push) begin fifo[wr_ptr] <= rx_data; wr_ptr <= wr_ptr + 1'b1; end
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule

module uart_tx_8n1 #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200
)(
    input wire clk, input wire rst_n, input wire [7:0] data,
    input wire valid, output wire ready, output wire tx
);
    localparam integer TICKS = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer CW = (TICKS < 2) ? 1 : $clog2(TICKS);
    reg [CW-1:0] timer;
    reg [9:0] shift;
    reg [3:0] bit_index;
    reg busy;
    assign ready = !busy;
    assign tx = busy ? shift[0] : 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin timer <= 0; shift <= 10'h3ff; bit_index <= 0; busy <= 0; end
        else if (!busy) begin
            if (valid) begin
                shift <= {1'b1, data, 1'b0}; timer <= TICKS-1;
                bit_index <= 0; busy <= 1;
            end
        end else if (timer != 0) timer <= timer - 1'b1;
        else if (bit_index == 9) busy <= 0;
        else begin
            shift <= {1'b1, shift[9:1]}; bit_index <= bit_index + 1'b1;
            timer <= TICKS-1;
        end
    end
endmodule

module uart_rx_8n1 #(
    parameter integer CLK_HZ = 50000000,
    parameter integer BAUD = 115200
)(
    input wire clk, input wire rst_n, input wire rx,
    output reg [7:0] data, output reg valid, output reg frame_error
);
    localparam integer TICKS = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer CW = (TICKS < 2) ? 1 : $clog2(TICKS);
    localparam IDLE=0, START=1, DATA=2, STOP=3, WAIT_HIGH=4;
    (* async_reg="true" *) reg rx_meta, rx_sync;
    reg [2:0] state, bit_index;
    reg [CW-1:0] timer;
    reg [7:0] shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_meta <= 1; rx_sync <= 1; end
        else begin rx_meta <= rx; rx_sync <= rx_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; bit_index <= 0; timer <= 0;
            shift <= 0; data <= 0; valid <= 0; frame_error <= 0;
        end else begin
            valid <= 0; frame_error <= 0;
            case (state)
                IDLE: if (!rx_sync) begin state <= START; timer <= TICKS/2-1; end
                START: if (timer != 0) timer <= timer - 1'b1;
                    else if (rx_sync) state <= IDLE;
                    else begin state <= DATA; bit_index <= 0; timer <= TICKS-1; end
                DATA: if (timer != 0) timer <= timer - 1'b1;
                    else begin
                        shift[bit_index] <= rx_sync; timer <= TICKS-1;
                        if (bit_index == 7) state <= STOP;
                        else bit_index <= bit_index + 1'b1;
                    end
                STOP: if (timer != 0) timer <= timer - 1'b1;
                    else if (rx_sync) begin data <= shift; valid <= 1; state <= IDLE; end
                    else begin frame_error <= 1; state <= WAIT_HIGH; end
                WAIT_HIGH: if (rx_sync) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
