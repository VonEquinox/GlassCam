# HNCS 技术交付

本目录是可独立移动的源码、运行资产、标定输入和技术说明集合，固定当前 render revision 6、colour path revision 2。技术分析按实际代码重新编写，说明每一步的数据单位、矩阵方向、参数选择、截断和输出编码。目标是让其他开发者根据交付文件重建**本项目当前实现**，得到相同颜色运算；完整 Phocus RAW 与空间处理的行为仍有已知差异，具体见验证说明。

从 [阅读指南](docs/00_阅读指南.md) 开始。源代码保留在根目录和 `work` 原有相对结构中，避免移动后模型路径失效。此仓库只收录技术资料、源码、DCP、LUT、ICC、标定模型与数值测试数据。所有图片、RAW、TIFF、DNG和安装镜像均不上传；渲染、重新拟合或原生核验所需的输入由使用者在本地另行提供。

```bash
# 在本目录执行；首次允许安装固定依赖，已有缓存可增加 --offline
uv run --python 3.12 --with-requirements requirements.txt python tools/verify_delivery.py
uv run --python 3.12 --with-requirements requirements.txt python -m unittest -v test_hncs_pipeline test_dual_illuminant test_paired_illuminants test_phocus_presets
uv run --python 3.12 --with-requirements requirements.txt python process_photo_batch.py --output-dir output /absolute/path/to/photo.ARW
```

`docs` 是新的分析正文；`validation` 保存本次文件检查、测试和完整性清单；`tools/reference_color_core.py` 是不调用主颜色实现的独立参考实现。运行数据保存在 `work/hncs-pipeline/assets`、`work/hncs-pipeline/a7rv_to_x2dii.json` 和 `work/hncs-finalization`。

所有照片和图片文件均不在此仓库内，包括小尺寸预览和实际Phocus对照TIFF。保留的是代码、参数、数据来源记录和文本核验结果。`validation/local_inventory.json` 覆盖原目录中的全部非缓存文件，逐项标记是否收录；旧技术正文已由本目录新文档取代，旧路径只保留导航页。

交付完整性以 `validation/delivery_manifest.json` 为准。历史 `artifact_hashes.json` 只记录之前的运行，不作为交付副本校验依据。详情、预设限制与全部 Pipeline 命令见 [运行说明](docs/06_运行与全部Pipeline.md)。

当前验收：30项测试通过，52组/6656固定像素颜色核最大差0；隔离全尺寸单张的三份TIFF像素差0、DNG CFA相同；两光源重新拟合数值回归通过。
