const {beijingTime,weatherView}=require('../../utils/environment');
const {request} = require('../../utils/api');
function formatBeijingTime(value) {
 const timestamp = Date.parse(value);
 if (!Number.isFinite(timestamp)) return '--';
 const date = new Date(timestamp + 8 * 60 * 60 * 1000);
 const pad = n => String(n).padStart(2, '0');
 return date.getUTCFullYear() + '-' + pad(date.getUTCMonth() + 1) + '-' + pad(date.getUTCDate()) + ' ' + pad(date.getUTCHours()) + ':' + pad(date.getUTCMinutes()) + ':' + pad(date.getUTCSeconds());
}
Page({
 data:{connecting:false,connectionError:'',showConnection:false,showWeatherDetails:false,fireActive:false,fireAcknowledged:false,fireMessage:'等待火灾状态',fireVibrationError:'',beijingNow:'--',clockSource:'本机时间 · 北京时区',weatherText:'等待天气数据',weatherIcon:'—',outdoorTemperature:'--',weatherUpdatedAt:'--',weatherFetchedAt:'--',weatherFreshness:'尚无天气数据',environmentError:'',noticeState:'状态尚未查询',noticeBusy:false,baseUrl:'http://127.0.0.1:3000',accessToken:'',connection:'尚未连接',mode:'',temperature:'--',humidity:'--',updatedAt:'--',freshness:'尚无数据',volume:50,actualVolume:null,volumeControlEnabled:false,autoBrightness:false,autoBrightnessSupported:false,lightSensorOk:null,brightness:100,actualBrightness:null,brightnessControlEnabled:false,controlsError:'',muted:false,autoPlay:false,controlsEnabled:false,busy:false,error:'',commandStatus:'尚未发送命令'},
 onLoad(){this.setData({showConnection:!wx.getStorageSync('backendUrl'),baseUrl:wx.getStorageSync('backendUrl') || this.data.baseUrl,accessToken:wx.getStorageSync('backendToken') || ''});},
 onShow(){this.active=true;this.updateClock();clearInterval(this.clockTimer);this.clockTimer=setInterval(()=>this.updateClock(),1000);this.refresh();this.refreshEnvironment();},
 onHide(){this.stop();},
 onUnload(){this.stop();},
 stop(){this.active=false;clearTimeout(this.timer);clearTimeout(this.environmentTimer);clearInterval(this.clockTimer);clearInterval(this.fireTimer);},
 toggleConnection(){this.setData({showConnection:!this.data.showConnection});},
 toggleWeatherDetails(){this.setData({showWeatherDetails:!this.data.showWeatherDetails});},
 onAddress(e){this.setData({baseUrl:e.detail.value});},
 onToken(e){this.setData({accessToken:e.detail.value});},
 connect(){
  if(this.data.connecting)return;
  const baseUrl=this.data.baseUrl.trim().replace(/\/+$/,'');
  if(!/^https?:\/\/[^\s/]+$/.test(baseUrl)){wx.showToast({title:'请输入正确后端地址',icon:'none'});return;}
  clearInterval(this.fireTimer);this.lastFireVibration=0;this.setData({fireActive:false,fireAcknowledged:false,fireMessage:'等待火灾状态',fireVibrationError:''});this.volumeAckAt=0;this.dragging=false;this.setData({noticeState:'状态尚未查询'});
  this.setData({baseUrl,connecting:true,connectionError:'',connection:'正在连接…',error:'',controlsEnabled:false,brightnessControlEnabled:false,actualBrightness:null,volumeControlEnabled:false,actualVolume:null});
  wx.setStorageSync('backendUrl',baseUrl);wx.setStorageSync('backendToken',this.data.accessToken);
  this.environmentGeneration=(this.environmentGeneration||0)+1;this.environmentWeather=null;this.clockOffset=0;this.clockSyncedAt=0;this.setData({...weatherView(null,Date.now()),environmentError:''});this.updateClock();
  this.refresh(true);this.refreshEnvironment();
 },
 updateClock(){
  const now=Date.now()+(this.clockOffset||0);
  this.setData({beijingNow:beijingTime(now),clockSource:!this.clockSyncedAt?'本机时间 · 北京时区':Date.now()-this.clockSyncedAt>60000?'后端校时已中断 · 本地继续走时':'北京时间 · 后端已校时',...(this.environmentWeather?weatherView(this.environmentWeather,now):{})});
 },
 async refreshEnvironment(){
  clearTimeout(this.environmentTimer);if(!this.active)return;
  const generation=this.environmentGeneration||0,url=this.data.baseUrl,token=this.data.accessToken;
  if(this.environmentLoading===generation)return;this.environmentLoading=generation;
  const current=()=>this.active&&generation===(this.environmentGeneration||0)&&url===this.data.baseUrl&&token===this.data.accessToken;
  try{
   const e=await request(url,token,'/api/environment');if(!current())return;
   const serverTime=Date.parse(e.serverTime);if(Number.isFinite(serverTime)){this.clockOffset=serverTime-Date.now();this.clockSyncedAt=Date.now();}
   this.environmentWeather=e.weather||null;
   this.setData({...weatherView(this.environmentWeather,Date.now()+(this.clockOffset||0)),environmentError:e.enabled===false?'当前后端未启用天气，请启动时间天气版后端':e.weatherError||(!e.weather?'等待后端获取福州天气':'')});this.updateClock();
  }catch(e){if(current())this.setData({environmentError:e.message==='HTTP 404'?'请启动时间天气版后端':e.message});}
  finally{if(this.environmentLoading===generation)this.environmentLoading=null;if(this.active){clearTimeout(this.environmentTimer);this.environmentTimer=setTimeout(()=>this.refreshEnvironment(),15000);}}
 },
 async refresh(manual=false){
  clearTimeout(this.timer);
  if((this.loading && !manual) || !this.active)return;
  const requestId=(this.statusRequestId||0)+1;this.statusRequestId=requestId;
  this.loading=true;
  const controlEpoch=this.controlEpoch||0;
  const url=this.data.baseUrl,token=this.data.accessToken;
  try{
   const s=await request(url,token,'/api/device/status');
   if(requestId!==this.statusRequestId || !this.active || url!==this.data.baseUrl || token!==this.data.accessToken)return;
   this.setData({connectionError:''});
   if(manual)wx.showToast({title:'后端已连接',icon:'success'});
   this.updateFire(s);
   const canUpdateControls=!this.data.busy && controlEpoch===(this.controlEpoch||0);
   const age=Date.now()-Date.parse(s.updatedAt);
   const reportedVolume=Number.isInteger(s.volume) && s.volume>=0 && s.volume<=100?s.volume:null;
   const canUpdateVolume=!this.data.busy && !this.dragging && (!this.volumeAckAt || Date.parse(s.volumeUpdatedAt)>=this.volumeAckAt || s.mode==='mock');
   this.setData({mode:s.mode,connection:s.mode==='mock'?'已连接模拟后端':'已连接后端（不等于设备在线）',temperature:s.temperature == null?'--':s.temperature,humidity:s.humidity == null?'--':s.humidity,updatedAt:formatBeijingTime(s.updatedAt),freshness:!Number.isFinite(age)?'时间未知':age>30000?'数据已过期':'数据较新',controlsEnabled:s.controlsEnabled===true,autoBrightnessSupported:s.mode==='mock'||s.autoBrightnessSupported===true,autoBrightness:canUpdateControls&&typeof s.autoBrightness==='boolean'?s.autoBrightness:this.data.autoBrightness,lightSensorOk:typeof s.lightSensorOk==='boolean'?s.lightSensorOk:null,controlsError:s.controlsError||'',brightnessControlEnabled:s.mode==='mock'||s.brightnessControlEnabled===true,actualBrightness:canUpdateControls&&Number.isInteger(s.brightness)?s.brightness:this.data.actualBrightness,brightness:canUpdateControls&&!this.brightnessDragging&&Number.isInteger(s.brightness)?s.brightness:this.data.brightness,error:'',volume:canUpdateVolume && reportedVolume!==null?reportedVolume:this.data.volume,actualVolume:canUpdateVolume?reportedVolume:this.data.actualVolume,volumeControlEnabled:s.mode==='mock' || s.volumeControlEnabled===true,muted:canUpdateControls&&typeof s.muted==='boolean'?s.muted:this.data.muted,autoPlay:canUpdateControls&&typeof s.autoPlay==='boolean'?s.autoPlay:this.data.autoPlay,autoBrightness:this.data.autoBrightness});
  }catch(e){if(requestId===this.statusRequestId && this.active && url===this.data.baseUrl && token===this.data.accessToken){this.updateFire({});this.setData({error:e.message,connectionError:e.message,connection:'连接失败',controlsEnabled:false,brightnessControlEnabled:false,volumeControlEnabled:false,freshness:'未能更新'});if(manual)wx.showToast({title:'连接失败，请查看下方提示',icon:'none'});}}
  finally{if(requestId===this.statusRequestId){this.loading=false;this.setData({connecting:false});if(this.active)this.timer=setTimeout(()=>this.refresh(),1000);}}
 },
 async send(command,value){
  if(this.data.busy || this.data.noticeBusy || !(command==='set_volume'?this.data.volumeControlEnabled:command==='set_brightness'?this.data.brightnessControlEnabled:this.data.controlsEnabled))return;
  this.controlEpoch=(this.controlEpoch||0)+1;
  this.setData({busy:true,commandStatus:'正在提交命令…'});
  const submittedAt=Date.now(),url=this.data.baseUrl,token=this.data.accessToken;
  try{
   const r=await request(url,token,'/api/device/commands','POST',{command,value});
   if(url!==this.data.baseUrl || token!==this.data.accessToken)return;
   if(!r.simulated && r.status==='executed' && command==='set_volume'){
    this.volumeAckAt=submittedAt;
    this.setData({actualVolume:r.volume,volume:r.volume,commandStatus:'FPGA 已确认音量：'+r.volume+'%'});
    }else if(!r.simulated && r.status==='executed'){
    const update={commandStatus:command==='set_brightness'?'FPGA 已确认亮度：'+r.brightness+'%':command==='next_image'?'FPGA 已切换下一张':command==='prev_image'?'FPGA 已切换上一张':'FPGA 已确认控制状态'};
    if(typeof r.autoBrightness==='boolean')update.autoBrightness=r.autoBrightness;
    if(typeof r.lightSensorOk==='boolean')update.lightSensorOk=r.lightSensorOk;
    if(typeof r.autoBrightnessSupported==='boolean')update.autoBrightnessSupported=r.autoBrightnessSupported;
    if(command==='set_auto_brightness')update.commandStatus=r.autoBrightness?'已开启亮度自适应':'已切换手动亮度';
    if(typeof r.muted==='boolean')update.muted=r.muted;
    if(typeof r.autoPlay==='boolean')update.autoPlay=r.autoPlay;
    if(Number.isInteger(r.brightness)){update.brightness=r.brightness;update.actualBrightness=r.brightness;}
    this.setData(update);
   }else this.setData({commandStatus:r.simulated?'模拟操作完成，未向 FPGA 下发':'命令已提交，尚未确认设备执行'});
  }catch(e){if(url===this.data.baseUrl && token===this.data.accessToken)this.setData({commandStatus:e.message});}
  finally{this.setData({busy:false,muted:this.data.muted,autoPlay:this.data.autoPlay});this.flushNoticeCancel();if(this.active)this.refresh();}
 },
 flushNoticeCancel(){if(this.cancelNoticeQueued && !this.data.busy && !this.data.noticeBusy){this.cancelNoticeQueued=false;this.noticeCommand({currentTarget:{dataset:{action:'off'}}});}},
 async noticeCommand(e){
  const action=e.currentTarget.dataset.action;
  if(action==='off' && (this.data.noticeBusy || this.data.busy)){this.cancelNoticeQueued=true;this.setData({noticeState:'取消已排队，当前命令结束后立即发送'});return;}
  if(this.data.noticeBusy || this.data.busy)return;
  if(action==='on' && this.data.busy){wx.showToast({title:'请等待当前命令完成',icon:'none'});return;}
  this.setData({noticeBusy:true,noticeState:'等待 FPGA 应答…'});
  const url=this.data.baseUrl,token=this.data.accessToken;
  const command=action==='query'?'get_child_notice':'set_child_notice';
  try{
   const r=await request(url,token,'/api/device/commands','POST',{command,value:action==='on'});
   if(url!==this.data.baseUrl || token!==this.data.accessToken)return;
   if(typeof r.notice!=='boolean' || (!r.simulated && r.status!=='executed'))throw new Error('未收到设备确认');
   this.setData({noticeState:(r.simulated?'模拟状态：':'FPGA 已确认：')+(r.notice?'寻人通知已开启（火灾时暂停）':'寻人通知已取消')});
  }catch(e){if(url===this.data.baseUrl && token===this.data.accessToken)this.setData({noticeState:e.message});}
  finally{this.setData({noticeBusy:false});this.flushNoticeCancel();}
 },
 updateFire(s){
  clearInterval(this.fireTimer);
  const age=Date.now()-Date.parse(s.fireUpdatedAt);
  this.fireFresh=typeof s.fire==='boolean' && Number.isFinite(age) && age>=-5000 && age<=30000;
  this.fireAt=Date.parse(s.fireUpdatedAt);
  if(!this.fireFresh){this.setData({fireMessage:this.data.fireActive?'火灾状态更新中断，请现场核实（未确认解除）':'火灾状态未知或已过期'});return;}
  if(!s.fire){this.setData({fireActive:false,fireAcknowledged:false,fireMessage:'未检测到火灾',fireVibrationError:''});return;}
  this.setData({fireActive:true,fireMessage:this.data.fireAcknowledged?'已确认提醒，火灾报警仍在持续':'火灾报警！请立即核实并处理'});
  if(!this.data.fireAcknowledged){this.vibrateFire();this.fireTimer=setInterval(()=>this.vibrateFire(),5000);}
 },
 vibrateFire(){
  if(!this.active || !this.fireFresh || !this.data.fireActive || this.data.fireAcknowledged || Date.now()-this.fireAt>30000)return;
  if(this.lastFireVibration && Date.now()-this.lastFireVibration<4500)return;
  this.lastFireVibration=Date.now();
  wx.vibrateLong({type:'heavy',fail:()=>{if(this.active)this.setData({fireVibrationError:'手机未能震动，请查看屏幕报警提示'});}});
 },
 acknowledgeFire(){
  if(!this.data.fireActive)return;
  clearInterval(this.fireTimer);this.setData({fireAcknowledged:true,fireMessage:'已确认提醒，火灾报警仍在持续'});
 },
 onVolumeChanging(e){this.dragging=true;this.setData({volume:e.detail.value});},
 onVolume(e){this.dragging=false;this.setData({volume:e.detail.value});this.send('set_volume',e.detail.value);},
 onAutoBrightness(e){this.send('set_auto_brightness',e.detail.value);},
 onBrightnessChanging(e){this.brightnessDragging=true;this.setData({brightness:e.detail.value});},
 onBrightness(e){this.brightnessDragging=false;this.setData({brightness:e.detail.value});this.send('set_brightness',e.detail.value);},
 onMute(e){this.send('set_mute',e.detail.value);},
 onAuto(e){this.send('set_auto_play',e.detail.value);},
 onCommand(e){this.send(e.currentTarget.dataset.command);}
});
