# 文档导览

文档按数据流划分职责，术语统一见 [GLOSSARY.md](../GLOSSARY.md)。行为以主题文档为准，取舍查 ADR，变化查 CHANGELOG。

## 阅读路径

| 目的 | 最短顺序 |
|---|---|
| 理解一次快门到相册落盘 | [架构](architecture.md) → [拍摄与恢复](capture-and-recovery.md) → [F5](f5.md) → [图像管线](image-pipeline.md) |
| 修改色彩引擎或 GPU 着色器 | [原生与 Metal 契约](adr/0017-native-and-metal-contracts.md) → [图像管线](image-pipeline.md) → [HNCS](color/hncs.md)／[FFCS](color/ffcs.md)／[LUMIX](color/lumix.md) → [测试](testing.md) |
| 修改取景器、外围玻璃或回看 UI | [取景与回看](viewfinder.md) → [外围玻璃](peripheral-glass.md) → [术语表](../GLOSSARY.md) |

## 子系统主题

| 文档 | 负责边界 | 核心代码目录 |
|---|---|---|
| [架构](architecture.md) | 模块、构建产物、快门至相册的数据与色彩域流转 | [App](../App/GlassCam)、[GlassCamKit](../Packages/GlassCamKit/Package.swift) |
| [拍摄与恢复](capture-and-recovery.md) | 两槽准入、冻结快照、持久化、相册回执与重试 | [Camera](../App/GlassCam/Camera)、[Capture](../Packages/GlassCamKit/Sources/Capture) |
| [F5](f5.md) | Bayer 归一化、配准、曲率重建、镜头操作与调色前归档 | [F5](../Packages/GlassCamKit/Sources/F5)、[CMetalF5](../Packages/GlassCamKit/Sources/CMetalF5) |
| [图像管线](image-pipeline.md) | 源图、曝光、HDR、分条、缩放、HEIF 与 JPEG | [ImagingCore](../Packages/GlassCamKit/Sources/ImagingCore)、[CMetalImage](../Packages/GlassCamKit/Sources/CMetalImage) |
| [取景与回看](viewfinder.md) | 控件、测光交互、实时色彩代理与浮点回看 | [UI](../App/GlassCam/UI)、[Camera](../App/GlassCam/Camera) |
| [外围玻璃](peripheral-glass.md) | 双路配对、接缝分析、遮黑与同步呈现 | [Peripheral](../Packages/GlassCamKit/Sources/Peripheral) |
| [HNCS](color/hncs.md) | 虚拟白点、原厂颜色核、HDR 工作尺度与空间效果 | [CHNCS](../Packages/GlassCamKit/Sources/CHNCS) |
| [FFCS](color/ffcs.md) | 表族、参考调整、颗粒、锐化与受限实时代理 | [CFFCS](../Packages/GlassCamKit/Sources/CFFCS) |
| [LUMIX](color/lumix.md) | Photo Style、双色温表与浮点色域压缩 | [CLUMIX](../Packages/GlassCamKit/Sources/CLUMIX) |

## 工程规范

- [工作规则](../AGENTS.md) · [文档写法](writing-docs.md) · [测试层次与命令](testing.md) · [构建与发布](release.md)。
- 原生修改先确认[契约等级与验收入口](adr/0017-native-and-metal-contracts.md)，行为变化同步主题文档与 [CHANGELOG](../CHANGELOG.md)。

## 参考索引

- [架构决策](adr/README.md) · [术语表](../GLOSSARY.md) · [变更记录](../CHANGELOG.md) · [来源与权利](../NOTICE.md)。
- 调查、实验、性能测量、逆向分析与设备证据保存在独立的 `GlassCam-research` 仓库。
