# 构建与工程入口

附带可烧录镜像均为原成品。力度键盘ELF已移除调试信息，加载段与原BIN一致；构建脚本也在导出时清理ELF调试信息。重建与下载分开进行；重建后的FS需独立审查实际时序与板测。

## 音乐主控制器

打开fpga/music_controller/music_controller.gprj。器件GW5AT-LV60PG484AC1/I0，使用Gowin1.9.12.03。
Top Module为control_ui_v24_top；该RTL标识保持原样，正式顶层文件名为src/music_controller_top.v。
build.tcl固定原area、shift_reg=registers、map=2、place=2、route=2、route_maxfan=23及use_cpu_as_gpio=1，输出基名music_controller。
工程引用、CST/SDC与原数值逻辑保持；未为整理提交包重新布局布线。
UI文本在assets/ui_text.json，tools/generate_labels.py生成ui_labels.v，--check可检查当前生成内容。

## 手势视觉副板

打开fpga/gesture_vision/gesture_vision.gprj。器件GW2A-LV18PG256C8/I7，使用Gowin1.9.12.04。
Top Module为p20_crop_live_top，顶层文件名src/gesture_vision_top.v；build.tcl输出基名gesture_vision。
assets包含完整七份模型文件。附带FS与B交付的41个原始构建输入匹配，不需要电脑传模型。
副板发送GS2和GE3；音乐主板使用GS2普通延音，忽略GE3位置表达。

## 力度键盘F103

Keil5+DAPLink可打开firmware/velocity_keyboard/mcu/keil/velocity_keyboard.uvprojx。
该工程封装附带的原GNU镜像，F7/F8用于一致镜像的编程，不改用另一编译器重写采集算法。
需要STM32F1xx_DFP 2.4.1及CMSIS-DAP支持。GNU源码构建示例：

```powershell
python firmware/velocity_keyboard/tools/build_mcu.py --gcc D:/tools/arm/bin/arm-none-eabi-gcc.exe
```

输出bin/velocity_keyboard。Cortex-M3、内部HSI/PLL名义64MHz，64KiB Flash/20KiB RAM，不依赖HAL或外部晶振。
MCU仅采集触点状态和时间戳；配对、消抖音乐语义、Δt、力度与音符由FPGA处理。

## 曲库网关F411

使用GNU Arm GCC14.2.1，外接8MiB SPI NOR/LittleFS，实际配置LIBRARY_WRITES=1。

```powershell
$env:ARM_GNU_BIN='D:/tools/arm/bin'
python firmware/library_gateway/tools/build_gnu.py
```

输出bin/library_gateway。内部HSI16MHz、UART115200/8N1，LittleFS许可证随源码保留。

## Android客户端

android/src为最终23份Java编译输入。需要JDK17、Android SDK平台android-35及build-tools。
设置JAVA_HOME和ANDROID_SDK_ROOT，可选ANDROID_BUILD_TOOLS/ANDROID_JAR：

```powershell
python android/build_app.py --unsigned
# 自有签名：设置ANDROID_KEYSTORE后运行不带--unsigned的命令
```

原签名私钥不分发，重建APK字节不保证与原签名成品一致。直接安装使用bin/android/qinjian.apk。
若自行签名且与旧签名不同，安装前先备份手机歌曲和录制内容。

## 模型导出及缓存训练

见model/gesture_classifier/README.md。export_rom.py保留原导出算法，在临时目录重建原相对路径，并核对七份产物。
train.py把最终训练脚本和缓存复制到新工作目录，只运行rgb32_hard入口；不会覆盖附带权重或固件。
