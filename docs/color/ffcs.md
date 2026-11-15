# FFCS 色彩处理

FFCS 使用 RAW FILE CONVERTER EX 3.0 所附 SILKYPIX 8.1.20.0 的原始整数网格与颜色映射，将已显影的 linear-sRGB 源照片转换为成片颜色。Speed／Balanced 输入由 F5 完成 Bayer 重建、源白平衡和色域转换；导入 RAW 使用 Core Image 解码。`FFCSEngine` 管理资源与上下文，`CFFCS` 实现原生参考，Metal 执行成片颜色；导入解码及成片编码由 `ImagePipeline` 承担。

## 工作方式

### 输入前提、白平衡与 ISO

输入为上游完成白平衡与基准曝光的扩展线性 sRGB，可包含有限负值与大于 1 的高光。公共管线先施加用户效果曝光，再提取 `max(1,R,G,B)` 幅度；FFCS 将归一化输入按原生 `[0,1]` 入口约束限幅，因此负分量在颜色核前裁剪。完成颜色及空间效果后恢复高光幅度。

照片白点随公共配方保存，FFCS 不按照片 xy、CCT 或源 ISO 选择 LUT，也不再次施加传感器白平衡。表族与模拟风格由冻结的 `FFCSSettings` 和 `simulationIndex` 决定。

### 相机表族与模拟风格

`FFCSCameraFamily` 选择 LUT 的来源表族。模拟风格使用 C++ 目录的稳定索引，范围为 `0...19`；选择器通过资源解析器筛选当前表族实际可用的风格。

| 表族 | 资源解析规则 |
|---|---|
| `XH2S` | 使用 `xh2s/` 的对应表，包含 PROVIA、ACROS 及其滤色变体等风格。 |
| `XA3` | 使用 `xa3/` 的对应表，只提供该目录中的风格。 |
| `GFX100` | 使用 `gfx100/` 的对应表。 |
| `GFX100S` | 优先使用 `gfx100s/` 专用表；其余风格查找 `gfx100/`，NOSTALGIC NEG. 有专用表。 |
| `GFX100II` | 优先使用 `gfx100ii/` 专用表；其余风格查找 `gfx100/`，REALA ACE 有专用表。 |

`resolvedAssetFamily` 返回实际使用的表族。找不到对应资源时，创建上下文失败；解析器只使用上述资源规则。REALA ACE 的可用组合为 `GFX100II`。

资源目录由调用方通过 `ColorResources` 注入。当前上下文从 `FFCS/` 加载 `.ffcm` 原始网格，并读取参考容器的源域矩阵。上下文缓存以目录、模拟风格、全部 FFCS 设置和效果开关为身份；切换配置会替换缓存项，正在处理的任务继续持有原上下文。

### 原厂风格与细节效果

`FFCSSettings.standard` 使用 `XH2S`、`renderRevision = 3`、`applyReferenceAdjustments = false`、`sharpenRadius = 1`。原厂映射决定颜色和明暗，包括黑白、滤色与棕褐变换。

设置中的“Grain and sharpening”控制 `applyReferenceAdjustments` 字段。当前版本开启它时仅采用所选风格的颗粒与 Gaussian USM 参数；颜色、饱和度和对比度始终由原厂映射提供，不叠加参考配方中的 Lab/Oklab、tone、toe 或 shoulder。Swift 设置接受的锐化半径为 `0.1...5.0`。

处理配方独立保存三个效果开关，默认均为 `true`：

| 开关 | FFCS 中的作用 |
|---|---|
| `applyGrain` | 允许使用风格已有的颗粒系数；关闭时跳过颗粒。 |
| `applySharpness` | 允许使用风格已有的锐化系数；关闭时跳过 Gaussian USM。 |
| `applyExtraCrop` | 随配方保存；FFCS 的裁剪始终为 `.none`。 |

