'use strict';
const WEATHER_URL='https://api.open-meteo.com/v1/forecast?latitude=26.0745&longitude=119.2965&current=temperature_2m,weather_code&timezone=Asia%2FShanghai';
const CODES=[0,1,2,3,45,48,51,53,55,56,57,61,63,65,66,67,71,73,75,77,80,81,82,85,86,95,96,99];
function timeCommand(now){return 'TIME='+new Date(now+8*3600000).toISOString().slice(0,19).replace(/[-:T]/g,'');}
function parseWeather(body,now){
 const c=body?.current,units=body?.current_units;
 const observed=Date.parse((c?.time || '')+'+08:00');
 if(units?.temperature_2m!=='°C'||!Number.isFinite(c?.temperature_2m)||Math.abs(c.temperature_2m)>99||!CODES.includes(c?.weather_code)||!Number.isFinite(observed)||now-observed>7200000||observed-now>1200000)throw Error('天气数据格式错误或已过期');
 const t=Math.round(c.temperature_2m);
 return {city:'福州',temperature:c.temperature_2m,code:c.weather_code,observedAt:new Date(observed).toISOString(),source:'Open-Meteo',payload:'WX='+String(c.weather_code).padStart(2,'0')+(t<0?'-':'+')+String(Math.abs(t)).padStart(2,'0')};
}
function createEnvironmentSync({send,fetchImpl=fetch,now=Date.now}={}){
 let timer,running=false,nextFetch=0,lastTime=0,lastWeather=0;
 const state={city:'福州',timezone:'Asia/Shanghai',weather:null,timeSyncedAt:null,weatherSyncedAt:null,weatherError:null,error:null};
 async function tick(){
  if(running)return;running=true;
  try{
   // Check every 2 s; resync cached weather/time every 10 s so reconnects recover quickly.
   // Fetch upstream every 5 min (its observation timestamp may update less often).
   // Time synchronization must keep working even if the weather service fails.
   let commandError=null;
   if(now()-lastTime>=10000){try{await send(timeCommand(now()),'time');lastTime=now();state.timeSyncedAt=new Date(lastTime).toISOString();}catch(e){commandError=e.message;}}
   if(now()>=nextFetch){
    try{const r=await fetchImpl(WEATHER_URL,{signal:AbortSignal.timeout(10000),redirect:'error'});if(!r.ok)throw Error('天气 HTTP '+r.status);state.weather=parseWeather(await r.json(),now());state.weather.fetchedAt=new Date(now()).toISOString();nextFetch=now()+300000;state.weatherError=null;}
    catch(e){nextFetch=now()+10000;state.weatherError=e.message;}
   }
   if(!commandError && state.weather && now()-Date.parse(state.weather.observedAt)<=7200000 && now()-lastWeather>=10000){await send(state.weather.payload,'weather');lastWeather=now();state.weatherSyncedAt=new Date(lastWeather).toISOString();}
   state.error=commandError||state.weatherError;
  }catch(e){state.error=e.message;}finally{running=false;}
 }
 return {tick,status:()=>JSON.parse(JSON.stringify({...state,serverTime:new Date(now()).toISOString()})),start(){if(!timer){tick();timer=setInterval(tick,2000);timer.unref();}},stop(){clearInterval(timer);timer=null;}};
}
// Background synchronization yields to interactive controls; never overlap MQTT requests.
function prioritizeCommands(send){
 let active=false;const waiting=[];
 function pump(){if(active||!waiting.length)return;active=true;const job=waiting.shift();Promise.resolve().then(()=>send(job.value,job.kind)).then(job.resolve,job.reject).finally(()=>{active=false;pump();});}
 return (value,kind='volume')=>{
  if((kind==='time'||kind==='weather') && (active||waiting.length)){const e=Error('Interactive command in progress');e.status=409;return Promise.reject(e);}
  if(waiting.length>=16)return Promise.reject(Error('Too many pending commands'));
  return new Promise((resolve,reject)=>{waiting.push({value,kind,resolve,reject});pump();});
 };
}
module.exports={createEnvironmentSync,timeCommand,parseWeather,prioritizeCommands};
