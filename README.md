# 基于FPGA的多维交互实时电子音乐系统

本仓库仅保留作品最终代码、完整部署固件、模型资料和操作说明。
完整提交压缩包：`FPGA_Multimodal_Music_System_Final.rar`。
[下载完整RAR及固件附件](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/tag/final)。RAR包含下表全部现有成品，视觉板固件已补齐。

## 工程入口

| 部分 | 正式工程或构建入口 | 可直接使用的成品 |
|---|---|---|
| 60K音乐主控制器 | fpga/music_controller/music_controller.gprj | bin/music_controller/music_controller.fs |
| 20K手势视觉副板 | fpga/gesture_vision/gesture_vision.gprj | bin/gesture_vision/gesture_vision.fs |
| F103力度键盘采集 | firmware/velocity_keyboard/mcu/keil/velocity_keyboard.uvprojx | bin/velocity_keyboard/velocity_keyboard.hex |
| F411曲库与蓝牙网关 | firmware/library_gateway/tools/build_gnu.py | bin/library_gateway/library_gateway.hex |
| 琴间Android客户端 | android/build_app.py | bin/android/qinjian.apk |
| 手势模型与离线复现 | model/gesture_classifier/export_rom.py、train.py | 冻结权重、训练缓存及FPGA ROM |
| 自主PCB | hardware/pcb中的三个.eprj | 主控制板、力度键盘及PMOD转接板 |

文件按用途正式命名；复用RTL的内部模块标识保留。工程Top、工具版本及重建方式见[构建说明](docs/BUILD.md)。
源码目录独立于原开发工作区，不包含中间工程、独立验证程序、仿真缓存或历史构建报告。

## 产品功能

- Main/DD/Looper共享64路旋律与8路鼓；曲谱/音游场景16/4；独立展示模式支持512路分量。
- 逐样本合成、三音色独立ADSR、双延音、节拍器、增强Room/Wet、四轨四层2048事件Looper。
- 13个双段键在FPGA内由采集时间戳配对、计算Δt并映射64档力度；力度键盘具有独立音色和八度。
- 四谐波、A/B波表与可视化，波形、频谱及李萨如分析，显示由FPGA实时生成。
- F411外接8MiB SPI NOR持久曲库，支持手机蓝牙和屏幕选曲、加载、播放及音游。
- 板载PT8211与外接PCM5102A标准I2S同步输出同一最终PCM。
- 20K独立处理摄像头与量化CNN，通过GS2控制主板普通延音，支持手动接管和失联回退。

主摇杆弯音/颤音保留。视觉固件同时发出GE3位置包，当前音乐主板采用GS2延音控制；位置参数不参与主板音乐表达。
完整Looper持久化/手机导出与TF/FAT未开放。

## 使用

先读[快速开始](docs/QUICK_START.md)、[接线](docs/INTERFACES.md)和[操控](docs/CONTROLS.md)。
现有成品可用Gowin Programmer手动SRAM Program，无需先Run All；MCU可烧录镜像与App保持原样。力度键盘ELF仅移除调试元数据，加载段和BIN内容均与原程序一致。
GitHub源码克隆未附二进制时，从同仓库Release按[成品说明](bin/README.md)下载到对应目录。

```powershell
python tools/verify_package.py --strict-binaries
# 只克隆源码、尚未下载固件时：
python tools/verify_package.py --source-only
```

主板50MHz，Fs=50MHz/1040≈48.0769kHz；资源52875 Logic /26066 Reg /28597 CLS /110物理RAM /27 DSP /55IO。
既有实现setup/hold违例0/0、最差+0.008/+0.134ns；显示MPW −1.067ns仍开放。
本次仅补齐成品、整理命名与资料，没有新综合/PnR、重新训练或板卡下载；文件核验不扩展为新的实物或长稳验收。
固件身份见[成品清单](docs/ARTIFACTS.md)、VERSION.json和SHA256SUMS.txt。