效果开关只控制已有阶段，保持原参数不变；中性默认的颗粒和锐化系数为零，即使开关打开也保持零效果。`applyReferenceAdjustments` 是独立的 FFCS 设置。

### 颜色与完整源照片导出

当前 linear-RGB 路径依次执行输入增益与限幅、源域矩阵、sRGB 编码、原表 gamma 定义的整数入口、原厂映射、可选细节效果，最后转换为 display-linear Float32 RGB。映射的工作白值为 `20000`，网格保持原始 BGR 轴、保护节点和 UInt16 数据。输入按原表 gamma 转换为整数码，映射输出经相反的 gamma／sRGB 传递返回公共线性域。

映射使用 `sigma = 0.5055`、8 位定点位置、8 个立方体角点及 24 个面邻点。XH2S、GFX100 及 GFX100S/II 专用表使用 Normal2Fixed；XA3 按原厂资源 ID 分派 Normal2／Normal2Fixed。gamma 表、距离表、整数舍入和原映射的不对称邻点由 C++ 与 Metal 共享数据契约。

新处理配方先在完整线性输入上施加曝光，再由公共管线分离高光幅度，传给 FFCS 的后端曝光为零。FFCS 返回颜色后，公共管线恢复高光幅度；旧配方依据保存的 `pipelineRevision` 保留对应的曝光顺序。完整规则见 [ProcessingRecipe](../../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift) 与 [导出管线](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)。

