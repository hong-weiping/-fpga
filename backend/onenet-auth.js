'use strict';
const crypto=require('node:crypto');
function getAuthorization(env=process.env,now=Date.now()){
 const user=env.ONENET_USER_ID?.trim(),key=env.ONENET_USER_ACCESS_KEY?.trim();
 if(user || key){
  if(!user || !key)throw new Error('Both ONENET_USER_ID and ONENET_USER_ACCESS_KEY are required');
  if(!/^\d+$/.test(user) || !/^[A-Za-z0-9+/]+={0,2}$/.test(key) || key.length%4!==0)throw new Error('Invalid OneNet user credential format');
  const version='2022-05-01',method='sha1',res='userid/'+user,et=String(Math.floor(now/1000)+3600);
  const sign=crypto.createHmac(method,Buffer.from(key,'base64')).update([et,method,res,version].join('\n')).digest('base64');
  return new URLSearchParams({version,res,et,method,sign}).toString();
 }
 return env.ONENET_AUTHORIZATION?.trim();
}
module.exports={getAuthorization};
