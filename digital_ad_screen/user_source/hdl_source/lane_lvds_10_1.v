


module lane_lvds_10_1 #(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_rst,

    input wire[9:0] I_data_in,

    output wire     O_serial_out
);

    wire pixel_rst_n, serial_rst_n;
    reset_sync u_pixel_reset (
        .clk(I_pixel_clk), .ext_rst_n(~I_rst), .rst_n_sync(pixel_rst_n)
    );
    reset_sync u_serial_reset (
        .clk(I_serial_clk), .ext_rst_n(~I_rst), .rst_n_sync(serial_rst_n)
    );

    reg      S_odd_even;     
    reg      S_odd_even_1d;  
    reg      S_odd_even_2d;  
    reg      S_load_en;      
    reg      S_load_en_1d;   
    reg      S_load_en_2d;   
    reg[9:0] S_shift_data;   
    reg[1:0] S_oddr_data;    


    always @(posedge I_pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n)
            S_odd_even <= 1'b0;
        else
            S_odd_even <= ~S_odd_even;
    end

    always @(posedge I_serial_clk or negedge serial_rst_n) begin
        if (!serial_rst_n) begin
            S_odd_even_1d <= 1'b0;
            S_odd_even_2d <= 1'b0;
        end else begin
            S_odd_even_1d <= S_odd_even;
            S_odd_even_2d <= S_odd_even_1d;
        end
    end

    always @(posedge I_serial_clk or negedge serial_rst_n) begin
        if (!serial_rst_n) begin
            S_load_en <= 1'b0;
            S_load_en_1d <= 1'b0;
            S_load_en_2d <= 1'b0;
        end else begin
            S_load_en    <= S_odd_even_1d ^ S_odd_even_2d;
            S_load_en_1d <= S_load_en;
            S_load_en_2d <= S_load_en_1d;
        end
    end

    always @(posedge I_serial_clk or negedge serial_rst_n) begin
        if(!serial_rst_n)
            S_shift_data <= 'd0;
        else
            if(S_load_en_2d)
                S_shift_data <= I_data_in;
            else 
                S_shift_data <= S_shift_data << 2;
    end

    always @(posedge I_serial_clk or negedge serial_rst_n) begin
        if (!serial_rst_n)
            S_oddr_data <= 2'b00;
        else
            S_oddr_data <= S_shift_data[9:8];
    end

    generate
        if(DEVICE == "EF2")
            begin
                EF2_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF3")
            begin
                EF3_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF4")
            begin
                EF4_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "SF1")
            begin
                SF1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EG")
            begin
                EG_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1A")
            begin
                PH1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1P")
            begin
                PH1P_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "DR1")
            begin
                DR1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( ~serial_rst_n ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
    endgenerate
    
endmodule