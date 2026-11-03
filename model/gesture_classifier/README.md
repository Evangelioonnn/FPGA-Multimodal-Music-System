# 最终手势分类模型

固定模型ID为dc5423302f9a36fa468c66b0b713ac92。输入为原生32×32 RGB565，先扩展RGB8再取高7位。
网络含两层3×3卷积、4×4平均池化和四输出全连接，共2860参数；输出OPEN/FIST/REJECT/ACCEPT。
固件内ROM已固定，设备运行不需要PC、PyTorch或上传模型。

## 文件

- weights：最终float、QAT权重和冻结quantized.npz。
- source/rom_export：B原始导出与整数参考代码，内容未改。
- source/training、source/tools：最终rgb32_hard训练入口和其本地模块依赖，内容未改。
- training_cache：对应最终训练缓存及划分元数据，可用于缓存训练；不是完整原始图片集镜像。
- SOURCE_IDENTITIES.json：原交付路径和SHA，保存代码/权重来源。

## 重现七份模型文件

安装requirements_export.txt所列依赖后，在仓库根运行：

```powershell
python model/gesture_classifier/export_rom.py --output D:/music_model_export
```

输出目录须尚不存在。包装入口在临时目录恢复原脚本的相对路径，不改导出算法或模型身份；生成的七份文件须与fpga/gesture_vision/assets逐字节一致才导出成功。
MODEL.json中的原训练路径及source_sha256描述原始模型来源，包装入口不改写这些身份字段。

## 缓存训练

在独立Python环境安装requirements_export.txt、requirements_reference.txt和requirements_training.txt。
浮点6000步＋QAT2000步，固定种子，入口只选择最终rgb32_hard：

```powershell
python model/gesture_classifier/train.py --work-dir D:/music_model_training
# 仅准备可复现工作目录，不启动训练：
python model/gesture_classifier/train.py --work-dir D:/music_model_inputs --prepare-only
```

工作目录必须位于提交包外且尚不存在。训练从新网络开始，原冻结权重不会复制到训练输出中，避免误覆盖。
本包没有完整的原始图片、教师权重或早期检测器数据准备链；附带缓存支持该最终学生网络训练，不能宣称从原始数据完整重建全部早期研究流程。
训练得到的新参数需另做数值、时序和实物审查；不自动替换本作品固件。本次整理只复现ROM导出，没有重新训练或扩大真实识别精度结论。
