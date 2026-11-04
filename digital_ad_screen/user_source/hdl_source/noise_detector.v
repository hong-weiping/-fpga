module noise_detector #(
    parameter integer HOLD_CYCLES = 500000000 // 10 seconds at board clk=50 MHz
) (
    input wire clk,
    input wire rst_n,
    input wire noise_in,
    input wire fire_active,
    output wire noise_flag,
    output wire noise_alarm
);
    // External threshold output: high = noise, low = normal.
    (* keep="true", async_reg="true" *) reg noise_meta /* synthesis keep */;
    (* keep="true", async_reg="true" *) reg noise_sync /* synthesis keep */;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_meta <= 1'b0;
            noise_sync <= 1'b0;
        end else begin
            noise_meta <= noise_in;
            noise_sync <= noise_meta;
        end
    end
    assign noise_flag = noise_sync;
    // Reload while noise is present; release only after a continuous quiet interval.
    // Keep the raw synchronized flag separate from the playback hold state.
    localparam integer COUNT_WIDTH = HOLD_CYCLES < 2 ? 1 : $clog2(HOLD_CYCLES+1);
    reg [COUNT_WIDTH-1:0] quiet_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) quiet_count <= 0;
        else if (fire_active) quiet_count <= 0;
        else if (noise_sync) quiet_count <= HOLD_CYCLES;
        else if (quiet_count != 0) quiet_count <= quiet_count - 1'b1;
    end
    assign noise_alarm = !fire_active && (noise_sync || (quiet_count != 0));
endmodule
