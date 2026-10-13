# GlassCam — HNCS + FFCS 原生效果原型

SwiftUI 原生界面、Apple 图像入口、标准 C++17 颜色/空间后端。沿用现有技术交付，不新增色卡拟合。当前具备导入、原生 ProRAW 拍摄、比较、全源处理、HEIF 保存与兼容分享的源码；**尚未通过 Apple 编译、装机或真机验收**。

三个独立开关控制锐化、颗粒和预设额外裁切，默认保留开关选择，实际效果遵循当前参考参数，切换预设不重置选择。HNCS/FFCS各自只开关原本存在的阶段，FFCS0.2原生表默认无额外颗粒/锐化，须显式开启参考解析叠加才有对应系数。详见[开关与旧配方迁移](docs/EFFECT_TOGGLES.md)。

## 当前路径

- Photos/Files 导入，或能力门控后的物理镜头 ProRAW 捕获；完整输入保留为本次编辑的临时文件。
- HNCS 与 FFCS 独立选择。HNCS已接入render revision8真实预设后曲线、film curve、完整目标WB、方裁切及便携颗粒/锐化；linear-sRGB → virtual native RGB 源域桥仍是实验适配。FFCS已同步0.2.0，提供5个研究表族的50张真实资产及中性默认/显式解析叠加，不声称iPhone传感器标定。详见[revision8合同与验证](docs/HNCS_REVISION8.md)。
- 导入/拍后效果预览走 Float32 → Metal RGBA16Float 高精度 SDR 显示，不经过8位UIImage；不声称屏幕面板原生10bit。导入预览默认最长边 2048px。相机中心与外围视频输出独立缩放，预览像素不决定原始捕获或最终输出大小。
- 最终图从完整源重新解码，裁切后按64行处理；HNCS空间预设额外经过磁盘暂存的全图统计/滤波，再写RGBAf；颜色/空间处理后才在线性光中 Lanczos 缩小，使用专用 HEIF10 writer 请求 10-bit SDR sRGB HEIF。
- 用户保存仅有 HEIF：独立保存到 Photos / Files。分享先注册原始 HEIC，再提供按需、从最终 HEIF 转出的同尺寸 JPEG 兼容表示；没有 JPEG 导出选项。接收方选择哪种表示、微信能否发送和查看仍未验证。
- 默认关闭的实验性中心实时色彩开关：65³ GPU代理仅省取景空间效果，原始系统取景保留为回退；支持范围与误差见[实现边界](docs/LIVE_COLOR_PROXY.md)。最终照片继续精确处理。
- 方案A参考布局：外围使用原生iOS26 Glass.clear；中央成片框按完整窗口最大等比显示，不为控件缩小、不覆玻璃。真实网格、缩略图与设置入口保留，详见[clear玻璃UI](docs/CLEAR_GLASS_UI.md)。主摄/长焦外围使用实际更广物理镜头与近似 FOV 映射、覆盖门控；超广无更广镜头时黑边。光学对齐、视差与硬件组合仍需实测。

每颗物理镜头独立保存实际源能力允许的 12/24/48MP 输出档位。主摄/长焦先双路预览，按快门后明确冻结画面、停止MultiCam，切到同一物理镜头的普通.photo会话拍最高支持ProRAW，再恢复预览。48MP须运行时检测与回调验证；不静默降为12MP，恢复预览失败也不丢已成功照片。见[会话切换](docs/CAPTURE_SESSION_HANDOFF.md)。

## 文档

- [已确认需求、偏好推断与建议](docs/REQUIREMENTS.md)
- [架构、颜色域与生命周期](docs/DESIGN.md)
- [有明确替代关系的决策日志](docs/DECISIONS.md)
- [已执行测试、证据与未验证边界](docs/TEST_STATUS.md)
- [HNCS revision8预设/WB/空间处理](docs/HNCS_REVISION8.md)
- [FFCS 数值移植与资产准备](docs/FFCS.md)
- [iOS 构建与设备验收](ios/README.md) / [C++ 核](core/README.md)
- [相机能力与取景](docs/camera-capture.md) / [方案A透明玻璃UI](docs/CLEAR_GLASS_UI.md) / [全源导出](docs/FULL_RESOLUTION_EXPORT.md)
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
python tools/verify_hncs_revision8.py
python tools/test_hncs_spatial.py --reference reference --large --output validation/hncs-spatial.json
python tools/test_hncs_numpy_rng.py
python tools/benchmark_optimized.py
python tools/render_preview.py --synthetic
```

依赖见 `requirements.txt`；使用系统 g++ 编译 C++，不需要 Apple SDK。Python 诊断 PNG 不属于 App 导出选项。具体通过记录见测试状态，不能把静态源码测试算成 Swift 编译或真实 HEIF 验收。

## 验证边界

现有核的数值一致性不证明完整 Phocus RAW pipeline、富士机内 JPEG 等价性、iPhone 标定或真实照片审美。10-bit 编码 API 请求不证明实际位流。原始 RAW/配方长期资料库、Apple 性能与内存/热状态、微信兼容和商业权利清理尚未完成。原始交付及证据保持不变。

最新FFCS0.2同步：225项整合测试通过，50资产/1,206阶段对新参考最大误差5.52e-15；独立审查通过。Apple编译和设备仍未执行，详见[测试状态](docs/TEST_STATUS.md)。
