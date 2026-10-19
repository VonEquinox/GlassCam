# 颜色精度受控的 Apple 加速研究

2026-10-18。采用 FFCS 的严格缓存与调度优化；Metal／Core ML 候选继续作为研究工具。FFCS 在这台 Mac 的完整导出中耗时降低约 **0.8%–2.1%**（速度比约 1.008–1.022），输出文件逐字节相同。Metal 颜色候选虽快约 6%–8%，完整 HDR 输出未达到事先确定的精度预算，不能启用为默认实现。没有执行手机安装或真机测量。

同日后续完成的独立真机分段测量见 [iPhone 性能报告](IPHONE_PERFORMANCE_20261018.md)。本页各表保留原 Mac 研究的范围与数据。

## 基线、硬件与测量范围

Apple M5，10 个逻辑 CPU，16 GiB 内存，macOS 27.2（26B5101f）。输入为既有 6048×8064 DNG，49,513,537 字节，SHA-256 `4bd1990df9893381b89797d1e761925973c0c840c3cd47dce758635c7502929e`。24MP 实际输出 4242×5656，48MP 输出 6048×8064。两者均先处理完整源，再缩小。

性能基线是已验证的**当前应用路径**：Apple RAW 解码、现有源域适配、HNCS revision 10 或 FFCS 0.2 配方、HDR 幅值恢复、10-bit BT.2020/PQ HEIF 与回看解码。曝光 −0.05 EV；Standard／Nature 使用 L* 工作空间；FFCS 使用 XH2S PROVIA／ACROS 的中性默认。它不是新增的 X2D 专用 RAW 解码器，也不是完整原厂成片等价基线。Phocus／SILKYPIX 原版残差分别见 [X2D 报告](X2D_COLOR_PIPELINE_20261018.md)和 [FFCS 报告](FFCS_ORIGINAL_AUDIT_20261018.md)。

[严格测量工具](../tools/run_color_performance.py)对两组构建只替换冻结的 `ffcs.cpp`，其余源码、参数、资源与输出要求相同。C++ 使用 `-O3 -fno-fast-math -ffp-contract=off`，Swift 使用 `-O`。性能测量串行运行；后续并行编译、回归不计入性能样本。每种配方／版本独立进程，先各尺寸一次预热，再三轮测量；每轮交替 24／48MP 顺序，配方间交替旧／新版本顺序。每个进程第一次 48MP 包含启动成本，紧随的第一次 24MP 是尺寸预热，不能也称为独立冷启动。

大文件与原始记录保存在[性能证据目录](/Users/vonequinox/.codex/visualizations/2026/10/17/01a14afa-ebe0-7180-be23-7f59ec9cef36/color-research-20261018/performance)。[汇总 JSON](../validation/color-performance-20261018.json)保留输入、源码、构建清单和各实验位置；所有旧结果与失败尝试保留。

## 已采用：严格无损路径

[FFCS](../core/ffcs.cpp)保留压缩后的 UInt16 三维 LUT，在创建上下文时缓存所有 65,536 个 `double(code)/scale` 值，减少逐像素重复除法。每个存活上下文增加 **512 KiB**。插值、矩阵、曲线、取整和边界顺序不变。Apple 使用同步 `dispatch_apply_f` 执行最多四个不重叠行区间；异常按工作区间收集后重新抛出，非 Apple 保留 `std::thread` 路径。

Swift `FFCSEngine` 的现有 `workerCount` 仍为 1。因此完整应用结果验证的是缓存收益，不能把它归因于多工作区间调度。四工作区间路径由合成性能探针及数值／sanitizer 检查覆盖，没有擅自提高应用并行度。

曾尝试把整个三维表展开为 Double，约增加 9 MiB／上下文，没有相应收益；又尝试合并输出循环，耗时反而增加约 24%。这两个候选已撤回，源码和实验记录留在证据目录。

macOS 原生文件保护类会导致 Cocoa 513／EPERM，普通原子写入成功。因此 [SourceImageStore](../ios/GlassCam/SourceImageStore.swift)按平台选择写入选项：Mac 使用原子写入，iOS 继续使用完整文件保护。更换 TMPDIR 未能解决最初问题，其失败记录同样保留。

### 完整耗时和波动

单位为秒，中位数后括号为三轮最小—最大值。包含源文件保留、完整导出和回看解码，排除相机采集与 Photos 事务。

