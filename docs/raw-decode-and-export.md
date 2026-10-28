# RAW 解码与成片导出

`ImagingCore` 把保留的源照片与冻结的处理配方转换为 10-bit BT.2020/PQ HEIF。管线的缩小工作图与最终导出分别解码；导出始终从完整源照片开始，完成色彩和空间处理后才调整输出尺寸。缩小工作图属于管线 API 能力，当前回看界面只展示已生成的成片。

## 工作方式

### 源照片与 RAW 输入

`SourceImageFile` 持有源照片的原始字节、方向后的尺寸和拍摄元数据；恢复记录也可以借出已有文件，由记录管理其生命周期。`ImportedImage` 另外保存缩小工作图的 Float32 RGB、照片白点和已解析的 RAW 解码参数。

扩展名为 `dng` 或 `raw` 的输入经过 `CIRAWFilter`。缩小解码默认最长边为 2048，可选范围为 256–4096；完整导出固定 `scaleFactor = 1`。普通图片通过内嵌色彩配置转换到 extended linear sRGB，并请求展开 HDR。两条路径都应用源方向，将透明区域合成到黑色背景。

`configureRAW` 统一处理缩小解码、自动拍摄的元数据绑定和完整源解码：

| 参数 | 行为 |
|---|---|
| 解码器版本 | 首次使用所选解码器，写入解析后的 `RAWDecodeRecipe`；再次配置时检查该版本仍受支持。 |
| `cameraNeutral` | 关闭 Apple 全局色调曲线，即 `boostAmount = 0`；保留照片的 `baselineExposure`、局部色调映射和色域映射，EDR 默认设为 1。 |
| `sceneLinear` | 将 `baselineExposure`、`shadowBias`、`boostAmount` 和受支持的局部色调映射设为 0，关闭色域映射，EDR 默认设为 0。 |
| `appleRendered` | 保留解码器的色调处理，EDR 默认设为 1。 |
| HNCS 锐化 | 请求解码器锐化为 0，读取该 DNG 的 `BaselineSharpness` 交给 HNCS 空间阶段；缺失值为 0，非法值或与冻结值不符时拒绝处理。 |

新处理配方使用 `cameraNeutral`，防止 Apple 全局色调曲线与后续色彩引擎的明暗映射叠加。`ImportedImage.baseRAWDecode` 保存引擎覆盖前的参数；切换引擎需要重解码时，从这份参数重新生成输入策略，LUMIX 会清除其他引擎遗留的解码器锐化覆盖。

管线 revision 2 在保留 Apple 锐化的 RAW 全源读取中插入固定分块缓存，缓存保持到所有源行和 halo 读完，再在全图空间处理和 HEIF 编码前释放。

### 白平衡与冻结配方

RAW 白点在计算 `outputImage` 前从解码器取得，包含 temperature、tint 和完整 xy。Apple 完成源照片白平衡；HNCS 使用 xy 建立虚拟捕获基线，模型色温用于工厂矩阵与 LUT 的选择，工厂色温覆盖和预设目标白平衡各自保留。普通已渲染图片使用 `renderedD65`；无法取得有效 RAW 白点时使用带来源标记的 `fallbackD65`。

`ProcessingRecipe.resolvingWhiteBalance` 只绑定一次照片白点。已绑定的 RAW 白点重新设置到完整源解码器，配方、缓存和后续导出保持同一份白平衡。LUMIX 的源 ISO 也只在尚未绑定时从照片元数据补入。

快门事务冻结处理配方、输出设置和拍摄质量。直接导出入口仅先读取元数据并绑定配方，随后处理完整源照片；管线也提供先处理 `ImportedImage` 得到 `ProcessedImage` 的入口，从后者导出时使用其中冻结的配方与源文件。处理失败重试继续使用保留输入与快照，保存失败重试复用已编码文件。

### 曝光与 HDR 工作域

管线 revision 2 将用户 `exposureEV` 作为 `2^EV` 标量施加在线性 RGB 上，再进行高光分离或 HNCS 扩展工作域处理；色彩后端收到的曝光为 0。`RAWDecodeRecipe.decoderExposureEV` 和 `linearExposureEV` 是独立输入参数，分别作用于 RAW 解码器和解码后的线性图像。

