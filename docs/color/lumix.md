# LUMIX 色彩

LUMIX 将 SILKYPIX Developer Studio 8 SE 的 DC-S1M2 SDR Photo Style 数据用于 GlassCam 成片。当前渲染版本为 revision 4，以扩展线性 sRGB 为输入，使用原始双表、色温选择与风格参数，并通过浮点色域压缩处理 iPhone 输入。

## 工作方式

### 风格与控制

风格目录由 CLUMIX 提供，处理配方保存稳定的 `photoStyle` 标识。默认风格为 Standard，对比度与饱和度均为 0；界面允许在 −5…+5 范围内以 0.5 步进调整，后端对应原始 0…20 档参数，中性档为 10。

| `photoStyle` | 名称 |
|---|---|
| `standard` | Standard |
| `vivid` | Vivid |
| `natural` | Natural |
| `monochrome` | Monochrome |
| `landscape` | Landscape |
| `portrait` | Portrait |
| `l-monochrome` | L.Monochrome |
| `like709` | Like709 |
| `l-monochrome-d` | L.Monochrome D |
| `flat` | Flat |
| `cinelike-d2` | Cinelike D2 |
| `cinelike-v2` | Cinelike V2 |
| `l-monochrome-s` | L.Monochrome S |
| `classic-neo` | L.Classic Neo |
| `leica-monochrome` | Leica Monochrome |
| `cinelike-a2` | Cinelike A2 |

### 白平衡、CCT 与 ISO

RAW 解码先恢复照片白点，再输出线性 RGB。处理配方首次绑定 `PhotoWhiteBalance` 时，将其模型色温写入 `illuminantKelvin`；缺少模型色温时采用 6500 K。已经绑定的白点和色温用于后续重试与导出，LUMIX 将色温用于选表。

revision 2 及之后的版本使用每种风格的两张完整 129³ LUT。CCT 的允许范围为 2000…10000 K；资源中的色温折线节点为 `(3000, 256)`、`(5000, 512)`、`(6500, 618)`、`(7500, 725)`。选择量截取为整数后限于 256…512：256 选第二张表，512 选第一张表，中间按整数权重混合节点，再做三线性插值。RGB12 采样保留步长 32、白值 4095 和末端保护节点。

`sourceISO` 从照片 EXIF 首次绑定；有效范围为 1…1,000,000，缺失时采用 100。revision 2、3 的原始整数路径在 ISO 恰为 50、64、80 时选择对应预曲线，源风格分支固定为 0。revision 4 仍保存 ISO，但浮点适配器跳过这些松下传感器补偿曲线。

### 当前 RAW 输入与像素处理

新处理配方采用 `rawInputPolicy = cameraNeutral`。CIRAWFilter 关闭 Apple 全局色调曲线（`boostAmount = 0`），保留照片的 BaselineExposure、局部色调映射及解码器细节处理；EDR 使用已存设置，未指定时为 1。LUMIX 保留照片的 BaselineSharpness，并恢复解码器默认锐化设置。

输入策略、已冻结白点或解码参数发生变化时，成片处理从保留的 RAW 重新解码。revision 4 的像素路径如下：

1. 在完整线性 RGB 上施加用户曝光，范围为 −2…+2 EV。
2. 按每个像素的 `max(1, R, G, B)` 分离 HDR 幅度，将颜色送入 LUMIX。
3. 沿等亮度中性色方向收束超出 LUT 色域的输入，生成有界 RGB12 坐标并采样原始 LUT。
4. 使用原始饱和度、黑白有符号色度和对比度参数，在浮点域生成输出；从归一化色度半径 0.95 开始连续压缩色域边界。
5. 通过 sRGB EOTF 返回 `[0, 1]` 的线性 Float32 RGBA，再恢复 HDR 幅度。

### 完整源图与 HDR 导出

成片导出从保留的源照片重新取得完整尺寸像素，由 Metal 执行曝光、颜色与 HDR 幅度恢复，使用原始 129³ LUT 和整数插值权重。原生缓冲按块写入 Float32 工作文件，精度按 [GPU 色彩处理](../gpu-color.md)验收。需要调整成片尺寸时，在颜色处理之后进行线性重采样，最终编码为 10-bit BT.2020/PQ HEIF。

