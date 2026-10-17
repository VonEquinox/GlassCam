# 高精度 HDR 效果预览

> 当前界面已改为相机、独立设置和成片查看，旧 before/after 编辑入口不再开放；本文件的底层 Float/Metal 精度约束继续适用。见[自动拍摄](AUTOMATIC_CAPTURE.md)。

更新：2026-10-17。本轮 Xcode 27 模拟器 Release 构建、31 项相关便携检查及本机 Core Image/Metal/HEIF 回归通过，包含新增显示层 headroom 检查；iPhone 物理屏幕在不同亮度下的表现仍待真机验证。

## 当前实现

- 解码后的原图预览保留 Float32 linear-sRGB RGBA；HNCS/FFCS 处理后的预览也使用精确 Float 输出。HNCS 内部 double / UInt16 核不变，FFCS 原数学不变。
- before/after 使用同一个按需重绘的 MTKView：CPU 只在配方变化时处理，拖动比较线在 Core Image / Metal 中裁切合成，不重新运行颜色核。
- 不再将效果输出转成 UInt8、8位 CGImage 或 UIImage 再显示。使用 RGBAf 输入/工作格式，最终 drawable 为 `.rgba16Float`。
- render destination 与 CAMetalLayer 都标为 extendedLinearSRGB；保留超白浮点值。成片查看页和缩略图通过 `PreviewDisplay` 向显示层传递本张照片的 headroom，让 Core Animation 按屏幕当前可用范围做色调映射。RAW 解码开启 EDR，普通图片请求 HDR 解码；效果外层恢复源高光增益，最终导出 BT.2020/PQ HEIF。
- 编辑器与实时代理共用 `PreviewRendering`，用 `CIRenderDestination.isFlipped=true` 对齐Metal的顶部首行；源位图和效果计算保持从上到下，不额外翻转照片。渲染任务与像素所有者保留至GPU完成。
- 半精度只用于最终显示存储，不把颜色算法改成 half，也不声称面板原生10bit。无法初始化 Metal 或 GPU 命令失败时显示错误，不静默降成8位图。
- Float 数据由不可变所有者保持，GPU 完成前继续保留；视图销毁或新图替换不提前释放当前命令引用的内存。

## 2026-10-17：成片显示端的 HDR 适配

`PreviewRaster` 保存实际 RGB 峰值相对参考白的比例，最低为 1；裁切沿用源图的保守上界。`PrecisionPreview` 在请求重绘、取得 drawable 前更新显示配置。iOS/macOS 26 及以上使用 `contentsHeadroom`、`preferredDynamicRange=high` 和 `toneMapMode=ifSupported`，由系统随屏幕亮度和 EDR 能力变化适配；旧系统使用按显示参考白归一化的 HDR10 EDR metadata。

同一个视图从 HDR 换到较低 headroom 的照片或 SDR 时会更新配置。旧比较组件只采用实际显示的图像范围，部分比较时覆盖两侧；尺寸不匹配的旧结果不参与。该配置用于 App 内的成片查看和缩略图，显示映射不写回源像素或导出文件。实时取景继续使用其独立显示路径。

`tools/test_apple_images.py` 增加实际 CAMetalLayer 检查，覆盖 8× → 2× → SDR 的元数据更新、半浮点 drawable、比较端点和源像素保持；现有 Metal 像素与 HEIF 回归继续验证渲染/导出边界。物理屏幕在不同亮度下的观感仍需真机验收。

接口依据：[CAMetalLayer EDR metadata](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata)、[CALayer contentsHeadroom](https://developer.apple.com/documentation/quartzcore/calayer/contentsheadroom)。

## 来源位深与处理精度分开

普通图片的 ImageIO 缩略解码可能只有8bit，即使后续缓冲为Float也不能恢复丢失的信息。界面显示实际 `thumbnail.bitsPerComponent`。RAW 显示“Float32 decoded”，明确这不是传感器原生位深。

实时相机视频是独立路径，当前选用8bit YCbCr420（420f/420v），首帧检查像素格式与尺寸，设置菜单将在运行时首帧检查通过后显示该格式；此检查尚未在Apple设备执行；拍摄的 ProRAW 不取自视频帧。高精度拍后/导入效果显示不代表相机视频输入自动变成10bit。10bit视频输出必须按设备/activeFormat/SDR颜色空间另行查询和验证，不能只改最终纹理名字。

## 已执行的软件检查

`python tests/test_precision_preview_source.py --write-report`

-4096个线性灰阶样本经 IEEE binary16 存储后仍有3073级，超过8位的256级。
- 最大线性误差0.000244081；换算到sRGB编码域最大误差0.000107317；本样本均低于半个归一化10bit步长0.000488759。
- 原色/灰阶/alpha样本保留，opaque alpha精确为1。

另检查0…1范围全部15,360个binary16相邻量化区间的中点两侧极限：线性域最大0.000244141，sRGB域最大0.000160776，也低于同一预算。此处仅建立round-to-nearest软件存储模型的区间界，不证明Apple显示链。

这些都是软件存储量化检查，不是GPU实测、完整颜色管线误差证明、屏幕位深检测或对所有解码器的保证。结果见 `validation/precision-preview-storage.json`。既有 CPU 参考数值回归继续适用；历史8bit fast benchmark仅保留为对照，不代表当前App效果预览路线。

## 与实验性实时颜色的关系

本文件描述拍后/导入before-after高精度显示。完整CPU实时流水线仍后置；用户随后批准仅颜色的轻量方案，中心新增默认关闭的实验GPU代理，主摄保留系统视频。它不逐帧运行完整HNCS/FFCS，也不替换最终图片算法。支持参数、精度与生命周期见 [实验取景](LIVE_COLOR_PROXY.md)；帧率/丢帧/热状态和源格式仍需设备验证。

## Apple 侧待验收

- 真机 Release 运行；检查实际 Metal drawable 和工作格式，确认无隐式8bit中间降级。
- 不对称方向图、before/after端点与滑线、窗口/旋转尺寸变化；确认一次色彩转换、无上下翻转和暗/亮偏差。
- 超过256级的真实渐变、负值裁切与超白HDR保留、sRGB/P3来源、alpha黑底。
- 连续拖动、切换配方/图片、视图销毁时GPU在途、无Metal/命令失败状态。
- 峰值内存与热状态。两份Float32 RGBA预览各需16字节/像素，此外还有输入RGB、CoreImage/Metal资源和解码器；不能将低分辨率预览理解为固定总内存。

官方API与精度限制见 [Apple精度研究](apple_precision_acceleration.md)。

HDR 的编码合同、参考效果的适配范围与回读检查见 [HDR 导出](HDR_EXPORT.md)。上述 binary16 软件量化预算只覆盖 0…1 区间，不声称对整个 HDR 区间保持同一绝对误差。