| 配方 | 输出 | 旧版 | 严格新版 |
|---|---:|---:|---:|
| Standard | 24MP | 4.289571（4.270344–4.296795） | 4.289118（4.270460–4.317832） |
| Standard | 48MP | 4.469550（4.461010–4.530629） | 4.493742（4.481351–4.503694） |
| Nature | 24MP | 4.282422（4.274717–4.351988） | 4.284370（4.268709–4.293536） |
| Nature | 48MP | 4.474877（4.462417–4.479124） | 4.470752（4.464451–4.476555） |
| PROVIA | 24MP | 5.503092（5.484980–5.590338） | 5.458565（5.407725–5.464703） |
| PROVIA | 48MP | 5.661475（5.649507–5.718556） | 5.599003（5.558590–5.601602） |
| ACROS | 24MP | 5.543897（5.494681–5.705497） | 5.427564（5.383684–5.472482） |
| ACROS | 48MP | 5.699730（5.659123–5.720143） | 5.578304（5.577700–5.630831） |

共 64 个 HEIF，同配方／尺寸的旧新文件及重复输出全部逐字节一致，首次完整 Float32 解码也一致。HNCS 是未修改的对照组，中位数波动约 0.5% 以内；Standard 48MP 的本次差值约 0.54%，不能算优化收益。FFCS 收益较小，部分区间重叠，三轮测量不构成普遍性能保证。

所有代码收尾后，另用最终源码重编译并导出八组配方／尺寸，文件与完整 Float32 解码再次匹配上述保留输出。该轮只核对报告与最终代码的一致性，不纳入新的性能计时样本。

另外对全部 50 个 FFCS 资源进行冻结旧 C++／最终 C++ 的[严格数值对照](../validation/ffcs-strict-cache-20261018.json)：4,351,500 个 Double 通道、13,054,500 个 Float32 通道及相应 RGBA 预览均无任何位变化，覆盖三组曝光与实际四工作区间执行。

### 阶段、启动、同步和内存

Standard 48MP 旧版进度区间中位数：源设置约 0.151 s，包含延迟 RAW 解码的颜色／工作文件生成约 2.478 s，空间阶段约 0.694 s，后置颜色／幅值恢复约 0.489 s，编码前准备约 0.077 s，最终 Core Image／HEIF 约 0.209 s。新版各阶段相近。

PROVIA 48MP 的完整导出中位数从 5.3593 s 降到 5.2768 s，ACROS 从 5.3804 s 降到 5.2664 s。FFCS 的 0.1–0.85 进度区间是同一条带处理循环，不能将其中 0.45／0.65 标记当作独立算法阶段。Core Image 的延迟求值意味着最终编码计时还包含缩放和色彩转换，不是纯编码器耗时。

第一次 48MP 完整调用：Standard 旧／新为 5.0738／4.6083 s，PROVIA 为 5.8176／5.7274 s，ACROS 为 5.9130／5.7259 s。进程间系统缓存状态不同，不能把这一次差值解释为稳定启动收益。

进程峰值 RSS 约 **2.74–2.78 GB（十进制）**，包括完整解码核验、映射页和系统编解码分配，不是算法工作区大小，也不是手机峰值。新增缓存另计为确定的 512 KiB／上下文。当前库调用保留最大四个工作区间；本轮未测并行相机采集、其他 App 竞争或手机热降频。

## 事先确定的近似预算

[预算原件](/Users/vonequinox/.codex/visualizations/2026/10/17/01a14afa-ebe0-7180-be23-7f59ec9cef36/color-research-20261018/performance/precision-budget-v1.json)在候选测量前保存，没有因失败而放宽。它限制**优化额外引入的差异**，原厂残差另列。

| 指标 | 均值 | P95 | P99 | 最大值 |
|---|---:|---:|---:|---:|
| SDR ΔE00 | 0.02 | 0.05 | 0.1 | 0.5 |
| HDR ΔEITP | 0.1 | 0.25 | 0.5 | 1.0 |

还要求高光峰值相对误差 ≤0.001，无新增裁剪、无新增渐变反转。依据是保守地把误差限制在约一个色差单位以内，并用分位数约束常见像素；这不是适用于所有显示条件的可见性保证。