LUMIX 上下文保存不可变 LUT 与风格参数；缓存身份包含资源目录、全部 LUMIX 设置和色温。处理中的调用持有自己的上下文，因此后续选择其他风格不会替换其数据。运行时校验 LUT 和参数表的格式、长度及 CRC，资源错误会终止处理。

## 不变量

1. 选择任一目录风格后，成片配方保留该风格和照片白点、无额外裁剪，并保留 HDR 亮度。— `ImagingCoreTests/LUMIXPipelineTests.selectedPhotoStyle_preservesRecipeWhitePointAndHDR`
2. Standard 与 Vivid 对同一输入产生不同像素。— `ImagingCoreTests/LUMIXPipelineTests.standardAndVivid_produceDistinctPixels`
3. 色温、ISO、对比度与饱和度随配方编解码保持一致，已经绑定的 ISO 不被后续元数据替换。— `ImagingCoreTests/LUMIXPipelineTests.adjustedRecipe_roundtripKeepsCCTISOAndLookControls`
4. 当前 LUMIX 配方绑定 ISO 后使用 cameraNeutral 输入，并清除继承的 HNCS 解码器锐化覆盖。— `ImagingCoreTests/LUMIXPipelineTests.captureISO_bindsWithoutInheritingHNCSDecoderOverride`
5. revision 4 的 iPhone 输出不随 ISO 50、64、80、100、400 切换松下低 ISO 补偿。— `test_lumix_iphone.test_iphone_iso_does_not_select_panasonic_sensor_compensation`
6. revision 4 的饱和色渐变不发生整数回绕造成的黑色突变，灰阶保持端点且无大幅反转。— `test_lumix_iphone.test_saturated_ramp_has_no_wraparound_discontinuity`、`test_lumix_iphone.test_gray_ramp_preserves_local_steps_and_endpoints`
7. 相同上下文的有符号输入并发分条与整段输出逐值一致。— `test_lumix_iphone.test_signed_gamut_concurrent_strips_preserve_full_output`
8. 当前曝光作用于 HDR 分离之前，增加曝光也增加超白高光幅度。— `ImagingCoreTests/LUMIXPipelineTests.exposure_scalesSceneLinearHighlightsBeforeStripExport`、`ImagingCoreTests/LUMIXPipelineTests.currentExposure_increasesSuperwhiteMagnitude`
9. Standard 与 L.Monochrome 的分条导出和整图参考在编码容差内一致，直接导出与先生成成片回看图再导出的解码像素相同，并保留尺寸、HDR 与 10-bit 编码。— `ImagingCoreTests/LUMIXPipelineTests.stripHEIF_matchesFullFrameAndDirectExport`
10. revision 1 照片不绑定 ISO 修正，缺少 RAW 输入策略的旧配方在绑定元数据后仍保持 legacy 语义。— `ImagingCoreTests/LUMIXPipelineTests.savedV1Photo_doesNotAdoptISOCorrection`、`ImagingCoreTests/LUMIXPipelineTests.absentInputPolicy_keepsLegacyPhotoSemanticsDuringMetadataBinding`
11. 保存的 revision 2、共享管线 revision 1 配方重放原有超白曝光行为。— `ImagingCoreTests/LUMIXPipelineTests.savedV2Exposure_replaysOriginalSuperwhiteMagnitude`
12. 原始 RGB12 插值和 RGB48 整数路径分别与固定原程序样本逐值一致。— `test_lumix_reference.test_rgb12_interpolation_matches_native_vectors`、`test_lumix_iphone.test_original_rgb48_fixture_remains_bit_exact`
13. 非有限 iPhone 输入在写入输出之前失败，缺失、截断、损坏或网格错误的 LUT 被拒绝。— `test_lumix_iphone.test_nonfinite_input_is_rejected_before_writing`、`test_lumix_reference.test_invalid_lumix_resource_fails`

测试入口为 [Swift 管线测试](../../Packages/GlassCamKit/Tests/ImagingCoreTests/LUMIXPipelineTests.swift)、[原始 LUT 数值测试](../../tests/numeric/test_lumix_reference.py)和 [iPhone 适配器测试](../../tests/numeric/test_lumix_iphone.py)；固定样本的来源见 [LUMIX 数值夹具](../../tests/fixtures/lumix/README.md)。

## 数据与版本

