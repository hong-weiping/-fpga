# 智显安播——商场信息展示与应急广播 FPGA 工程

## 1. 工程概述

本工程基于安路 HX4S20C 开发板及 EG4S20BG256 FPGA，面向商场广告播放、环境信息展示和应急通知场景。`digital_ad_screen` 是最终版 FPGA 工程的新目录名称，功能沿用此前最终版。

FPGA 完成 TF 卡文件读取、图像缓存、视频处理、HDMI 音视频输出、传感器采集、事件仲裁和 ESP8266 通信。微信小程序及 HTTP 后端是独立工程，不包含在本目录中。

## 2. 主要功能

- 通过 SPI 读取 FAT32 TF 卡上的 BMP 图片及 PCM 音频，使用 SDRAM 缓存图像。
- HDMI 输出 800×600，广告图片区为 640×480；音频链路采样节拍为 48 kHz。
- 手动切图、自动轮播、四档轮播周期、图片转场与对应音频播放。
- 叠加滚动字幕、日期时间、福州天气、室内温湿度、播放状态、显示参数及音频动态柱状图。
- 调节画面亮度、对比度、饱和度，以及远程音量和静音。
- 光敏模块配合 ADS1115 实现自动亮度调节，也支持手动亮度。
- 火灾、寻人、噪声三级应急处理，优先级为：**火灾 > 寻人 > 噪声 > 日常广告**。
- 火灾联动板载无源蜂鸣器；寻人通知引导到商场一楼广场中心集合，可远程取消。
- ESP8266 通过 MQTT 接入 OneNet，上传温湿度及状态，接收控制命令。

当前不提供缩略图功能及参数掉电保存。亮度调节作用于输出画面像素，不等同于控制显示器背光；音频柱状图不代表经过标定的频谱或声压测量。

## 3. 开发环境与入口

| 项目 | 配置 |
| --- | --- |
| 开发板 | 安路 HX4S20C |
| FPGA 器件 | EG4S20BG256 |
| 开发工具 | 安路 Tang Dynasty（已有实现报告使用 TD 6.2） |
| 工程入口 | `td_project/HDMI1.4b_Transmitter_v1.0.al` |
| 顶层模块 | `top` |
| 顶层源码 | `user_source/hdl_source/top_tf_hdmi_audio.v` |
| 引脚约束 | `user_source/constraints_source/pin.adc` |
| 时序约束 | `user_source/constraints_source/timing.sdc` |

### 移动目录后的路径检查

本次只更新 README，未修改工程配置或 RTL。当前文件仍存在以下旧路径：

- `.al` 的 `Project Path` 指向 `C:/Anlu_example/micu_change27_pin_clean2/td_project`。
- `esp8266_controller.v` 和 `mall_layout_osd.v` 中的 `$readmemh` 指向 `C:/Anlu_example/micu_change27_pin_clean/user_source/hdl_source/`。

因此，目录重命名不等于工程已完成路径迁移。重新编译前应检查工程源文件引用、IP 依赖及 ROM 路径，使其指向当前目录中的实际文件，避免缺失资源或误读旧目录素材。已有 bit 文件不需要在运行时访问这些电脑路径，但重新综合会用到它们。

## 4. 目录与模块分工

```text
digital_ad_screen/
├─ README.md
├─ td_project/
│  ├─ HDMI1.4b_Transmitter_v1.0.al
│  ├─ HDMI1.4b_Transmitter_v1.0_Runs/  实现报告与生成文件
│  └─ log/                            工具日志
└─ user_source/
   ├─ constraints_source/             引脚与时序约束
   └─ hdl_source/
      ├─ top_tf_hdmi_audio.v           系统集成
      ├─ SD/                          SPI、FAT32、BMP及PCM读取
      ├─ audio/                       音频处理与HDMI音频链路
      ├─ display/                     图像参数、显示处理
      ├─ ip/                          PLL、FIFO及配套生成文件
      ├─ include/                     公共头文件
      └─ *.v / *.hex                  控制逻辑及ROM初始化数据
```

