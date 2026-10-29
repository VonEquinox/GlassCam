# FFCS 色彩处理

FFCS 使用 FFCS 0.2.0 交付的相机表族与模拟风格 LUT，将已显影的 linear-sRGB 源照片转换为成片颜色。Apple 输入由 Core Image RAW 解码，进入 FFCS 时已经完成源色彩配置转换；上游 Python 的传感器 CFA／RAF 解码器不参与 App 拍摄。`FFCSEngine` 负责 Swift 与 C ABI 的资源、缓冲区和上下文所有权，`CFFCS` 负责颜色与空间阶段；RAW 解码及成片编码由 `ImagePipeline` 承担。

## 工作方式

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

资源目录由调用方通过 `ColorResources` 注入，FFCS 从其中的 `FFCS/` 子目录加载 `.lutz` 文件。上下文缓存以目录、模拟风格、全部 FFCS 设置和效果开关为身份；切换配置会替换缓存项，正在处理的任务继续持有原上下文。

### 中性默认与参考调整

`FFCSSettings.standard` 使用 `XH2S`、`renderRevision = 2`、`applyReferenceAdjustments = false`、`sharpenRadius = 1`。中性默认保留 LUT 自身的颜色，包括黑白、滤色与棕褐变换；附加参数为 contrast/saturation 等于 `1`，hue/shoulder/toe/grain/sharpness 等于 `0`。

开启 `applyReferenceAdjustments` 后，内核采用所选模拟风格的参考参数，加入 Lab/UCS、tone、颗粒与 Gaussian USM 阶段。中性 Lab/UCS 和 tone 直接旁路，避免引入浮点往返。Swift 设置接受的锐化半径为 `0.1...5.0`。

处理配方独立保存三个效果开关，默认均为 `true`：

| 开关 | FFCS 中的作用 |
|---|---|
| `applyGrain` | 允许使用风格已有的颗粒系数；关闭时跳过颗粒。 |
| `applySharpness` | 允许使用风格已有的锐化系数；关闭时跳过 Gaussian USM。 |
| `applyExtraCrop` | 随配方保存；FFCS 的裁剪始终为 `.none`。 |

效果开关只控制已有阶段，保持原参数不变；中性默认的颗粒和锐化系数为零，即使开关打开也保持零效果。`applyReferenceAdjustments` 是独立的 FFCS 设置。

### 颜色与完整源照片导出

原生 linear-RGB 路径依次执行输入增益与限幅、容器矩阵、sRGB 编码、LUT 浮点三线性插值、Lab/UCS、tone、颗粒和 Gaussian USM，最后转换为 display-linear Float32 RGB。linear-RGB 入口跳过 `gamma_pre` 解码；LUT 保持 BGR 轴次序及容器定义的输出通道顺序。

新处理配方先在完整线性输入上施加曝光，再由公共管线分离高光幅度，传给 FFCS 的后端曝光为零。FFCS 返回颜色后，公共管线恢复高光幅度；旧配方依据保存的 `pipelineRevision` 保留对应的曝光顺序。完整规则见 [ProcessingRecipe](../../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift) 与 [导出管线](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)。

成片导出重新读取完整源照片，每次处理 `64` 个输出行，并向 `ffcs_required_halo` 查询上下所需邻域。活动 Gaussian USM 的 halo 为 `ceil(3 × sharpenRadius)`，半径 `1` 对应 `3` 行；关闭锐化或使用中性默认时 halo 为零。邻域仅在整图边缘截断和归一化，条带使用整图坐标计算颗粒。

条带输出保持 Float32，先完成颜色和空间处理，再交给公共线性光缩放与 HEIF 编码链；成片导出不经过字节图像中间缓冲区。输入条带须包含所请求输出行及完整 halo，尺寸、有限值、缓冲区和邻域检查失败时返回诊断。

### 实时颜色代理

