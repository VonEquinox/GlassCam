# LUMIX 色彩接入 · 2026-10-26

本文保留 revision 1 的历史记录。后续 ProRAW 输入与完整 SDR VE 像素分支实现见 [revision 2](LUMIX_PRORAW_20261026.md)。

GlassCam 在 HNCS、FFCS 之外新增独立的 **LUMIX** 选项，接入 SILKYPIX 8 SE 中 DC-S1M2 的 16 个原始 SDR Photo Style LUT。风格选择、设置记忆、快门时冻结的处理配方、成片预览、后台恢复及全分辨率 HDR HEIF 导出共用该选项。

## 可选风格

| Photo Style | 原始枚举 | 原始资源 |
|---|---:|---|
| Standard | 1 | L00801 |
| Vivid | 2 | L00803 |
| Natural | 3 | L00805 |
| Monochrome | 4 | L00831 |
| Landscape | 5 | L00811 |
| Portrait | 6 | L00813 |
| L.Monochrome | 8 | L00815 |
| Like709 | 11 | L00827 |
| L.Monochrome D | 13 | L00817 |
| Flat | 14 | L00809 |
| Cinelike D2 | 16 | L00823 |
| Cinelike V2 | 17 | L00825 |
| L.Monochrome S | 18 | L00819 |
| L.Classic Neo | 19 | L00807 |
| Leica Monochrome | 20 | L00835 |
| Cinelike A2 | 21 | L00821 |

相机标识和名称由原二进制中的 `GetCameraID`、`Get3DLUTFileName` 与已初始化的枚举表核对。本轮确认 DC-S1M2 对应相机 ID 106、L008 资源组；该映射在原报告中尚未解出。没有把文件编号直接当风格编号，也没有按相机名称猜测 LUT 分组。

## 处理与接入

原生解码器离线解压原 `.s3d`，保留全部 **129³** 个网格点，再无损重排、zlib 压缩为运行时资源；16 项归档约 76.7 MB。构建时只校验、展开自包含归档，不依赖相邻的分析目录或原框架。

运行路径为：Apple 解码与源白平衡 → GlassCam HDR 幅度分离 → 效果曝光 → RGB12 → 原始 LUT 的三线性插值及舍入 → sRGB EOTF → Float32 RGBA → 恢复 HDR 幅度 → 原有 10-bit BT.2020/PQ HEIF。

插值保留原实现的步长 32、白值 4095、末端保护节点及 `floor(x+0.5)`，不将坐标误改为 `x×128/4095`。照片导出按已有条带路径处理完整源图，不使用取景 LUT 代理或 8-bit 中间图。没有资源、校验失败或风格非法时明确报错，保留原照片供重试。

`ProcessingRecipe.lumix` 保存风格与渲染版本，旧 HNCS／FFCS 配方缺少该字段时默认补 Standard，保持原引擎与原白平衡语义。白平衡解析会把 LUMIX 配方完整带入最终快照；切换引擎或修改设置不会改变已开始处理的照片。

取景仍显示系统画面，成片预览使用完整 LUMIX 后端。实验实时色彩不会把 LUMIX 错交给 FFCS。LUMIX 页面不显示当前后端未实现的颗粒／锐化开关；已有 HNCS／FFCS 开关继续保存。

## 复现范围

这里实现的是**原始 Photo Style LUT 对 iPhone 输入的适配**。固定使用每种风格的第一张原始 LUT；没有宣称获得松下传感器原始色域或完成全套 SILKYPIX RW2 管线。原始 RAW 双表白平衡混合、低 ISO／preLUT、VE 非 LUT 分支、去马赛克、空间降噪锐化及原始 CMS 转换不属于本适配。V-Log 和 HLG 专用表没有作为普通显示风格暴露。

原始数据和插值相同，可以证明色彩节点按给定输入工作；不能证明 iPhone 成片与松下机内 JPEG 或 SILKYPIX 开发结果相同。完整来源和接口边界见 [ORIGIN](../reference_lumix/ORIGIN.md)。

## 验证

`validation/lumix-integration-20261026/` 保存提取、原生数值、生产 Swift／Core Image／HEIF、Python 回归及 iOS Release 的记录。

- `tools/verify_lumix.py` 比较每种风格的 12,304 组独立原程序样本，合计 **196,864** 组，覆盖全部 4,096 级灰阶、随机颜色、边界和通道顺序；RGB12 输出逐值一致。
- 同时检查 Float32 适配、并发条带与整图逐位一致、非法输入，以及缺失／损坏资源的拒绝行为。
- `tools/test_lumix_images.py` 运行真实生产 Swift 管线，覆盖全部风格预览、跨条带 HDR 编码、配方持久化、设置恢复及旧引擎配方兼容。

本轮原生数值检查、16 种成片预览、10-bit HDR HEIF、配方与设置恢复、217 项 Python 回归及 iOS Release 构建均通过。HDR 验收使用保留高光的 Float32 TIFF，避免压缩 HEIF 输入的缩略图／全尺寸解码差异进入颜色节点对照；Standard 和 L.Monochrome 的分条、整图及跳过预览的导出解码像素一致。

最终文件指纹及安装状态见 `validation/lumix-integration-20261026/verification.json`。本轮未安装或启动手机，Mac 夹具不能代替真机成片验收。
