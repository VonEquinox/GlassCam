# A7R V → X2D II → HNCS

当前版本：**render revision 8 / colour path revision 2**。默认使用两组配对色卡的 `paired` 模型，将 Sony A7R V RAW 映射为虚拟 X2D II，再执行 Phocus 4.2.2 非 HDR 工厂颜色核心。

从 [当前阅读指南](docs/00_阅读指南.md) 开始。[运行命令](docs/06_运行与全部Pipeline.md)、[曲线与预设](docs/05_曲线预设与显示导出.md)、[验证与适用范围](docs/07_验证结果与复现标准.md)描述当前实现。

```sh
uv run --python 3.12 --with-requirements requirements.txt python tools/verify_delivery.py
uv run --python 3.12 --with-requirements requirements.txt python process_photo_batch.py --output-dir output /absolute/path/photo.ARW
```

将输入路径换成 Sony ILCE-7RM5 RAW；可连续列出多个文件。固定依赖安装完成后可增加 `--offline`。渲染不需要 Phocus、原色卡或在线色彩数据库。

每张生成16位工作RGB TIFF及匹配ICC、16位sRGB TIFF、全尺寸HNCS JPG、保留完整CFA的普通DNG、实际重读DNG常规显影的原色TIFF/JPG，以及对比和参数/哈希JSON。

Nature、Lighten、Extra contrast采用原生全长预设曲线与对比度/Gamma顺序；固定WB施加完整目标增益，Square Crop按输入尺寸居中裁成正方形。无Point曲线时保留Gamma/对比度控制。43份原始设置及对应表随代码分发。

36项测试通过；Nature/Lighten/Extra contrast的278528个原生滤镜灰阶和彩色样本最大uint16差0。工厂非HDR颜色核的260000个原生样本最大差0。专有RAW曝光、镜头、HDR和空间内核的完整Phocus等价性，以及任意光谱下的跨相机准确度，仍未证明。颗粒与USM为明确的便携实现。

当前完整工作区和技术交付包含标定输入及可选原生核验镜像；源码上传目录只包含文档、代码、参数和数值证据。完整运行包由 `package_hncs_runtime.py` 生成到 `work/hncs-finalization/hncs-runtime.zip`，内含运行文件与SHA清单。

本源码分发不含照片、RAW、TIFF/DNG、安装镜像和ZIP；图片运行及重拟合须自行提供本地输入。
