module mall_layout_osd(
 input wire clk,rst_n,frame_start,hs_in,vs_in,de_in,
 input wire [11:0] x,y,input wire [23:0] rgb_in,
 input wire [2:0] image_index,input wire [83:0] environment,input wire [16:0] sensor,
 input wire [1:0] carousel_period_gray,
 input wire online,auto_play,input wire [7:0] volume,
 input wire [7:0] picture_brightness,contrast,saturation,screen_brightness,
 input wire [1:0] parameter_selection,
 input wire pcm_valid,input wire signed [15:0] pcm_sample,
 output wire hs_out,vs_out,de_out,output wire [23:0] rgb_out);
 wire [9:0] sx=x[9:0],sy=y[9:0];
 reg [1:0] period_q;
 reg [83:0] env;reg [16:0] sens;reg connected,auto_q;reg [7:0] vol;
 function [7:0] decimal_pair;
 input [7:0] binary_value;
 reg [19:0] b;integer k;
 begin b={12'd0,binary_value};for(k=0;k<8;k=k+1)begin
 if(b[11:8]>=5)b[11:8]=b[11:8]+3;
 if(b[15:12]>=5)b[15:12]=b[15:12]+3;
 if(b[19:16]>=5)b[19:16]=b[19:16]+3;
 b=b<<1;end decimal_pair=b[15:8];end endfunction
 wire [7:0] temperature_bcd,humidity_bcd,volume_bcd;
 reg [7:0] pb,ct,st,screen;
 wire [7:0] pb_bcd,ct_bcd,st_bcd,screen_bcd;
 reg [1:0] selection;

 // Synchronous BCD ROMs replace seven parallel combinational converters.
 reg decimal_valid;
 always @(posedge clk or negedge rst_n)if(!rst_n)decimal_valid<=0;else if(frame_start)decimal_valid<=1;
reg [7:0] temperature_bcd_rom[0:255];reg [7:0] temperature_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",temperature_bcd_rom);
always @(posedge clk)if(frame_start)temperature_bcd_q<=temperature_bcd_rom[sensor[15:8]];
assign temperature_bcd=decimal_valid?temperature_bcd_q:8'h0;
reg [7:0] humidity_bcd_rom[0:255];reg [7:0] humidity_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",humidity_bcd_rom);
always @(posedge clk)if(frame_start)humidity_bcd_q<=humidity_bcd_rom[sensor[7:0]];
assign humidity_bcd=decimal_valid?humidity_bcd_q:8'h0;
reg [7:0] volume_bcd_rom[0:255];reg [7:0] volume_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",volume_bcd_rom);
always @(posedge clk)if(frame_start)volume_bcd_q<=volume_bcd_rom[volume];
assign volume_bcd=decimal_valid?volume_bcd_q:8'h0;
reg [7:0] pb_bcd_rom[0:255];reg [7:0] pb_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",pb_bcd_rom);
always @(posedge clk)if(frame_start)pb_bcd_q<=pb_bcd_rom[picture_brightness];
assign pb_bcd=decimal_valid?pb_bcd_q:8'h55;
reg [7:0] ct_bcd_rom[0:255];reg [7:0] ct_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",ct_bcd_rom);
always @(posedge clk)if(frame_start)ct_bcd_q<=ct_bcd_rom[contrast];
assign ct_bcd=decimal_valid?ct_bcd_q:8'h28;
reg [7:0] st_bcd_rom[0:255];reg [7:0] st_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",st_bcd_rom);
always @(posedge clk)if(frame_start)st_bcd_q<=st_bcd_rom[saturation];
assign st_bcd=decimal_valid?st_bcd_q:8'h28;
reg [7:0] screen_bcd_rom[0:255];reg [7:0] screen_bcd_q;
initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/decimal_pair.hex",screen_bcd_rom);
always @(posedge clk)if(frame_start)screen_bcd_q<=screen_bcd_rom[screen_brightness];
assign screen_bcd=decimal_valid?screen_bcd_q:8'h0;
 // 12 visible temporal peak bars; no FFT, multiplier or additional block RAM.
 reg [4:0] bars[0:11];reg [4:0] capture_peak;reg [6:0] sample_count;
 reg [3:0] capture_slot;reg [11:0] fresh;integer bi;
 wire [15:0] magnitude=pcm_sample[15]?(~pcm_sample+16'd1):pcm_sample;
 wire [4:0] amplitude=|magnitude[15:14]?5'd31:magnitude[13:9];
 always @(posedge clk or negedge rst_n) begin
 if(!rst_n)begin capture_peak<=0;sample_count<=0;capture_slot<=0;fresh<=0;for(bi=0;bi<12;bi=bi+1)bars[bi]<=0;end
 else begin
 if(frame_start)begin fresh<=0;for(bi=0;bi<12;bi=bi+1)if(!fresh[bi] && bars[bi]!=0)bars[bi]<=bars[bi]-1'b1;end
 if(pcm_valid)begin
 if(sample_count==95)begin
 bars[capture_slot]<=amplitude>capture_peak?amplitude:capture_peak;
 fresh[capture_slot]<=1;capture_slot<=(capture_slot == 4'd11) ? 4'd0 : capture_slot+1'b1;capture_peak<=0;sample_count<=0;
 end else begin sample_count<=sample_count+1'b1;if(amplitude>capture_peak)capture_peak<=amplitude;end
 end end end
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin pb<=255;ct<=128;st<=128;screen<=100;selection<=0;end
 else if(frame_start)begin pb<=picture_brightness;ct<=contrast;st<=saturation;screen<=screen_brightness;
 selection<=parameter_selection;end end
 reg [2:0] caption_index;reg [11:0] scroll;
 reg [9:0] caption_base;reg [7:0] caption_length;
 always @* begin caption_base=0;caption_length=0;case(caption_index)
 3'd0:begin caption_base=10'd0;caption_length=8'd61;end
3'd1:begin caption_base=10'd61;caption_length=8'd56;end
3'd2:begin caption_base=10'd117;caption_length=8'd53;end
3'd3:begin caption_base=10'd170;caption_length=8'd52;end
3'd4:begin caption_base=10'd222;caption_length=8'd51;end
3'd5:begin caption_base=10'd273;caption_length=8'd36;end
3'd6:begin caption_base=10'd309;caption_length=8'd36;end
 default:begin end endcase end
 wire [12:0] end_scroll=13'd832+({5'd0,caption_length}<<4);
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin period_q<=0;env<=0;sens<=0;connected<=0;auto_q<=0;vol<=0;caption_index<=7;scroll<=0;end
 else begin
 if(frame_start)begin period_q<=carousel_period_gray;env<=environment;sens<=sensor;connected<=online;auto_q<=auto_play;vol<=volume;
 if({1'b0,scroll}>=end_scroll)scroll<=0;else scroll<=scroll+1'b1;end
 if(image_index!=caption_index)begin caption_index<=image_index;scroll<=0;end
 end end
 wire [55:0] t=env[79:24];wire [23:0] w=env[23:0];
 reg [2:0] weather;
 always @* begin
 if(!env[82] || !env[80])weather=7;
 else case(w[15:8])
 8'h00:weather=0;8'h01,8'h02:weather=1;8'h03:weather=2;8'h45,8'h48:weather=3;
 8'h71,8'h73,8'h75,8'h77,8'h85,8'h86:weather=5;8'h95,8'h96,8'h99:weather=6;
 default:weather=4;endcase end

 reg [8:0] text_rom[0:1023];reg [3:0] icon_rom[0:8191];
 initial begin
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/layout_text.hex",text_rom);
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/layout_icons.hex",icon_rom);end
 reg [9:0] char_addr;reg [8:0] direct_char;reg direct,text_here,icon_here;
 reg big_here;reg [4:0] big_index,big_x,big_y;
 reg large_here;reg [4:0] lx,ly;
 reg [3:0] gx,gy;reg [23:0] bg,fg;reg [4:0] ix,iy;
 reg [4:0] n;reg [3:0] digit;reg [7:0] value;
 wire [12:0] caption_pos={1'b0,sx}+{1'b0,scroll};
 always @* begin
 large_here=0;lx=0;ly=0;big_here=0;big_index=0;big_x=0;big_y=0;char_addr=0;direct_char=0;direct=0;text_here=0;icon_here=0;gx=0;gy=0;ix=0;iy=0;n=0;digit=0;value=0;
 bg=24'h101e2a;fg=24'he4edf5;
 if(sx>=16 && sx<656 && sy>=64 && sy<544)bg=rgb_in;
 if(sy<64)bg=sx<224?24'hffffff:24'h203c55;
 // Warm brass branding, teal accents and three distinct information cards.

 if(sx>=672 && sy>=64 && sy<544)bg=24'h152b39;
 if(sx>=680 && sx<792 && sy>=76 && sy<160)bg=24'h303b44;
 if(sx>=680 && sx<792 && sy>=168 && sy<252)bg=24'h193e46;
 if(sx>=680 && sx<792 && sy>=260 && sy<416)bg=24'h24354b;
 if(sx>=680 && sx<683 && sy>=84 && sy<152)bg=24'hdeb879;
 if(sx>=680 && sx<683 && sy>=176 && sy<244)bg=24'h66d4c0;
 if(sx>=680 && sx<683 && sy>=268 && sy<408)bg=24'h9caceb;
 if(sy>=544)bg=caption_index==4?24'h7f2632:caption_index==6?24'h17646c:24'h142b42;
 if(sy==62 || sy==63 || sy==544 || sy==545)bg=24'hdeb879;


 // Native 14px antialiased header, 8px numeric / 16px text pitch.
 if(sx>=256 && sx<336 && sy>=8 && sy<24)begin
 large_here=1;text_here=1;direct=1;lx=(sx-256)%8;ly=sy-8;n=(sx-256)/8;
 case(n)0:digit=t[55:52];1:digit=t[51:48];2:digit=t[47:44];3:digit=t[43:40];5:digit=t[39:36];6:digit=t[35:32];8:digit=t[31:28];9:digit=t[27:24];default:digit=0;endcase
 direct_char=env[83]?9'd1+digit:9'd12;if(n==4||n==7)direct_char=12;end
 if(sx>=268 && sx<332 && sy>=36 && sy<52)begin
 large_here=1;text_here=1;direct=1;lx=(sx-268)%8;ly=sy-36;n=(sx-268)/8;
 case(n)0:digit=t[23:20];1:digit=t[19:16];3:digit=t[15:12];4:digit=t[11:8];6:digit=t[7:4];7:digit=t[3:0];default:digit=0;endcase
 direct_char=env[83]?9'd1+digit:9'd12;if(n==2||n==5)direct_char=11;end
 if(!env[83])begin if(sx>=392 && sx<440 && sy>=36 && sy<52)begin large_here=1;text_here=1;char_addr=10'd392+(sx-392)/16;lx=(sx-392)%16;ly=sy-36;end
end else if(!env[81])begin if(sx>=392 && sx<440 && sy>=36 && sy<52)begin large_here=1;text_here=1;char_addr=10'd395+(sx-392)/16;lx=(sx-392)%16;ly=sy-36;end
end
 if(sx>=512 && sx<544 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd381+(sx-512)/16;lx=(sx-512)%16;ly=sy-8;end

 case(weather)
0:begin if(sx>=584 && sx<600 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd383+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
1:begin if(sx>=584 && sx<616 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd384+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
2:begin if(sx>=584 && sx<600 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd386+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
3:begin if(sx>=584 && sx<600 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd387+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
4:begin if(sx>=584 && sx<600 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd388+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
5:begin if(sx>=584 && sx<600 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd389+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
6:begin if(sx>=584 && sx<616 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd390+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
7:begin if(sx>=584 && sx<632 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd392+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
endcase
 if(env[82]&&!env[80])begin if(sx>=584 && sx<632 && sy>=8 && sy<24)begin large_here=1;text_here=1;char_addr=10'd395+(sx-584)/16;lx=(sx-584)%16;ly=sy-8;end
end
 if(sx>=512 && sx<536 && sy>=36 && sy<52)begin
 large_here=1;text_here=1;direct=1;lx=(sx-512)%8;ly=sy-36;n=(sx-512)/8;
 case(n)0:direct_char=w[23:16]==45?12:0;1:direct_char=env[82]?1+w[7:4]:12;default:direct_char=env[82]?1+w[3:0]:12;endcase end
 if(sx>=552 && sx<568 && sy>=36 && sy<52)begin large_here=1;text_here=1;char_addr=10'd418+(sx-552)/16;lx=(sx-552)%16;ly=sy-36;end

 if(sx>=704 && sx<768 && sy<64)begin icon_here=1;ix=(sx-704)>>1;iy=sy>>1;end
if(sx>=696 && sx<760 && sy>=84 && sy<100)begin text_here=1;char_addr=10'd351+((sx-696)>>4);gx=sx-696;gy=sy-84;fg=24'hdeb879;end
if(sx>=696 && sx<760 && sy>=176 && sy<192)begin text_here=1;char_addr=10'd355+((sx-696)>>4);gx=sx-696;gy=sy-176;fg=24'h66d4c0;end
if(sx>=696 && sx<728 && ((sy>=112 && sy<140)||(sy>=204 && sy<232)))begin
 big_here=1;big_x=(sx-696)&15;big_y=sy-(sy<160?112:204);value=sy<160?temperature_bcd:humidity_bcd;
 digit=sx<712?value[7:4]:value[3:0];big_index=sens[16]?(5'd6+{1'b0,digit}):5'd16;
 fg=sy<160?24'hffe0a3:24'h88e5d2;end
if(sx>=736 && sx<752 && sy>=124 && sy<140)begin text_here=1;char_addr=10'd418+((sx-736)>>4);gx=sx-736;gy=sy-124;fg=24'hffe0a3;end
if(sx>=736 && sx<752 && sy>=216 && sy<232)begin text_here=1;char_addr=10'd419+((sx-736)>>4);gx=sx-736;gy=sy-216;fg=24'h88e5d2;end
if(sx>=688 && sx<720 && sy>=272 && sy<288)begin text_here=1;char_addr=10'd420+((sx-688)>>4);gx=sx-688;gy=sy-272;fg=24'he4edf5;end
if(sx>=680 && sx<683 && sy>=272 && sy<288 && selection==0)bg=24'hffe0a3;
if(sx>=744 && sx<768 && sy>=272 && sy<288)begin
 text_here=1;direct=1;gx=((sx-744)&7)+1;gy=sy-272;n=(sx-744)>>3;
 case(n)0:direct_char=pb>=200?9'd3:pb>=100?9'd2:9'd0;1:direct_char=9'd1+pb_bcd[7:4];default:direct_char=9'd1+pb_bcd[3:0];endcase end
if(sx>=688 && sx<736 && sy>=300 && sy<316)begin text_here=1;char_addr=10'd422+((sx-688)>>4);gx=sx-688;gy=sy-300;fg=24'he4edf5;end
if(sx>=680 && sx<683 && sy>=300 && sy<316 && selection==1)bg=24'hffe0a3;
if(sx>=744 && sx<768 && sy>=300 && sy<316)begin
 text_here=1;direct=1;gx=((sx-744)&7)+1;gy=sy-300;n=(sx-744)>>3;
 case(n)0:direct_char=ct>=200?9'd3:ct>=100?9'd2:9'd0;1:direct_char=9'd1+ct_bcd[7:4];default:direct_char=9'd1+ct_bcd[3:0];endcase end
if(sx>=688 && sx<736 && sy>=328 && sy<344)begin text_here=1;char_addr=10'd425+((sx-688)>>4);gx=sx-688;gy=sy-328;fg=24'he4edf5;end
if(sx>=680 && sx<683 && sy>=328 && sy<344 && selection==2)bg=24'hffe0a3;
if(sx>=744 && sx<768 && sy>=328 && sy<344)begin
 text_here=1;direct=1;gx=((sx-744)&7)+1;gy=sy-328;n=(sx-744)>>3;
 case(n)0:direct_char=st>=200?9'd3:st>=100?9'd2:9'd0;1:direct_char=9'd1+st_bcd[7:4];default:direct_char=9'd1+st_bcd[3:0];endcase end
if(sx>=684 && sx<748 && sy>=356 && sy<372)begin text_here=1;char_addr=10'd432+((sx-684)>>4);gx=sx-684;gy=sy-356;fg=24'he4edf5;end
if(sx>=680 && sx<683 && sy>=356 && sy<372 && selection==7)bg=24'hffe0a3;
if(sx>=752 && sx<776 && sy>=356 && sy<372)begin
 text_here=1;direct=1;gx=((sx-744)&7)+1;gy=sy-356;n=(sx-752)>>3;
 case(n)0:direct_char=screen>=200?9'd3:screen>=100?9'd2:9'd0;1:direct_char=9'd1+screen_bcd[7:4];default:direct_char=9'd1+screen_bcd[3:0];endcase end
if(sx>=776 && sx<792 && sy>=356 && sy<372)begin text_here=1;char_addr=10'd419+((sx-776)>>4);gx=sx-776;gy=sy-356;fg=24'he4edf5;end
if(sx>=688 && sx<720 && sy>=384 && sy<400)begin text_here=1;char_addr=10'd379+((sx-688)>>4);gx=sx-688;gy=sy-384;fg=24'he4edf5;end
if(sx>=680 && sx<683 && sy>=384 && sy<400 && selection==7)bg=24'hffe0a3;
if(sx>=744 && sx<768 && sy>=384 && sy<400)begin
 text_here=1;direct=1;gx=((sx-744)&7)+1;gy=sy-384;n=(sx-744)>>3;
 case(n)0:direct_char=vol>=200?9'd3:vol>=100?9'd2:9'd0;1:direct_char=9'd1+volume_bcd[7:4];default:direct_char=9'd1+volume_bcd[3:0];endcase end
if(sx>=768 && sx<784 && sy>=384 && sy<400)begin text_here=1;char_addr=10'd419+((sx-768)>>4);gx=sx-768;gy=sy-384;fg=24'he4edf5;end
if(connected)begin if(sx>=688 && sx<752 && sy>=424 && sy<440)begin text_here=1;char_addr=10'd363+((sx-688)>>4);gx=sx-688;gy=sy-424;fg=24'h74dcc3;end
end else begin if(sx>=688 && sx<752 && sy>=424 && sy<440)begin text_here=1;char_addr=10'd367+((sx-688)>>4);gx=sx-688;gy=sy-424;fg=24'hffd77d;end
end
if(auto_q)begin if(sx>=688 && sx<752 && sy>=448 && sy<464)begin text_here=1;char_addr=10'd371+((sx-688)>>4);gx=sx-688;gy=sy-448;fg=24'habbde1;end
end else begin if(sx>=688 && sx<752 && sy>=448 && sy<464)begin text_here=1;char_addr=10'd375+((sx-688)>>4);gx=sx-688;gy=sy-448;fg=24'habbde1;end
end
// Current carousel period in seconds; blank tens for the five-second setting.
if(auto_q && sx>=760 && sx<776 && sy>=448 && sy<464)begin
 text_here=1;direct=1;gx=((sx-760)&7)+1;gy=sy-448;fg=24'hdeb879;
 if(sx<768)begin
 case(period_q)2'b01:direct_char=9'd2;2'b11:direct_char=9'd3;2'b10:direct_char=9'd4;default:direct_char=9'd0;endcase
 end else direct_char=period_q==0?9'd6:9'd1;
end
// Bar cell pitch is eight pixels; 12 bars occupy the right-hand card.
 if(sx>=688 && sx<784 && sy>=504 && sy<536)begin
 bg=24'h1d3440;
 if(sx[2:0]>=1 && sx[2:0]<=5 && sy>=536-{5'd0,bars[(sx-688)>>3]})
 bg=sy<512?24'hf3c775:sy<524?24'h70d8bd:24'h42aaac;
 end
case(caption_index)
4:begin if(sx>=688 && sx<752 && sy>=476 && sy<492)begin text_here=1;char_addr=10'd402+((sx-688)>>4);gx=sx-688;gy=sy-476;fg=24'hffb3a9;end
end
5:begin if(sx>=688 && sx<752 && sy>=476 && sy<492)begin text_here=1;char_addr=10'd410+((sx-688)>>4);gx=sx-688;gy=sy-476;fg=24'hffd77d;end
end
6:begin if(sx>=688 && sx<752 && sy>=476 && sy<492)begin text_here=1;char_addr=10'd406+((sx-688)>>4);gx=sx-688;gy=sy-476;fg=24'h74dcc3;end
end
default:begin if(sx>=688 && sx<752 && sy>=476 && sy<492)begin text_here=1;char_addr=10'd398+((sx-688)>>4);gx=sx-688;gy=sy-476;fg=24'habbde1;end
end endcase
 if(sx>=16 && sx<784 && sy>=564 && sy<580 && caption_pos>=800 && caption_pos<800+({5'd0,caption_length}<<4))begin
 large_here=1;text_here=1;direct=0;char_addr=caption_base+(caption_pos-800)/16;lx=(caption_pos-800)%16;ly=sy-564;fg=24'hffffff;end
 if(large_here)begin gx=lx+1'b1;gy=ly+1'b1;large_here=0;end

 end
 reg big_q,big_qq;reg [4:0] big_col_q,big_col_qq;reg [8:0] big_addr_q;reg [47:0] big_glyph_q;
 wire [9:0] big_address={big_index,5'b0}-{big_index,2'b0}+{5'd0,big_y};
 
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin big_q<=0;big_qq<=0;big_col_q<=0;big_col_qq<=0;big_addr_q<=0;end
 else begin big_q<=big_here;big_qq<=big_q;big_col_q<=big_x;big_col_qq<=big_col_q;big_addr_q<=big_address[8:0];end end
 reg [8:0] char_q,direct_q;reg use_direct_q,text_q,text_qq,icon_q,icon_qq;
 reg [3:0] row_q,row_qq,col_q,col_qq,icon_pixel,icon_pixel_q;
 reg [27:0] glyph_q;reg [23:0] bg_q,bg_qq,fg_q,fg_qq;
 reg [1:0] hs_q,vs_q,de_q;
 wire [8:0] font_char=use_direct_q?direct_q:char_q;
 wire [12:0] font_row_addr={font_char,4'b0}-{font_char,1'b0}+{9'd0,row_q}-13'd1;
 wire [11:0] font_addr=font_row_addr[11:0];
 always @(posedge clk)begin
 char_q<=text_rom[char_addr];
 icon_pixel<=icon_rom[{weather,iy,ix}];icon_pixel_q<=icon_pixel;end
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin direct_q<=0;use_direct_q<=0;text_q<=0;text_qq<=0;icon_q<=0;icon_qq<=0;row_q<=0;row_qq<=0;col_q<=0;col_qq<=0;bg_q<=0;bg_qq<=0;fg_q<=0;fg_qq<=0;hs_q<=0;vs_q<=0;de_q<=0;end
 else begin direct_q<=direct_char;use_direct_q<=direct;text_q<=text_here;text_qq<=text_q;icon_q<=icon_here;icon_qq<=icon_q;
 row_q<=gy;row_qq<=row_q;col_q<=gx;col_qq<=col_q;bg_q<=bg;bg_qq<=bg_q;fg_q<=fg;fg_qq<=fg_q;
 hs_q<={hs_q[0],hs_in};vs_q<={vs_q[0],vs_in};de_q<={de_q[0],de_in};end end
 reg [23:0] icon_rgb;always @* begin case(icon_pixel_q)
 4'd0:icon_rgb=24'h203C55;
4'd1:icon_rgb=24'h203D56;
4'd2:icon_rgb=24'h355671;
4'd3:icon_rgb=24'h59758D;
4'd4:icon_rgb=24'h8AA1B4;
4'd5:icon_rgb=24'hB8CAD8;
4'd6:icon_rgb=24'hE3EDF4;
4'd7:icon_rgb=24'hFFFFFF;
4'd8:icon_rgb=24'hFFC34D;
4'd9:icon_rgb=24'hFFD77D;
4'd10:icon_rgb=24'hA47C35;
4'd11:icon_rgb=24'h78B8E8;
4'd12:icon_rgb=24'h4099DC;
4'd13:icon_rgb=24'hC3E7FF;
4'd14:icon_rgb=24'hECF7FF;
4'd15:icon_rgb=24'hEBAE40;
 default:icon_rgb=24'h142b42;endcase end
 assign hs_out=hs_q[1];assign vs_out=vs_q[1];assign de_out=de_q[1];
 wire [4:0] coverage_shift=(5'd14-{1'b0,col_qq})<<1;
 wire [27:0] coverage_word=glyph_q>>coverage_shift;
 wire [1:0] small_coverage=(text_qq && col_qq>=1 && col_qq<=14 && row_qq>=1 && row_qq<=14)?coverage_word[1:0]:2'd0;
 wire [5:0] big_shift=(6'd23-{1'b0,big_col_qq})<<1;
 wire [47:0] big_word=big_glyph_q>>big_shift;

 reg large_q,large_qq;reg [4:0] lx_q,lx_qq,ly_q,ly_qq;reg [39:0] large_glyph;
 wire [13:0] large_addr=({5'd0,font_char}<<4)+({5'd0,font_char}<<2)+ly_q;

 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin large_q<=0;large_qq<=0;lx_q<=0;lx_qq<=0;ly_q<=0;ly_qq<=0;end
 else begin large_q<=large_here;large_qq<=large_q;lx_q<=lx;lx_qq<=lx_q;ly_q<=ly;ly_qq<=ly_q;end end
 wire [39:0] large_word=large_glyph>>((19-lx_qq)*2);
 wire [1:0] large_coverage=(lx_qq<20 && ly_qq<20)?large_word[1:0]:2'd0;

 wire logo_here=sx<192 && sy>=8 && sy<56;
 wire [7:0] logo_x=sx;wire [5:0] logo_y=sy-8;
 wire [11:0] logo_addr=({6'd0,logo_y}<<5)+({6'd0,logo_y}<<4)+{6'd0,logo_x[7:2]};
 reg [7:0] logo_byte,logo_byte_q;reg [1:0] logo_col,logo_col_q;reg logo_q,logo_qq;

 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin logo_q<=0;logo_qq<=0;logo_col<=0;logo_col_q<=0;end
 else begin logo_q<=logo_here;logo_qq<=logo_q;logo_col<=logo_x[1:0];logo_col_q<=logo_col;end end
 // Lossless shared coverage store: same 2-bit pixels, only used glyphs.
 function [16:0] small_base;input [8:0] id;begin small_base={id,8'b0};end endfunction
 
 function [16:0] big_base;input [8:0] id;begin case(id)
9'd6:big_base=17'd73472;
9'd7:big_base=17'd74144;
9'd8:big_base=17'd74816;
9'd9:big_base=17'd75488;
9'd10:big_base=17'd76160;
9'd11:big_base=17'd76832;
9'd12:big_base=17'd77504;
9'd13:big_base=17'd78176;
9'd14:big_base=17'd78848;
9'd15:big_base=17'd79520;
9'd16:big_base=17'd80192;
default:big_base=0;endcase end endfunction
 reg [16:0] coverage_pixel_address;reg coverage_valid;
 reg [4:0] big_y_q;reg [4:0] big_id_q;reg [7:0] logo_x_q;reg [5:0] logo_y_q;
 always @(posedge clk)begin big_y_q<=big_y;big_id_q<=big_index;logo_x_q<=logo_x;logo_y_q<=logo_y;end
 always @* begin
 coverage_pixel_address=0;coverage_valid=0;
 if(logo_q)begin coverage_pixel_address=17'd80864+({11'd0,logo_y_q}<<7)+({11'd0,logo_y_q}<<6)+logo_x_q;coverage_valid=1;end
 else if(big_q)begin coverage_pixel_address=big_base({4'd0,big_id_q})+({12'd0,big_y_q}<<4)+({12'd0,big_y_q}<<3)+big_col_q;coverage_valid=big_col_q<24 && big_y_q<28;end
 else if(text_q)begin coverage_pixel_address=small_base(font_char)+(({13'd0,row_q}-1)<<4)+col_q-1;coverage_valid=col_q>=1 && col_q<=14 && row_q>=1 && row_q<=14;end
 end
  // Eight 2-bit pixels per word: exact bit slicing, no divide/modulo circuit.
 wire [13:0] packed_address=coverage_pixel_address[16:3];
 reg [2:0] packed_col_q;reg valid_coverage_q;
 reg [15:0] coverage0[0:8191],coverage1[0:4095];reg [15:0] packed0,packed1;reg bank_q;
 initial begin
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/ui_coverage14_0.hex",coverage0);
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/ui_coverage14_1.hex",coverage1);
 end
 always @(posedge clk)begin
 packed_col_q<=coverage_pixel_address[2:0];valid_coverage_q<=coverage_valid;
 bank_q<=packed_address[13];packed0<=coverage0[packed_address[12:0]];packed1<=coverage1[packed_address[11:0]];
 end
 wire [15:0] packed_pixels=bank_q?packed1:packed0;
 wire [15:0] packed_shift=packed_pixels>>{packed_col_q,1'b0};
wire [1:0] shared_coverage=valid_coverage_q?packed_shift[1:0]:2'd0;
 wire [1:0] coverage=shared_coverage;
 wire [23:0] half_rgb={1'b0,fg_qq[23:17],1'b0,fg_qq[15:9],1'b0,fg_qq[7:1]}+{1'b0,bg_qq[23:17],1'b0,bg_qq[15:9],1'b0,bg_qq[7:1]};
 wire [23:0] light_rgb={1'b0,fg_qq[23:17],1'b0,fg_qq[15:9],1'b0,fg_qq[7:1]}+{1'b0,half_rgb[23:17],1'b0,half_rgb[15:9],1'b0,half_rgb[7:1]};
 wire [23:0] faint_rgb={1'b0,bg_qq[23:17],1'b0,bg_qq[15:9],1'b0,bg_qq[7:1]}+{1'b0,half_rgb[23:17],1'b0,half_rgb[15:9],1'b0,half_rgb[7:1]};
 // 192x48 source-derived logo, 2-bit antialias coverage, packed byte ROM.

 wire [7:0] logo_shifted=logo_byte_q>>((3-logo_col_q)*2);
 reg [23:0] logo_rgb;
 always @* case(shared_coverage)
 0:logo_rgb=24'hffffff;1:logo_rgb=24'hf5b5b2;2:logo_rgb=24'hea6a65;3:logo_rgb=24'he02018;
 endcase
 assign rgb_out=!de_q[1]?24'd0:logo_qq?logo_rgb:(icon_qq && icon_pixel_q!=0)?icon_rgb:coverage==3?fg_qq:coverage==2?light_rgb:coverage==1?faint_rgb:bg_qq;
 endmodule
