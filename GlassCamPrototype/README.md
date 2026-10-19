# GlassCam — HNCS + FFCS 原生效果原型

SwiftUI 原生界面、Apple 图像入口、标准 C++17 颜色/空间后端。当前开发版支持三摄接力变焦、ProRAW、24MP／48MP 输出策略、HDR HEIF 自动保存与单张待完成照片恢复。最低系统为 iOS 27.0。本轮按用户要求先离线开发，完成后统一真机验收；历史手机结果对应其各自版本。见[当前范围](docs/IPHONE_FIRST_USABLE_20261018.md)和[构建、安装与续签](ios/README.md)。

最新：HNCS revision 11 默认保留每张照片的白平衡，并提供 Original preset 选择，修复 Nature 在现有室内照片中新增的黄绿色偏色。209 项回归、Mac 图像／恢复检查、三摄已有 RAW 的 6 张全源 HDR 对照和未签名 iOS Release 编译通过；手机验收仍暂停，新版未安装。见[Nature 完整处理流程与修复](docs/PHOCUS_NATURE_PIPELINE_20261018.md)。

2026-10-18 补充：[X2D II 必要颜色阶段](docs/X2D_COLOR_PIPELINE_20261018.md)、[原始 SILKYPIX／FFCS 审计](docs/FFCS_ORIGINAL_AUDIT_20261018.md)与[受控加速报告](docs/COLOR_PERFORMANCE_20261018.md)。独立 X2D HDR 接口要求原生准备输入；不等于完整 RAW 到成片复刻。默认采用逐位一致的 FFCS 缓存优化，Metal／Core ML 近似候选未启用。最新 206 项回归、Apple 图像检查、ASan/UBSan 和未签名 iOS Release 编译通过。

三个独立开关控制锐化、颗粒和预设额外裁切，默认保留开关选择，实际效果遵循当前参考参数，切换预设不重置选择。HNCS/FFCS各自只开关原本存在的阶段，FFCS0.2原生表默认无额外颗粒/锐化，须显式开启参考解析叠加才有对应系数。详见[开关与旧配方迁移](docs/EFFECT_TOGGLES.md)。

## 当前路径

- 启动即相机；双指变焦、焦段快捷入口和长按标尺控制视角，iOS 自动选择三颗镜头中的实际来源。齿轮打开独立设置页。快门冻结构图、方向、完整配方与输出，自动处理并保存到系统相册。
- HNCS 与 FFCS 独立选择。HNCS revision 11 在 revision 10 的原版亮度锐化、每张 RAW 的 BaselineSharpness、饱和度／灰度顺序上增加独立白平衡选择，原颜色资产保留；Standard 也执行其原厂锐化，HNCS 解码明确关闭 Apple 额外锐化。此前两轮颜色核／曲线检查合计 203,709,420 个通道为 0 差，另有完整串联检查。颗粒仍为便携模型，虚拟源域桥及 HDR 外层适配有独立边界。FFCS 保持 0.2.0 的 5 个研究表族、50 张资产和中性默认。详见[可读反编译分析](docs/PHOCUS_READABLE_ANALYSIS_20261018.md)及[revision 10 验收](docs/PHOCUS_REVISION10_20261018.md)。
- 导入/拍后效果预览走 Float32 → Metal RGBA16Float 高精度 HDR 显示，不经过8位UIImage；不声称屏幕面板原生10bit。导入预览默认最长边 2048px。主摄预览独立缩放，预览像素不决定原始捕获或最终输出大小。
- 最终图从完整 RAW 解码并处理；相机施加的变焦不再次作为软件裁切。HNCS 空间阶段保留全图处理，完成颜色／空间阶段后再在线性光中缩放，编码为 10-bit BT.2020/PQ HDR HEIF。
- 24MP 档输出 24MP；48MP 档在最终构图有效像素估计达到 24MP 时输出 48MP，否则输出 24MP。必要时插值并标明实际尺寸；旧 12MP 选择迁移到 24MP。保存失败复用同一 HEIF，回看和兼容分享继续使用最终成片。
- 一张 RAW 与配方成功持久保留后可跨进程恢复，后台暂停处理、前台继续；Photos 写入结果未知时让用户核对后决定是否重存，保持仅添加权限。
- 默认关闭的实验性中心实时色彩开关：65³ GPU代理仅省取景空间效果，原始系统取景保留为回退；支持范围与误差见[实现边界](docs/LIVE_COLOR_PROXY.md)。最终照片继续精确处理。
- 相机画面按完整窗口最大等比显示，周围为不透明纯黑区域，网格、缩略图和设置入口保留；App 自定义界面不再使用 Liquid Glass 或材质模糊。

