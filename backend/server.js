'use strict';
const http = require('node:http');
const crypto = require('node:crypto');
const {createReader}=require('./onenet');
const {createVolumeSender}=require('./volume-command');
const {createEnvironmentSync,prioritizeCommands}=require('./environment-sync');
const COMMANDS = new Set(['set_child_notice','get_child_notice','set_volume','set_mute','next_image','prev_image','set_auto_play','set_brightness','set_auto_brightness']);
function validateCommand(body) {
 if(!body || typeof body!=='object' || !COMMANDS.has(body.command)) return '不支持的命令';
 if(['set_volume','set_brightness'].includes(body.command) && (!Number.isInteger(body.value) || body.value<0 || body.value>100))return '数值必须为0到100的整数';
 if(['set_mute','set_auto_play','set_child_notice','set_auto_brightness'].includes(body.command) && typeof body.value!=='boolean')return '开关参数必须为布尔值';
 return null;
}
function createServer({token,mode='real',readStatus=createReader(),sendVolume=createVolumeSender(),environment=null}={}) {
 if(!token)throw new Error('必须设置 DEMO_ACCESS_TOKEN');
 const state={notice:false,volume:50,muted:false,autoPlay:false,brightness:100,autoBrightness:false,autoBrightnessSupported:true,lightSensorOk:true};
 return http.createServer(async(req,res)=>{
  const respond=(code,data)=>{res.writeHead(code,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'});res.end(JSON.stringify(data));};
  if(req.url==='/health' && req.method==='GET')return respond(200,{ok:true,mode});
  const actual=Buffer.from(req.headers.authorization || ''), expected=Buffer.from('Bearer '+token);
  if(actual.length!==expected.length || !crypto.timingSafeEqual(actual,expected))return respond(401,{error:'后端访问口令不正确'});
  if(req.url==='/api/environment' && req.method==='GET')return respond(200,environment?environment.status():{enabled:false});
  if(req.url==='/api/device/status' && req.method==='GET'){
   if(mode!=='mock'){try{
    const results=await Promise.allSettled([readStatus(),sendVolume(0,'control')]);
    if(results[0].status==='rejected')throw results[0].reason;
    const c=results[1];
    return respond(200,{...results[0].value,controlsEnabled:c.status==='fulfilled',brightnessControlEnabled:c.status==='fulfilled',
     ...(c.status==='fulfilled'?{muted:c.value.muted,autoPlay:c.value.autoPlay,brightness:c.value.brightness,autoBrightness:c.value.autoBrightness,autoBrightnessSupported:c.value.autoBrightnessSupported,lightSensorOk:c.value.lightSensorOk,controlsError:''}:{controlsError:c.reason.message})});
   }catch(e){return respond(e.status || 502,{error:e.message});}}
   return respond(200,{mode:'mock',temperature:25,humidity:51,updatedAt:new Date().toISOString(),controlsEnabled:true,...state});
  }
  if(req.url==='/api/device/commands' && req.method==='POST'){
   let text='',size=0;
   try{
    for await(const chunk of req){size+=chunk.length;if(size>2048){respond(413,{error:'请求过大'});return;}text+=chunk.toString();}
    const body=JSON.parse(text),error=validateCommand(body);
    if(error)return respond(400,{error});
    if(mode!=='mock'){
     const codes={set_mute:body.value?1:2,set_auto_play:body.value?3:4,next_image:5,prev_image:6};
     if(body.command in codes){try{return respond(200,{...await sendVolume(codes[body.command],'control'),command:body.command});}catch(e){return respond(e.status||502,{error:e.message});}}
     if(body.command==='set_auto_brightness'){try{return respond(200,{...await sendVolume(body.value,'auto_brightness'),command:body.command});}catch(e){return respond(e.status||502,{error:e.message});}}
     if(body.command==='set_brightness'){try{return respond(200,{...await sendVolume(body.value,'brightness'),command:body.command});}catch(e){return respond(e.status||502,{error:e.message});}}
     try{return respond(200,await sendVolume(body.value,body.command==='set_child_notice'?'notice':body.command==='get_child_notice'?'query_notice':'volume'));}catch(e){return respond(e.status || 502,{error:e.message});}
    }
    if(body.command==='set_child_notice')state.notice=body.value;
    if(body.command==='get_child_notice' || body.command==='set_child_notice')return respond(200,{simulated:true,status:'simulated',command:body.command,notice:state.notice});
    if(body.command==='set_volume')state.volume=body.value;
    if(body.command==='set_brightness'){state.brightness=body.value;state.autoBrightness=false;}
    if(body.command==='set_auto_brightness')state.autoBrightness=body.value;
    if(body.command==='set_mute')state.muted=body.value;
    if(body.command==='set_auto_play')state.autoPlay=body.value;
    return respond(200,{simulated:true,status:'simulated',command:body.command});
   }catch(e){return respond(400,{error:'请求必须是有效JSON'});}
  }
  respond(404,{error:'接口不存在'});
 });
}
if(require.main===module){
 const token=process.env.DEMO_ACCESS_TOKEN;
 if(!token){console.error('请先设置 DEMO_ACCESS_TOKEN，再启动。');process.exit(1);}
 const mode=process.env.MODE || 'real';
 if(!['real','mock'].includes(mode)){console.error('MODE只能是real或mock');process.exit(1);}
 const sendVolume=prioritizeCommands(createVolumeSender());
 const environment=mode==='real'?createEnvironmentSync({send:sendVolume}):null;
 createServer({token,mode,sendVolume,environment}).listen(Number(process.env.PORT || 3000),'0.0.0.0',()=>{if(environment)environment.start();console.log('后端已启动，端口 '+(process.env.PORT || 3000)+'，模式 '+mode+'。模拟数据不来自FPGA。');});
}
module.exports={createServer,validateCommand};
