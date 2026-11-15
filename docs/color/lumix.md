# LUMIX 色彩

LUMIX 将 SILKYPIX Developer Studio 8 SE 8.0.31.1 的 DC-S1M2 SDR Photo Style 用于 GlassCam 成片。当前 revision 5 使用原始双表、整数颜色阶段、色温选择、低 ISO 预曲线与风格参数；输入为已白平衡的扩展线性 sRGB。

## 工作方式

### 输入前提

输入为已完成源白平衡与基准曝光的扩展线性 sRGB，允许有限负值与大于 1 的高光。公共管线先施加用户效果曝光、再按 `max(1,R,G,B)` 分离高光；有符号颜色沿等亮度中性色方向收束到 LUT 色域，返回 `[0,1]` 线性结果后恢复高光幅度。

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

Speed／Balanced 从 DNG 取得照片白点，由 F5 相机矩阵生成已白平衡的线性 RGB；导入 RAW 由 Apple 解码器提供白点与线性图像。处理配方首次绑定 `PhotoWhiteBalance` 时，将其模型色温写入 `illuminantKelvin`；缺少模型色温时采用 6500 K。已经绑定的白点和色温用于后续重试与导出，LUMIX 将色温用于选表。

revision 2 及之后的版本使用每种风格的两张完整 129³ LUT。CCT 的允许范围为 2000…10000 K；资源中的色温折线节点为 `(3000, 256)`、`(5000, 512)`、`(6500, 618)`、`(7500, 725)`。选择量截取为整数后限于 256…512：256 选第二张表，512 选第一张表，中间按整数权重混合节点，再做三线性插值。RGB12 采样保留步长 32、白值 4095 和末端保护节点。

`sourceISO` 从照片 EXIF 首次绑定；有效范围为 1…1,000,000，缺失时采用 100。当前整数路径在 ISO 恰为 50、64、80 时选择原厂对应预曲线，源风格分支固定为 0；其他 ISO 使用恒等预曲线。已经绑定的 ISO 在重试或导出时保持不变。

### 当前 RAW 输入与像素处理

Speed／Balanced 直接使用 F5 交付的扩展线性 sRGB、拍摄白点、ISO 和 BaselineSharpness，源白平衡与 BaselineExposure 已由相机矩阵处理一次。

导入 RAW 的新处理配方采用 `rawInputPolicy = cameraNeutral`。CIRAWFilter 关闭 Apple 全局色调曲线（`boostAmount = 0`），保留照片的 BaselineExposure、局部色调映射及解码器细节处理；EDR 使用已存设置，未指定时为 1。LUMIX 保留照片的 BaselineSharpness，并恢复解码器默认锐化设置。

导入 RAW 的输入策略、已冻结白点或解码参数发生变化时，从保留源文件重新解码。revision 5 的像素路径如下：

1. 在完整线性 RGB 上施加用户曝光，范围为 −2…+2 EV。
2. 按每个像素的 `max(1, R, G, B)` 分离 HDR 幅度，将颜色送入 LUMIX。
3. 沿等亮度中性色方向收束超出 LUT 色域的输入，以原生 `4 × 4095 = 16380` 工作白值量化为 RGB48，施加低 ISO 预曲线，按原厂次序截断到 RGB12 并采样双表。
4. 在同一工作白值下执行整数中间窄化、饱和度或单色有符号色度、原厂对比度曲线及舍入。UInt16 容器保留约四倍参考白的处理余量，最终按 SDR 白值归一化并限幅。
5. 通过 sRGB EOTF 返回 `[0, 1]` 的线性 Float32 RGBA，再恢复 HDR 幅度。

### 完整源图与 HDR 导出

成片导出从保留的源照片重新取得完整尺寸像素，由 Metal 执行曝光、颜色与 HDR 幅度恢复，使用原始 129³ LUT 和整数插值权重。原生缓冲按块写入 Float32 工作文件，精度按 [图像管线与成片导出](../image-pipeline.md)验收。需要调整成片尺寸时，在颜色处理之后进行线性重采样，最终编码为 10-bit BT.2020/PQ HEIF。

LUMIX 上下文保存不可变 LUT 与风格参数；缓存身份包含资源目录、全部 LUMIX 设置和色温。处理中的调用持有自己的上下文，因此后续选择其他风格不会替换其数据。运行时校验 LUT 和参数表的格式、长度及 CRC，资源错误会终止处理。

### 空间效果、CPU 与 Metal

