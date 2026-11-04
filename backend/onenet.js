'use strict';
const {getAuthorization}=require('./onenet-auth');
const crypto = require('node:crypto');
function makeToken(productId, accessKey, now = Date.now()) {
 const version='2018-10-31', method='sha256', res='products/'+productId;
 const et=String(Math.floor(now/1000)+3600);
 const sign=crypto.createHmac(method,Buffer.from(accessKey,'base64')).update([et,method,res,version].join('\n')).digest('base64');
 return Object.entries({version,res,et,method,sign}).map(([k,v])=>k+'='+encodeURIComponent(v)).join('&');
}
function parsePoint(body, name) {
 if(body.code!==0)throw new Error('OneNet 查询失败，错误码 '+String(body.code)+'；请核对产品、设备ID及产品密钥是否属于同一产品。');
 if(!Array.isArray(body.data?.datastreams))throw new Error('OneNet 返回格式与当前查询文档不匹配');
 const points=body.data.datastreams.find(s=>s.id===name)?.datapoints;
 if(!points?.length)return {value:null,at:null};
 const p=points[0];
 const value=typeof p.value==='number'?p.value:typeof p.value==='string' && p.value.trim()!==''?Number(p.value):NaN;
 if(!Number.isFinite(value))throw new Error('OneNet '+name+' 数据不是有效数值');
 // The documented timestamp has no timezone. Interpret it as Beijing time.
 let t=typeof p.at==='string'?p.at.replace(' ','T'):'';
 if(t && !/(Z|[+-]\d{2}:?\d{2})$/i.test(t))t+='+08:00';
 const ms=typeof p.at_timestamp==='number'?p.at_timestamp:Date.parse(t);
 return {value,at:Number.isFinite(ms)?new Date(ms).toISOString():null};
}
function createReader(env=process.env, fetchImpl=fetch) {
 let cached=null, cachedAt=0, pending=null;
 async function query(){
  const pid=env.ONENET_PRODUCT_ID?.trim(), device=env.ONENET_DEVICE_NAME?.trim();
  const authorization=getAuthorization(env);
  if(!pid || !device || !authorization){const e=new Error('请使用 start-real.ps1 启动新版接口，或设置 ONENET_PRODUCT_ID、ONENET_DEVICE_NAME、ONENET_AUTHORIZATION');e.status=503;throw e;}
  const expiry=Number(new URLSearchParams(authorization).get('et'));
  if(!Number.isFinite(expiry) || expiry<=Date.now()/1000)throw new Error('OneNet Token 已过期，请重新执行控制台数据流调试并更新调试文件后重启后端');
  const points=await Promise.all(['temperature','humidity','volume','fire'].map(async name=>{
   const url=new URL('https://iot-api.heclouds.com/datapoint/history-datapoints');
   url.search=new URLSearchParams({product_id:pid,device_name:device,datastream_id:name,sort:'DESC',limit:'1'}).toString();
   let response;
   try{response=await fetchImpl(url,{headers:{Authorization:authorization},signal:AbortSignal.timeout(6000),redirect:'error'});}
   catch(e){throw new Error('无法连接 OneNet 查询服务或请求超时，请检查电脑网络；不会自动降级为明文传输');}
   if(!response.ok)throw new Error('OneNet HTTP '+response.status+'：请核对接口版本、设备ID和产品级密钥');
   let body;try{body=await response.json();}catch(e){throw new Error('OneNet 未返回有效JSON');}
   return parsePoint(body,name);
  }));
  const [temperature,humidity,volume,fire]=points;
  const times=points.slice(0,2).map(p=>p.at && Date.parse(p.at));
  return {mode:'real',source:'onenet',fire:fire.value===1?true:fire.value===0?false:null,fireUpdatedAt:fire.at,temperature:temperature.value,humidity:humidity.value,
   temperatureUpdatedAt:temperature.at,humidityUpdatedAt:humidity.at,
   updatedAt:times.every(t=>typeof t==='number' && Number.isFinite(t))?new Date(Math.min(...times)).toISOString():null,
   volume:Number.isInteger(volume.value) && volume.value>=0 && volume.value<=100?volume.value:null,volumeUpdatedAt:volume.at,volumeControlEnabled:true,controlsEnabled:false,online:null};
 }
 return async()=>{
  if(cached && Date.now()-cachedAt<1000)return cached;
  if(!pending)pending=query().then(s=>{cached=s;cachedAt=Date.now();return s;}).finally(()=>{pending=null;});
  return pending;
 };
}
module.exports={makeToken,parsePoint,createReader};