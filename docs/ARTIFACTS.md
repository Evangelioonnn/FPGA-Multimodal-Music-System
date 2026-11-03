# 成品及来源

部署所需的两个FPGA FS、两颗MCU固件和Android客户端均已包含。文件按用途改名，可烧录镜像沿用原成品。力度键盘ELF仅清除调试信息，入口、加载段、HEX及BIN内容均已核对一致。
没有重新生成FS、重新训练、刷写MCU或操作板卡Flash。所有SHA均由实际文件计算。

| 文件 | SHA256 |
|---|---|
| bin/android/qinjian.apk | `7a48a535e797da4ad43ceca31bae6393ed530d0f2ab2d9aca533494aef761658` |
| bin/gesture_vision/gesture_vision.fs | `22aea4a484a47d7c49a0cc1da64e138fd41476b4a76c1d0904cb0dab54c61806` |
| bin/library_gateway/library_gateway.elf | `1f4f8fc23f27815ebf7aff3b2dbc6627847d7e880b59937aa963e7bfb6921ffd` |
| bin/library_gateway/library_gateway.hex | `45c88ccfed55b0de357010afdf1dba36ab7605007956fb40ed03a250eeb258f1` |
| bin/music_controller/music_controller.fs | `0a3341e86d1de4de61ca85c1828d163d0f13c9de9edd46304ca1a855d2aa52e5` |
| bin/velocity_keyboard/velocity_keyboard.bin | `f9d8d8d6782ef4bd77c028b10d15e279aa00a58f211b93328e1699e85cf731cb` |
| bin/velocity_keyboard/velocity_keyboard.elf | `6967b3d7861e8db76e3b85aa06554b8c4ed74f3928befb01817ee8435558a0f2` |
| bin/velocity_keyboard/velocity_keyboard.hex | `15ba1a50befe4fa02d45f5dc4d3fc33f511a54a75f38f89b1d8d2cc43d2ab7f1` |

视觉补充固定来自B提交f8d2b28a4e8da03475b04b835ae3da30bc141339；FS与先前源码交接目标完全匹配，41个构建输入一致。
其冻结权重重新导出七份文件全部字节一致，两个历史固定输入的整数参考结果一致。
此结论仅证明文件与模型身份；原构建/实物/识别精度结论按各自范围保留。
主板既有setup/hold为+0.008/+0.134ns、违例0/0，显示MPW −1.067ns开放，不称所有STA类别闭合。
完整原始训练图片和教师流程不在本包；缓存训练与导出说明见model/gesture_classifier/README.md。
