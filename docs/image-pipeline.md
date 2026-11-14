# 图像管线与成片导出

`ImagingCore` 与 `CMetalImage` 将场景线性输入与冻结的处理配方转换为 10-bit BT.2020/PQ HEIF，并提供原始 HEIF 与兼容 JPEG 分享。相机拍摄的输入由 [F5](f5.md) 重建为扩展线性 sRGB（`SceneLinearImage`）；本地基线与内部图像 API 另支持通过 `CIRAWFilter` 解码外部 RAW 或普通图片。最终导出始终在完整源尺寸上完成色彩与空间处理，再在线性光中调整成片尺寸。

## 工作方式

### 场景线性输入与外部 RAW 解码

Speed／Balanced 的整数 Bayer 输入由 [F5](f5.md) 在 C++／Metal 中完成坏点修复、降噪、去马赛克、镜头操作、一次相机矩阵白平衡和基准曝光，以 `SceneLinearImage` 直接进入 `ImagePipeline.writeLinearHEIF`。颜色阶段直接使用扩展线性 sRGB，绑定拍摄白点、实际 ISO 与 `BaselineSharpness`，不再经过系统 RAW 解码器。

内部文件入口（`SourceImageFile`、`ImportedImage` 及本地 ProRAW 基线）接收外部 `dng`／`raw` 或普通图片：

- **外部 RAW（`configureRAW`）**：完整导出固定 `scaleFactor = 1`（缩小工作图默认最长边 2048，可选 256–4096）。当前配方采用 `cameraNeutral`，关闭 Apple 全局色调曲线（`boostAmount = 0`），保留照片的 `baselineExposure`、局部色调映射和色域映射，EDR 默认设为 1。HNCS 路径将解码器锐化设为 0 并读取 DNG 的 `BaselineSharpness` 交给 HNCS 空间阶段；LUMIX 清除其他引擎遗留的解码器锐化覆盖。保留 Apple 锐化的全源读取插入固定分块缓存，在空间处理与编码前释放。历史配方兼容保留 `sceneLinear` 与 `appleRendered`。
- **普通图片**：按内嵌色彩配置转换到 extended linear sRGB 并展开 HDR；所有输入均规范化方向并将透明区域合成到黑色背景。

### 白平衡、曝光与 HDR 工作域

`ProcessingRecipe.resolvingWhiteBalance` 只绑定一次照片白点（含 temperature、tint 和完整 xy），绑定后随配方持久化，供重试与导出复用；LUMIX 的 `sourceISO` 同样只在首次绑定时从元数据写入。HNCS 用 xy 建立虚拟捕获基线，模型色温用于工厂矩阵与 LUT 选择；无法取得有效 RAW 白点时分别标记 `renderedD65` 或 `fallbackD65`。

管线 revision 2 先将用户效果曝光 `exposureEV` 作为 `2^EV` 标量施加在线性 RGB 上，后端收到的曝光为 0：

- **HNCS（revision 12）**：在扩展工作域保留高光幅度，空间颗粒与锐化作用于完整高光细节。
- **FFCS、LUMIX 与旧 HNCS**：逐像素提取 `max(1, R, G, B)`，将归一化颜色交给对应引擎，返回后再恢复高光幅度。恢复先于输出缩放。

CPU C ABI 内核保持各引擎的数值类型、运算次序及 `-fno-fast-math -ffp-contract=off`；并行处理共享不可变上下文。RGB／RGBA 打包、效果曝光、高光分离／恢复、实时立方体节点、像素范围校验与峰值扫描由 `float_raster.cpp` 承担，ARM64 使用 NEON 加速连续遍历，保留标量尾部及负零位型；Swift 负责缓冲所有权与错误传播。

### GPU 成片处理与有界分条

成片导出先按源像素确定配方裁剪，再处理完整源图。FFCS／LUMIX 颜色和 HNCS 原生锐化通过 Metal 执行，HNCS 颜色量化保留精确 C++；`CMetalImage` 用 Objective-C++ 管理不可变参数、GPU 命令和两个交替复用的有界缓冲（单缓冲目标 16 MiB）：