| 模块或文件 | 作用 |
| --- | --- |
| `media_player_control.v` | 播放索引、手动/自动控制、轮播周期及帧边界提交 |
| `media_frame_loader.v` / `media_frame_reader.v` | 图像缓存写入与视频读取 |
| `media_pixel_cdc.v` / `sync_2ff.v` / `reset_sync.v` | 数据、控制和复位的跨时钟域处理 |
| `video_timing_ctrl.v` | 视频扫描时序，由顶层设置有效分辨率 |
| `mall_layout_osd.v` | 屏幕布局、字体、图标和状态叠加 |
| `alarm_media_select.v` | 应急内容优先级仲裁 |
| `dht11_reader.v` | 温湿度采集 |
| `fire_detector.v` / `noise_detector.v` | 外部事件检测 |
| `esp8266_controller.v` | ESP8266连接、MQTT上传及命令交互；文件内还包含部分辅助模块 |
| `hdmi_phy_warpper.v` / `lane_lvds_10_1.v` | HDMI物理发送链路 |

`.hex` 是字体、图标、寻人画面或查找表等必要 ROM 数据，不是无关编译垃圾。IP 的 `.ipc`、`.v`、`.vhd`、`.tcl` 等文件应按工程依赖一起保留，不能只留下顶层 Verilog。

## 5. 硬件连接

以下以**当前目录的 `pin.adc`**为准，UART 方向均从 FPGA 端定义。

| 功能 | 顶层端口 | FPGA引脚 | 接线与含义 |
| --- | --- | --- | --- |
| DHT11温湿度 | `GPIOA_0` | M14 | 接DATA，注意上拉电平 |
| ESP8266使能 | `esp8266_en` | P11 | 接EN，固定高电平使能 |
| UART发送 | `uart_tx` | **L10** | 接ESP8266 RXD |
| UART接收 | `uart_rx` | **M10** | 接ESP8266 TXD |
| 火灾输入 | `GPIOB_0` | N1 | 数字输出，低有效 |
| 噪声输入 | `GPIOB_1` | M2 | 数字输出，高有效 |
| 无源蜂鸣器 | `buzzer_n` | H11 | 低有效连接，由周期波形驱动 |
| ADS1115时钟 | `light_scl` | M1 | 接SCL |
| ADS1115数据 | `light_sda` | L1 | 接SDA |

**当前 UART 是 TX=L10、RX=M10，与旧 README 中 TX=M10、RX=L10 的文字相反。接线与文档以当前约束为准；本次没有更改引脚。**

- 外设与开发板共地，数字信号及上拉电平需符合 FPGA IO Bank 的 3.3V 逻辑要求。
- UART 为 115200 bit/s、8数据位、无校验、1停止位。
- 光敏模块 AO 接 ADS1115 AIN0，ADDR 接 GND，对应7位地址 `0x48`；SCL/SDA 使用合适的3.3V上拉。
- ADS1115 驱动采用单端采集、±4.096 V量程及128 SPS配置；量程不代表输入允许超过器件供电范围。
- 两块拓展板分别组织 ESP8266/DHT11 接口，以及火灾/噪声/光敏/ADS1115 接口；供电连接应结合实际原理图检查。
- 板载HDMI、TF卡、按键、拨码、数码管等完整引脚见 `pin.adc`。

## 6. TF卡与素材

使用与已有演示一致的 FAT32 TF 卡及配套素材。当前文件扫描器识别根目录中的8.3短文件名：

- 图片：`PIC1.BMP`～`PIC6.BMP`。
- 分段媒体音频：`AUDIO1.PCM`～`AUDIO7.PCM`；扫描器另有识别 `AUDIO.PCM` 的模式。

实际使用哪些音频入口及媒体编号由顶层、音频源和应急选择逻辑决定，不应只根据扫描器能识别的文件名推断全部都会播放。普通广告、应急图片及配套音频应沿用已经联调成功的编号关系。

图片使用当前链路匹配的640×480、24位非压缩BMP素材；不要直接替换为任意分辨率或压缩BMP。PCM是原始音频数据，不是把MP3/WAV改扩展名；采样率、位宽、声道及排列方式需与当前解码链路一致，建议直接沿用已验证素材。

TF卡上的图片音频与工程内的ROM `.hex` 是两类资源，不能相互替代。

## 7. 板载操作与远程控制

| 操作 | 功能 |
| --- | --- |
| KEY1短按 | 下一张广告 |
| KEY1长按约1秒 | 轮播周期循环切换：10 → 20 → 30 → 5秒 |
| KEY2 | 自动播放开/关 |
| KEY3 / KEY4 | 对所选图像参数增加 / 减少 |
| `sw[1:0]=00/01/10` | 选择亮度 / 对比度 / 饱和度 |
| `sw[1:0]=11` | 恢复图像参数默认值 |
| `sw[3:2]=00/01/10/11` | 调节步长1 / 4 / 16 / 32（内部参数单位） |