实验性实时颜色默认关闭。FFCS 准入表仅包含以下同时成立的配方：`XH2S`、PROVIA（索引 `0`）或 ACROS（索引 `8`）、曝光 `0 EV`、关闭参考调整、半径 `1`，且设置有效、对应资源可用；其余配方显示系统取景画面。

`LiveColorCubeStore` 在 `[0,1]` linear-sRGB 输入域内调用 `ffcs_process_linear_rgb_color_only`，生成 sRGB shaped `65³` 立方体，保存 Float32 display-linear RGBA，R 轴变化最快，alpha 为 `1`。代理只包含逐像素颜色阶段；颗粒、锐化和几何裁剪均不进入立方体。三个效果开关仍参与配方与缓存身份，配方变化会使旧结果失效。

## 不变量

1. 配方缺少 FFCS 设置时采用版本 `2` 的中性默认，并保留已有三个效果开关。— [ImagingCoreTests/RecipeTests.absentFFCSSettings_useNeutralDefaultsWithoutLosingEffects](../../Packages/GlassCamKit/Tests/ImagingCoreTests/RecipeTests.swift)
2. 默认 C 构造器的线性输出、字节输出及编码输入阶段结果与显式中性配置一致。— [test_ffcs_defaults.test_default_linear_and_preview_equal_explicit_neutral / test_default_encoded_stages_equal_explicit_neutral](../../tests/numeric/test_ffcs_defaults.py)
3. C++ 的各表族与风格阶段结果符合冻结的 FFCS 0.2.0 golden 及其数值容差。— [FFCSReferenceTests.test_cpp_all_presets_stages_and_linear_mobile_contract](../../tests/numeric/test_ffcs_source.py)
4. 颗粒和锐化开关只旁路对应阶段，保持原风格系数不变，零系数保持无效果。— [NativeTests/ffcs_effect_switches_test](../../Packages/GlassCamKit/NativeTests/ffcs_effect_switches_test/ffcs_effect_switches_test.cpp)
5. FFCS 忽略额外裁剪标志，即使配方同时保存 HNCS square-crop 设置。— [ImagingCoreTests/RecipeTests.extraCrop_onlyAffectsActiveHNCSSquarePreset](../../Packages/GlassCamKit/Tests/ImagingCoreTests/RecipeTests.swift)
6. 带足 halo 的分条结果与完整帧输出逐位相同。— [test_ffcs_strips.test_strips_match_full_frame](../../tests/numeric/test_ffcs_strips.py)
7. 无效条带和缺失 halo 的请求返回诊断并保持输出缓冲区原值。— [test_ffcs_strips.test_invalid_strip_preserves_output_and_returns_diagnostic](../../tests/numeric/test_ffcs_strips.py)
8. 中性和参考调整配方的完整源照片导出符合整图处理基准与编码容差。— [ImagingCoreTests/ImagePipelineTests.fullSourceExport_matchesWholeFrameAndDirectEncoding](../../Packages/GlassCamKit/Tests/ImagingCoreTests/ImagePipelineTests.swift)
9. FFCS 配置变化会更新缓存身份，替换缓存后旧上下文仍能完成处理。— [ImagingCoreTests/ContextCacheTests.ffcsChangedRequest_keepsAllRequestedSettings / replacedFFCSEntry_keepsInFlightNativeOwnerUsable](../../Packages/GlassCamKit/Tests/ImagingCoreTests/ContextCacheTests.swift)
10. 实时代理只接纳准入表中的 FFCS 配方，不支持的配方撤销已呈现的旧画面。— [GlassCamTests/LiveColorTests.measuredFFCSRecipe_isAvailable / unmeasuredRecipe_usesSystemPreview；LivePresentationTests.lifecycleChange_revokesPresentedFrame](../../App/GlassCamTests/LiveColorTests.swift)
11. 实时立方体采样节点遵循原生 color-only 的 RGB 次序和 alpha 约定，效果开关变化使其缓存身份变化。— [GlassCamTests/LiveColorTests.cubeNodes_matchNativeColorOnlyRGBOrderAndAlpha / effectChange_invalidatesCubeIdentity](../../App/GlassCamTests/LiveColorTests.swift)