LUMIX 不提供额外颗粒、锐化或裁剪阶段，公共 `applyGrain`、`applySharpness` 与 `applyExtraCrop` 不改变该引擎输出。C++ 负责资源验证和原厂整数参考，Metal 使用相同工作白值、双表、低 ISO 与对比度节点执行成片颜色。资源随不可变上下文缓存复用。参考输出和 GPU 预算分别验收，见 [ADR 0017](../adr/0017-native-and-metal-contracts.md)。

### 实时颜色代理

LUMIX 不在 `experimentalLiveColor` 的 65³ 立方体准入表内，取景显示系统颜色；设置开关处显示原因，光学滤镜拨盘不为 LUMIX 点亮 `LIVE`。

## 不变量

1. 选择任一目录风格后，成片配方保留该风格和照片白点、无额外裁剪，并保留 HDR 亮度。— `ImagingCoreTests/LUMIXPipelineTests.selectedPhotoStyle_preservesRecipeWhitePointAndHDR`
2. Standard 与 Vivid 对同一输入产生不同像素。— `ImagingCoreTests/LUMIXPipelineTests.standardAndVivid_produceDistinctPixels`
3. 色温、ISO、对比度与饱和度随配方编解码保持一致，已经绑定的 ISO 不被后续元数据替换。— `ImagingCoreTests/LUMIXPipelineTests.adjustedRecipe_roundtripKeepsCCTISOAndLookControls`
4. 当前 LUMIX 配方绑定 ISO 后使用 cameraNeutral 输入，并清除继承的 HNCS 解码器锐化覆盖。— `ImagingCoreTests/LUMIXPipelineTests.captureISO_bindsWithoutInheritingHNCSDecoderOverride`
5. 当前工作白值下的颜色、饱和度、对比度和低 ISO 曲线符合固定原厂整数样本；浮点适配仅承担规定的输入／输出域转换。— `test_lumix_native_color.test_production_white_and_controls_match_original_integer_stage`、`test_float_adapter_replays_original_colour_saturation_and_contrast`
6. 保留的 revision 4 参考输出继续满足原有的 ISO 与渐变约束。— `test_lumix_iphone.test_iphone_iso_does_not_select_panasonic_sensor_compensation`、`test_saturated_ramp_has_no_wraparound_discontinuity`、`test_gray_ramp_preserves_local_steps_and_endpoints`
7. 相同上下文的有符号输入并发分条与整段输出逐值一致。— `test_lumix_iphone.test_signed_gamut_concurrent_strips_preserve_full_output`
8. 当前曝光作用于 HDR 分离之前，增加曝光也增加超白高光幅度。— `ImagingCoreTests/LUMIXPipelineTests.exposure_scalesSceneLinearHighlightsBeforeStripExport`、`ImagingCoreTests/LUMIXPipelineTests.currentExposure_increasesSuperwhiteMagnitude`
9. Standard 与 L.Monochrome 的分条导出符合整图参考，直接导出与先生成回看图再导出的 HEIF 字节相同，并保留尺寸、HDR 与 10-bit 编码。— `ImagingCoreTests/LUMIXPipelineTests.stripHEIF_matchesFullFrameAndDirectExport`
10. revision 1 照片不绑定 ISO 修正，缺少 RAW 输入策略的旧配方在绑定元数据后仍保持 legacy 语义。— `ImagingCoreTests/LUMIXPipelineTests.savedV1Photo_doesNotAdoptISOCorrection`、`ImagingCoreTests/LUMIXPipelineTests.absentInputPolicy_keepsLegacyPhotoSemanticsDuringMetadataBinding`
11. 保存的 revision 2、共享管线 revision 1 配方重放原有超白曝光行为。— `ImagingCoreTests/LUMIXPipelineTests.savedV2Exposure_replaysOriginalSuperwhiteMagnitude`
12. 原始 RGB12 插值和 RGB48 整数路径分别与固定原程序样本逐值一致，覆盖风格、色温分派与整数控制参数。— `test_lumix_reference.test_rgb12_interpolation_matches_native_vectors`、`test_lumix_iphone.test_original_rgb48_fixture_remains_bit_exact`、`test_lumix_native_dispatch.test_native_dispatch_produces_original_integer_outputs`
13. 非有限 iPhone 输入在写入输出之前失败，缺失、截断、损坏或网格错误的 LUT 被拒绝。— `test_lumix_iphone.test_nonfinite_input_is_rejected_before_writing`、`test_lumix_reference.test_invalid_lumix_resource_fails`
14. RGB 至 RGBA 输出重叠在写入前拒绝；即使 CRC 有效，非有限或不递增的色温曲线仍被拒绝。— `test_lumix_iphone.test_overlapping_iphone_buffers_are_rejected_without_writes`、`test_lumix_reference.test_overlapping_rgb_rgba_is_rejected_without_writes`、`test_lumix_reference.test_invalid_temperature_curve_with_valid_checksum_is_rejected`
15. 资源准备恢复已展开文件和清单的损坏，并在已有缓存时继续拒绝归档校验失败。— `test_lumix_materialization.test_cached_resource_damage_is_restored_from_verified_archive`、`test_cached_manifest_damage_is_restored_from_verified_archive`、`test_existing_resources_do_not_hide_archive_checksum_failure`
16. Swift 当前生产入口使用原厂低 ISO 和整数控制，非有限源值在写入前被拒绝。— `ImagingCoreTests/CurrentColorTests.currentLUMIX_usesNativeLowISOAndIntegerControls`、`test_lumix_native_color.test_invalid_source_leaves_native_output_unchanged`