取景与 ProRAW 共用一个普通 `.photo` 会话，首选系统虚拟三摄，按实际 ProRAW 能力回退到物理镜头；不恢复历史 MultiCam 外围预览。倍率和镜头能力在设备上查询；每次拍摄核验真实 RAW 类型和尺寸。实际三摄、变焦构图、像素估计和恢复仍需最终设备验收。旧[单主摄版本说明](docs/SINGLE_CAMERA.md)保留为历史。

## 文档

- [首版范围、分辨率政策与实施状态](docs/IPHONE_FIRST_USABLE_20261018.md)
- [领域术语](../GLOSSARY.md) · [单张持久恢复](docs/adr/0001-durable-single-capture.md) · [插值输出取舍](docs/adr/0002-adaptive-output-resolution.md)
- [已确认需求、偏好推断与建议](docs/REQUIREMENTS.md)
- [架构、颜色域与生命周期](docs/DESIGN.md)
- [有明确替代关系的决策日志](docs/DECISIONS.md)
- [已执行测试、证据与未验证边界](docs/TEST_STATUS.md)
- [Phocus 可读 C 反编译、默认参数与处理顺序](docs/PHOCUS_READABLE_ANALYSIS_20261018.md)
- [Nature 完整处理流程、白平衡与偏绿修复](docs/PHOCUS_NATURE_PIPELINE_20261018.md)
- [HNCS revision 10 锐化与颜色链路验收](docs/PHOCUS_REVISION10_20261018.md)
- [HNCS revision8预设/WB/空间处理](docs/HNCS_REVISION8.md)
- [HNCS 颜色核查与 iPhone 保精度提速实测](docs/HNCS_AUDIT_AND_SPEED_20261017.md)
- [RAW 输入统一、内嵌配置与真机成片对照](docs/RAW_INPUT_STUDY_20261017.md)
- [FFCS 数值移植与资产准备](docs/FFCS.md)
- [iOS 构建与设备验收](ios/README.md) / [C++ 核](core/README.md)
- [相机能力与取景](docs/camera-capture.md) / [单摄黑边界面](docs/SINGLE_CAMERA.md) / [全源导出](docs/FULL_RESOLUTION_EXPORT.md)
- [精确 Float 并行优化](docs/EXACT_FLOAT_PARALLEL.md) / [Apple 精度与加速约束](docs/apple_precision_acceleration.md)
- [当前颜色核心分段性能](docs/COLOR_PERFORMANCE.md) / [硬件与加速路线](docs/HARDWARE_PERFORMANCE.md)
- [高精度 HDR 预览](docs/HIGH_PRECISION_PREVIEW.md)
- [默认 HDR 导出与高光保留](docs/HDR_EXPORT.md) / [设置前置与自动保存](docs/AUTOMATIC_CAPTURE.md)
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

上游 FFCS 0.2 的历史证据保留。最新本地 206 项测试、Apple 图像回归、48MP RAW 导出、ASan/UBSan 与 iOS Release 编译通过；当前与历史构建的数值证据、24/48MP 测量及真机边界见[测试状态](docs/TEST_STATUS.md)。
