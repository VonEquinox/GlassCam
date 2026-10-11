# GlassCam — HNCS + FFCS 原生效果原型

SwiftUI 原生界面、Apple 图像入口、标准 C++17 颜色/空间后端。沿用现有技术交付，不新增色卡拟合。当前具备导入、原生 ProRAW 拍摄、比较、全源处理、HEIF 保存与兼容分享的源码；**尚未通过 Apple 编译、装机或真机验收**。

## 当前路径

- Photos/Files 导入，或能力门控后的物理镜头 ProRAW 捕获；完整输入保留为本次编辑的临时文件。
- HNCS 与 FFCS 独立选择。HNCS 保留真实数值核，但 linear-sRGB → virtual native RGB 源域桥仍是实验适配；FFCS 使用 19 款实际 XH2S 参考资产，不声称 iPhone 传感器标定。
- 导入/拍后效果预览走 Float32 → Metal RGBA16Float 高精度 SDR 显示，不经过8位UIImage；不声称屏幕面板原生10bit。导入预览默认最长边 2048px。相机中心与外围视频输出独立缩放，预览像素不决定原始捕获或最终输出大小。
- 最终图从完整源重新解码，精确算法按 64 行输出块处理，写磁盘 RGBAf；颜色/空间处理后才在线性光中 Lanczos 缩小，使用专用 HEIF10 writer 请求 10-bit SDR sRGB HEIF。
- 用户保存仅有 HEIF：独立保存到 Photos / Files。分享先注册原始 HEIC，再提供按需、从最终 HEIF 转出的同尺寸 JPEG 兼容表示；没有 JPEG 导出选项。接收方选择哪种表示、微信能否发送和查看仍未验证。
- 默认关闭的实验性中心实时色彩开关：65³ GPU代理仅省取景空间效果，原始系统取景保留为回退；支持范围与误差见[实现边界](docs/LIVE_COLOR_PROXY.md)。最终照片继续精确处理。
- 原生 iOS 26 Liquid Glass 控件，中心成片框不覆玻璃。主摄/长焦外围使用实际更广物理镜头与近似 FOV 映射、覆盖门控；超广无更广镜头时黑边。光学对齐、视差与硬件组合仍需实测。

每颗物理镜头独立保存实际源能力允许的 12/24/48MP 输出档位。MultiCam 与高分辨率 ProRAW 有实际限制，不能由传感器宣传像素推断可用模式；不支持即明确报错，不静默换格式、降源尺寸或伪造外围。

## 文档

- [已确认需求、偏好推断与建议](docs/REQUIREMENTS.md)
- [架构、颜色域与生命周期](docs/DESIGN.md)
- [有明确替代关系的决策日志](docs/DECISIONS.md)
- [已执行测试、证据与未验证边界](docs/TEST_STATUS.md)
- [FFCS 数值移植与资产准备](docs/FFCS.md)
- [iOS 构建与设备验收](ios/README.md) / [C++ 核](core/README.md)
- [相机能力与取景](docs/camera-capture.md) / [全源导出](docs/FULL_RESOLUTION_EXPORT.md)
- [精确 Float 并行优化](docs/EXACT_FLOAT_PARALLEL.md) / [Apple 精度与加速约束](docs/apple_precision_acceleration.md)
- [当前颜色核心分段性能](docs/COLOR_PERFORMANCE.md) / [硬件与加速路线](docs/HARDWARE_PERFORMANCE.md)
- [高精度 SDR 预览](docs/HIGH_PRECISION_PREVIEW.md)
- [完整实时CPU颜色的成本估计](docs/LOWRES_COLOR_PERFORMANCE.md)（完整实时流水线后置）
- [实验性仅色彩GPU取景](docs/LIVE_COLOR_PROXY.md) / [LUT误差](docs/lut-proxy-preview.md) / [FFCS阶段热点](docs/FFCS_STAGE_PROFILE.md)
- [保存、分享与失败恢复](docs/DELIVERY_AND_RECOVERY.md)
- [来源及分发边界](NOTICE.md)

## 可移植验证

从本目录运行（仓库内为 `GlassCamPrototype/`，与原始技术交付同级）：

```sh
python tools/materialize_ffcs_reference.py
python -m unittest discover -s tests -v
python tools/verify_cpp.py
python tools/verify_linear_export.py
python tools/benchmark_optimized.py
python tools/render_preview.py --synthetic
```

依赖见 `requirements.txt`；使用系统 g++ 编译 C++，不需要 Apple SDK。Python 诊断 PNG 不属于 App 导出选项。具体通过记录见测试状态，不能把静态源码测试算成 Swift 编译或真实 HEIF 验收。

## 验证边界

现有核的数值一致性不证明完整 Phocus RAW pipeline、富士机内 JPEG 等价性、iPhone 标定或真实照片审美。10-bit 编码 API 请求不证明实际位流。原始 RAW/配方长期资料库、Apple 性能与内存/热状态、微信兼容和商业权利清理尚未完成。原始交付及证据保持不变。