测试入口为 [Swift 管线测试](../../Packages/GlassCamKit/Tests/ImagingCoreTests/LUMIXPipelineTests.swift)、[原始 LUT 数值测试](../../tests/numeric/test_lumix_reference.py)、[原程序分派测试](../../tests/numeric/test_lumix_native_dispatch.py)和 [iPhone 适配器测试](../../tests/numeric/test_lumix_iphone.py)；固定样本的来源见 [LUMIX 数值夹具](../../tests/fixtures/lumix/README.md)。

## 数据与版本

`ProcessingRecipe.lumix` 保存 `renderRevision`（当前为 `5`）、`photoStyle`、`contrast`、`saturation` 和 `sourceISO`。相机偏好恢复时将后续拍摄固定为版本 5、清空已绑定 ISO，并搭配 `cameraNeutral` 与共享管线 revision 2。

已冻结配方按保存字段重放：版本 1 使用单张 LUT；版本 2、3 保留原始 SDR VE 整数路径，版本 4 保留原浮点适配器。它们的 CPU 参考与 golden 保持不变；版本 5 的原厂样本单独保存。

资源由 `source.zip`（schema 1）和 `pipeline.zip`（schema 2）提供：前者保存各风格第一张 LUT，后者保存配对 LUT 与风格参数表。每次准备资源时都检查归档和已展开文件的 SHA-256，仅重新写入缺失或损坏的 `.lmx`、`pipeline.lmp` 与清单。来源、固定哈希及权利说明见 [ORIGIN](../../vendor/lumix/ORIGIN.md)。

## 已知限制

- LUMIX 的输入是 Speed／Balanced 的线性 sRGB、导入 RAW 的 Apple 解码图像或其他已解码图像，未恢复松下传感器 RGB、MakerNote、RW2 去马赛克、镜头标定或松下空间降噪与锐化。
- V-Log、HLG 专用表以及任意原始 CMS/ICC 转换不在这些 SDR 风格的处理范围内。
- 输入色域投影、HDR 幅度恢复和 HEIF 编码属于 GlassCam 的输出策略；SDR Photo Style 没有对应的原厂 HDR 成片契约。
- 原厂低 ISO 曲线随照片 ISO 选择，这不是 iPhone 与松下传感器之间的标定。
- 固定样本和合成图像覆盖色彩数值一致性，跨相机的原厂成片匹配与真实拍摄观感需要另行验证。

## 代码入口

- [CLUMIX](../../Packages/GlassCamKit/Sources/CLUMIX/lumix.cpp)：风格目录、资源读取、双表混合、原始整数路径与 iPhone 浮点适配器。
- [LUMIXEngine](../../Packages/GlassCamKit/Sources/ImagingCore/Engines/LUMIXEngine.swift)：资源注入、上下文缓存和按版本派发。
- [LUMIXSettings](../../Packages/GlassCamKit/Sources/ImagingCore/Model/LUMIXSettings.swift)与 [ProcessingRecipe](../../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift)：风格设置、兼容解码、白点与 ISO 绑定、输入策略及曝光顺序。
- [RAW 解码](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+RAW.swift)与[成片处理](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Rendering.swift)：源输入配置与完整颜色处理。
- [分条导出](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)与 [HDR 输出](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+HDR.swift)：源图分条、HDR 恢复与 HEIF 编码。
- [CameraSettingsStore](../../Packages/GlassCamKit/Sources/Capture/CameraSettingsStore.swift)：后续拍摄设置的恢复与版本选择。
- [prepare_lumix_resources.py](../../scripts/prepare_lumix_resources.py)：构建和测试使用的资源校验与展开。
