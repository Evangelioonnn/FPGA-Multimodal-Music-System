# 使用附带成品

RAR包含全部部署成品。只克隆GitHub源码时，先从Release下载附件到bin的对应目录。
以下操作由使用者手动执行，包内工具不会自动写板卡Flash。

1. 按INTERFACES核对接线和供电。先较低主音量，PCM5102A接有源音箱或耳放。
2. 音乐主板使用Gowin Programmer的SRAM Program，Programming File选择bin/music_controller/music_controller.fs，无需Run All。
3. 视觉副板同样选择SRAM Program，文件为bin/gesture_vision/gesture_vision.fs，器件GW2A-18。20K T6→60K P16/J9.7，并共地。两板运行不需要主机上传模型。
4. 力度F103使用bin/velocity_keyboard/velocity_keyboard.hex；BIN基址0x08000000。BOOT0=0，SWD/DAPLink，PA9→60K T21、PA10→P19，共地。已有正常固件无需重烧。
5. 曲库F411使用bin/library_gateway/library_gateway.hex，保留原8MiB NOR内容。已有正常曲库的设备不执行首次格式化或初始化；HC05和STATE接法见INTERFACES。
6. 手机安装bin/android/qinjian.apk，包名org.fpgamusic.upload，versionCode21。配对已配置的蓝牙模块，在App内连接。
7. 松开全部Main/DD键，按底板KEY.0复位。RAM中的Loop及已加载歌曲清除，F411持久曲库保留。
8. TIM切换导航/表情，摇杆选择，EDIT确认和编辑；完整按键分配见CONTROLS。
9. 曲库操作：Library→Choose song→Load selected→Ready→Start/pause。手机连接时屏幕加载受限。Stop song→Return Perform后恢复普通演奏，不需要删除持久曲库。
10. Settings→Input Diagnostics→Gesture control开启视觉延音。先张开手掌取得有效OPEN，再握拳开启延音、张手关闭，KEY10可手动接管；录制/加载/C/512等场景暂停视觉接管。

01JOY、03HALL、04SLEEV为配套FMS事件曲谱。新增歌曲可通过App选FMS并保存到设备曲库；已有三曲时无需初始化NOR。
普通Looper保存在本次供电的RAM中，完整Loop持久保存和手机导出未开放。
