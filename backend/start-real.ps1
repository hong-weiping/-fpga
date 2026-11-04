$ErrorActionPreference='Stop'
$configPath=Join-Path $PSScriptRoot 'onenet-user.local.json'
if(Test-Path -LiteralPath $configPath){
 $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
 $env:ONENET_USER_ID=[string]$config.userId
 $env:ONENET_USER_ACCESS_KEY=[string]$config.accessKey
}
foreach($name in @('DEMO_ACCESS_TOKEN','ONENET_PRODUCT_ID','ONENET_DEVICE_NAME','ONENET_USER_ID','ONENET_USER_ACCESS_KEY')){
 if(-not [Environment]::GetEnvironmentVariable($name)){throw "Missing environment variable: $name"}
}
$env:MODE='real'
& node (Join-Path $PSScriptRoot 'server.js')