`ProcessingRecipe.lumix` 保存 `renderRevision`、`photoStyle`、`contrast`、`saturation` 和 `sourceISO`。照片白点、`illuminantKelvin`、`rawInputPolicy` 与共享 `pipelineRevision` 保存在同一处理配方中；它们分别控制输入和共享处理顺序。

| LUMIX 渲染版本 | 保存照片的颜色路径 |
|---|---|
| 1 | 每个风格的第一张 LUT；对比度、饱和度为 0，ISO 为空 |
| 2 | 双表与完整 SDR VE 整数路径，包含低 ISO 预曲线 |
| 3 | 沿用 revision 2 的颜色路径，用户曝光在 HDR 幅度分离之前施加 |
| 4 | 双表和原始风格参数，采用有界 RGB12 输入与浮点色域压缩，跳过低 ISO 预曲线 |

保存的 `lumix` 对象缺少 `renderRevision` 时按 1 解码；整个 `lumix` 字段缺失时补当前 Standard 设置，并保留已有色彩模式。相机偏好恢复时将后续拍摄的 LUMIX 版本设为 4、清空已绑定 ISO，并使用 cameraNeutral 与共享管线 revision 2；照片配方按保存字段重放。

缺少 `rawInputPolicy` 的旧照片采用 `legacy`：LUMIX revision 2 及之后选择 sceneLinear RAW 解码，revision 1 沿用照片原解码设置。sceneLinear 会清零 BaselineExposure、shadowBias、boostAmount 与可用的局部色调映射，并关闭 gamut mapping、将未指定的 EDR 设为 0。显式 cameraNeutral 策略独立于 LUMIX 版本生效。

缺少共享 `pipelineRevision` 时按 1 解码。用户曝光在共享管线版本至少为 2，或 LUMIX 版本至少为 3 时先于 HDR 分离；其余保存配方保留在颜色后端内施加曝光的路径。

资源由 `source.zip`（schema 1）和 `pipeline.zip`（schema 2）提供：前者保存各风格第一张 LUT，后者保存配对 LUT 与风格参数表。资源准备脚本检查归档与每个文件的 SHA-256，输出 `.lmx`、`pipeline.lmp` 和对应清单。来源、固定哈希及权利说明见 [ORIGIN](../../vendor/lumix/ORIGIN.md)。

## 已知限制

- LUMIX 的输入是 Apple 解码后的 ProRAW 或已解码图像，未恢复松下传感器 RGB、MakerNote、RW2 去马赛克、镜头标定或松下空间降噪与锐化。
- V-Log、HLG 专用表以及任意原始 CMS/ICC 转换不在这些 SDR 风格的处理范围内。
- revision 4 的浮点色域压缩、HDR 幅度恢复和 HEIF 编码属于 GlassCam 的输出策略，原始 RGB48 样本约束的是保留的整数路径。
- 固定样本和合成图像覆盖色彩数值一致性，跨相机的原厂成片匹配与真实拍摄观感需要另行验证。
- LUMIX 取景画面使用系统颜色，成片颜色在照片处理阶段应用。

## 代码入口

- [CLUMIX](../../Packages/GlassCamKit/Sources/CLUMIX/lumix.cpp)：风格目录、资源读取、双表混合、原始整数路径与 iPhone 浮点适配器。
- [LUMIXEngine](../../Packages/GlassCamKit/Sources/ImagingCore/Engines/LUMIXEngine.swift)：资源注入、上下文缓存和按版本派发。
- [LUMIXSettings](../../Packages/GlassCamKit/Sources/ImagingCore/Model/LUMIXSettings.swift)与 [ProcessingRecipe](../../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift)：风格设置、兼容解码、白点与 ISO 绑定、输入策略及曝光顺序。
- [RAW 解码](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+RAW.swift)与[成片处理](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Rendering.swift)：源输入配置与完整颜色处理。
- [分条导出](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)与 [HDR 输出](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+HDR.swift)：源图分条、HDR 恢复与 HEIF 编码。
- [CameraSettingsStore](../../Packages/GlassCamKit/Sources/Capture/CameraSettingsStore.swift)：后续拍摄设置的恢复与版本选择。
- [prepare_lumix_resources.py](../../scripts/prepare_lumix_resources.py)：构建和测试使用的资源校验与展开。
