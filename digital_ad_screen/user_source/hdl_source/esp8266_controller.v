module esp8266_controller #(
 parameter integer CLK_HZ=50000000, BAUD=115200,
 parameter integer BOOT_MS=10000, RETRY_MS=5000,
 parameter integer RESPONSE_MS=5000, TCP_MS=20000, PING_MS=60000, COMMAND_GAP_MS=100, UPLOAD_MS=10000
)(input wire clk,rst_n,uart_rx, input wire [7:0] temperature,humidity, input wire sensor_valid, input wire fire_active, input wire applied_notice,output wire requested_notice,input wire [7:0] applied_volume, output wire [7:0] requested_volume, output wire uart_tx,
 output wire [3:0] control_request,input wire [10:0] control_reply,
 output wire [7:0] requested_brightness,input wire [7:0] applied_brightness,
 output wire automatic_brightness,input wire light_sensor_ok,
 output wire time_set,weather_set,output wire [55:0] time_bcd,output wire [23:0] weather_bcd,
 output wire [7:0] reject_byte, output wire reject_valid,reject_start,reject_done, output wire [27:0] reject_length,
 output wire [2:0] feedback_status, output wire [15:0] feedback_code, output reg connected, output reg [3:0] stage, output reg [7:0] last_error);
 localparam BOOT=0,PREP=1,SEND=2,DRAIN=3,WAIT_REPLY=4,ONLINE=5,RETRY=6,GAP=7;
 reg [2:0] state;
 localparam UAW=(UPLOAD_MS<1)?1:$clog2(UPLOAD_MS+1), PAW=(PING_MS<1)?1:$clog2(PING_MS+1); reg [UAW-1:0] upload_age;reg [PAW-1:0] ping_age;
 reg [7:0] sample_temperature,sample_humidity,sample_volume;
 reg volume_only;
 reg sample_fire,fire_reported;
 wire reply_auto;wire reply_control,reply_brightness; wire [1:0] reply_env; wire reply_notice; wire command_pending; wire [287:0] command_id;
 wire command_done,failed;
 wire reply_done=state==WAIT_REPLY && stage==15 && command_done && !failed;
 wire reply_ready=command_pending && (reply_auto ? 1'b1 : reply_control ? control_reply[10]==control_request[3] : reply_brightness ? applied_brightness==requested_brightness : reply_env!=0 || (reply_notice ? applied_notice==requested_notice : applied_volume==requested_volume));
 wire [11:0] reply_volume;
 assign reply_volume=reply_auto ? {10'd0,light_sensor_ok,automatic_brightness} : reply_control ? {light_sensor_ok,automatic_brightness,control_reply[9:0]} : reply_brightness ? requested_brightness : reply_env!=0 ? {6'd0,reply_env} : reply_notice ? {7'd0,requested_notice} : requested_volume;
 reg [7:0] request_id;
 // JSON allows leading whitespace, but not leading zeroes.
 function [31:0] decimal4;
 input [11:0] value;
 reg [27:0] b;integer k;
 begin
 // Shift/add-3 conversion: no division or remainder hardware.
 b={16'd0,value};
 for(k=0;k<12;k=k+1)begin
 if(b[15:12]>=5)b[15:12]=b[15:12]+4'd3;
 if(b[19:16]>=5)b[19:16]=b[19:16]+4'd3;
 if(b[23:20]>=5)b[23:20]=b[23:20]+4'd3;
 if(b[27:24]>=5)b[27:24]=b[27:24]+4'd3;
 b=b<<1;
 end
 decimal4[31:24]=value>=1000?{4'h3,b[27:24]}:8'd32;
 decimal4[23:16]=value>=100?{4'h3,b[23:20]}:8'd32;
 decimal4[15:8]=value>=10?{4'h3,b[19:16]}:8'd32;
 decimal4[7:0]={4'h3,b[15:12]};
 end endfunction
 function [23:0] decimal3;
 input [7:0] value;
 reg [19:0] b;integer k;
 begin
 b={12'd0,value};
 for(k=0;k<8;k=k+1)begin
 if(b[11:8]>=5)b[11:8]=b[11:8]+4'd3;
 if(b[15:12]>=5)b[15:12]=b[15:12]+4'd3;
 if(b[19:16]>=5)b[19:16]=b[19:16]+4'd3;
 b=b<<1;end
 decimal3[23:16]=value>=100?{4'h3,b[19:16]}:8'd32;
 decimal3[15:8]=value>=10?{4'h3,b[15:12]}:8'd32;
 decimal3[7:0]={4'h3,b[11:8]};
 end endfunction
 wire [1175:0] publish_packet={
  8'h30,8'd144,8'd1,16'd38,"$sys/Q3FhlsOoK7/anlu_fpga/dp/post/json",
  "{\"id\":",decimal3(request_id),",\"dp\":{\"temperature\":[{\"v\":",decimal3(sample_temperature),
  "}],\"humidity\":[{\"v\":",decimal3(sample_humidity),"}],\"volume\":[{\"v\":",decimal3(sample_volume),"}],\"fire\":[{\"v\":",(sample_fire ? 8'h31 : 8'h30),"}]}}"};
 wire [775:0] volume_packet={8'h30,8'd95,16'd38,"$sys/Q3FhlsOoK7/anlu_fpga/dp/post/json",
 "{\"id\":",decimal3(request_id),",\"dp\":{\"volume\":[{\"v\":",decimal3(sample_volume),"}],\"fire\":[{\"v\":",(sample_fire ? 8'h31 : 8'h30),"}]}}"};
 wire [831:0] reply_packet={8'h30,8'd102,16'd75,"$sys/Q3FhlsOoK7/anlu_fpga/cmd/response/",command_id,
 "{\"ok\":true,\"",(reply_auto ? "autobr" : reply_control ? "ctrlv2" : reply_brightness ? "bright" : reply_env!=0 ? "synced" : reply_notice ? "notice" : "volume"),"\":",decimal4(reply_volume),"}"};
 localparam [1175:0] SUBSCRIBE_PACKET={8'h82,8'd144,8'd1,16'd1,
 16'd47,"$sys/Q3FhlsOoK7/anlu_fpga/dp/post/json/accepted",8'd0,
 16'd47,"$sys/Q3FhlsOoK7/anlu_fpga/dp/post/json/rejected",8'd0,
 16'd39,"$sys/Q3FhlsOoK7/anlu_fpga/cmd/request/+",8'd0};
 reg [7:0] byte_index;
 reg [31:0] elapsed;localparam MDW=(CLK_HZ/1000<2)?1:$clog2(CLK_HZ/1000);reg [MDW-1:0] ms_div;
 wire ms_tick=ms_div==CLK_HZ/1000-1;
 wire [7:0] rx_data,tx_data;
 wire rx_valid,frame_error,tx_ready;
 reg [511:0] command;
 reg [7:0] command_length;
 // Public source: configure a private MQTT CONNECT packet before device deployment.
localparam [1319:0] CONNECT_PACKET = 1320'h0; // Authentication removed from public repository
 always @* begin
  command=0; command_length=0;
  case(stage)
   0: begin command="AT\015\012"; command_length=4; end
   1: begin command="ATE0\015\012"; command_length=6; end
   2: begin command="AT+CIPMODE=0\015\012"; command_length=14; end
   3: begin command="AT+CIPMUX=0\015\012"; command_length=13; end
   4: begin command="AT+CIPCLOSE\015\012"; command_length=13; end
   5: begin command="AT+CIPSTART=\"TCP\",\"mqtts.heclouds.com\",1883\015\012"; command_length=45; end
   6: begin command="AT+CIPSEND=165\015\012"; command_length=16; end
   7: command_length=165;
   8: begin command="AT+CIPSEND=2\015\012"; command_length=14; end
   9: command_length=2;
   10: begin command=volume_only ? "AT+CIPSEND=97\015\012" : "AT+CIPSEND=147\015\012"; command_length=volume_only ? 15 : 16; end
   11: command_length=volume_only ? 97 : 147;
   12: begin command="AT+CIPSEND=147\015\012"; command_length=16; end
   13: command_length=147;
   14: begin command="AT+CIPSEND=104\015\012"; command_length=16; end
   15: command_length=104;
   default: begin command=0; command_length=0; end
  endcase
 end
 function [7:0] at_byte;input [3:0] st;input [7:0] idx;input vol_only;begin
 if(st==10 && vol_only)begin case(idx)
8'd0:at_byte=8'd65;
8'd1:at_byte=8'd84;
8'd2:at_byte=8'd43;
8'd3:at_byte=8'd67;
8'd4:at_byte=8'd73;
8'd5:at_byte=8'd80;
8'd6:at_byte=8'd83;
8'd7:at_byte=8'd69;
8'd8:at_byte=8'd78;
8'd9:at_byte=8'd68;
8'd10:at_byte=8'd61;
8'd11:at_byte=8'd57;
8'd12:at_byte=8'd55;
8'd13:at_byte=8'd13;
8'd14:at_byte=8'd10;
default:at_byte=0;endcase end else begin case({st,idx})
12'd0:at_byte=8'd65;
12'd1:at_byte=8'd84;
12'd2:at_byte=8'd13;
12'd3:at_byte=8'd10;
12'd256:at_byte=8'd65;
12'd257:at_byte=8'd84;
12'd258:at_byte=8'd69;
12'd259:at_byte=8'd48;
12'd260:at_byte=8'd13;
12'd261:at_byte=8'd10;
12'd512:at_byte=8'd65;
12'd513:at_byte=8'd84;
12'd514:at_byte=8'd43;
12'd515:at_byte=8'd67;
12'd516:at_byte=8'd73;
12'd517:at_byte=8'd80;
12'd518:at_byte=8'd77;
12'd519:at_byte=8'd79;
12'd520:at_byte=8'd68;
12'd521:at_byte=8'd69;
12'd522:at_byte=8'd61;
12'd523:at_byte=8'd48;
12'd524:at_byte=8'd13;
12'd525:at_byte=8'd10;
12'd768:at_byte=8'd65;
12'd769:at_byte=8'd84;
12'd770:at_byte=8'd43;
12'd771:at_byte=8'd67;
12'd772:at_byte=8'd73;
12'd773:at_byte=8'd80;
12'd774:at_byte=8'd77;
12'd775:at_byte=8'd85;
12'd776:at_byte=8'd88;
12'd777:at_byte=8'd61;
12'd778:at_byte=8'd48;
12'd779:at_byte=8'd13;
12'd780:at_byte=8'd10;
12'd1024:at_byte=8'd65;
12'd1025:at_byte=8'd84;
12'd1026:at_byte=8'd43;
12'd1027:at_byte=8'd67;
12'd1028:at_byte=8'd73;
12'd1029:at_byte=8'd80;
12'd1030:at_byte=8'd67;
12'd1031:at_byte=8'd76;
12'd1032:at_byte=8'd79;
12'd1033:at_byte=8'd83;
12'd1034:at_byte=8'd69;
12'd1035:at_byte=8'd13;
12'd1036:at_byte=8'd10;
12'd1280:at_byte=8'd65;
12'd1281:at_byte=8'd84;
12'd1282:at_byte=8'd43;
12'd1283:at_byte=8'd67;
12'd1284:at_byte=8'd73;
12'd1285:at_byte=8'd80;
12'd1286:at_byte=8'd83;
12'd1287:at_byte=8'd84;
12'd1288:at_byte=8'd65;
12'd1289:at_byte=8'd82;
12'd1290:at_byte=8'd84;
12'd1291:at_byte=8'd61;
12'd1292:at_byte=8'd34;
12'd1293:at_byte=8'd84;
12'd1294:at_byte=8'd67;
12'd1295:at_byte=8'd80;
12'd1296:at_byte=8'd34;
12'd1297:at_byte=8'd44;
12'd1298:at_byte=8'd34;
12'd1299:at_byte=8'd109;
12'd1300:at_byte=8'd113;
12'd1301:at_byte=8'd116;
12'd1302:at_byte=8'd116;
12'd1303:at_byte=8'd115;
12'd1304:at_byte=8'd46;
12'd1305:at_byte=8'd104;
12'd1306:at_byte=8'd101;
12'd1307:at_byte=8'd99;
12'd1308:at_byte=8'd108;
12'd1309:at_byte=8'd111;
12'd1310:at_byte=8'd117;
12'd1311:at_byte=8'd100;
12'd1312:at_byte=8'd115;
12'd1313:at_byte=8'd46;
12'd1314:at_byte=8'd99;
12'd1315:at_byte=8'd111;
12'd1316:at_byte=8'd109;
12'd1317:at_byte=8'd34;
12'd1318:at_byte=8'd44;
12'd1319:at_byte=8'd49;
12'd1320:at_byte=8'd56;
12'd1321:at_byte=8'd56;
12'd1322:at_byte=8'd51;
12'd1323:at_byte=8'd13;
12'd1324:at_byte=8'd10;
12'd1536:at_byte=8'd65;
12'd1537:at_byte=8'd84;
12'd1538:at_byte=8'd43;
12'd1539:at_byte=8'd67;
12'd1540:at_byte=8'd73;
12'd1541:at_byte=8'd80;
12'd1542:at_byte=8'd83;
12'd1543:at_byte=8'd69;
12'd1544:at_byte=8'd78;
12'd1545:at_byte=8'd68;
12'd1546:at_byte=8'd61;
12'd1547:at_byte=8'd49;
12'd1548:at_byte=8'd54;
12'd1549:at_byte=8'd53;
12'd1550:at_byte=8'd13;
12'd1551:at_byte=8'd10;
12'd2048:at_byte=8'd65;
12'd2049:at_byte=8'd84;
12'd2050:at_byte=8'd43;
12'd2051:at_byte=8'd67;
12'd2052:at_byte=8'd73;
12'd2053:at_byte=8'd80;
12'd2054:at_byte=8'd83;
12'd2055:at_byte=8'd69;
12'd2056:at_byte=8'd78;
12'd2057:at_byte=8'd68;
12'd2058:at_byte=8'd61;
12'd2059:at_byte=8'd50;
12'd2060:at_byte=8'd13;
12'd2061:at_byte=8'd10;
12'd2560:at_byte=8'd65;
12'd2561:at_byte=8'd84;
12'd2562:at_byte=8'd43;
12'd2563:at_byte=8'd67;
12'd2564:at_byte=8'd73;
12'd2565:at_byte=8'd80;
12'd2566:at_byte=8'd83;
12'd2567:at_byte=8'd69;
12'd2568:at_byte=8'd78;
12'd2569:at_byte=8'd68;
12'd2570:at_byte=8'd61;
12'd2571:at_byte=8'd49;
12'd2572:at_byte=8'd52;
12'd2573:at_byte=8'd55;
12'd2574:at_byte=8'd13;
12'd2575:at_byte=8'd10;
12'd3072:at_byte=8'd65;
12'd3073:at_byte=8'd84;
12'd3074:at_byte=8'd43;
12'd3075:at_byte=8'd67;
12'd3076:at_byte=8'd73;
12'd3077:at_byte=8'd80;
12'd3078:at_byte=8'd83;
12'd3079:at_byte=8'd69;
12'd3080:at_byte=8'd78;
12'd3081:at_byte=8'd68;
12'd3082:at_byte=8'd61;
12'd3083:at_byte=8'd49;
12'd3084:at_byte=8'd52;
12'd3085:at_byte=8'd55;
12'd3086:at_byte=8'd13;
12'd3087:at_byte=8'd10;
12'd3584:at_byte=8'd65;
12'd3585:at_byte=8'd84;
12'd3586:at_byte=8'd43;
12'd3587:at_byte=8'd67;
12'd3588:at_byte=8'd73;
12'd3589:at_byte=8'd80;
12'd3590:at_byte=8'd83;
12'd3591:at_byte=8'd69;
12'd3592:at_byte=8'd78;
12'd3593:at_byte=8'd68;
12'd3594:at_byte=8'd61;
12'd3595:at_byte=8'd49;
12'd3596:at_byte=8'd48;
12'd3597:at_byte=8'd52;
12'd3598:at_byte=8'd13;
12'd3599:at_byte=8'd10;
default:at_byte=0;endcase end end endfunction
 assign tx_data=stage==15 ? reply_packet[(103-byte_index)*8 +:8] : stage==13 ? SUBSCRIBE_PACKET[(146-byte_index)*8 +:8] :
  stage==11 ? (volume_only ? volume_packet[(96-byte_index)*8 +:8] : publish_packet[(146-byte_index)*8 +:8]) :
  stage==7 ? CONNECT_PACKET[(164-byte_index)*8 +:8] : stage==9 ? (byte_index==0 ? 8'hc0 : 8'h00) : at_byte(stage,byte_index,volume_only);
 uart_rx_8n1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx(.clk(clk),.rst_n(rst_n),
  .rx(uart_rx),.data(rx_data),.valid(rx_valid),.frame_error(frame_error));
 uart_tx_8n1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx(.clk(clk),.rst_n(rst_n),
  .data(tx_data),.valid(state==SEND),.ready(tx_ready),.tx(uart_tx));
 reg [127:0] text_tail;
 wire [127:0] next_tail={text_tail[119:0],rx_data};
 reg saw_ok,saw_error,saw_prompt,saw_send_ok,saw_closed;
 reg [1:0] ipd_state;
 wire connack_ok,connack_bad,pingresp,suback_ok,suback_bad;
 mqtt_feedback_parser u_feedback(
  .clk(clk),.rst_n(rst_n),.session_reset(state==RETRY || state==BOOT),
  .clear_connect(state==PREP && stage==6),.clear_ping(state==PREP && stage==8),
  .publish_start(state==PREP && stage==10),.ms_tick(ms_tick),
  .data(rx_data),.valid(rx_valid && ipd_state==2),
  .connack_ok(connack_ok),.connack_bad(connack_bad),.pingresp(pingresp),
  .suback_ok(suback_ok),.suback_bad(suback_bad),
  .status(feedback_status),.code(feedback_code),.reject_byte(reject_byte),.reject_valid(reject_valid),.reject_start(reject_start),.reject_done(reject_done),.reject_length(reject_length));

 mqtt_volume_command u_volume_command(.clk(clk),.rst_n(rst_n),.session_reset(state==RETRY || state==BOOT),
 .data(rx_data),.valid(rx_valid && ipd_state==2),.reply_done(reply_done),
 .automatic_brightness(automatic_brightness),.reply_auto(reply_auto),
 .control_request(control_request),.reply_control(reply_control),.requested_brightness(requested_brightness),.reply_brightness(reply_brightness),
 .time_set(time_set),.weather_set(weather_set),.time_bcd(time_bcd),.weather_bcd(weather_bcd),.reply_env(reply_env),.requested_notice(requested_notice),.reply_notice(reply_notice),.requested_volume(requested_volume),.pending(command_pending),.command_id(command_id));
 reg [15:0] ipd_length,ipd_remaining;
 reg [31:0] binary_tail;
 wire [31:0] next_binary={binary_tail[23:0],rx_data};
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   text_tail<=0; saw_ok<=0; saw_error<=0; saw_prompt<=0; saw_send_ok<=0;
   saw_closed<=0;
   ipd_state<=0; ipd_length<=0; ipd_remaining<=0; binary_tail<=0;
  end else if(state==PREP || state==RETRY) begin
   text_tail<=0; saw_ok<=0; saw_error<=0; saw_prompt<=0; saw_send_ok<=0; saw_closed<=0;
   if(state==RETRY || stage==0 || stage==6) begin
    ipd_state<=0; ipd_length<=0;
    ipd_remaining<=0; binary_tail<=0;
   end

  end else if(rx_valid) begin
   if(ipd_state==2) begin
    binary_tail<=next_binary;



    if(ipd_remaining==1) begin ipd_state<=0; text_tail<=0; end
    else ipd_remaining<=ipd_remaining-1'b1;
   end else if(ipd_state==1) begin
    if(rx_data>="0" && rx_data<="9") ipd_length<=ipd_length*10+(rx_data-"0");
    else if(rx_data==":" && ipd_length!=0) begin
     ipd_remaining<=ipd_length; ipd_state<=2;
    end else begin ipd_state<=0; text_tail<=0; end
   end else begin
    text_tail<=next_tail;
    if(next_tail[39:0]=="+IPD,") begin ipd_state<=1; ipd_length<=0; end
    if(next_tail[31:0]=="OK\015\012") saw_ok<=1;
    if(next_tail[71:0]=="SEND OK\015\012") saw_send_ok<=1;
    if(next_tail[55:0]=="ERROR\015\012" || next_tail[47:0]=="FAIL\015\012") saw_error<=1;
    if(rx_data==">") saw_prompt<=1;
    if(next_tail[63:0]=="CLOSED\015\012" || next_tail=="WIFI DISCONNECT\015") saw_closed<=1;
   end
  end
 end
 assign command_done=(stage==6 || stage==8 || stage==10 || stage==12 || stage==14) ? saw_prompt :
  stage==7 ? saw_send_ok && connack_ok : stage==9 ? saw_send_ok && pingresp :
  stage==13 ? saw_send_ok && suback_ok : (stage==11 || stage==15) ? saw_send_ok : stage==4 ? saw_ok || saw_error || saw_closed : saw_ok;
 assign failed=(saw_error && stage!=4) || connack_bad || suback_bad || (saw_closed && stage>=5) || frame_error;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=BOOT; stage<=0; connected<=0; last_error<=0; elapsed<=0; ms_div<=0; byte_index<=0; upload_age<=0; ping_age<=0; sample_temperature<=0; sample_humidity<=0; request_id<=0; sample_volume<=255;volume_only<=0;sample_fire<=0;fire_reported<=0;
  end else begin
   if(ms_tick) begin ms_div<=0; elapsed<=elapsed+1'b1; end
   else ms_div<=ms_div+1'b1;
   if(!connected) begin fire_reported<=0; upload_age<=0; ping_age<=0; end
   else if(ms_tick) begin
    if(upload_age<UPLOAD_MS) upload_age<=upload_age+1'b1;
    if(ping_age<PING_MS) ping_age<=ping_age+1'b1;
   end
   case(state)
    BOOT: if(elapsed>=BOOT_MS) begin stage<=0; state<=PREP; elapsed<=0; end
    GAP: if(elapsed>=COMMAND_GAP_MS) begin state<=PREP; elapsed<=0; end
    PREP: begin byte_index<=0; elapsed<=0; state<=SEND; end
    SEND: if(tx_ready) begin
     if(byte_index==command_length-1) state<=DRAIN;
     else byte_index<=byte_index+1'b1;
    end
    DRAIN: if(tx_ready) begin state<=WAIT_REPLY; elapsed<=0; end
    WAIT_REPLY: begin
     if(failed) begin
      last_error<=suback_bad ? 8'h04 : connack_bad ? 8'h02 : 8'h01; connected<=0; state<=RETRY; elapsed<=0;
     end else if(command_done) begin
      elapsed<=0;
      if(stage==13 || stage==9 || stage==11 || stage==15) begin
       state<=ONLINE; connected<=1; last_error<=0;
       if(stage==11) begin fire_reported<=1;upload_age<=0;end
       if(stage==13) upload_age<=0;
       if(stage==13 || stage==9) ping_age<=0;
      end
      else if(stage==7) begin stage<=12; state<=GAP; ms_div<=0; end
      else begin stage<=stage+1'b1; state<=GAP; ms_div<=0; end
     end else if(elapsed>=(stage==5 ? TCP_MS : RESPONSE_MS)) begin
      last_error<=8'h10+stage; connected<=0; state<=RETRY; elapsed<=0;
     end
    end
    ONLINE: begin
     if(failed) begin connected<=0; state<=RETRY; elapsed<=0; last_error<=3; end
     else if(reply_ready) begin stage<=14;state<=GAP;elapsed<=0;ms_div<=0;end
     else if(ping_age>=PING_MS) begin stage<=8; state<=PREP; elapsed<=0; end
     else if(upload_age>=UPLOAD_MS || applied_volume!=sample_volume || !fire_reported || fire_active!=sample_fire) begin
      sample_fire<=fire_active;sample_volume<=applied_volume;volume_only<=!(upload_age>=UPLOAD_MS && sensor_valid);
      sample_temperature<=temperature; sample_humidity<=humidity;
      request_id<=request_id==255 ? 8'd1 : request_id+1'b1;
      stage<=10; state<=PREP; elapsed<=0;
     end
    end
    RETRY: if(elapsed>=RETRY_MS) begin stage<=0; state<=PREP; elapsed<=0; end
    default: begin state<=BOOT; connected<=0; elapsed<=0; end
   endcase
  end
 end
endmodule
// Bundled-data handshake. Source holds data while acknowledgement crosses.
module dht_snapshot_cdc #(parameter WIDTH=17)(
 input wire src_clk,src_rst_n,dst_clk,dst_rst_n,
 input wire [WIDTH-1:0] src_data,
 output reg [WIDTH-1:0] dst_data
);
 reg request,ack;
 (* async_reg="true" *) reg req_meta,req_sync,ack_meta,ack_sync;
 reg [WIDTH-1:0] held_data;
 always @(posedge src_clk or negedge src_rst_n)
  if(!src_rst_n) begin req_meta<=0; req_sync<=0; ack<=0; held_data<=0; end
  else begin
   req_meta<=request; req_sync<=req_meta;
   if(req_sync!=ack) begin held_data<=src_data; ack<=req_sync; end
  end
 always @(posedge dst_clk or negedge dst_rst_n)
  if(!dst_rst_n) begin request<=0; ack_meta<=0; ack_sync<=0; dst_data<=0; end
  else begin
   ack_meta<=ack; ack_sync<=ack_meta;
   if(ack_sync==request) begin dst_data<=held_data; request<=~request; end
  end
endmodule
// MQTT stream framing persists across +IPD boundaries. Only QoS0 is requested.
module mqtt_feedback_parser(
 input wire clk,rst_n,session_reset,clear_connect,clear_ping,publish_start,ms_tick,
 input wire [7:0] data,input wire valid,
 output reg connack_ok,connack_bad,pingresp,suback_ok,suback_bad,
 output wire [7:0] reject_byte, output wire reject_valid,reject_start,reject_done, output wire [27:0] reject_length,
 output reg [2:0] status,output reg [15:0] code
);
 // status: 0 no subscription, 1 ready, 2 waiting, 3 accepted, 4 rejected, 5 timeout.
 reg [1:0] phase;
 reg [7:0] header;
 reg [27:0] remaining,length_acc,index;
 reg [4:0] length_shift;
 wire [27:0] decoded_length=length_acc | ({21'd0,data[6:0]} << length_shift);
 reg [31:0] control_tail;
 reg [15:0] topic_length;
 reg topic_accept,topic_reject;
 reg [47:0] json_tail;
 reg [1:0] code_state;
 reg [15:0] code_acc;
 reg code_seen;
 reg [15:0] feedback_age;
 reg awaiting_feedback;
 localparam [375:0] ACCEPT_TOPIC="$sys/Q3FhlsOoK7/anlu_fpga/dp/post/json/accepted";
 localparam [375:0] REJECT_TOPIC="$sys/Q3FhlsOoK7/anlu_fpga/dp/post/json/rejected";
 wire [47:0] next_json={json_tail[39:0],data};
 wire [31:0] next_control={control_tail[23:0],data};
 // Raw rejection stream. Valid only after exact full topic has matched.
 assign reject_byte=data;
 assign reject_valid=valid && phase==2 && header[7:4]==3 && header[2:1]==0 && topic_reject && index>=49 && !session_reset;
 assign reject_start=reject_valid && index==49;
 assign reject_done=valid && phase==2 && header[7:4]==3 && header[2:1]==0 && topic_reject && index>=48 && remaining==1 && !session_reset;
 assign reject_length=index-48;
 wire is_digit=data>=8'd48 && data<=8'd57;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   phase<=0; header<=0;remaining<=0;length_acc<=0;index<=0;length_shift<=0;
   control_tail<=0;topic_length<=0;topic_accept<=0;topic_reject<=0;
   json_tail<=0;code_state<=0;code_acc<=0;code_seen<=0;feedback_age<=0;awaiting_feedback<=0;
   connack_ok<=0;connack_bad<=0;pingresp<=0;suback_ok<=0;suback_bad<=0;
   status<=0;code<=16'hffff;
  end else if(session_reset) begin
   phase<=0;remaining<=0;length_acc<=0;index<=0;length_shift<=0;
   connack_ok<=0;connack_bad<=0;pingresp<=0;suback_ok<=0;suback_bad<=0;
   status<=0;code<=16'hffff;feedback_age<=0;awaiting_feedback<=0;
  end else begin
   if(clear_connect) begin connack_ok<=0;connack_bad<=0;end
   if(clear_ping) pingresp<=0;
   if(publish_start) begin
    // Keep last received result visible while subsequent packets are sent.
    if(status<3) status<=2;
    feedback_age<=0;awaiting_feedback<=1;
   end else if(ms_tick && awaiting_feedback) begin
    if(feedback_age==4999) begin status<=5;awaiting_feedback<=0;end
    else feedback_age<=feedback_age+1'b1;
   end
   if(valid) case(phase)
    0: begin header<=data;phase<=1;length_acc<=0;length_shift<=0;end
    1: begin
     if(data[7]) begin
      if(length_shift==21) begin phase<=0;suback_bad<=1;end
      else begin length_acc<=decoded_length;length_shift<=length_shift+7;end
     end else begin
      remaining<=decoded_length;index<=0;control_tail<=0;topic_length<=0;
      topic_accept<=1;topic_reject<=1;json_tail<=0;code_state<=0;code_acc<=0;code_seen<=0;
      if(decoded_length==0) begin
       phase<=0;
       if(header==8'hd0) pingresp<=1;
      end else phase<=2;
     end
    end
    2: begin
     control_tail<=next_control;
     if(header[7:4]==3) begin
      if(index==0) topic_length[15:8]<=data;
      else if(index==1) begin
       topic_length[7:0]<=data;
       if({topic_length[15:8],data}!=47) begin topic_accept<=0;topic_reject<=0;end
      end else if(index<2+{12'd0,topic_length}) begin
       if(index<49) begin
        if(data!=ACCEPT_TOPIC[(48-index)*8 +:8]) topic_accept<=0;
        if(data!=REJECT_TOPIC[(48-index)*8 +:8]) topic_reject<=0;
       end
      end else if(header[2:1]==0) begin
       json_tail<=next_json;
       // Extract a non-negative integer "code", with JSON whitespace allowed.
       if(next_json==48'h22636f646522) begin code_state<=1;code_acc<=0;code_seen<=0;end
       else if(code_state==1) begin
        if(data==":") code_state<=2;
        else if(data!=32 && data!=9 && data!=10 && data!=13) code_state<=0;
       end else if(code_state==2) begin
        if(is_digit) begin code_acc<=data-48;code_seen<=1;code_state<=3;end
        else if(data!=32 && data!=9 && data!=10 && data!=13) code_state<=0;
       end else if(code_state==3) begin
        if(is_digit) begin
         if(code_acc<=6552 || (code_acc==6553 && data<=53)) code_acc<=code_acc*10+(data-48);
         else begin code_seen<=0;code_state<=0;end
        end else code_state<=0;
       end
      end
     end
     if(remaining==1) begin
      phase<=0;
      if(header==8'h20 && index==1 && control_tail[7:0]==0) begin
       if(data==0) connack_ok<=1;else connack_bad<=1;
      end
      if(header==8'h90 && (index==3 || index==4)) begin
       if((index==3 && next_control==32'h00010000) || (index==4 && next_control==32'h01000000)) begin suback_ok<=1;if(status==0) status<=1;end
       else suback_bad<=1;
      end
      if(header[7:4]==3 && header[2:1]==0 && index>=49 && (topic_accept || topic_reject)) begin
       status<=topic_accept ? 3 : 4;awaiting_feedback<=0;
       code<=code_seen ? code_acc : 16'hffff;
      end
     end else begin remaining<=remaining-1'b1;index<=index+1'b1;end
    end
    default:phase<=0;
   endcase
  end
 end
endmodule

module mqtt_feedback_osd(
 input wire clk,rst_n,frame_start,input wire [19:0] status,
 input wire de,input wire [11:0] pixel_x,pixel_y,
 input wire [23:0] rgb_in,output reg [23:0] rgb_out);
 reg [19:0] snapshot;
 reg [19:0] decimal_digits,bcd_work;
 wire [3:0] digit4=decimal_digits[19:16],digit3=decimal_digits[15:12],digit2=decimal_digits[11:8],digit1=decimal_digits[7:4],digit0=decimal_digits[3:0];
 reg [15:0] binary_work;
 reg [4:0] conversion_count;
 reg [19:0] adjusted;
 integer di;
 always @* begin
  adjusted=bcd_work;
  for(di=0;di<5;di=di+1)if(bcd_work[di*4 +:4]>=5)adjusted[di*4 +:4]=bcd_work[di*4 +:4]+4'd3;
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin decimal_digits<=0;bcd_work<=0;binary_work<=0;conversion_count<=0;end
 else if(frame_start)begin bcd_work<=0;binary_work<=status[15:0];conversion_count<=16;end
 else if(conversion_count!=0)begin
  bcd_work<={adjusted[18:0],binary_work[15]};binary_work<={binary_work[14:0],1'b0};conversion_count<=conversion_count-1'b1;
  if(conversion_count==1)decimal_digits<={adjusted[18:0],binary_work[15]};
 end
 always @(posedge clk or negedge rst_n)
  if(!rst_n) snapshot<=0;else if(frame_start) snapshot<=status;
 function [34:0] glyph;
 input [7:0] c;
 begin case(c)
  8'd37: glyph=35'b11001110100001000100010000101110011;
  8'd45: glyph=35'b00000000000000011111000000000000000;
  8'd48: glyph=35'b01110100011001110101110011000101110;
  8'd49: glyph=35'b00100011000010000100001000010001110;
  8'd50: glyph=35'b01110100010000100010001000100011111;
  8'd51: glyph=35'b11110000010000101110000010000111110;
  8'd52: glyph=35'b00010001100101010010111110001000010;
  8'd53: glyph=35'b11111100001000011110000010000111110;
  8'd54: glyph=35'b01110100001000011110100011000101110;
  8'd55: glyph=35'b11111000010001000100010000100001000;
  8'd56: glyph=35'b01110100011000101110100011000101110;
  8'd57: glyph=35'b01110100011000101111000010000101110;
  8'd58: glyph=35'b00000001000010000000001000010000000;
  8'd67: glyph=35'b01111100001000010000100001000001111;
  8'd69: glyph=35'b11111100001000011110100001000011111;
  8'd72: glyph=35'b10001100011000111111100011000110001;
  8'd77: glyph=35'b10001110111010110101100011000110001;
  8'd80: glyph=35'b11110100011000111110100001000010000;
  8'd84: glyph=35'b11111001000010000100001000010000100;
  8'd85: glyph=35'b10001100011000110001100011000101110;
  default: glyph=0;
 endcase end
 endfunction
 integer dx,dy,index,col,row;
 reg [7:0] c;
 reg [34:0] bits;
 reg [15:0] value;
 always @* begin
  rgb_out=rgb_in;dx=0;dy=0;index=0;col=0;row=0;c=32;bits=0;value=snapshot[15:0];
  if(de && pixel_x>=400 && pixel_x<632 && pixel_y>=56 && pixel_y<100) begin
   rgb_out=24'h102030;dx=pixel_x-406;dy=pixel_y-62;
   if(dx>=0 && dx<216 && dy>=0 && dy<34) begin
    index=dx/12;col=(dx%12)/2;
    if(dy<14) begin
     case(index)
      0:c="M";1:c=":";2:c=48+snapshot[18:16];
      4:c="C";5:c=":";6:c=48+snapshot[19];
      default:c=32;
     endcase
    end else if(dy>=20) begin
     dy=dy-20;
     case(index)
      0:c="C";1:c=":";2:c=value==65535 ? "-" : 48+digit4;
      3:c=value==65535 ? "-" : 48+digit3;
      4:c=value==65535 ? "-" : 48+digit2;
      5:c=value==65535 ? "-" : 48+digit1;
      6:c=value==65535 ? "-" : 48+digit0;
      default:c=32;
     endcase
    end
    row=dy/2;bits=glyph(c);
    if(col<5 && row<7 && bits[34-row*5-col])
     rgb_out=snapshot[18:16]==4 ? 24'hff6666 : snapshot[18:16]==3 ? 24'h66ff66 : 24'hffffff;
   end
  end
 end
endmodule
module mqtt_raw_feedback_osd(
 input wire src_clk,src_rst_n,input wire [7:0] data,input wire valid,start,done,input wire [27:0] length,
 input wire clk,rst_n,frame_start,de,input wire [11:0] pixel_x,pixel_y,
 input wire [23:0] rgb_in,output reg [23:0] rgb_out);
 // First complete rejected response is frozen until board reset.
 (* ram_style="block" *) reg [7:0] buffer[0:511];
 reg [9:0] count;
 reg frozen;
 reg [27:0] saved_length;
 always @(posedge src_clk or negedge src_rst_n)
  if(!src_rst_n) begin count<=0;frozen<=0;saved_length<=0;end
  else if(!frozen) begin
   if(start) begin count<=1;end
   else if(valid && count<512) begin count<=count+1'b1;end
   if(done) begin frozen<=1;saved_length<=length;end
  end
 // No reset on RAM storage; validity/length guards every read.
 always @(posedge src_clk)
  if(src_rst_n && !frozen && valid && (start || count<512))
   buffer[start ? 9'd0 : count[8:0]]<=data;
 wire [28:0] info;
 dht_snapshot_cdc #(.WIDTH(29)) u_info(
 .src_clk(src_clk),.src_rst_n(src_rst_n),.dst_clk(clk),.dst_rst_n(rst_n),
 .src_data({frozen,saved_length}),.dst_data(info));
 reg ready;
 reg [9:0] size;
 reg truncated;
 reg [2:0] page,last_page;
 reg [7:0] frames;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) begin ready<=0;size<=0;truncated<=0;page<=0;last_page<=0;frames<=0;end
  else if(frame_start) begin
   if(!ready && info[28]) begin
    ready<=1;size<=info[27:0]>512 ? 512 : info[9:0];
    truncated<=info[27:0]>512;
    last_page<=info[27:0]>512 ? 7 : info[27:0]==0 ? 0 : (info[27:0]-1)>>6;
    page<=0;frames<=0;
   end else if(ready) begin
    if(frames==239) begin frames<=0;page<=page==last_page ? 0 : page+1'b1;end
    else frames<=frames+1'b1;
   end
  end
 function [7:0] hexchar;
 input [3:0] v;
 begin hexchar=v<10 ? 48+v : 65+v-10;end
 endfunction
 function [34:0] glyph;
 input [7:0] ch;
 reg [7:0] c;
 begin
 c=(ch>=97 && ch<=122) ? ch-32 : ch;
 case(c)
 8'd48:glyph=35'b01110100011001110101110011000101110;
 8'd49:glyph=35'b00100011000010000100001000010001110;
 8'd50:glyph=35'b01110100010000100010001000100011111;
 8'd51:glyph=35'b11110000010000101110000010000111110;
 8'd52:glyph=35'b00010001100101010010111110001000010;
 8'd53:glyph=35'b11111100001000011110000010000111110;
 8'd54:glyph=35'b01110100001000011110100011000101110;
 8'd55:glyph=35'b11111000010001000100010000100001000;
 8'd56:glyph=35'b01110100011000101110100011000101110;
 8'd57:glyph=35'b01110100011000101111000010000101110;
 8'd32:glyph=35'b00000000000000000000000000000000000;
 8'd65:glyph=35'b01110100011000111111100011000110001;
 8'd66:glyph=35'b11110100011000111110100011000111110;
 8'd67:glyph=35'b01111100001000010000100001000001111;
 8'd68:glyph=35'b11110100011000110001100011000111110;
 8'd69:glyph=35'b11111100001000011110100001000011111;
 8'd70:glyph=35'b11111100001000011110100001000010000;
 8'd71:glyph=35'b01110100011000010111100011000101110;
 8'd72:glyph=35'b10001100011000111111100011000110001;
 8'd73:glyph=35'b11111001000010000100001000010011111;
 8'd74:glyph=35'b00111000100001000010100101001001100;
 8'd75:glyph=35'b10001100101010011000101001001010001;
 8'd76:glyph=35'b10000100001000010000100001000011111;
 8'd77:glyph=35'b10001110111010110101100011000110001;
 8'd78:glyph=35'b10001110011010110011100011000110001;
 8'd79:glyph=35'b01110100011000110001100011000101110;
 8'd80:glyph=35'b11110100011000111110100001000010000;
 8'd81:glyph=35'b01110100011000110001101011001001101;
 8'd82:glyph=35'b11110100011000111110101001001010001;
 8'd83:glyph=35'b01111100001000001110000010000111110;
 8'd84:glyph=35'b11111001000010000100001000010000100;
 8'd85:glyph=35'b10001100011000110001100011000101110;
 8'd86:glyph=35'b10001100011000110001100010101000100;
 8'd87:glyph=35'b10001100011000110101101011010101010;
 8'd88:glyph=35'b10001100010101000100010101000110001;
 8'd89:glyph=35'b10001100010101000100001000010000100;
 8'd90:glyph=35'b11111000010001000100010001000011111;
 8'd58:glyph=35'b00000001000010000000001000010000000;
 8'd44:glyph=35'b00000000000000000000001000010001000;
 8'd46:glyph=35'b00000000000000000000000000010000100;
 8'd34:glyph=35'b01010010100000000000000000000000000;
 8'd123:glyph=35'b00010001000010001000001000010000010;
 8'd125:glyph=35'b01000001000010000010001000010001000;
 8'd91:glyph=35'b01110010000100001000010000100001110;
 8'd93:glyph=35'b01110000100001000010000100001001110;
 8'd47:glyph=35'b00001000100001000100010000100010000;
 8'd45:glyph=35'b00000000000000011111000000000000000;
 8'd95:glyph=35'b00000000000000000000000000000011111;
 8'd61:glyph=35'b00000000001111100000111110000000000;
 8'd63:glyph=35'b01110100010000100010001000000000100;
 default:glyph=35'b01110100010000100010001000000000100;
 endcase end
 endfunction
 // Synchronous dual-clock block RAM; delay all rendering inputs by the same cycle.
 wire [9:0] read_x=pixel_x-12'd64;
 wire [7:0] read_y=pixel_y-12'd120;
 wire [3:0] read_line=read_y[7:4];
 wire [8:0] read_address={page,6'b000000}+((read_line==1 || read_line==2)?{3'd0,read_line[0]?1'b0:1'b1,5'd0}+{3'd0,read_x[9:4]}:({5'd0,read_line}-9'd4)*9'd16+{5'd0,read_x[8:5]});
 reg [7:0] read_byte;
 always @(posedge clk)read_byte<=buffer[read_address];
 reg [11:0] pixel_x_q,pixel_y_q;reg de_q;reg [23:0] rgb_in_q;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin pixel_x_q<=0;pixel_y_q<=0;de_q<=0;rgb_in_q<=0;end
 else begin pixel_x_q<=pixel_x;pixel_y_q<=pixel_y;de_q<=de;rgb_in_q<=rgb_in;end
 reg [9:0] x; reg [7:0] y; reg [5:0] ci; reg [3:0] ri; reg [2:0] col,row; reg [9:0] offset;
 reg [7:0] c,raw;
 reg [34:0] bits;
 reg [255:0] title;
 always @* begin
  rgb_out=rgb_in_q;x=0;y=0;ci=0;ri=0;col=0;row=0;offset=0;c=32;raw=0;bits=0;
  title={"REJECT PAGE ",8'd49+{5'd0,page},"/",8'd49+{5'd0,last_page},"  TRUNC:",truncated ? "1" : "0","        "};
  if(ready && de_q && pixel_x_q>=48 && pixel_x_q<592 && pixel_y_q>=112 && pixel_y_q<264) begin
   rgb_out=24'h102030;
   x=pixel_x_q-64;y=pixel_y_q-120;
   if(pixel_x_q>=64 && x<512 && pixel_y_q>=120 && y<128) begin
    ci=x[9:4];col=x[3:1];ri=y[7:4];row=y[3:1];
    if(ri==0) c=title[(31-ci)*8 +:8];
    else if(ri==1 || ri==2) begin
     offset=page*64+(ri-1)*32+ci;
     if(offset<size) begin raw=read_byte;c=raw>=32 && raw<=126 ? raw : 8'd63;end
    end else if(ri>=4 && ri<=7) begin
     ci=x[8:3];col=x[2:0];
     offset=page*64+(ri-4)*16+ci[5:2];
     if(offset<size) begin raw=read_byte;case(ci[1:0]) 0:c=hexchar(raw[7:4]);1:c=hexchar(raw[3:0]);default:c=32;endcase end
    end
    bits=glyph(c);
    if(col<5 && row<7 && bits[34-row*5-col]) rgb_out=24'hffffff;
   end
  end
 end
endmodule

// Compact application protocol: exactly VOL=000 .. VOL=100 (7 ASCII bytes).
// A request is committed only after the full QoS0 packet and UUID validate.
module mqtt_volume_command(
 input wire clk,rst_n,session_reset,input wire [7:0] data,input wire valid,reply_done,
 output reg automatic_brightness,reply_auto,
 output reg [3:0] control_request,output reg reply_control,reply_brightness,output reg [7:0] requested_brightness,
 output reg time_set,weather_set,output reg [55:0] time_bcd,output reg [23:0] weather_bcd,output reg [1:0] reply_env,
 output reg requested_notice,reply_notice,output reg [7:0] requested_volume,output reg pending,output wire [287:0] command_id);
 localparam [303:0] PREFIX="$sys/Q3FhlsOoK7/anlu_fpga/cmd/request/";
 reg [1:0] phase;
 reg [7:0] header;
 reg [27:0] remaining,acc;
 reg [6:0] index; // Saturate outside the only accepted 83-byte body.
 reg [4:0] shift;
 reg match_topic;
 reg [287:0] candidate_id;
 reg [55:0] payload;
 reg [55:0] digits;
 reg env_match;
 reg [1:0] env_kind;
 reg [7:0] wx_sign;
 wire [55:0] final_time={digits[51:0],data[3:0]};
 wire [7:0] yy=final_time[47:40], mo=final_time[39:32], dd=final_time[31:24];
 wire leap=(yy[4:4]^yy[1:1])==0 && yy[0]==0;
 wire [7:0] maxday=mo==8'h02 ? (leap?8'h29:8'h28) : (mo==8'h04 || mo==8'h06 || mo==8'h09 || mo==8'h11) ? 8'h30 : 8'h31;
 wire date_ok=final_time[55:48]==8'h20 && mo>=1 && mo<=8'h12 && dd>=1 && dd<=maxday && final_time[23:16]<=8'h23 && final_time[15:8]<=8'h59 && final_time[7:0]<=8'h59;
 assign command_id=candidate_id; // Freeze the ID until the reply has been sent.
 wire [27:0] decoded=acc | ({21'd0,data[6:0]}<<shift);
 wire [55:0] completed={payload[47:0],data};
 wire digit0=completed[23:16]>=48 && completed[23:16]<=49;
 wire digit1=completed[15:8]>=48 && completed[15:8]<=57;
 wire digit2=data>=48 && data<=57;
 wire [7:0] amount=completed[23:16]==8'd49 ? 8'd100 : ({4'd0,completed[11:8]}*8'd10+{4'd0,data[3:0]});
 wire in_range=completed[23:16]==8'd48 || (completed[15:8]==8'd48 && data==8'd48);
 wire uuid_dash=index==48 || index==53 || index==58 || index==63;
 wire uuid_char=uuid_dash ? data==45 : ((data>=48 && data<=57)||(data>=97 && data<=102)||(data>=65 && data<=70));
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   automatic_brightness<=0;reply_auto<=0;control_request<=0;reply_control<=0;reply_brightness<=0;requested_brightness<=100;
   phase<=0;header<=0;remaining<=0;acc<=0;index<=0;shift<=0;match_topic<=0;
   time_set<=0;weather_set<=0;time_bcd<=0;weather_bcd<=0;reply_env<=0;digits<=0;env_match<=0;env_kind<=0;wx_sign<=0;
   candidate_id<=0;payload<=0;requested_notice<=0;reply_notice<=0;requested_volume<=50;pending<=0;
  end else begin
   time_set<=0;weather_set<=0;
   if(!pending) begin reply_auto<=0;reply_control<=0;reply_brightness<=0;end
   if(reply_done) pending<=0;
   if(session_reset) begin phase<=0;remaining<=0;acc<=0;index<=0;shift<=0;pending<=0;end
   else if(valid) case(phase)
    0:begin header<=data;phase<=1;acc<=0;shift<=0;end
    1:begin
     if(data[7]) begin
      if(shift==21) phase<=0;
      else begin acc<=decoded;shift<=shift+7;end
     end else begin
      remaining<=decoded;index<=0;if(!pending) candidate_id<=0;payload<=0;
      env_kind<=decoded==95?1:decoded==84?2:0;env_match<=1;digits<=0;
      match_topic<=header==8'h30 && (decoded==83 || decoded==95 || decoded==84) && !pending;
      phase<=decoded==0 ? 0 : 2;
     end
    end
    2:begin
     if(index==0 && data!=0) match_topic<=0;
     else if(index==1 && data!=74) match_topic<=0;
     else if(index>=2 && index<40) begin
      if(data!=PREFIX[(39-index)*8 +:8]) match_topic<=0;
     end else if(index>=40 && index<76) begin
      if(!pending) candidate_id<={candidate_id[279:0],data};
      if(!uuid_char) match_topic<=0;
     end else if(index>=76 && index<83) payload<={payload[47:0],data};
     if(index>=76 && env_kind!=0) begin
      if(env_kind==1) begin
       case(index)
        76:if(data!="T")env_match<=0;
        77:if(data!="I")env_match<=0;
        78:if(data!="M")env_match<=0;
        79:if(data!="E")env_match<=0;
        80:if(data!="=")env_match<=0;
        default:begin if(data<48 || data>57)env_match<=0;digits<={digits[51:0],data[3:0]};end
       endcase
      end else begin
       case(index)
        76:if(data!="W")env_match<=0;
        77:if(data!="X")env_match<=0;
        78:if(data!="=")env_match<=0;
        81:begin wx_sign<=data;if(data!="+" && data!="-")env_match<=0;end
        default:begin if(data<48 || data>57)env_match<=0;digits<={digits[51:0],data[3:0]};end
       endcase
      end
     end
     if(remaining==1) begin
      phase<=0;
      if(index==82 && match_topic && !pending && completed[55:8]=="AUT=00" && data>=48 && data<=50)begin
       if(data!=50)automatic_brightness<=data==49;reply_auto<=1;pending<=1;
      end else if(index==82 && match_topic && !pending && completed[55:8]=="CTL=00" && data>=48 && data<=54) begin
       control_request<={~control_request[3],data[2:0]};reply_control<=1;reply_brightness<=0;pending<=1;
      end else if(index==82 && match_topic && !pending && completed[55:24]=="BRI=" && digit0 && digit1 && digit2 && in_range) begin
       automatic_brightness<=0;requested_brightness<=amount;reply_brightness<=1;reply_control<=0;pending<=1;
      end else if(index==94 && env_kind==1 && match_topic && env_match && digit2 && date_ok && !pending) begin
       time_bcd<=final_time;time_set<=1;reply_env<=1;pending<=1;
      end else if(index==83 && env_kind==2 && match_topic && env_match && digit2 && !pending) begin
       weather_bcd<={wx_sign,digits[11:0],data[3:0]};weather_set<=1;reply_env<=2;pending<=1;
      end else if(index==82 && match_topic && !pending && completed[55:24]=="VOL=" && digit0 && digit1 && digit2 && in_range) begin
       requested_volume<=amount;reply_env<=0;reply_notice<=0;pending<=1;
      end else if(index==82 && match_topic && !pending && completed[55:8]=="FIND=0" && (data==48 || data==49 || data==50)) begin
       if(data!=50) requested_notice<=data==49;
       reply_env<=0;reply_notice<=1;pending<=1;
      end
     end else begin remaining<=remaining-1'b1;if(index<95) index<=index+1'b1;end
    end
    default:phase<=0;
   endcase
  end
 end
endmodule
// Fixed 512x384 four-colour notice panel; an 8192x16 synchronous ROM stores palette pixels.
// All video sidebands and ordinary video receive exactly the same one-clock delay.
module child_notice_screen #(
 parameter MAP_FILE="C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/child_notice_map.hex",
 parameter TILE_FILE="C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/child_notice_tiles.hex")(
 input wire clk,rst_n,enabled,hs_in,vs_in,de_in,
 input wire [11:0] x,y,input wire [23:0] rgb_in,
 output wire hs_out,vs_out,de_out,output reg [23:0] rgb_out);
 // Lossless RLE expansion into alternating scanline banks. Original 16-colour pixels.
 reg [13:0] row_rom[0:511];reg [11:0] run_dict[0:511];
 reg [8:0] run_lo[0:8191],run_hi[0:2047];
 reg [3:0] line_pixels[0:1023];
 initial begin
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/notice_run_start.hex",row_rom);
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/notice_run_dict.hex",run_dict);
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/notice_run_0.hex",run_lo);
 $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/notice_run_1.hex",run_hi);
 end
 wire panel_inside=x>=64 && x<576 && y>=48 && y<432;
 wire [8:0] px=x-64,py=y-48;
 reg [8:0] decode_row;reg [9:0] write_x;reg [13:0] token_address;
 reg [13:0] row_start_q;reg [8:0] token_lo_q,token_hi_q;reg token_bank_q;
 reg [11:0] run_q;reg [8:0] remaining;reg [3:0] run_colour;
 reg [3:0] decode_state;reg vs_previous;reg [1:0] row_ready;
 reg [3:0] line_colour_q,colour;reg [1:0] inside_q,enabled_q,hs_q,vs_q,de_q;
 reg [23:0] rgb_q,rgb_qq;
 always @(posedge clk)begin
 row_start_q<=row_rom[decode_row];
 token_lo_q<=run_lo[token_address[12:0]];token_hi_q<=run_hi[token_address[10:0]];token_bank_q<=token_address[13];
 run_q<=run_dict[token_bank_q?token_hi_q:token_lo_q];
 if(decode_state==5)line_pixels[{decode_row[0],write_x[8:0]}]<=run_colour;
 line_colour_q<=line_pixels[{py[0],px}];colour<=line_colour_q;
 end
 // Each row takes <= 512 + 4*114 + 10 = 978 clocks, below the 1056-clock line.
 always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin decode_row<=0;write_x<=0;token_address<=0;remaining<=0;run_colour<=0;decode_state<=0;vs_previous<=1;row_ready<=0;end
 else begin
 vs_previous<=vs_in;
 if(vs_previous && !vs_in)begin decode_row<=0;write_x<=0;decode_state<=0;row_ready<=0;end
 else case(decode_state)
 0:decode_state<=1;
 1:begin token_address<=row_start_q;decode_state<=2;end
 2:decode_state<=3;
 3:decode_state<=4;
 4:begin remaining<={1'b0,run_q[7:0]}+1'b1;run_colour<=run_q[11:8];decode_state<=5;end
 5:begin
 if(write_x==511)begin row_ready[decode_row[0]]<=1;decode_state<=6;end
 else begin write_x<=write_x+1'b1;
 if(remaining==1)begin token_address<=token_address+1'b1;decode_state<=2;end
 else remaining<=remaining-1'b1;end
 end
 6:if(de_in && panel_inside && px==0 && py==decode_row && decode_row<383)begin
 decode_row<=decode_row+1'b1;write_x<=0;row_ready[~decode_row[0]]<=0;decode_state<=0;
 end
 default:decode_state<=0;
 endcase
 end end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin inside_q<=0;enabled_q<=0;hs_q<=0;vs_q<=0;de_q<=0;rgb_q<=0;rgb_qq<=0;end
 else begin
 inside_q<={inside_q[0],panel_inside && row_ready[py[0]]};enabled_q<={enabled_q[0],enabled};
 hs_q<={hs_q[0],hs_in};vs_q<={vs_q[0],vs_in};de_q<={de_q[0],de_in};rgb_q<=rgb_in;rgb_qq<=rgb_q;
 end
 assign hs_out=hs_q[1];assign vs_out=vs_q[1];assign de_out=de_q[1];
 reg [23:0] panel_rgb;
 always @* begin
  case(colour)
   4'd0:panel_rgb=24'h143042;
   4'd1:panel_rgb=24'hf5f3ea;
   4'd2:panel_rgb=24'h207f82;
   4'd3:panel_rgb=24'hffd366;
   4'd4:panel_rgb=24'h3a515e;
   4'd5:panel_rgb=24'h5f717a;
   4'd6:panel_rgb=24'h859296;
   4'd7:panel_rgb=24'haab2b2;
   4'd8:panel_rgb=24'hd0d3ce;
   4'd9:panel_rgb=24'h4f594b;
   4'd10:panel_rgb=24'h8a8254;
   4'd11:panel_rgb=24'hc4aa5d;
   4'd12:panel_rgb=24'h67a6a5;
   4'd13:panel_rgb=24'haeccc7;
   4'd14:panel_rgb=24'hfcde92;
   4'd15:panel_rgb=24'hf8e8be;
   default:panel_rgb=24'hf5f3ea;
  endcase
  rgb_out=enabled_q[1] ? (inside_q[1] ? panel_rgb : 24'hf5f3ea) : rgb_qq;
 end
endmodule

// Beijing civil clock, BCD calendar valid for 2000..2099.
module environment_clock #(parameter CLK_HZ=50000000)(
 input wire clk,rst_n,time_set,weather_set,input wire [55:0] time_bcd,input wire [23:0] weather_bcd,
 output wire [83:0] status);
 reg [55:0] civil;
 reg [23:0] wx;
 reg tv,wv;
 reg [9:0] ta,wa;
 reg [25:0] divider;
 wire tick=divider==CLK_HZ-1;
 wire [7:0] yy=civil[47:40],mo=civil[39:32],dd=civil[31:24];
 wire leap=(yy[4]^yy[1])==0 && yy[0]==0;
 wire [7:0] maxday=mo==8'h02 ? (leap?8'h29:8'h28):(mo==8'h04||mo==8'h06||mo==8'h09||mo==8'h11)?8'h30:8'h31;
 function [7:0] inc;input [7:0] b;begin inc=b[3:0]==9?{b[7:4]+4'd1,4'd0}:b+8'd1;end endfunction
 assign status={tv,wv,ta<180,wa<300,civil,wx};
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin civil<=0;wx<=0;tv<=0;wv<=0;ta<=1023;wa<=1023;divider<=0;end
 else begin
  if(time_set || tick)divider<=0;else divider<=divider+1'b1;
  if(tick)begin
   if(ta<1023)ta<=ta+1'b1;
   if(wa<1023)wa<=wa+1'b1;
   if(tv)begin
    if(civil[7:0]!=8'h59)civil[7:0]<=inc(civil[7:0]);
    else begin
     civil[7:0]<=0;
     if(civil[15:8]!=8'h59)civil[15:8]<=inc(civil[15:8]);
     else begin
      civil[15:8]<=0;
      if(civil[23:16]!=8'h23)civil[23:16]<=inc(civil[23:16]);
      else begin
       civil[23:16]<=0;
       if(dd!=maxday)civil[31:24]<=inc(dd);
       else begin
        civil[31:24]<=1;
        if(mo!=8'h12)civil[39:32]<=inc(mo);
        else begin civil[39:32]<=1;civil[47:40]<=yy==8'h99 ? 0:inc(yy);end
       end
      end
     end
    end
   end
  end
  if(time_set)begin civil<=time_bcd;tv<=1;ta<=0;end
  if(weather_set)begin wx<=weather_bcd;wv<=1;wa<=0;end
 end
endmodule

module environment_osd(input wire clk,rst_n,frame_start,enabled,hs_in,vs_in,de_in,
 input wire [11:0] x,y,input wire [23:0] rgb_in,input wire [83:0] status,
 output reg hs_out,vs_out,de_out,output reg [11:0] x_out,y_out,output wire [23:0] rgb_out);
 reg [83:0] snap;
 always @(posedge clk or negedge rst_n)if(!rst_n)snap<=0;else if(frame_start)snap<=status;
 wire [55:0] t=snap[79:24];wire [23:0] w=snap[23:0];
 wire [5:0] char_index=x[9:4]-6'd1;
 reg [5:0] ch;
 reg [3:0] nib;
 always @* begin
 ch=6'd12;nib=0;
 if(y<448)begin
  case(char_index)
   0:nib=t[55:52];1:nib=t[51:48];2:nib=t[47:44];3:nib=t[43:40];
   5:nib=t[39:36];6:nib=t[35:32];8:nib=t[31:28];9:nib=t[27:24];
   11:nib=t[23:20];12:nib=t[19:16];14:nib=t[15:12];15:nib=t[11:8];17:nib=t[7:4];18:nib=t[3:0];default:nib=0;
  endcase
  if(char_index<19)begin
   ch=snap[83]?{2'd0,nib}:6'd10;
   case(char_index)4,7:ch=6'd10;10:ch=6'd12;13,16:ch=6'd11;default:begin end endcase
  end else begin case(char_index)
   21:ch=6'd15;
22:ch=6'd16;
23:ch=6'd17;
24:ch=6'd18;
   28:ch=snap[83]?(snap[81]?6'd38:6'd38):6'd35;
   29:ch=snap[83]&&!snap[81]?6'd39:6'd36;
   30:ch=snap[83]&&!snap[81]?6'd40:6'd37;
   default:ch=6'd12;
  endcase end
 end else begin
  case(char_index)
   0:ch=6'd19;
1:ch=6'd20;
2:ch=6'd21;
3:ch=6'd22;
   5:begin
    if(!snap[82])ch=6'd35;else case(w[15:8])
    8'h00:ch=6'd23;8'h01,8'h02:ch=6'd24;8'h03:ch=6'd26;8'h45,8'h48:ch=6'd27;
    8'h71,8'h73,8'h75,8'h77,8'h85,8'h86:ch=6'd29;8'h95,8'h96,8'h99:ch=6'd30;default:ch=6'd28;endcase
   end
   6:if(!snap[82])ch=6'd36;else if(w[15:8]==8'h01||w[15:8]==8'h02)ch=6'd25;else if(w[15:8]>=8'h95)ch=6'd28;
   7:if(!snap[82])ch=6'd37;
   11:ch=6'd31;
12:ch=6'd32;
13:ch=6'd33;
14:ch=6'd34;
   16:ch=!snap[82]?6'd10:w[23:16]==45?6'd10:6'd13;
   17:ch=snap[82]?{2'd0,w[7:4]}:6'd10;18:ch=snap[82]?{2'd0,w[3:0]}:6'd10;19:ch=6'd14;
   28:ch=!snap[82]?6'd35:6'd38;29:ch=snap[82]&&!snap[80]?6'd39:6'd36;30:ch=snap[82]&&!snap[80]?6'd40:6'd37;
   default:ch=6'd12;
  endcase
 end
 end
 wire icon_here=x>=560 && x<592 && y>=432 && y<464 && snap[82] && snap[80];
 wire [4:0] icon_x=x-12'd560,icon_y=y-12'd432;
 reg [5:0] icon_char;reg [23:0] icon_colour;
 always @* begin
  icon_colour=24'h8fd3ef;
  case(w[15:8])
   8'h00:begin icon_char=41;icon_colour=24'hffd366;end
   8'h01,8'h02:icon_char=42;
   8'h03:icon_char=43;
   8'h45,8'h48:icon_char=44;
   8'h71,8'h73,8'h75,8'h77,8'h85,8'h86:begin icon_char=46;icon_colour=24'heaf4ef;end
   8'h95,8'h96,8'h99:begin icon_char=47;icon_colour=24'hffd366;end
   default:icon_char=45;
  endcase
 end
 wire [13:0] font_addr=icon_here?{icon_char,icon_y[4:1],icon_x[4:1]}:{ch,y[3:0],x[3:0]};
 reg icon_q;reg [23:0] colour_q;
 always @(posedge clk)begin icon_q<=icon_here;colour_q<=icon_colour;end
 reg font[0:16383];reg ink_q;
 initial $readmemh("C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/environment_pixels.hex",font);
 always @(posedge clk)ink_q<=font[font_addr];
 reg panel_q,text_q;reg [3:0] col_q;reg [23:0] rgb_q;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin hs_out<=0;vs_out<=0;de_out<=0;x_out<=0;y_out<=0;panel_q<=0;text_q<=0;col_q<=0;rgb_q<=0;end
 else begin
  hs_out<=hs_in;vs_out<=vs_in;de_out<=de_in;x_out<=x;y_out<=y;rgb_q<=rgb_in;col_q<=x[3:0];
  panel_q<=enabled&&de_in&&x>=8&&x<632&&y>=428&&y<468;
  text_q<=x>=16&&x<624&&y>=432&&y<464;
 end
 assign rgb_out=panel_q?(text_q&&ink_q?(icon_q?colour_q:24'heaf4ef):24'h143042):rgb_q;
endmodule

// One outstanding request, acknowledged only after the destination state changes.
module remote_media_control #(parameter TIMEOUT_CYCLES=100000000)(
 input clk,rst_n,input [3:0] request,output reg [10:0] reply,
 input suspend,blocked,input [3:0] image_complete,input [2:0] display_state,
 input auto_enabled,muted_applied,input [7:0] brightness,
 output reg muted,next_event,prev_event,auto_valid,auto_value,output wire busy);
 reg [1:0] state;reg seen;reg [2:0] command;reg [1:0] old_index;reg [26:0] age;
 wire multiple=(image_complete & (image_complete-4'd1))!=0;
 wire [9:0] status={1'b0,brightness[6:0],auto_enabled,muted_applied};
 assign busy=state!=0 || request[3]!=seen;
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin reply<=0;state<=0;seen<=0;command<=0;old_index<=0;age<=0;muted<=0;next_event<=0;prev_event<=0;auto_valid<=0;auto_value<=0;end
 else begin
  next_event<=0;prev_event<=0;auto_valid<=0;
  if(state==0 && request[3]!=seen)begin
   seen<=request[3];command<=request[2:0];age<=0;old_index<=display_state[1:0];
   case(request[2:0])
    0:reply<={request[3],status};
    1,2:begin muted<=request[2:0]==1;state<=1;end
    3,4:begin auto_value<=request[2:0]==3;auto_valid<=1;state<=1;end
    5,6:if(suspend || blocked || !display_state[2] || !multiple) reply<={request[3],(status | 10'd512)};
        else begin next_event<=request[2:0]==5;prev_event<=request[2:0]==6;state<=1;end
    default:reply<={request[3],(status | 10'd512)};
   endcase
  end else if(state==1)begin
   age<=age+1'b1;
   if(((command==1 || command==2) && muted_applied==(command==1)) ||
      ((command==3 || command==4) && auto_enabled==(command==3)) ||
      ((command==5 || command==6) && !suspend && display_state[1:0]!=old_index && !blocked))begin
    reply<={seen,status};state<=0;
   end else if(age>=TIMEOUT_CYCLES-1 || ((command==5 || command==6) && suspend))begin
    reply<={seen,(status | 10'd512)};state<=0;
   end
  end
 end
endmodule

// Two-stage, 3-channel gain pipeline. Sync signals have identical latency.
// Gain is 0..256; 100% is bit-exact passthrough. Changes latch on vertical blank.
module remote_video_brightness(input clk,rst_n,input [7:0] percent,output reg [7:0] applied,
 input hs_in,vs_in,de_in,input [23:0] rgb_in,output wire hs_out,vs_out,de_out,output wire [23:0] rgb_out);
 reg [8:0] gain;reg vs_previous;
 reg [16:0] red,green,blue;reg [1:0] hp,vp,dp;reg [23:0] rgb;
 function [8:0] brightness_gain;input [7:0] value;begin case(value)
8'd0:brightness_gain=9'd0;
8'd1:brightness_gain=9'd3;
8'd2:brightness_gain=9'd5;
8'd3:brightness_gain=9'd8;
8'd4:brightness_gain=9'd10;
8'd5:brightness_gain=9'd13;
8'd6:brightness_gain=9'd15;
8'd7:brightness_gain=9'd18;
8'd8:brightness_gain=9'd20;
8'd9:brightness_gain=9'd23;
8'd10:brightness_gain=9'd26;
8'd11:brightness_gain=9'd28;
8'd12:brightness_gain=9'd31;
8'd13:brightness_gain=9'd33;
8'd14:brightness_gain=9'd36;
8'd15:brightness_gain=9'd38;
8'd16:brightness_gain=9'd41;
8'd17:brightness_gain=9'd44;
8'd18:brightness_gain=9'd46;
8'd19:brightness_gain=9'd49;
8'd20:brightness_gain=9'd51;
8'd21:brightness_gain=9'd54;
8'd22:brightness_gain=9'd56;
8'd23:brightness_gain=9'd59;
8'd24:brightness_gain=9'd61;
8'd25:brightness_gain=9'd64;
8'd26:brightness_gain=9'd67;
8'd27:brightness_gain=9'd69;
8'd28:brightness_gain=9'd72;
8'd29:brightness_gain=9'd74;
8'd30:brightness_gain=9'd77;
8'd31:brightness_gain=9'd79;
8'd32:brightness_gain=9'd82;
8'd33:brightness_gain=9'd84;
8'd34:brightness_gain=9'd87;
8'd35:brightness_gain=9'd90;
8'd36:brightness_gain=9'd92;
8'd37:brightness_gain=9'd95;
8'd38:brightness_gain=9'd97;
8'd39:brightness_gain=9'd100;
8'd40:brightness_gain=9'd102;
8'd41:brightness_gain=9'd105;
8'd42:brightness_gain=9'd108;
8'd43:brightness_gain=9'd110;
8'd44:brightness_gain=9'd113;
8'd45:brightness_gain=9'd115;
8'd46:brightness_gain=9'd118;
8'd47:brightness_gain=9'd120;
8'd48:brightness_gain=9'd123;
8'd49:brightness_gain=9'd125;
8'd50:brightness_gain=9'd128;
8'd51:brightness_gain=9'd131;
8'd52:brightness_gain=9'd133;
8'd53:brightness_gain=9'd136;
8'd54:brightness_gain=9'd138;
8'd55:brightness_gain=9'd141;
8'd56:brightness_gain=9'd143;
8'd57:brightness_gain=9'd146;
8'd58:brightness_gain=9'd148;
8'd59:brightness_gain=9'd151;
8'd60:brightness_gain=9'd154;
8'd61:brightness_gain=9'd156;
8'd62:brightness_gain=9'd159;
8'd63:brightness_gain=9'd161;
8'd64:brightness_gain=9'd164;
8'd65:brightness_gain=9'd166;
8'd66:brightness_gain=9'd169;
8'd67:brightness_gain=9'd172;
8'd68:brightness_gain=9'd174;
8'd69:brightness_gain=9'd177;
8'd70:brightness_gain=9'd179;
8'd71:brightness_gain=9'd182;
8'd72:brightness_gain=9'd184;
8'd73:brightness_gain=9'd187;
8'd74:brightness_gain=9'd189;
8'd75:brightness_gain=9'd192;
8'd76:brightness_gain=9'd195;
8'd77:brightness_gain=9'd197;
8'd78:brightness_gain=9'd200;
8'd79:brightness_gain=9'd202;
8'd80:brightness_gain=9'd205;
8'd81:brightness_gain=9'd207;
8'd82:brightness_gain=9'd210;
8'd83:brightness_gain=9'd212;
8'd84:brightness_gain=9'd215;
8'd85:brightness_gain=9'd218;
8'd86:brightness_gain=9'd220;
8'd87:brightness_gain=9'd223;
8'd88:brightness_gain=9'd225;
8'd89:brightness_gain=9'd228;
8'd90:brightness_gain=9'd230;
8'd91:brightness_gain=9'd233;
8'd92:brightness_gain=9'd236;
8'd93:brightness_gain=9'd238;
8'd94:brightness_gain=9'd241;
8'd95:brightness_gain=9'd243;
8'd96:brightness_gain=9'd246;
8'd97:brightness_gain=9'd248;
8'd98:brightness_gain=9'd251;
8'd99:brightness_gain=9'd253;
default:brightness_gain=9'd256;endcase end endfunction
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin gain<=256;applied<=100;vs_previous<=1;red<=0;green<=0;blue<=0;hp<=0;vp<=0;dp<=0;rgb<=0;end
 else begin
  vs_previous<=vs_in;
  if(vs_previous && !vs_in)begin gain<=brightness_gain(percent);applied<=percent>=100?8'd100:percent;end
  red<=rgb_in[23:16]*gain;green<=rgb_in[15:8]*gain;blue<=rgb_in[7:0]*gain;
  rgb<={red[15:8],green[15:8],blue[15:8]};hp<={hp[0],hs_in};vp<={vp[0],vs_in};dp<={dp[0],de_in};
 end
 assign rgb_out=rgb;assign hs_out=hp[1];assign vs_out=vp[1];assign de_out=dp[1];
endmodule

// ADS1115 0x48, AIN0/GND, +/-4.096V, 128 SPS, comparator disabled.
// Both bus lines are open-drain and require external pull-ups to 3.3V.
module ads1115_light #(parameter CLK_HZ=50000000, I2C_HZ=100000,
 parameter SAMPLE_CYCLES=5000000, BUS_TIMEOUT=1000000)(
 input clk,rst_n,inout scl,sda,output reg [15:0] sample,
 output reg sample_valid,output reg healthy);
 // I2C_HZ is the bus ceiling. 5us phases at 100kHz give ~66.7kHz data clocks,
 // with >=5us START/STOP setup/hold and >=5us SCL high.
 localparam DIV=CLK_HZ/(I2C_HZ*2);
 localparam ADW=(DIV<2)?1:$clog2(DIV);
 reg [ADW-1:0] divider;wire tick=divider==DIV-1;
 reg scl_low,sda_low;assign scl=scl_low?1'b0:1'bz;assign sda=sda_low?1'b0:1'bz;
 (* async_reg="true" *) reg scl1,scl2,sda1,sda2;
 reg [4:0] state;reg [2:0] byte_no,bit_no;reg [7:0] tx,rx;
 reg [15:0] result;reg [1:0] transaction; // 0 config write, 1 OS poll, 2 ADC read
 localparam AGE_W=(BUS_TIMEOUT<2)?1:$clog2(BUS_TIMEOUT);
 localparam WAIT_MAX=(SAMPLE_CYCLES>CLK_HZ/1000)?SAMPLE_CYCLES:CLK_HZ/1000;
 localparam WAIT_W=(WAIT_MAX<2)?1:$clog2(WAIT_MAX);
 reg [AGE_W-1:0] age;reg [WAIT_W-1:0] wait_count;reg [4:0] polls;reg [3:0] recovery;
 reg failed;
 function [7:0] next_byte;input [2:0] n;input [1:0] kind;
 begin case(n)0:next_byte=8'h90;1:next_byte=kind==2?8'h00:8'h01;2:next_byte=kind==0?8'hc3:8'h91;default:next_byte=8'h83;endcase end endfunction
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin divider<=0;scl1<=1;scl2<=1;sda1<=1;sda2<=1;end
 else begin scl1<=scl;scl2<=scl1;sda1<=sda;sda2<=sda1;if(tick)divider<=0;else divider<=divider+1'b1;end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin state<=0;scl_low<=0;sda_low<=0;sample<=0;sample_valid<=0;healthy<=0;transaction<=0;age<=0;wait_count<=0;polls<=0;byte_no<=0;bit_no<=7;tx<=0;rx<=0;result<=0;recovery<=0;failed<=0;end
 else begin
 sample_valid<=0;
 if(state==0)begin
  age<=0;scl_low<=0;sda_low<=0;
  if(wait_count<SAMPLE_CYCLES-1)wait_count<=wait_count+1'b1;
  else begin wait_count<=0;transaction<=0;polls<=0;failed<=0;recovery<=0;state<=20;end
 end else if(state==19)begin
  age<=0;
  if(wait_count<CLK_HZ/1000-1)wait_count<=wait_count+1'b1;
  else begin wait_count<=0;byte_no<=0;tx<=8'h90;bit_no<=7;state<=1;end
 end else if(age>=BUS_TIMEOUT-1)begin
  healthy<=0;state<=0;wait_count<=0;scl_low<=0;sda_low<=0;age<=0;
 end else begin
 age<=age+1'b1;
 if(tick)case(state)
  20:begin // Clear a slave left mid-byte after FPGA reset (nine clocks then STOP).
   sda_low<=0;scl_low<=1;state<=21;
  end
  21:begin scl_low<=0;state<=22;end
  22:if(scl2)begin if(recovery==8)begin scl_low<=1;sda_low<=1;state<=23;end else begin recovery<=recovery+1'b1;state<=20;end end
  23:begin scl_low<=0;state<=24;end
  24:if(scl2)begin sda_low<=0;state<=25;end
  25:if(sda2 && scl2)begin byte_no<=0;tx<=8'h90;bit_no<=7;state<=1;age<=0;end
  1:begin scl_low<=0;sda_low<=0;if(scl2 && sda2)state<=2;end
  2:begin sda_low<=1;state<=3;end
  3:begin scl_low<=1;state<=4;end
  4:begin sda_low<=!tx[bit_no];state<=5;end
  5:begin scl_low<=0;state<=6;end
  6:if(scl2)begin scl_low<=1;if(bit_no==0)state<=7;else begin bit_no<=bit_no-1'b1;state<=4;end end
  7:begin sda_low<=0;state<=8;end
  8:begin scl_low<=0;state<=9;end
  9:if(scl2)begin
   scl_low<=1;
   if(sda2)begin failed<=1;state<=16;end
   else if(transaction==0 && byte_no==3)state<=16;
   else if(transaction!=0 && byte_no==2)begin bit_no<=7;rx<=0;byte_no<=0;state<=10;end
   else begin byte_no<=byte_no+1'b1;tx<=next_byte(byte_no+1'b1,transaction);bit_no<=7;
    if(transaction!=0 && byte_no==1)state<=1;else state<=4;
   end
  end
  10:begin sda_low<=0;state<=11;end
  11:begin scl_low<=0;state<=12;end
  12:if(scl2)begin rx<={rx[6:0],sda2};scl_low<=1;if(bit_no==0)state<=13;else begin bit_no<=bit_no-1'b1;state<=10;end end
  13:begin sda_low<=byte_no==0;state<=14;end
  14:begin scl_low<=0;state<=15;end
  15:if(scl2)begin scl_low<=1;result<={result[7:0],rx};if(byte_no==1)state<=16;else begin byte_no<=1;bit_no<=7;state<=10;end end
  16:begin scl_low<=1;sda_low<=1;state<=17;end
  17:begin scl_low<=0;state<=18;end
  18:if(scl2)begin sda_low<=0;state<=26;end
  26:begin
   if(failed)begin healthy<=0;state<=0;wait_count<=0;end
   else if(transaction==0)begin transaction<=1;state<=19;wait_count<=0;end
   else if(transaction==1)begin
    if(result[15])begin transaction<=2;state<=19;wait_count<=0;end
    else if(polls==19)begin healthy<=0;state<=0;wait_count<=0;end
    else begin polls<=polls+1'b1;state<=19;wait_count<=0;end
   end else begin sample<=result;sample_valid<=1;healthy<=1;state<=0;wait_count<=0;end
  end
  default:state<=0;
 endcase
 end
 end
endmodule

// AO is assumed to fall as illumination rises; reverse with BRIGHT_LOW=0.
// Defaults span approx 0.25..3.0V. Tune endpoints after measuring the actual sensor.
module ambient_brightness #(parameter CLK_HZ=50000000,STEP_CYCLES=2500000,
 parameter BRIGHT_LOW=1, parameter [15:0] LOW_CODE=2000,HIGH_CODE=24000)(
 input clk,rst_n,auto_mode,healthy,sample_valid,input [15:0] sample,input [7:0] manual,
 output wire [7:0] brightness,output wire sensor_ok);
 reg [15:0] filtered;reg initialized;localparam STALE_W=$clog2(CLK_HZ+1),STEP_W=(STEP_CYCLES<2)?1:$clog2(STEP_CYCLES);
 reg sample_fresh;
 reg [STALE_W-1:0] stale;reg [STEP_W-1:0] step_count;reg [7:0] smooth,target;
 wire [15:0] safe_sample=sample[15]?16'd0:sample;
 assign sensor_ok=healthy && initialized && sample_fresh;
 assign brightness=auto_mode?(sensor_ok?smooth:8'd100):manual;
 wire [15:0] level=BRIGHT_LOW?(filtered>=HIGH_CODE?16'd0:HIGH_CODE-filtered):(filtered<=LOW_CODE?16'd0:filtered-LOW_CODE);
 reg [7:0] mapped;
 always @* begin
  // Ten monotonic bands avoid a hardware divider/multiplier.
  if(level>=(HIGH_CODE-LOW_CODE))mapped=100;
  else if(level>=(HIGH_CODE-LOW_CODE)*9/10)mapped=93;
  else if(level>=(HIGH_CODE-LOW_CODE)*8/10)mapped=85;
  else if(level>=(HIGH_CODE-LOW_CODE)*7/10)mapped=78;
  else if(level>=(HIGH_CODE-LOW_CODE)*6/10)mapped=70;
  else if(level>=(HIGH_CODE-LOW_CODE)*5/10)mapped=63;
  else if(level>=(HIGH_CODE-LOW_CODE)*4/10)mapped=55;
  else if(level>=(HIGH_CODE-LOW_CODE)*3/10)mapped=48;
  else if(level>=(HIGH_CODE-LOW_CODE)*2/10)mapped=40;
  else if(level>=(HIGH_CODE-LOW_CODE)/10)mapped=33;
  else mapped=25;
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin sample_fresh<=0;filtered<=0;initialized<=0;stale<=CLK_HZ;step_count<=0;smooth<=100;target<=100;end
 else begin
  if(stale<CLK_HZ)stale<=stale+1'b1;
  if(stale==CLK_HZ-1)sample_fresh<=0;
  if(!healthy)initialized<=0;
  if(sample_valid)begin
   stale<=0;sample_fresh<=1;initialized<=1;
   if(!initialized)filtered<=safe_sample;
   else if(safe_sample>filtered)filtered<=filtered+((safe_sample-filtered+16'd3)>>2);
   else filtered<=filtered-((filtered-safe_sample+16'd3)>>2);
  end
  if(!sensor_ok)begin smooth<=100;target<=100;step_count<=0;end
  else begin
   if(mapped>target+2 || mapped+2<target)target<=mapped;
   if(step_count==STEP_CYCLES-1)begin step_count<=0;if(smooth<target)smooth<=smooth+1'b1;else if(smooth>target)smooth<=smooth-1'b1;end
   else step_count<=step_count+1'b1;
  end
 end
endmodule