| 路径 | 分条、空间范围与 GPU／CPU 分工 |
|---|---|
| FFCS | `CIImageProcessorKernel` 直接读取 Core Image 的 Float32 Metal 纹理执行颜色、颗粒与水平／垂直两趟一维 Gaussian 锐化；请求完整 ` halo ` 以保证跨块连续，颗粒使用整图坐标。 |
| HNCS | C++ 打包、施加曝光并执行精确颜色核，写出完整的 Float32 RGB 工作文件并统计整图最大尺度；原生整数锐化以两个带邻域的 Metal 缓冲（单 RGB 缓冲上限 32 MiB 另加 UInt16 亮度平面）运行，颗粒随机流、全图统计与后置颜色结束阶段沿用 C++，复用读写缓冲直接生成 RGBAf 文件。 |
| LUMIX | Metal 读取原始 129³ LUT（12 位网格整数权重插值），在纹理上分条完成曝光、颜色与高光恢复后写出。 |

外部 RAW 解码源与 CPU 参考路径固定每次请求 64 个输出行；F5 线性源及其他 GPU 输入按缓冲容量分块。位图和文件使用自上而下行序，Core Image 矩形使用左下原点。成片颜色与锐化在 App 使用预编译 Metal 库，SwiftPM 测试编译同一份源码并采用 safe／precise 数学选项；其 CPU 回退保留参考路径，失败或取消丢弃临时结果。F5 重建要求 Metal。

成片 RGBAf 按每像素 16 字节写入 `ExportRasterFile`。F5 线性输入与成片编码均通过 C++ 文件供给器（`pread` 并发读取 256×256 像素块）供给 Core Image，不分配整幅位图表面。开始前预检尺寸乘法与磁盘可用空间（含成片、空间工作图、编码余量及 64 MiB 预留）；临时文件随所有者释放清理。

### GPU 精度预算

GPU Float32 颜色结果与 CPU 参考结果经相同 Core Image 转换至 BT.2020/PQ，按 ITU-R BT.2124 的 ΔEITP 验收，同时要求不新增黑白截断、不产生灰阶渐变反转；HNCS 整数锐化要求与 CPU 位级一致：

| 指标 | 上限 |
|---|---:|
| 平均 ΔEITP | 0.1 |
| P95 ΔEITP | 0.25 |
| P99 ΔEITP | 0.5 |
| 编码前最大 ΔEITP | 小于 1.0 |
| HEIF 解码后最大 ΔEITP | 小于 3.0 |
| HDR 峰值相对误差 | 0.001 |

### 尺寸缩放、HDR 编码与分享

相机拍摄统一使用 `ExportSettings.camera24`：完成裁剪、色彩与空间效果后，在线性光中以 Lanczos 将像素总数缩放到约 24MP（宽高取偶数，保持构图比例；滤镜前延展源图边缘防止黑边）。`ExportSettings.native` 与显式不放大宽高仅供内部图像处理使用。

最终编码使用 `writeHEIF10Representation`、BT.2020/PQ 色彩空间，压缩质量固定为 1.0。HNCS 扩展工作域在线性 BT.2020 中裁剪色域外负值与缩放振铃，其他路径保留线性 sRGB 裁剪域；高光上限按 10,000 nit 除以 203 nit 参考白计算并写入 headroom。编码前挂载相机、镜头、曝光与拍摄日期元数据（方向规范为 1，移除失效 MakerNote），写完后回读校验尺寸、10 位深度、HDR 色彩空间与关键元数据。

相册保存与首选分享直接交付原 HEIF。分享按 HEIC、JPEG 顺序注册类型；仅当接收方请求 JPEG 时，才从已完成 HEIF 按需生成同尺寸、8 位 sRGB SDR 副本（`CIToneMapHeadroom` 压缩高光，质量 0.95）并缓存复用。

