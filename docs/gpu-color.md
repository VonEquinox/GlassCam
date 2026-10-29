# GPU 色彩处理

FFCS／LUMIX 颜色和 HNCS 原生锐化通过 Metal 处理完整源分辨率的像素。HNCS 颜色量化保留精确 C++。`CMetalImage` 用 Objective-C++ 管理不可变参数、GPU 命令和有界缓冲，`ImagingCore` 负责配方与 Core Image 图像的衔接。CPU C ABI 保留精确参考语义。

## 工作方式

1. C++ 上下文解析白平衡、原始 LUT、曲线与预设参数。FFCS／LUMIX GPU 颜色使用不可变副本，HNCS 颜色直接使用参考上下文。
2. FFCS／LUMIX 的 `CIImageProcessorKernel` 直接读取 Core Image 的 Float32 Metal 纹理，在系统提供的命令缓冲内执行颜色阶段。参数和 LUT 在一张图像的各块之间复用。
3. 原生渲染器用两个复用的 RGBAf 缓冲交替提交渲染与写入工作文件，每个缓冲的目标容量为 16 MiB，按剩余行数分配。RAW 和 HNCS 固定请求 64 个输出行，保持系统解码器与 CPU 参考相同的取样区域；FFCS 另加所需 halo。HNCS 的解码结果直接由 C++ 打包、施加曝光和执行参考颜色核。文件行序自上而下。
4. HNCS 输出扩展工作图，C++ 统计整图最大值并选择共同尺度。原生锐化以两个带邻域的 Metal 缓冲运行；每个 RGB 缓冲不超过 32 MiB，另有对应的 UInt16 亮度平面。读入下一块邻域后才写回上一块，避免重复处理边界。
5. HNCS 颗粒的随机流、全图统计和后置饱和度、灰度、显示矩阵沿用 C++；结束阶段复用原生读写缓冲，直接生成 RGBAf 文件。FFCS 与 LUMIX 在 GPU 完成颜色与高光恢复后写入 RGBAf 文件。
6. 颜色和空间处理结束后，公共管线执行线性光缩放与质量 1.0 的 10 位 PQ HEIF 编码。

FFCS 的颗粒使用整图坐标，锐化请求完整 halo，只有真实图像边界截断 Gaussian 邻域。LUMIX 使用原始 129³ LUT；12 位网格插值用整数权重计算。HNCS 锐化保留整数卷积、两次除法截断、32 位乘法回绕和原来的 Float32 量化。

App 构建预编译 Metal 文件；SwiftPM 测试宿主使用同一份打包源码。编译关闭 fast math 和隐式浮点融合，运行时同时选择 safe math 与 precise 浮点函数。Metal 不可用时选择 CPU；已经开始的渲染失败或取消会丢弃临时结果。

## 精度预算

GPU Float32 颜色结果与 CPU 参考结果在相同的 Core Image 转换下比较，使用 BT.2020/PQ 和 ITU-R BT.2124 的 ΔEITP。

| 指标 | 上限 |
|---|---:|
| 平均 ΔEITP | 0.1 |
| P95 ΔEITP | 0.25 |
| P99 ΔEITP | 0.5 |
| 编码前最大 ΔEITP | 小于 1.0 |
| HEIF 解码后最大 ΔEITP | 小于 3.0 |
| HDR 峰值相对误差 | 0.001 |

验收还要求不新增黑白截断、不产生灰阶渐变反转。编码前线性结果和 HEIF 解码结果分别测量，分别执行对应的最大色差限制。CPU 参考仍通过固定 golden，HNCS 整数锐化要求位级一致。

## 不变量

1. GPU 颜色结果落在规定的 HDR 色差预算内。— `MetalColorTests.pointwiseColor_staysWithinHDRBudget`
2. HNCS 锐化在 HDR 尺度和分块边界上与 CPU 位级一致。— `MetalColorTests.spatialGPU_matchesCPUIncludingTileBoundaries`
3. 原生渲染保留自上而下的行序和末块像素。— `MetalColorTests.nativeRenderer_preservesTopDownRowsAndTail`
4. 渲染前取消不向输出文件写入像素。— `MetalColorTests.cancelledNativeRenderer_leavesEmptyDestination`
5. HNCS 原生文件结束阶段与内存参考结果逐位一致。— `MetalColorTests.nativeFinishFile_matchesReferenceAcrossChunks`

## 已知限制

- HNCS 颜色量化、全图颗粒统计和后置颜色结束阶段在 CPU 执行。
- 系统 RAW 解码与 HEIF 编码可能分配完整图像的内部表面，原生缓冲上限不代表整个进程的峰值内存。

## 代码入口

- [metal_color.mm](../Packages/GlassCamKit/Sources/CMetalImage/metal_color.mm)：Core Image 处理器、参数上传与异步分块落盘。
- [metal_spatial.mm](../Packages/GlassCamKit/Sources/CMetalImage/metal_spatial.mm)：HNCS 原生整数锐化与邻域调度。
- [ColorKernels.metal](../Packages/GlassCamKit/Sources/ImagingCore/Metal/ColorKernels.metal)、[NativeSharpness.metal](../Packages/GlassCamKit/Sources/ImagingCore/Metal/NativeSharpness.metal)：GPU 像素计算。
- [ImagePipeline+MetalExport.swift](../Packages/GlassCamKit/Sources/ImagingCore/Processing/ImagePipeline+MetalExport.swift)：颜色、空间工作图与公共编码链的衔接。