成片导出在 Core Image 的 Metal 纹理上执行矩阵、原厂整数映射、颗粒与水平／垂直两趟 Gaussian 锐化，并按 [HDR 预算](../image-pipeline.md#gpu-精度预算)验收。C++ 保留 CPU 参考、资源解析与不可变参数，GPU 的网格、gamma 与距离表随上下文复用。活动 USM 的 halo 为 `ceil(3 × sharpenRadius)`，半径 `1` 对应 `3` 行；关闭锐化或使用中性默认时 halo 为零。邻域仅在整图边缘截断和归一化，颗粒使用整图坐标。

条带输出保持 Float32，先完成颜色和空间处理，再交给公共线性光缩放与 HEIF 编码链；成片导出不经过字节图像中间缓冲区。输入条带须包含所请求输出行及完整 halo，尺寸、有限值、缓冲区和邻域检查失败时返回诊断。

### 实时颜色代理

实验性实时颜色默认关闭。FFCS 准入表仅包含以下同时成立的配方：`XH2S`、PROVIA（索引 `0`）或 ACROS（索引 `8`）、曝光 `0 EV`、关闭参考调整、半径 `1`，且设置有效、对应资源可用；其余配方显示系统取景画面。

`LiveColorCubeStore` 在 `[0,1]` linear-sRGB 输入域内调用 `ffcs_process_linear_rgb_color_only`，生成 sRGB shaped `65³` 立方体，保存 Float32 display-linear RGBA，R 轴变化最快，alpha 为 `1`。代理只包含逐像素颜色阶段；颗粒、锐化和几何裁剪均不进入立方体。三个效果开关仍参与配方与缓存身份，配方变化会使旧结果失效。

## 不变量

1. 配方缺少 FFCS 设置时采用版本 `3` 的中性默认，并保留已有三个效果开关。— `ImagingCoreTests/RecipeTests.absentFFCSSettings_useNeutralDefaultsWithoutLosingEffects`
2. 保留的参考 C 构造器的线性、字节及编码阶段结果与显式中性配置一致。— `test_ffcs_defaults.test_default_linear_and_preview_equal_explicit_neutral`、`test_ffcs_defaults.test_default_encoded_stages_equal_explicit_neutral`
3. 各表族与风格阶段结果符合冻结的 FFCS 0.2.0 golden 及其数值容差。— `test_ffcs_source.test_frozen_native_stage_matches_reference`、`test_switch_encoded_stage_matches_reference`、`test_mobile_linear_output_matches_both_reference_input_domains`
4. 颗粒和锐化开关只旁路对应阶段，保持原风格系数不变，零系数保持无效果。— `NativeTests/ffcs_effect_switches_test`
5. FFCS 忽略额外裁剪标志，即使配方同时保存 HNCS square-crop 设置。— `ImagingCoreTests/RecipeTests.extraCrop_onlyAffectsActiveHNCSSquarePreset`
6. 带足 halo 的分条结果与完整帧输出逐位相同。— `test_ffcs_strips.test_strips_match_full_frame`
7. 无效条带和缺失 halo 的请求返回诊断并保持输出缓冲原值。— `test_ffcs_strips.test_invalid_strip_preserves_output_and_returns_diagnostic`
8. 中性和参考调整配方的完整源导出符合整图基准与编码容差。— `ImagingCoreTests/ImagePipelineTests.fullSourceExport_matchesWholeFrameAndDirectEncoding`
9. 配置变化更新缓存身份，替换缓存后旧上下文仍能完成处理。— `ImagingCoreTests/ContextCacheTests.ffcsChangedRequest_keepsAllRequestedSettings`、`replacedFFCSEntry_keepsInFlightNativeOwnerUsable`
10. 实时代理只接纳准入表中的 FFCS 配方，不支持的配方撤销旧画面。— `GlassCamTests/LiveColorTests.measuredFFCSRecipe_isAvailable`、`unmeasuredRecipe_usesSystemPreview`、`GlassCamTests/LivePresentationTests.lifecycleChange_revokesPresentedFrame`
11. 实时立方体节点遵循原生 color-only 的 RGB 次序与 alpha 约定，效果开关改变缓存身份。— `GlassCamTests/LiveColorTests.cubeNodes_matchNativeColorOnlyRGBOrderAndAlpha`、`effectChange_invalidatesCubeIdentity`
12. 浮点结果与 RGBA8 预览输出重叠时，在写入前拒绝处理。— `tests/numeric/test_native_buffer_contracts.py::test_ffcs_overlapping_outputs_fail_without_writes`
13. 完整帧入口的输入与浮点或预览输出发生任何范围重叠时，拒绝处理并保留所有缓冲原值。— `tests/numeric/test_ffcs_buffer_aliasing.py::test_full_frame_input_overlap_fails_before_writing`
14. GPU 的颗粒网格、裁切坐标与锐化邻域保持整图语义，输出符合 CPU 参考的 HDR 色差预算。— `ImagingCoreTests/FFCSMetalCoverageTests.croppedGPURequests_preserveWholeFrameHaloAndCoordinates`
15. 运行时 LUT 缺失或内容损坏时，从经过 SHA-256 校验的固定归档恢复。— `tests/tools/test_ffcs_runtime_resources.py::test_damaged_cached_lut_is_restored`
16. 归档 SHA-256 不匹配时，即使大小和修改时间保持不变，也拒绝准备资源并保留已有 LUT。— `tests/tools/test_ffcs_runtime_resources.py::test_changed_archive_with_same_stat_is_rejected_without_changing_cached_luts`
17. 当前整数映射与原厂冻结输出逐值一致；关闭空间开关时，细节设置不改变颜色和 tone。— `test_ffcs_native_mapping.test_native_mapping_matches_original_integer_outputs`、`test_float_adapter_preserves_original_colour_without_duplicate_tone`
18. Swift 当前生产入口使用经过原厂对照的整数映射，实时立方体使用相同颜色入口。— `ImagingCoreTests/CurrentColorTests.currentFFCS_usesTheVerifiedNativeMapping`、`GlassCamTests/LiveColorTests.cubeNodes_matchNativeColorOnlyRGBOrderAndAlpha`
19. 损坏的整数网格、非法 gamma、尾随压缩数据与重叠的整数缓冲被拒绝；损坏缓存可从固定归档恢复。— `test_ffcs_native_mapping.test_invalid_native_mapping_is_rejected`、`test_native_code_overlap_is_rejected_without_writes`、`test_ffcs_mapping_materialization.test_corrupt_cached_mapping_is_restored`

## 数据与版本

原厂整数网格保存在 `mapping.zip`，FFCS `0.2.0` 的冻结参考仍由 `source.zip` 提供。来源、哈希和权利说明见 [vendor/ffcs/ORIGIN.md](../../vendor/ffcs/ORIGIN.md)。每次准备都校验两个归档及逐表 SHA-256；仅展开缺失或损坏的资源。生成资源由 Git 忽略。

在仓库根目录运行 `python3 scripts/materialize_ffcs_reference.py` 可从固定归档恢复保留的参考文件与 LUT。只展开选定的参考代码、数据和来源清单；保留项校验工作区内容，其余交付项直接从固定归档校验。Xcode 的资源阶段只按校验清单展开运行时表，不需要网络。

`FFCSMAP1` 保存网格尺寸、工作白值、分派、gamma 和原始网格 CRC；按通道作 UInt16 差分后 zlib 压缩，解码还原全部原始整数。内核检查参数、完整压缩流和还原后的 CRC。`FFCSLUT1/2` 继续供冻结参考与源域矩阵使用。C++ 保留 `-fno-fast-math -ffp-contract=off`，原生及 Metal 修改边界见 [ADR 0017](../adr/0017-native-and-metal-contracts.md)。

处理配方的 `ffcs` 对象保存 `renderRevision`、`cameraFamily`、`applyReferenceAdjustments`、`sharpenRadius`。新拍摄使用版本 `3`；版本 `2` 保留原参考算法与既有 golden。公共 `pipelineRevision` 当前为 `2`，旧 JSON 缺少该字段时恢复为 `1`。

[FFCS 数值夹具](../../tests/fixtures/ffcs/README.md) 区分当前 `ffcs-v020-stage-goldens.json` 与旧编码 RGB 阶段夹具的版本和来源；测试消费冻结数据。

## 已知限制

- 相机表族描述资源来源，Bayer 重建与导入 RAW 输入尚无对应富士传感器的完整标定。
- 可选颗粒和 Gaussian USM 保留参考配方，未复现原厂完整空间处理。
- GFX100S/II 回退到 GFX100 的风格使用公共表，其余缺失组合不可用。
- 实时代理属于颜色近似，设备相机输入、GPU 插值和成像观感需要实拍验证。
- 当前 FFCS 生产管线不复现 RFC EX 的原生 RAW 解码、白平衡、输入矩阵和完整输出流程。
- 上游 Python 的传感器 RAW/CFA、自定义 Cube、解析无表风格与独立 ICC 输出没有 App 入口。

## 代码入口

- [ProcessingRecipe.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift)：FFCS 设置、效果开关、版本解码和配方有效性。
- [ColorResources.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Engines/ColorResources.swift)：运行时资源目录注入。
- [FFCSEngine.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Engines/FFCSEngine.swift)：表族查询、上下文缓存和 Float32 整图／条带桥接。
- [ffcs_c.h](../../Packages/GlassCamKit/Sources/CFFCS/include/ffcs_c.h) 与 [ffcs.cpp](../../Packages/GlassCamKit/Sources/CFFCS/ffcs.cpp)：C ABI、资源解析、颜色阶段、颗粒、锐化与 halo。
- [ImagePipeline+Export.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)：完整源照片、条带邻域与成片编码。
- [LiveColorRecipe.swift](../../App/GlassCam/Camera/LiveColorRecipe.swift) 与 [LiveColorCubeStore.swift](../../App/GlassCam/Camera/LiveColorCubeStore.swift)：实时准入表、缓存身份与 color-only 立方体生成。
- [prepare_ffcs_resources.sh](../../scripts/prepare_ffcs_resources.sh)：离线校验并准备打包资源。