## 不变量

1. 改动任一处理配方字段都会改变配方身份，且编码往返保留其值。— `ImagingCoreTests/RecipeTests.changedRecipeField_changesIdentityAndSurvivesCodable`
2. 照片白点只绑定一次，绑定后随配方编码往返；拍摄后修改设置不改变已冻结照片的处理或重试。— `ImagingCoreTests/WhiteBalanceTests.automaticWhiteBalance_bindsPhotoOnceAndSurvivesCodable`、`CaptureTests/WorkflowTests.settingsMutation_doesNotRetargetFrozenCaptureOrRetry`
3. 当前配方的曝光等价于先缩放完整线性源 RGB 再以零曝光处理；缺失管线版本的旧配方继续重放固定曝光 golden。— `ImagingCoreTests/ColorChainTests.exposure_matchesScalingSceneLinearSource`、`unversionedRecipe_replaysFrozenExposureGolden`
4. GPU 颜色结果落在规定的 HDR ΔEITP 预算内，HNCS 锐化在 HDR 尺度和分块边界上与 CPU 位级一致。— `ImagingCoreTests/MetalColorTests.pointwiseColor_staysWithinHDRBudget`、`spatialGPU_matchesCPUIncludingTileBoundaries`
5. 原生渲染保留自上而下行序与末块像素，渲染前取消不写入像素，HNCS 文件结束阶段与内存参考逐位一致。— `ImagingCoreTests/MetalColorTests.nativeRenderer_preservesTopDownRowsAndTail`、`cancelledNativeRenderer_leavesEmptyDestination`、`nativeFinishFile_matchesReferenceAcrossChunks`
6. 浮点文件分块读取与位图输入在裁剪、方向、负值和 HDR 上逐值一致；读取失败拒绝成片。— `ImagingCoreTests/FileRasterTests`
7. 全源分条导出与空间工作图在裁剪、空间效果和缩放后符合整图参考及直接编码结果；HDR 高光细节参与 HNCS 锐化。— `ImagingCoreTests/ColorChainTests.spatialStripExport_matchesWholeImageAndDirectBytes`、`ImagePipelineTests.fullSourceExport_matchesWholeFrameAndDirectEncoding`、`spatialWorkFile_matchesNativeMemoryPath`、`hdrSpatialProcessing_sharpensNeutralHighlightDetail`
8. 输出放大与缩小保留 HDR 常量颜色及图像边界；导出取消时不交付成片文件且保留源照片。— `ImagingCoreTests/ImagePipelineTests.resizingConstantHDR_preservesColourThroughImageEdges`、`cancellation_discardsOutputAndRetainsSource`
9. 分享保留原始 HEIF 字节，按需生成的兼容 JPEG 保留完整尺寸、8 位深度并在并发请求间只编码一次；两类文件均保留拍摄元数据且 HEIF 维持 10 位 HDR。— `ImagingCoreTests/ShareTests`、`CaptureMetadataTests`
10. 显式开启本地 ProRAW 基线（`GLASSCAM_DNG_DIR`）时，保持真实解码白点、冻结锐化基准、重试像素与原生 10 位 HDR 输出。— `ImagingCoreTests/BaselineTests`
11. 浮点搬运保留有符号 HDR 位型，曝光只施加一次，高光恢复保留 alpha 与负零。— `ImagingCoreTests/FloatRasterTests.packing_preservesSignedHDRBitsAndSuppliesOpaqueAlpha`、`normalization_appliesExposureOnceAndRetainsSignedChannels`、`restoration_clampsRGBAndPreservesAlpha`、`restoration_preservesNegativeZeroAtTheFloatBoundary`
12. HNCS 完整输入／输出范围重叠及 FFCS 双输出重叠在写入前被拒绝。— `tests/numeric/test_native_buffer_contracts.py::test_hncs_overlapping_float_ranges_fail_without_writes`、`tests/numeric/test_native_buffer_contracts.py::test_hncs_overlapping_byte_output_fails_without_writes`、`tests/numeric/test_native_buffer_contracts.py::test_ffcs_overlapping_outputs_fail_without_writes`
13. 范围校验不改写像素，在向量块和标量尾部拒绝非有限与越界值，有限值检查保留完整有符号范围。— `NativeTests/float_raster_smoke`

