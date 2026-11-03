# 系统接线与通信

改线前全部断电。UART使用3.3V TTL，各板共同地；独立供电时不互接电源输出。球号与NEO排针物理编号均列出。

## 曲库、蓝牙与音乐主板

| 来源 | 目标 | 用途 |
|---|---|---|
| HC05 TXD | F411 PA10/RX1 | 手机→网关 |
| F411 PA9/TX1 | HC05 RXD | 网关→手机 |
| F411 PA2/TX2 | 60K AA19 / PMOD1 J8.5 | 网关→FPGA UART RX |
| 60K AA20 / PMOD1 J8.7 | F411 PA3/RX2 | FPGA UART TX→网关 |
| HC05 STATE | F411 PB1及60K AB21 / PMOD1 J8.9 | 手机占用状态，两端均为输入 |
| GND | 60K、F411、HC05 | 共同地 |

HC05数据经F411，不能同时保留直接连AA19/AA20的旁路，禁止两个TX并联。STATE不可省略。
F411与力度F103为不同MCU，不能刷错固件。F411的PA4～7连接已配置的8MiB SPI NOR，PA13/14为SWD；供电按具体核心板规格。

UART为115200/8N1，Wire v1使用0x7e分帧、0x7d转义及CRC16-CCITT，payload最多64字节。
0x40～43供屏幕能力/条目/加载/任务查询；原FMS/RT1服务保留，手机曲库协议在F411终止。
Flash最多32首，RAM一次一首；单曲最多66048字节、4096事件、2048交互音符。曲谱/音游16旋律/4鼓。
英文歌名显示，非ASCII回退为Song＋ID；新曲库预览显示前8字符，Loaded/Game显示前24字符，长名省略。
请求截止10秒，最多2次重试；加载必须等Ready，不能将accepted视作加载完成。
手机连接时屏幕加载受限；Stop song→Return Perform解除歌曲场景，复位后需重新加载歌曲。

## 音频、力度键盘与手势

| 信号 | 60K球号 / NEO针号 |
|---|---|
| PCM5102A BCK | T18 / J9.6 |
| PCM5102A LCK | R18 / J9.5 |
| PCM5102A DIN | R17 / J9.8 |
| F103 PA9 TX→力度RX | T21 / J9.9 |
| 力度TX→F103 PA10 | P19 / J9.11 |
| Primer20K T6 TX→手势RX | P16 / J9.7 |

J9.1/2为3.3V，J9.3/4为GND。R18是I2S时钟输出，不能接20K TX。
PCM5102A SCK接共同地，VIN使用已核对5V；已验模块H1/H2/H4低、H3高，XSMT约3.3V。
模拟输出接有源音箱高阻输入或耳放。板载PT8211与PCM5102A输出同一最终PCM，无需切换菜单。
原控制板按已完成线束连接，主板全部IO绑定见music_controller.cst，不以其他型号底板CST替代。

F103只扫描13个双段键及3个普通键，UART传采集时间戳与触点状态。
FPGA计算双触点Δt、消抖语义、64档力度和音符事件；不以UART到达间隔估算力度。

## 视觉控制边界

20K T6→60K P16/J9.7及共同地；UART115200/8N1。附带视觉固件包含相机、CNN和显示，发送GS2 v2及GE3 v3。
60K使用GS2普通延音：确认握拳锁存On，确认张手锁存Off；普通无效尖刺不会直接翻转延音。
复位默认Off，从Settings→Input Diagnostics开启，需先新有效OPEN建立控制权；KEY10可手动接管。
曲谱/音游、加载、512及Loop录制等场景暂停手势控制，返回需新OPEN。已经录好的Loop层不被改写。
当前60K不使用GE3位置参数，Settings右下Position Unavailable灰显；手动摇杆弯音/颤音照常可用。
模型与固件身份核验见ARTIFACTS，不把该核验扩展为新的识别精度、两板或长稳验收。