HNCS revision 12 在扩展工作图像中保留高光幅度，空间颗粒与锐化作用于完整的高光细节。旧 HNCS、FFCS 和 LUMIX 经过共享适配：逐像素提取 `max(1, R, G, B)`，将归一化颜色交给引擎，再恢复高光幅度。恢复先于输出缩放。

色彩引擎返回 Float32 线性数据，导出不经过 8 位显示编码。C++ 内核沿用各引擎的数值类型、运算次序及 `-fno-fast-math -ffp-contract=off` 编译设置；并行处理共享不可变上下文，各任务持有正在使用的上下文所有者。

### 全源分条、空间处理与尺寸

导出先按源像素确定配方裁剪，再以每条 64 行处理裁剪后的完整源图。位图和原生后端使用从上到下的行序；只有传入 Core Image 矩形时才转换为左下原点坐标。

| 路径 | 空间范围与暂存 |
|---|---|
| FFCS | 从原生上下文查询 halo，读取条带上下邻域，并传入完整宽高、全局输入与输出行号，使锐化边界和颗粒坐标连续。 |
| HNCS | 需要空间处理或扩展工作域时，先写完整的 Float32 RGB 工作文件，再执行全图统计、颗粒与锐化，最后分条完成颜色输出；旧 HDR 空间路径另存逐像素高光增益。 |
| LUMIX | 对完整源图分条执行颜色处理，经共享高光恢复后写出。 |

成片 RGBAf 数据按每像素 16 字节写入 `ExportRasterFile`，编码时映射文件。开始前检查尺寸乘法和可用磁盘空间，预算包含成片、空间工作图、编码余量及 64 MiB 预留；临时文件随所有者释放而清理。

`ExportSettings.native` 保留配方裁剪后的尺寸；显式宽高要求与源图同方向比例且不放大。相机输出策略独立决定 12、24 或 48 MP 目标，按有效像素和构图计算，必要时产生插值输出。色彩与空间效果完成后，使用线性光中的 Lanczos 统一执行下采样或插值。

### HDR 编码与分享

最终编码使用 `writeHEIF10Representation` 和 BT.2020/PQ 色彩空间。HNCS 扩展工作域先转换到线性 BT.2020，再去除目标色域外负值与缩放振铃；其他路径保留其线性 sRGB 裁剪域。高光上限为 PQ 的 10,000 nit 除以 203 nit 参考白，并设置处理结果的 headroom。

拍摄元数据在首次编码前挂到图像上，包含选定的相机、镜头、曝光和拍摄日期字段，方向规范为 1，尺寸更新为成片尺寸，去除失效的 MakerNote。文件写完后重新检查尺寸、10 位深度、HDR 色彩空间及关键元数据；检查失败或取消时丢弃输出，保留源照片。

保存与首选分享表示交付原 HEIF。分享按 HEIC、JPEG 的顺序注册具体文件与数据类型；只有接收方请求 JPEG 才从已完成的完整 HEIF 生成同尺寸、8 位 sRGB 的 SDR 副本，以 `CIToneMapHeadroom` 压缩高光，JPEG 质量参数为 0.95。成功副本供后续请求复用，失败或取消的副本不进入缓存，分享请求持有原文件直到回调完成。

## 不变量

