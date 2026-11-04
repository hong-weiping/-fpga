# OneNet HTTP 后端

需要 Node.js 18.17 或更高版本，仅使用 Node.js 内置模块，无需 npm install。

复制 onenet-user.example.json 为 onenet-user.local.json，填写自己的用户ID与Base64 AccessKey。本地配置已被Git忽略，不要提交真实密钥。

在 backend 目录打开 PowerShell：

```powershell
$env:DEMO_ACCESS_TOKEN = '设置自己的后端口令'
$env:ONENET_PRODUCT_ID = '自己的产品ID'
$env:ONENET_DEVICE_NAME = '自己的设备名称'
powershell -ExecutionPolicy Bypass -File .\start-real.ps1
```

默认端口3000；GET /health可检查服务。小程序填写相同后端口令。cpolar的HTTP隧道本地目标是 http://127.0.0.1:3000，小程序填写当前HTTPS公网地址。需遵守微信request合法域名及真机调试规则。

正式设备还需在FPGA上传副本中配置自己的MQTT认证报文。FPGA与后端的产品、设备配置必须一致。
