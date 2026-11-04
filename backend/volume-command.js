'use strict';
const {getAuthorization}=require('./onenet-auth');
// Official API: https://open.iot.10086.cn/doc/v5/fuse/detail/1436
function createVolumeSender(env=process.env, fetchImpl=fetch){
 let busy=false;
 return async (value,kind='volume')=>{
  if(!['volume','notice','query_notice','time','weather','control','brightness','auto_brightness'].includes(kind))throw new Error('不支持的命令类型');
  if(kind==='notice' && typeof value!=='boolean')throw new Error('通知开关必须为布尔值');
  if(kind==='control' && (!Number.isInteger(value)||value<0||value>6))throw Error('无效控制命令');
  if(kind==='auto_brightness' && typeof value!=='boolean')throw Error('自动亮度开关必须为布尔值');
  const sync=kind==='time'||kind==='weather';
  if(sync && !(kind==='time'?/^TIME=20[0-9]{12}$/:/^WX=[0-9]{2}[+-][0-9]{2}$/).test(value))throw new Error('Invalid environment command');
  const isNotice=kind==='notice'||kind==='query_notice';
  if(!sync && !isNotice && kind!=='control' && kind!=='auto_brightness' && (!Number.isInteger(value)||value<0||value>100))throw new Error('数值必须为0到100的整数');
  if(busy){const e=new Error('上一条命令仍在等待设备应答');e.status=409;throw e;}
  const authorization=getAuthorization(env);
  const expiry=Number(new URLSearchParams(authorization || '').get('et'));
  if(!authorization || !Number.isFinite(expiry) || expiry<=Date.now()/1000)throw new Error('OneNet Token 缺失或已过期，请更新调试文件并重启后端');
  if(!env.ONENET_PRODUCT_ID||!env.ONENET_DEVICE_NAME)throw new Error('缺少产品ID或设备名称');
  busy=true;
  try{
   const url=new URL('https://iot-api.heclouds.com/datapoint/synccmds');
   url.search=new URLSearchParams({product_id:env.ONENET_PRODUCT_ID,device_name:env.ONENET_DEVICE_NAME,timeout:'5'}).toString();
   let r;
   try{r=await fetchImpl(url,{method:'POST',headers:{Authorization:authorization,'Content-Type':'text/plain; charset=utf-8'},body:kind==='auto_brightness' ? (value?'AUT=001':'AUT=000') : kind==='control' ? 'CTL=00'+value : kind==='brightness' ? 'BRI='+String(value).padStart(3,'0') : sync ? value : isNotice ? (kind==='query_notice'?'FIND=02':value?'FIND=01':'FIND=00') : 'VOL='+String(value).padStart(3,'0'),signal:AbortSignal.timeout(7000),redirect:'error'});}
   catch(e){throw new Error('命令请求超时或网络异常，执行结果未知，请查询设备状态确认');}
   if(!r.ok)throw new Error('OneNet 命令接口 HTTP '+r.status+'，未确认设备执行');
   let data;try{data=await r.json();}catch(e){throw new Error('OneNet 命令返回格式错误，未确认设备执行');}
   if(data.code!==0)throw new Error('OneNet 命令失败，错误码 '+String(data.code)+'；请确认已烧录对应功能工程、设备在线且Token有效');
   let reply;
   try{reply=JSON.parse(Buffer.from(data.data.cmd_resp,'base64').toString('utf8'));}catch(e){throw new Error('未收到有效的 FPGA 音量执行应答');}
   if(kind==='control'){
    const v2=Number.isInteger(reply.ctrlv2);const raw=v2?reply.ctrlv2:reply.ctrlst;
    const n=v2?(raw&1023):raw;
    if(v2 && (raw<0||raw>4095))throw Error('FPGA 控制应答范围错误');
    if(reply.ok!==true || !Number.isInteger(n) || n<0 || n>915 || ((n>>2)&127)>100)throw Error('FPGA 控制应答格式错误');
    if(n&512)throw Error('设备未确认完成：报警占用画面、切换忙碌、图片尚未就绪或执行超时，请稍后重试');
    const muted=!!(n&1),autoPlay=!!(n&2);
    if((value===1&&!muted)||(value===2&&muted)||(value===3&&!autoPlay)||(value===4&&autoPlay))throw Error('设备控制状态与目标不一致');
    return {simulated:false,status:'executed',muted,autoPlay,brightness:(n>>2)&127,autoBrightnessSupported:v2,autoBrightness:v2?!!(raw&1024):false,lightSensorOk:v2?!!(raw&2048):null};
   }
   if(kind==='auto_brightness'){
    if(reply.ok!==true||![0,1,2,3].includes(reply.autobr)||!!(reply.autobr&1)!==value)throw Error('设备未确认自动亮度模式');
    return {simulated:false,status:'executed',autoBrightness:value,autoBrightnessSupported:true,lightSensorOk:!!(reply.autobr&2)};
   }
   if(kind==='brightness'){
    if(reply.ok!==true || reply.bright!==value)throw Error('设备亮度应答与目标不一致');
    return {simulated:false,status:'executed',brightness:value,autoBrightness:false};
   }
   if(sync){if(reply.ok!==true||reply.synced!==(kind==='time'?1:2))throw new Error('FPGA environment acknowledgement mismatch');return {status:'executed',command:kind};}
   if(isNotice){
    if(reply.ok!==true || ![0,1].includes(reply.notice) || (kind==='notice' && reply.notice!==Number(value)))throw new Error('FPGA 通知应答与目标不一致，未确认执行成功');
    return {simulated:false,status:'executed',command:kind==='notice'?'set_child_notice':'get_child_notice',notice:!!reply.notice,commandId:data.data.cmd_uuid};
   }
   if(reply.ok!==true || reply.volume!==value)throw new Error('FPGA 应答音量与目标不一致，未确认执行成功');
   return {simulated:false,status:'executed',command:'set_volume',volume:reply.volume,commandId:data.data.cmd_uuid};
  }finally{busy=false;}
 };
}
module.exports={createVolumeSender};