1. 改动任一处理配方字段都会改变配方身份，且编码往返保留其值。— [RecipeTests.changedRecipeField_changesIdentityAndSurvivesCodable](../Packages/GlassCamKit/Tests/ImagingCoreTests/RecipeTests.swift)
2. 照片白点只绑定一次，绑定后可以随配方编码往返。— [WhiteBalanceTests.automaticWhiteBalance_bindsPhotoOnceAndSurvivesCodable](../Packages/GlassCamKit/Tests/ImagingCoreTests/WhiteBalanceTests.swift)
3. 拍摄后的设置变化不改变已冻结照片的处理或重试。— [WorkflowTests.settingsMutation_doesNotRetargetFrozenCaptureOrRetry](../Packages/GlassCamKit/Tests/CaptureTests/WorkflowTests.swift)
4. 当前配方的曝光结果与先缩放完整线性源 RGB、再用零曝光处理一致。— [ColorChainTests.exposure_matchesScalingSceneLinearSource](../Packages/GlassCamKit/Tests/ImagingCoreTests/ColorChainTests.swift)
5. 缺失管线版本的旧配方继续重放固定曝光 golden。— [ColorChainTests.unversionedRecipe_replaysFrozenExposureGolden](../Packages/GlassCamKit/Tests/ImagingCoreTests/ColorChainTests.swift)
6. Float32 位图按不同行数分条后仍保持完整图像的从上到下像素顺序。— [StripRoundtripTests.floatBitmap_partitionPreservesTopDownPixels](../Packages/GlassCamKit/Tests/ImagingCoreTests/StripRoundtripTests.swift)
7. 带曝光与空间效果的分条导出符合整图参考，直接导出与从 `ProcessedImage` 导出的 HEIF 字节一致。— [ColorChainTests.spatialStripExport_matchesWholeImageAndDirectBytes](../Packages/GlassCamKit/Tests/ImagingCoreTests/ColorChainTests.swift)
8. 全源导出在裁剪、空间效果和下采样后符合经过相同编码器的整图参考。— [ImagePipelineTests.fullSourceExport_matchesWholeFrameAndDirectEncoding](../Packages/GlassCamKit/Tests/ImagingCoreTests/ImagePipelineTests.swift)
9. HNCS 磁盘工作图的空间处理结果与内存路径一致。— [ImagePipelineTests.spatialWorkFile_matchesNativeMemoryPath](../Packages/GlassCamKit/Tests/ImagingCoreTests/ImagePipelineTests.swift)
10. HDR 高光细节参与 HNCS 锐化，结果保持有限且保留超白值。— [ImagePipelineTests.hdrSpatialProcessing_sharpensNeutralHighlightDetail](../Packages/GlassCamKit/Tests/ImagingCoreTests/ImagePipelineTests.swift)
11. 导出取消时不交付成片文件，也不删除源照片。— [ImagePipelineTests.cancellation_discardsOutputAndRetainsSource](../Packages/GlassCamKit/Tests/ImagingCoreTests/ImagePipelineTests.swift)
12. HEIF 保留原始分享字节，兼容 JPEG 保留完整尺寸并编码为 8 位。— [ShareTests.heicRepresentation_preservesOriginalBytes、compatibilityJPEG_preservesFullDimensionsAtEightBits](../Packages/GlassCamKit/Tests/ImagingCoreTests/ShareTests.swift)
13. 并发 JPEG 请求只执行一次编码并复用文件，编码后取消允许重新生成副本。— [ShareConcurrencyTests.simultaneousJPEGRequests_encodeOnceAndReuseSameFile、cancellationAfterEncoding_discardsPartialFileAndAllowsFreshRetry](../Packages/GlassCamKit/Tests/ImagingCoreTests/ShareConcurrencyTests.swift)
14. 拍摄元数据随 HEIF 和 JPEG 保留，HEIF 仍是 10 位 HDR。— [CaptureMetadataTests.export_preservesCameraAndLensIdentity、export_preservesMeasuredExposure、export_preservesCaptureDateFields、captureMetadata_keepsTenBitHDRExport](../Packages/GlassCamKit/Tests/ImagingCoreTests/CaptureMetadataTests.swift)
15. 显式本地 RAW 基线保持真实解码白点、冻结的锐化基准、重试像素，以及原生尺寸的 10 位 HDR 输出。— [BaselineTests.rawWhiteBalance_isFrozenFromActualDecoder、rawSharpness_isAppliedOnceWithFrozenBaseline、rawRetry_preservesDecodedPixelsAndPolicy、rawNativeExport_preservesSensorExtentAndTenBitHDR](../Packages/GlassCamKit/Tests/ImagingCoreTests/BaselineTests.swift)

## 数据与版本

`ProcessingRecipe` 的 JSON 保存色彩模式、曝光、模型色温、模拟风格、随机种子、各引擎设置、效果开关、照片白平衡、RAW 输入策略与管线版本。它属于应用保存的处理数据；HEIF 的拍摄元数据由 `PhotoMetadata` 单独管理。

