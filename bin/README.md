# 正式部署固件

RAR内已包含全部八份成品文件。GitHub源码克隆后，从[最终发布](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/tag/final)下载并放回下列对应位置：

- [android/qinjian.apk](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/qinjian.apk)
- [gesture_vision/gesture_vision.fs](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/gesture_vision.fs)
- [library_gateway/library_gateway.elf](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/library_gateway.elf)
- [library_gateway/library_gateway.hex](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/library_gateway.hex)
- [music_controller/music_controller.fs](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/music_controller.fs)
- [velocity_keyboard/velocity_keyboard.bin](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/velocity_keyboard.bin)
- [velocity_keyboard/velocity_keyboard.elf](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/velocity_keyboard.elf)
- [velocity_keyboard/velocity_keyboard.hex](https://github.com/Evangelioonnn/FPGA-Multimodal-Music-System/releases/download/final/velocity_keyboard.hex)

完整SHA在docs/ARTIFACTS.md和VERSION.json。文件名已正式整理。力度键盘ELF已清除调试元数据，加载内容与原HEX/BIN一致；其他成品字节保持。
Gowin成品使用SRAM Program；既有正常MCU无需重烧，F411曲库NOR无需重新初始化。操作见docs/QUICK_START.md。