## 数据与版本

`ProcessingRecipe` 保存色彩模式、效果曝光、模型色温、模拟风格、随机种子、各引擎设置、独立效果开关（`applyGrain`、`applySharpness`、`applyExtraCrop`）、照片白平衡、RAW 输入策略（当前 `cameraNeutral`）与管线版本（当前 `pipelineRevision = 2`）。拍摄元数据由 `PhotoMetadata` 独立管理。

历史记录解码保留旧字段回退（缺省 `pipelineRevision = 1`、缺省 `rawInputPolicy = legacy` 及旧 HNCS `square-crop` 裁剪语义），版本 1 曝光参考冻结于 [color-pipeline-v1-exposure.json](../tests/fixtures/color-pipeline/color-pipeline-v1-exposure.json)。新拍摄偏好在 `CameraSettingsStore` 中独立采用当前版本与标准构图。

## 已知限制

- HNCS 颜色量化、全图颗粒统计和后置颜色结束阶段在 CPU 执行。
- 分条和磁盘暂存只约束应用侧缓冲，系统解码、缓存、HEIF 编码及映射页仍可能分配整图内部表面。
- 外部 RAW 的 `cameraNeutral` 保留 Apple 局部色调处理，源适配与 HNCS 虚拟白点模型尚非跨相机色卡标定结果。
- 同步系统解码或编码调用在返回后才能响应取消。
- 实际 HDR 显示亮度、接收方分享协商结果及持续处理的温度与功耗需要设备与接收端验证。

## 代码入口

- [ProcessingRecipe.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift)、[ExportSettings.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/ExportSettings.swift)：配方编码、效果开关与 24MP 输出尺寸策略。
- [PhotoWhiteBalance.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/PhotoWhiteBalance.swift)、[RAWWhiteBalance.swift](../Packages/GlassCamKit/Sources/ImagingCore/Engines/RAWWhiteBalance.swift)：照片白点模型与外部 RAW 解码器适配。
- [ImagePipeline.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline.swift)、[ImagePipeline+RAW.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+RAW.swift)、[ImagePipeline+Rendering.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Rendering.swift)：线性导出入口、外部 RAW 解码与缩小工作图处理。
- [ImagePipeline+Export.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)、[ImagePipeline+MetalExport.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+MetalExport.swift)、[ImagePipeline+HDR.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+HDR.swift)：全源分条、GPU 衔接、高光恢复、缩放与 HEIF10 编码。
- [metal_color.mm](../Packages/GlassCamKit/Sources/CMetalImage/metal_color.mm)、[metal_spatial.mm](../Packages/GlassCamKit/Sources/CMetalImage/metal_spatial.mm)、[file_raster.mm](../Packages/GlassCamKit/Sources/CMetalImage/file_raster.mm)：Metal 颜色处理器、HNCS 整数锐化与 256×256 并发文件供给器。
- [float_raster.cpp](../Packages/GlassCamKit/Sources/CMetalImage/float_raster.cpp)、[FloatRasterOperations.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/FloatRasterOperations.swift)：严格浮点搬运、曝光、高光与峰值扫描；契约见 [ADR 0017](adr/0017-native-and-metal-contracts.md)。
- [ColorKernels.metal](../Packages/GlassCamKit/Sources/ImagingCore/Metal/ColorKernels.metal)、[NativeSharpness.metal](../Packages/GlassCamKit/Sources/ImagingCore/Metal/NativeSharpness.metal)：GPU 像素计算内核。
- [ShareDelivery.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ShareDelivery.swift)：原始 HEIF 与按需兼容 JPEG 交付。