合成筛查覆盖中性灰／暗灰渐变、饱和原色、两种合成肤色渐变、半码邻域、固定随机值与 1–49.26 倍 HDR 幅值。它不是实拍肤色精度试验，也不能代表全部暗部彩色、CCT 和曝光组合。SDR 统一 sRGB／D65 Lab；HDR 使用 BT.2100 LMS/PQ 到 ITP、BT.2124 的 720 倍距离。完整 HEIF 则先统一解码到 BT.2020/PQ Float32，再计算 ΔEITP，分位数包含未变化像素。

## 已测但不采用：Metal 候选

[研究桥](../tools/metal_hncs_source_bridge.mm)可选 Float32 源矩阵，或 Float32 源矩阵加颜色核；gradation、空间和输出仍在 CPU。MSL 禁止 contraction，fast math 关闭，仍不能使 Float32 等同 Double。该桥没有链接到 App。

0.131MP 合成筛查中，完整 GPU 颜色候选 Standard／Nature 的最大 ΔE00 为 0.06557／0.03868，最大 ΔEITP 为 0.12599／0.09502，通过该样本筛查。点处理阶段约 1.25 ms；这不包含完整 RAW、空间及输出。

[同一可执行文件的完整对照](../tools/run_metal_performance.py)生成 32 个 HEIF，实际 GPU 调用计数非零，完整耗时快约 6%–8%。然而最终质量全部失败：

| 配方／尺寸 | 平均 ΔEITP | P95 | P99 | 最大值 |
|---|---:|---:|---:|---:|
| Standard 24MP | 0.80923 | 2.5301 | 4.0020 | 22.9348 |
| Standard 48MP | 0.66065 | 2.2406 | 3.5298 | 29.8730 |
| Nature 24MP | 0.85449 | 2.6697 | 4.2114 | 31.7924 |
| Nature 48MP | 0.69067 | 2.3590 | 3.7056 | 39.4565 |

约 50%–60% 解码像素变化；两个 24MP 案例分别新增 645／984 个黑色通道，有些案例的峰值相对误差也超限。完整统计和最差序号均保留，不能只采用合成筛查的较小最大值。

[编码前诊断](../tools/diagnose_metal_hdr_export.py)在生产 Swift 的外部副本中，截取完成缩放、限幅和 headroom 设置的同一幅图像，使用同一 context 渲染 PQ Float32。Standard 24MP 的编码前平均／P95／P99／最大 ΔEITP 为 **0.00017463／0／0.0044456／0.848667**，无新增裁剪，峰值一致。其写成 HEIF 再解码后的平均／最大值变为 0.80923／22.9348。带截取步骤的 CPU／GPU HEIF 各自与原实验文件哈希一致，支持“导出后的处理放大了输入微小差异”；没有据此声称已定位到某个 HEVC 内部决策。诊断耗时包含额外渲染与写盘，不进入性能数据。

每个 GPU 配方进程的八次导出共 1008 次颜色提交，上传约 4.958 GB，缓存缓冲区约 9.56 MB。Standard 累计 CPU 拷贝 0.0833 s、提交／等待 0.7573 s、GPU 时间戳 0.2661 s、CPU 点处理尾部 1.4994 s。第一次 shader 创建约 56 ms，后续进程命中系统缓存可短至约 0.355 ms。这些值说明统一内存仍有拷贝和同步成本。

## 已测但未证明完整收益：Accelerate 与 Core ML

Accelerate 的 Double 类型转换、乘法和 BLAS 矩阵候选在当前合成样本上逐位一致。没有证明任意 BLAS 实现／尺寸都保持原表达式的累加顺序，也未建立完整导出收益，因此没有替换默认路径。

[Core ML 探针](../tools/probe_coreml_source_matrix.py)把实际上下文的源矩阵表示为 1×1 卷积，不训练、不拟合。coremltools 9.0，FP32／FP16，各测试 CPU-only、CPU+GPU、CPU+ANE、all，Standard／Nature 共 16 次预测均成功。

**全部计算计划优先选择 CPU。** FP32 未把 ANE 列为支持设备；FP16 的部分算子可支持 ANE，但仍优先 CPU。`MLComputePlan` 是预期放置，不是 Instruments 运行轨迹，故没有 ANE 实际执行或速度结论。

矩阵预测中位数约 118–139 μs；布局转换 124–185 μs；模型加载／编译 22.6–69.3 ms；首次预测 0.431–11.58 ms。模型转换耗时 0.017–1.731 s。误差传播时另外执行原 CPU 颜色、曲线、锐化和输出，不能把矩阵预测时间当成完整流水线时间。