| 数据 | 当前规则与兼容行为 |
|---|---|
| `pipelineRevision` | 新配方为 2；字段缺失时按 1 解码，保留历史曝光计算。LUMIX render revision 3 及以上仍按其已有规则在高光分离前施加曝光。 |
| `rawInputPolicy` | 新配方为 `cameraNeutral`；字段缺失时为 `legacy`。旧 HNCS 关闭解码器锐化，旧 LUMIX revision 2 及以上使用 `sceneLinear`，其余沿用原输入设置。 |
| `RAWDecodeRecipe` | 记录 rendering、解码器版本、两类输入曝光、EDR、锐化量与照片 `BaselineSharpness`；运行中解析后的值随 `ImportedImage` 保留。 |
| `PhotoWhiteBalance` | 保存白点来源、temperature、tint 和 xy；绑定白平衡或 ISO 时保留管线版本与 RAW 输入策略。 |
| `EffectToggles` | `applyGrain`、`applySharpness`、`applyExtraCrop` 分别保存；单字段缺失或 null 时默认 true，非布尔值解码失败。显式 `effects` 优先于旧 HNCS 开关；没有 `effects` 时仅活动 HNCS 继承旧颗粒与锐化选择。 |

效果开关只控制预设已有阶段。历史 HNCS `square-crop` 配方仍可按 `applyExtraCrop` 裁剪；FFCS 和 LUMIX 的该标志不改变构图。新相机偏好的迁移与已有照片配方分开处理。

完整 RAW 基线由 `GLASSCAM_DNG_DIR` 显式启用，目录需要包含主摄、超广角和长焦 ProRAW 素材；未设置时 `BaselineTests` 跳过。固定的版本 1 曝光参考位于 [color-pipeline-v1-exposure.json](../tests/fixtures/color-pipeline/color-pipeline-v1-exposure.json)。

## 已知限制

- `cameraNeutral` 保留 Apple 局部处理，源适配与 HNCS 虚拟白点模型尚非跨相机色卡标定结果。
- Float32 描述解码与工作缓冲精度，传感器原始位深及已渲染输入的既有量化由源文件决定。
- 缩小图像上的颗粒、锐化和解码细节可能与全源处理后再缩小的成片不同。
- 分条和磁盘暂存只约束应用侧临时数组，Apple 解码、缓存、编码及映射页仍可能占用整图内存。
- 同步系统解码或编码调用在返回后才能响应取消。
- 实际 HDR 显示亮度、接收方对分享类型的选择，以及持续拍摄的温度和功耗需要设备与接收端验证。

## 代码入口

- [ProcessingRecipe.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift)、[RAWDecodeRecipe.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/RAWDecodeRecipe.swift)：冻结配方、版本兼容与 RAW 输入策略。
- [PhotoWhiteBalance.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/PhotoWhiteBalance.swift)、[RAWWhiteBalance.swift](../Packages/GlassCamKit/Sources/ImagingCore/Engines/RAWWhiteBalance.swift)：白点模型与 Apple 解码器适配。
- [ImagePipeline.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline.swift)：导出入口、串行解码队列与元数据绑定。
- [ImagePipeline+RAW.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+RAW.swift)：缩小与完整源解码、解码器配置及固定分块缓存。
- [ImagePipeline+Rendering.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Rendering.swift)：从 `ImportedImage` 生成 `ProcessedImage` 的处理入口与线性曝光。
- [ImagePipeline+Export.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)：全源条带、halo 与空间工作图。
- [ImagePipeline+HDR.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+HDR.swift)：高光适配、最终缩放与 HEIF10 编码。
- [ExportSettings.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/ExportSettings.swift)：裁剪与输出尺寸策略。
- [HNCSPresetWorkFile.swift](../Packages/GlassCamKit/Sources/ImagingCore/Engines/HNCSPresetWorkFile.swift)、[SourceImageStore.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/SourceImageStore.swift)：工作文件、源文件和拍摄元数据所有权。
- [ShareDelivery.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ShareDelivery.swift)：原 HEIF 与兼容 JPEG 的按需交付。