## 数据与版本

FFCS 参考版本为 `0.2.0`，来源 commit、归档及资产哈希、权利说明集中记录在 [vendor/ffcs/ORIGIN.md](../../vendor/ffcs/ORIGIN.md)。构建脚本按固定 [SHA-256 清单](../../scripts/ffcs_native_SHA256SUMS) 从原始归档离线准备 LUT，并核对归档和逐表内容；生成资源由 Git 忽略。

在仓库根目录运行 `python3 scripts/materialize_ffcs_reference.py` 可从固定归档恢复保留的参考文件与 LUT。四份已迁出的调查工具和二进制清单由原始归档校验，不重新展开到主仓库；其余交付文件校验工作区内容。Xcode 的资源阶段只按校验清单展开运行时表，不需要网络。

内核读取 `FFCSLUT1`、`FFCSLUT2` 容器，检查头部、矩阵与 scale 的有限性、通道标志、压缩长度和完整 zlib 数据。参考源码与上游文档保存在 `vendor/ffcs/`；C++ 的 SwiftPM 编译设置保留 `-fno-fast-math -ffp-contract=off`。

处理配方的 `ffcs` 对象保存 `renderRevision`、`cameraFamily`、`applyReferenceAdjustments`、`sharpenRadius`；模拟风格索引、随机种子和 `effects` 保存在处理配方中。字段缺失时按各字段默认值解码，显式 FFCS 版本仅接受 `2`。公共 `pipelineRevision` 当前为 `2`，旧 JSON 缺少该字段时恢复为 `1`，用于重放旧曝光行为。

[FFCS 数值夹具](../../tests/fixtures/ffcs/README.md) 区分当前 `ffcs-v020-stage-goldens.json` 与旧编码 RGB 阶段夹具的版本和来源；测试消费冻结数据。

## 已知限制

- 相机表族描述资源来源，Apple 解码输入尚无对应富士传感器的完整标定。
- `.lutz` 是重新采样的包装表，浮点插值与原版 SILKYPIX 固定点映射存在数值差异。
- 参考调整中的 Lab/UCS、tone、颗粒和 Gaussian USM 来自研究配方，缺少原厂完整处理链等价证据。
- GFX100S/II 回退到 GFX100 的风格使用公共表，其余缺失组合不可用。
- 实时代理属于颜色近似，设备相机输入、GPU 插值和成像观感需要实拍验证。
- 原厂 RAW、白平衡、输入矩阵和 ICC 的整图匹配缺少真实 RAF 与原厂配套成片对照。
- 上游 Python 的传感器 RAW/CFA、自定义 Cube、解析无表风格与独立 ICC 输出没有 App 入口。

## 代码入口

- [ProcessingRecipe.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Model/ProcessingRecipe.swift)：FFCS 设置、效果开关、版本解码和配方有效性。
- [ColorResources.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Engines/ColorResources.swift)：运行时资源目录注入。
- [FFCSEngine.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Engines/FFCSEngine.swift)：表族查询、上下文缓存和 Float32 整图／条带桥接。
- [ffcs_c.h](../../Packages/GlassCamKit/Sources/CFFCS/include/ffcs_c.h) 与 [ffcs.cpp](../../Packages/GlassCamKit/Sources/CFFCS/ffcs.cpp)：C ABI、资源解析、颜色阶段、颗粒、锐化与 halo。
- [ImagePipeline+Export.swift](../../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+Export.swift)：完整源照片、条带邻域与成片编码。
- [LiveColorRecipe.swift](../../App/GlassCam/Camera/LiveColorRecipe.swift) 与 [LiveColorCubeStore.swift](../../App/GlassCam/Camera/LiveColorCubeStore.swift)：实时准入表、缓存身份与 color-only 立方体生成。
- [prepare_ffcs_resources.sh](../../scripts/prepare_ffcs_resources.sh)：离线校验并准备打包资源。
