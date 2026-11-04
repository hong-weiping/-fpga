function request(baseUrl, token, path, method = 'GET', data) {
 return new Promise((resolve, reject) => {
  wx.request({url: baseUrl + path, method, data, timeout: path === '/api/device/commands' ? 12000 : 8000,
   header: {'Content-Type':'application/json','Authorization':'Bearer ' + token},
   success(res) {if(res.statusCode >= 200 && res.statusCode < 300) resolve(res.data); else reject(new Error((res.data && res.data.error) || 'HTTP ' + res.statusCode));},
   fail() {reject(new Error('无法连接后端，请检查电脑IP、后端进程、口令及微信网络调试设置'));}});
 });
}
module.exports = {request};
