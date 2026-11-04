module fire_detector (
    input wire clk,
    input wire rst_n,
    input wire fire_n,
    output wire fire_flag
);
    // Synchronize the asynchronous active-low sensor. Reset means no alarm.
    (* keep="true" *) reg fire_meta /* synthesis keep */;
    (* keep="true" *) reg fire_sync /* synthesis keep */;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fire_meta <= 1'b1;
            fire_sync <= 1'b1;
        end else begin
            fire_meta <= fire_n;
            fire_sync <= fire_meta;
        end
    end
    assign fire_flag = ~fire_sync;
endmodule