| 候选 | 配方 | ΔE00 均值／P95／P99／最大 | ΔEITP 均值／P95／P99／最大 | 结论 |
|---|---|---|---|---|
| FP32 | Standard | 0.00000162／0／0／0.01561 | 0.00000749／0／0／0.12599 | 合成筛查通过 |
| FP32 | Nature | 0.00000979／0／0／0.03190 | 0.00002660／0／0／0.07816 | 合成筛查通过 |
| FP16 | Standard | 0.01796／0.04851／0.07969／0.26558 | 0.04763／0.14451／0.23777／22.27634 | 失败 |
| FP16 | Nature | 0.01796／0.04930／0.07373／0.30098 | 0.05368／0.16452／0.26421／6.27937 | 失败 |

FP16 还新增裁剪与渐变反转：Standard 黑／白通道 24／2、反转 6；Nature 黑／白 2／78、反转 26。四种 compute-unit 选项在各自精度下得到相同输出。FP32 尚未证明完整 HEIF 质量、端到端速度或独立模型峰值内存，不能采用为默认优化。

最差案例也保留实际数值：Standard 的 22.27634 来自输入 RGB 均为约 0.0147652 的暗灰、HDR gain 1；经过后续处理的参考 RGB 约 `[0.00002082,0.00001221,0.00008382]`，FP16 为 `[0.00022354,0.00021492,0.00028653]`。Nature 的最大值来自约 41.14 倍 HDR 幅值下的饱和红暗部，参考／候选红通道约 0.068419／0.060817。不能用低 SDR 均值掩盖这些极值。

## Apple 官方能力与系统约束

本次实际读取并保存 16 份官方文档及摘要。[文档清单](/Users/vonequinox/.codex/visualizations/2026/10/17/01a14afa-ebe0-7180-be23-7f59ec9cef36/color-research-20261018/performance/apple-docs-final/index.json)保留 URL、平台版本和内容哈希。

| 能力 | 适用部分与限制 | 文档中的系统入口 |
|---|---|---|
| CPU SIMD／[Accelerate](https://developer.apple.com/documentation/accelerate) | 向量算术、类型／布局转换、矩阵；Double 与明确累加顺序仍须逐项验证 | Accelerate iOS 4／macOS 10.3；具体 API 另核对 |
| [vDSP](https://developer.apple.com/documentation/accelerate/vdsp)／[vImage](https://developer.apple.com/documentation/accelerate/vimage) | CPU 向量和图像操作，适合批量矩阵、通道和缓冲区处理；现成滤镜不自动等价于原版固定点算法 | 此处 Swift overlay：iOS 13／macOS 10.15；不代表 C 库首次出现版本 |
| [BNNS](https://developer.apple.com/documentation/accelerate/bnns-library) | CPU 神经网络／张量计算；并非 ANE 接口，本轮未制作独立 BNNS 整链候选 | Swift BNNS overlay：iOS 14／macOS 11；各算子要求不同 |
| [Metal](https://developer.apple.com/documentation/metal)／[MPS](https://developer.apple.com/documentation/metalperformanceshaders) | GPU 像素、LUT、矩阵、卷积；本次实际使用自定义 Metal，未宣称 MPS 算法逐位匹配 | Metal iOS 8／macOS 10.11；MPS 文档入口 iOS 9／macOS 10.13，还需设备／GPU family 支持 |
| [shared storage](https://developer.apple.com/documentation/metal/mtlstoragemode/shared) | CPU/GPU 共享系统内存，但读写仍须同步；本次显式提交并等待 | iOS 9／macOS 10.11；非 Apple GPU 的纹理支持不同 |
| [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits) | 是允许的设备集合，不保证实际放置；FP16/FP32、算子与图规模影响回退 | MLComputeUnits iOS 12／macOS 10.14；[CPU+ANE](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine) iOS 16／macOS 13，且需相应硬件 |
| [MLComputePlan](https://developer.apple.com/documentation/coreml/mlcomputeplan-1w21n) | 查询预期设备、支持集合与成本；本轮实际读取，未做运行设备追踪 | iOS 17.4／macOS 14.4；本次模型使用 iOS 18 算子部署目标 |

本轮有效交付是严格 FFCS 优化及可重复的拒绝／保留依据。更广的暗部彩色、CCT／曝光覆盖、全 Core ML 图、MPS／BNNS 独立候选和手机争用／热状态属于后续研究，不作为当前性能承诺。