拨码表中的0/1表示逻辑电平，实际拨杆方向以板卡标识及硬件电平为准。轮播周期仅在自动播放状态显示。应急状态下媒体选择由优先级逻辑接管。

小程序提供音量、静音、上一张/下一张、自动/手动播放、手动/自动亮度和寻人通知等控制。自动亮度与板载图像参数调节属于不同控制层，观察效果时应同时核对当前自动模式与显示参数。

火灾结束后重新检查寻人和噪声状态，不保证立即恢复广告。小程序“确认报警”只停止手机端提醒，不解除现场火灾或蜂鸣器。

## 8. 网络与配套软件

```text
FPGA ←UART→ ESP8266 ←Wi-Fi/MQTT→ OneNet
                                  ↑ HTTP API
                              Node.js后端
                                  ↑ HTTPS/HTTP
                               微信小程序
```

- 小程序：`C:\wechat_devtools\wechat_projects\miniprogram-1-clean`。
- 后端：`C:\wechat_devtools\wechat_projects\onenet-local-server-time-weather`。
- 后端启动、`DEMO_ACCESS_TOKEN`口令和cpolar配置见小程序的 `README.md`。
- cpolar用于手机访问电脑后端，不改变ESP8266到OneNet的MQTT连接。
- OneNet数据点主题采用 `$sys/{productID}/{deviceName}/dp/post/json`，温湿度数据流为 `temperature` 和 `humidity`，另有控制与状态数据。
- FPGA的Wi-Fi及OneNet参数在通信控制源码中配置，应与当前设备一致。本说明不复制访问密钥。
- 时间与天气通过配套网络链路同步；仅接通HDMI并不意味着天气与时间已更新。

## 9. 编译、下载与使用流程

1. 确认外设接线、TF卡素材与所使用的引脚约束一致。
2. 用Tang Dynasty打开 `.al` 工程，检查器件、顶层、源文件及约束；优先完成第3节的目录迁移检查。
3. 确认ROM初始化文件和IP生成依赖均存在，再执行综合、布局布线和配置文件生成。
4. 查看资源报告、时序报告及关键警告。生成bit文件并不等于建立/保持时间全部通过。
5. 通过开发板对应的下载工具下载当前工程生成的配置文件；如需断电重启运行，按板卡手册完成Flash固化并验证冷启动。
6. 插入TF卡、连接HDMI，先确认本地广告、音频与按键功能，再测试温湿度、自动亮度和应急优先级。
7. 确认ESP8266连接OneNet并能上传数据后，启动后端和小程序测试远程控制及反馈。

资源与时序以本目录当前实际编译报告为准，README不将其他目录的历史占用值当作本版结论。本次文档更新未运行综合或布局布线。

## 10. 常见问题

| 现象 | 检查方向 |
| --- | --- |
| ROM文件找不到、字形/图标异常 | `$readmemh`是否仍指向旧目录；hex是否完整 |
| Load IPC / generated file错误 | IP配置引用的Verilog、VHDL、Tcl等文件是否齐全 |
| 无图片或音频 | TF格式、根目录文件名、BMP尺寸格式及PCM编码是否符合当前链路 |
| ESP8266无应答 | TX/RX是否交叉连接，当前TX=L10、RX=M10；EN、共地和115200波特率是否正确 |
| 设备在线但无数据 | MQTT主题、数据点JSON、产品设备参数及上传反馈 |
| 自动亮度不正常 | AIN0接线、ADDR地址、供电与I²C上拉、自动模式状态 |
| 手机已连接但控制未生效 | 区分后端可访问、设备在线、命令提交和设备实际执行 |
| 资源超限或时序违例 | 查看本次实现报告及关键路径，不能以短时板测正常代替时序收敛 |

## 11. 维护说明

引脚变更需修改约束并重新生成配置文件；模块逻辑、ROM素材和工程配置应作为同一版本管理。保留必要IP依赖和ROM数据，避免把它们误当作备份删除。对外提交时检查通信源码中的敏感配置。

本README描述当前工程整体使用方法，不是某一次修改记录；本次仅修改此文档，FPGA功能代码、引脚约束、素材和编译配置均未修改。
