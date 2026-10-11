# GlassCam — first HNCS effect prototype

原生 SwiftUI 界面 + 标准 C++17 图像/颜色后端。现有 HNCS 资产，不新增色卡拟合。先验证导入、现有效果、前后比较、导出这条闭环。

## Start here

- [持续更新的需求](docs/REQUIREMENTS.md)：确认需求、偏好推断、工程建议、待决定事项。
- [架构与颜色域](docs/DESIGN.md)：真正 HNCS 核与实验性源域桥的边界。
- [决策日志](docs/DECISIONS.md)
- [测试状态与性能](docs/TEST_STATUS.md)
- [硬件与加速路线](docs/HARDWARE_PERFORMANCE.md)
- [iOS 项目与构建步骤](ios/README.md)
- [C++ 数值核心](core/README.md)
- [数据来源及分发边界](NOTICE.md)

## Current implementation

Photos/Files 导入 → Apple Core Image 解码 → experimental linear-sRGB source adapter → 既有 HNCS → before/after → sRGB PNG 分享。预览与导出最长边限制为 2048 px。

颜色核心保留 double、原始 2D chroma LUT、曲线和量化边界。标准 C++ 可独立编译，不需 Apple SDK。Swift 只负责界面、Apple 图像入口与缓冲区桥接。

完整 iOS Xcode 项目已包含。当前环境没有 Xcode/Apple SDK，**没有声称 iOS 已编译或真机跑通**。DNG/ProRAW 解码、图像方向、前后图一致性与分享需要 Apple 环境测试。当前不是实时拍摄 App，也没有 FFCS 或完整 RAW 原图/配方保存功能。

## Portable validation

在本目录运行（位于仓库 `GlassCamPrototype/`，与原始 `HNCS技术交付/` 同级）：

```sh
python -m unittest discover -s tests -v
python tools/verify_cpp.py
python tools/benchmark_optimized.py
python tools/render_preview.py --synthetic
# Or an existing ordinary photo, without new chart calibration:
python tools/render_preview.py --input /path/to/photo.jpg --output validation/photo-preview
```

测试依赖见 requirements.txt。C++ 验证使用系统 g++；`verify_cpp.py` 同时生成准确性结果与可移植 CPU benchmark。`build/` 仅是本地产物。诊断 PNG 默认不加入 Git。

```sh
g++ -std=c++17 -O3 -ffp-contract=off -fno-fast-math -pthread core/hncs.cpp core/hncs_cli.cpp -o /tmp/hncs_cli
python core/generate_assets.py   # Rebuild lossless numeric include from original NPZ
```

## What this does not establish

实验性源域桥不是 iPhone→Hasselblad 标定；传入已经开发的照片也不会变回原始传感器信号。测试保证现有核的数值移植，而不是完整 Phocus RAW/spatial pipeline、真实 ProRAW 成片质量或版权清理。颜色偏好需要看真实照片后判断。

原始 HNCS 技术交付与证据保持原位和内容不变。新的性能或外观修改必须先过黄金测试；近似优化需单独记录误差预算。
