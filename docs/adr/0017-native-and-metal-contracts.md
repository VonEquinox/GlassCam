# 原生 C++ 与 Metal 内核契约及修改边界

状态：现行

日期：2026-11-15

## 背景

GlassCam 同时保留参考锁定的 CPU 色彩核、逐值一致的加速路径、允许有限误差的 GPU 成片与独立数学参考。对所有文件采用同一种优化规则，会混淆参考输出、成片色差和重建误差的约束。[ADR 0014](0014-bounded-gpu-photo-processing.md) 确立 GPU 成片预算，本决定将修改边界落实到目标与文件。

## 决定

### 四级数值契约

| 等级 | 修改边界 |
|---|---|
| **L0 · 逐位／参考锁定核** | CPU 输出遵守各自冻结参考的比较规则。禁止通过修改 golden、结合律、浮点精度、量化或查表取整掩盖差异；保留 `-fno-fast-math -ffp-contract=off`。原算法显式 `std::fma` 属于参考语义，不能替换为隐式融合或拆开。 |
| **L1 · 位级一致加速核** | 可改变分块、调度、向量加载和文件供给方式；相同输入的像素位型、HDR 幅度、行序及跨块边界必须与参考路径一致。 |
| **L2 · 感知色差／线性容差预算核** | 可在明确预算内调整算法。成片颜色采用[图像管线的 HDR 预算](../image-pipeline.md#gpu-精度预算)；F5 常量、带限信号与重叠归一化采用测试定义的 14-bit 线性光容差，镜头后置操作采用冻结参考；外围玻璃遵守照片区内零遮黑、零玻璃写入及配对时序契约。 |
| **L3 · 独立数学参考核** | `CF5` 保留早期样条模型的纯 CPU 数学自检，使用严格浮点。它不在生产 F5 路径，无图像级 golden；算子伴随、导数、配准与条件信息由 `f5_core_tests` 验证。 |

L0 的“参考锁定”以测试定义的逐值或有名容差为准，不能把浮点容差测试描述为逐位一致。L2 的 F5 容差用于相应解析信号：有先验的常量／带限重建为 `2e-5`，自动先验与整图重叠通常为 `3e-5`，镜头后置操作为 `2e-5`；噪声、运动与配准各有独立断言。

### 逐目标与文件核查表

表中源码路径均相对 [Sources](../../Packages/GlassCamKit/Sources)，测试位置见[测试说明](../testing.md)。修改头文件、参数布局或共享资源时，运行所有消费方的验收入口。

| 模块 / 文件 | 契约等级 | 具体约束依据 | 必跑验收入口 |
|---|---|---|---|
| `CHNCS/hncs.cpp`、`hncs_phocus_hdr.hpp`、`hncs_phocus_post.hpp`、`hncs_phocus_hdr_post.hpp`、`hncs_phocus_sharpness.hpp` | L0 | `-O3`、严格浮点；矩阵、UInt16 量化、film curve、gradation、HDR 与锐化原始公式；[HNCS 固定向量](../../tests/fixtures/hncs/README.md) | `make test-numeric test-native`；`test_native_core.py`、`test_phocus_native_chain.py`、`test_hncs_hdr_domain.py`、`test_x2d_hdr*.py` |
| `CHNCS/hncs_numpy_rng.cpp`、`.h` 与 `generated/*.inc` | L0 | 固定 SHA-256／PCG64 随机流，生成矩阵、曲线、白点与预设资产；不得现场改写参考表 | `make test-numeric test-native`；`test_hncs_numpy_rng.py`、`test_hncs_spatial.py` |
| `CFFCS/ffcs.cpp` | L0 | `-O3`、严格浮点；FFCS 0.2.0 的阶段 golden、表轴次序、颗粒坐标与 Gaussian halo | `make test-numeric test-native`；`test_ffcs_source.py`、`test_ffcs_strips.py`、`ffcs_effect_switches_test` |
| `CLUMIX/lumix.cpp` | L0 | `-O3`、严格浮点；原始 RGB12／RGB48 整数输出与 revision 4 浮点适配器分开验收；[固定样本](../../tests/fixtures/lumix/README.md) | `make test-numeric test-native`；`test_lumix_reference.py`、`test_lumix_iphone.py`、`lumix_smoke` |
| `CHNCS/hncs_spatial.cpp`、`hncs_files.cpp` | L1 | 全图随机统计、统一 HDR 尺度、浮点文件布局与内存路径一致；复用 L0 公式 | `make test-numeric test-native`；`test_hncs_spatial.py`、`test_hncs_hdr_domain.py`、`hncs_spatial_smoke` |
| `CMetalImage/float_raster.cpp`、`include/float_raster.h` | L1 | 严格浮点；RGB／RGBA 搬运、曝光、高光、像素校验与峰值保持原语义和位型；ARM64 NEON 与标量尾部一致 | `make test-native test-swift test-app`；`float_raster_smoke`、`FloatRasterTests`、`PreviewDisplayTests`、`LiveColorTests` |
| `CMetalImage/metal_spatial.mm`、`ImagingCore/Metal/NativeSharpness.metal` | L1 | CPU 严格浮点；Metal safe／precise，App 关闭 fast-math 与隐式融合；整数锐化、HDR 与末块输出一致 | `make test-swift`；`MetalColorTests.spatialGPU_matchesCPUIncludingTileBoundaries`、`nativeFinishFile_matchesReferenceAcrossChunks` |
| `CMetalImage/metal_color.mm`、`ImagingCore/Metal/ColorKernels.metal` | L2 | 不可变 C++ 上下文提供原始 LUT 与参数；Metal safe／precise；FFCS／LUMIX 受 HDR 色差预算约束 | `make test-swift`；`MetalColorTests`、`ColorChainTests`、`LUMIXPipelineTests` |
| `CMetalImage/file_raster.mm` | L2，像素供给保持 L1 | `pread` 按块供给 Core Image；行序、裁剪、方向与浮点位型不变，读失败不能交付成片 | `make test-swift`；`FileRasterTests`、`ImagePipelineTests` |
| `CMetalF5/f5_curvature_source.mm` | L2 | 严格 CPU 浮点；CFA 相位、导引局部统计与有符号样本；分条缓存不能跨错位置 | `make test-swift`；`F5CurvatureRAWTests`、`F5CurvatureSourceTests` |
| `CMetalF5/f5_curvature_registration.mm` | L2 | 设备、缓冲、FFT 网格与工作区预算；一次性配准句柄；解析亚像素位移与运动可靠度 | `make test-swift`；`F5CurvatureRegistrationTests`、`F5NativeBoundaryTests` |
| `CMetalF5/f5_curvature.mm`、`F5/F5Kernels.metal` | L2 | 严格 CPU 浮点；Metal 关闭 fast-math；CFA 相位、Nyquist 实信号对称性、重叠条带与 14-bit 线性预算 | `make test-swift`；`F5CurvatureTests`、`F5CurvatureSourceTests`、`F5CurvatureRegistrationTests` |
| `CMetalF5/f5_curvature_output.mm`、`f5_curvature_archive.mm` | L2，文件复制保持 L1 | 镜头操作顺序、一次矩阵变换、有符号 HDR；拒绝不同 FD 指向同一源文件；[后置操作冻结资产](../../tests/fixtures/f5-post-operations/README.md) | `make test-swift`；`F5CurvatureOutputTests`、`F5FloatArchiveTests`、`F5NativeBoundaryTests` |
| `CHNCS/include/*`、`CFFCS/include/*`、`CLUMIX/include/*`、`CMetalImage/include/*`、`CMetalF5/include/f5_curvature.h` | 随 L0／L1／L2 消费方 | C ABI 的尺寸、布局、所有权、别名及取消约定；C++ 异常不得穿越 C ABI；零复制数据描述须与 GPU 参数匹配 | `make test-native test-numeric test-swift`；`test_native_buffer_contracts.py`、`F5NativeBoundaryTests` 与对应引擎套件 |
| `Peripheral/PeripheralGlassShaders.metal`、`PeripheralGlassShader.swift` | L2 | 预编译与内嵌回退实现的外围几何、传递函数和中心保护契约；使用系统默认 Metal 数学选项 | `make test-swift test-app`；`GlassShaderTests`、`PairedPresentationTests`、`PairedRendererTests` |
| `Peripheral/PeripheralVisibleSeam.swift` 及接缝／遮黑策略 | L2 | 原始接缝对应、结构缺失、逐边可靠度与恢复时序；不将拟合位移写回中心照片区 | `make test-swift`；`ControlledDisparityTests`、`LivePolicyTests`、`TemporalShadeTests`、`WorkerTests` |
| `CF5/f5_c.cpp`、`f5_math.cpp`、`f5_math.hpp`、`f5_quality.cpp`、`f5_registration.cpp`、`include/*` | L3 | `-O2 -fno-fast-math -ffp-contract=off`；纯数学参考，生产 `F5` 不依赖 `CF5` | `make test-native`；`f5_core_tests` 的 Release 与 ASan／UBSan |
| [NativeTestSupport](../../Packages/GlassCamKit/NativeTestSupport) 的 RNG／HDR 桥和 `hdr_metrics.cpp` | 支撑 L0／L2 | 仅暴露测试符号及 BT.2124 比较指标；App 不依赖该目标，不复制被测成片管线 | `make test-numeric test-swift`；`test_hncs_numpy_rng.py`、`test_x2d_hdr_post.py`、`MetalColorTests` |

### 构建、缓冲与验收

构建标志以 [Package.swift](../../Packages/GlassCamKit/Package.swift) 与 [Xcode 工程](../../App/GlassCam.xcodeproj/project.pbxproj) 为准。App 将四份 `.metal` 编入 `default.metallib`：F5 显式关闭 fast-math，颜色与锐化另关闭隐式融合，外围采用默认选项。SwiftPM 拷贝着色器资源，F5 和成片测试运行时以 safe／precise 编译；外围 GPU 测试使用内嵌源码和默认选项。两条构建路径都需要验证。

各入口按头文件处理缓冲别名：要求不重叠的调用必须在写入前拒绝完整范围重叠，包括并行入口跨分块的重叠；明确允许精确原位的入口保留原位语义。文件源与目的按文件身份判别，不能仅比较 FD 数值。失败的临时成片不得发布。

修改 L0／L1 后运行 CPU golden 和正常／sanitizer 原生检查；修改 L2 后调用真实 Metal 并运行相应预算、取消和边界检查。完整集成入口为 `make test`、`make test-ui` 和未签名 Release；有素材时显式开启 Bayer／ProRAW 回放，变量见[测试说明](../testing.md)。性能与图像质量实验保留在 `GlassCam-research`，参考实现和固定资产保留在产品仓库。

## 后果

性能优化有明确的可变部分与固定输出依据。HNCS 颜色继续使用 CPU，FFCS／LUMIX 成片和 F5 重建使用 GPU，Swift 负责配方、系统接口与生命周期；新增大图 CPU 遍历优先复用严格 C++ 搬运内核。

跨级改动必须同时验收各消费方，不能只凭单一 smoke、图像观感或编码成功判断契约成立。修改算法或版本同步主题文档与 CHANGELOG，修改参考资产则记录来源与受影响版本。
