# GlassCam — HNCS + FFCS 原生效果原型

SwiftUI 原生界面、Apple 图像入口、标准 C++17 颜色/空间后端。沿用现有技术交付，不新增色卡拟合。当前具备导入、原生 ProRAW 拍摄、比较、全源处理、HEIF 保存与兼容分享；**当前分支为单主摄黑边版本：启动直接进入相机，已通过 Xcode 27.0 Release 构建及 iPhone 18 Pro Max 的 48MP ProRAW 自动拍摄检查**。

三个独立开关控制锐化、颗粒和预设额外裁切，默认保留开关选择，实际效果遵循当前参考参数，切换预设不重置选择。HNCS/FFCS各自只开关原本存在的阶段，FFCS0.2原生表默认无额外颗粒/锐化，须显式开启参考解析叠加才有对应系数。详见[开关与旧配方迁移](docs/EFFECT_TOGGLES.md)。

## 当前路径

- Photos/Files 导入，或能力门控后的物理镜头 ProRAW 捕获；完整输入保留为本次编辑的临时文件。
- HNCS 与 FFCS 独立选择。HNCS已接入render revision8真实预设后曲线、film curve、完整目标WB、方裁切及便携颗粒/锐化；linear-sRGB → virtual native RGB 源域桥仍是实验适配。FFCS已同步0.2.0，提供5个研究表族的50张真实资产及中性默认/显式解析叠加，不声称iPhone传感器标定。详见[revision8合同与验证](docs/HNCS_REVISION8.md)。
- 导入/拍后效果预览走 Float32 → Metal RGBA16Float 高精度 SDR 显示，不经过8位UIImage；不声称屏幕面板原生10bit。导入预览默认最长边 2048px。主摄预览独立缩放，预览像素不决定原始捕获或最终输出大小。
- 最终图从完整源重新解码，裁切后按64行处理；HNCS空间预设额外经过磁盘暂存的全图统计/滤波，再写RGBAf；颜色/空间处理后才在线性光中 Lanczos 缩小，使用专用 HEIF10 writer 请求 10-bit SDR sRGB HEIF。
- 用户保存仅有 HEIF：独立保存到 Photos / Files。分享先注册原始 HEIC，再提供按需、从最终 HEIF 转出的同尺寸 JPEG 兼容表示；没有 JPEG 导出选项。接收方选择哪种表示、微信能否发送和查看仍未验证。
- 默认关闭的实验性中心实时色彩开关：65³ GPU代理仅省取景空间效果，原始系统取景保留为回退；支持范围与误差见[实现边界](docs/LIVE_COLOR_PROXY.md)。最终照片继续精确处理。
- 相机画面按完整窗口最大等比显示，周围为不透明纯黑区域，网格、缩略图和设置入口保留；App 自定义界面不再使用 Liquid Glass 或材质模糊。

仅使用一颗物理主摄。取景和 Apple ProRAW 拍摄共用普通 `.photo` 会话，没有 MultiCam、外围取景或按快门重建会话。冷启动的拍照准备期保留 2 秒，之后的快门沿用已经运行的会话。处理后的 12/24/48MP 输出选择仍与原始 RAW 分辨率分开，实际 RAW 类型和尺寸必须通过回调校验；拍摄完成进入编辑页，缩略图也可打开编辑/导入。见[单摄版本说明](docs/SINGLE_CAMERA.md)。

## 文档

- [已确认需求、偏好推断与建议](docs/REQUIREMENTS.md)
- [架构、颜色域与生命周期](docs/DESIGN.md)
- [有明确替代关系的决策日志](docs/DECISIONS.md)
- [已执行测试、证据与未验证边界](docs/TEST_STATUS.md)
- [HNCS revision8预设/WB/空间处理](docs/HNCS_REVISION8.md)
- [FFCS 数值移植与资产准备](docs/FFCS.md)
- [iOS 构建与设备验收](ios/README.md) / [C++ 核](core/README.md)
- [相机能力与取景](docs/camera-capture.md) / [单摄黑边界面](docs/SINGLE_CAMERA.md) / [全源导出](docs/FULL_RESOLUTION_EXPORT.md)
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

macOS 上另运行 `python3 -B tools/test_apple_images.py`：直接编译生产 Swift/C++，检查 Core Image 分块行序、奇数尺寸裁切、HNCS 空间文件、Metal 预览、实际 HEIF 和分享提供者。仅需 Apple 开发工具与 Metal，不需要 Python 第三方包；验证文件在退出时清理。

## 验证边界

现有核的数值一致性不证明完整 Phocus RAW pipeline、富士机内 JPEG 等价性、iPhone 标定或真实照片审美。10-bit 编码 API 请求不证明实际位流。原始 RAW/配方长期资料库、Apple 性能与内存/热状态、微信兼容和商业权利清理尚未完成。原始交付及证据保持不变。

上游FFCS0.2同步保留225项整合测试及50资产/1,206阶段的历史证据。本机已修复位图行序、Metal方向及编码前图像范围问题，77项相关便携检查和Apple图像回归通过；真机与接收端验证范围见[测试状态](docs/TEST_STATUS.md)。
