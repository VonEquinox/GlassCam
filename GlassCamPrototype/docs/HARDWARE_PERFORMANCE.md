# 硬件与性能设计

更新：2026-10-11。本文分别列出官方事实、本原型已测结果和下一步工程方案。尚无 iPhone 实测，不承诺实时帧率、48MP 吞吐、功耗或持续性能。

## 官方已公开的硬件

| 设备 | 芯片与 CPU | GPU | Neural Engine |
|---|---|---|---|
| iPhone 17 Pro / Pro Max | A19 Pro；6 核，2 性能 + 4 能效 | 6 核，含 Neural Accelerators | 16 核 |
| iPhone 18 Pro / Pro Max | A20 Pro；6 核，2 super + 4 能效 | 7 核，含 Neural Accelerators | 官方原文为 Dual 16-core Neural Engine |

来源：[17 Pro 官方规格](https://support.apple.com/en-us/125090)、[17 Pro Max 官方规格](https://support.apple.com/en-la/125091)、[18 Pro / Pro Max 官方规格](https://www.apple.com/iphone-18-pro/specs/)。这些规格页没有给出 RAM 容量、内存带宽或应用可用内存上限，本文不补猜测值。CPU/GPU 核心数也不能直接换算本应用性能。

## 公开 API 的能力边界

- **CPU：**标准 C++ 核默认在 CPU 上运行。Apple 的 [Accelerate/vImage](https://developer.apple.com/documentation/accelerate/vimage-library) 使用 CPU 向量处理能力。SIMD、vImage 或其他 Accelerate 调用应放在平台后端，保留不依赖 Apple 框架的参考核。
- **GPU：**Core Image 和 Metal 可承担图像处理。适合本项目的候选是融合逐像素变换、矩阵、曲线和查表，减少中间写回；需衡量上传、同步、下载及格式转换成本。
- **Neural Engine：**[Core ML computeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits) 设置允许的处理单元，由系统选择实际执行路径。它不保证所有运算都上 ANE，更不能把任意标准 C++ 自动编译到 ANE。
- **GPU Neural Accelerators：**它们与独立 ANE 不是同一个接口。Apple 已公开 Metal Tensor / MPP TensorOps，可在 Metal shader 中执行矩阵乘法、卷积等，并利用 A19 GPU 的相关加速。参见 [Apple TensorOps 说明](https://developer.apple.com/videos/play/wwdc2026/330/)及[性能讲解](https://developer.apple.com/videos/play/tech-talks/111432/)。简单 3×3 色彩矩阵不因此天然适合 TensorOps；必须与普通融合 kernel 对比。
- **RAW 与 ISP：**[AVFoundation / Core Image 的 ProRAW 流程](https://developer.apple.com/videos/play/wwdc2021/10160/)提供系统捕获、解码及调整接口，不等于允许应用把任意 C++ 部署到 ISP。当前原型使用的系统解码也不等于未处理 CFA 输入。
- **RAW9：**[Apple WWDC26](https://developer.apple.com/videos/play/wwdc2026/305/)介绍 iOS 27 的 RAW9，内部采用分块 Core ML 模型和 ANE。需检查 supportedDecoderVersions 后显式选择 version9，并检查具体属性支持情况。应记录解码器版本；系统解码变化不能混作自有色彩核心的变化。此路径尚未在本原型的 Apple 构建或手机上验证。

## 本次已经测到什么

以下是同一次云端 Linux / Intel Xeon Platinum 8370C 的对比，中位数来自预热后各 3 次；不是 iPhone 数据。完整环境、命令和结果见 [TEST_STATUS.md](TEST_STATUS.md) 与 [optimization.json](../validation/optimization.json)。

| 输入 | 精确单线程 | fast 编码表 + 4 线程 | 加速比 |
|---|---:|---:|---:|
| 2048×1536，约 3.15MP | 1308.8 ms | 400.4 ms | 3.27× |
| 4000×3000，12MP | 5151.7 ms | 1139.0 ms | 4.52× |

计时仅包括源域桥、HNCS 与显示编码，不含解码、缩放、Swift 缓冲区、PNG 编码、界面和上下文初始化。共享云 CPU 短测存在噪声，12MP 测试也不表示当前 2048px 原型已经支持 12MP 导出。

原始 HNCS UInt16 数值核仍按精确契约核验。fast 路径仅近似最终 linear-sRGB → 8 位显示编码；现有测试最大差 1 码，不能把这个容差扩展到 HNCS 核或未来高位深输出。1/2/3/4 线程输出已验证逐字节相同。精确入口保留。

## 下一轮优化实验

1. **先建端到端基线。**真机分别记录解码、颜色桥、HNCS、显示编码、导出和呈现耗时，再决定优先优化哪个阶段。记录冷启动、预热、交互与连续导出的区别。
2. **线程与 CPU SIMD。**比较现有连续块并行与可复用线程池，扫描块大小和 1/2/4 工作线程；不假定线程越多越快。检查编译器向量化，再比较显式 SIMD/Accelerate 后端。保持原有 double、ties-to-even、索引和截断语义，禁止默默开启 fast-math。
3. **Metal。**先实现可单独关闭的融合后端，尽量让 Core Image 解码结果、处理和显示留在 GPU，测量整个流水线而非只测 shader。GPU 浮点能力与 CPU double 参考核不同；若不能满足原核精确契约，应明确作为近似实验路径，不冒充等价实现。
4. **ANE / TensorOps。**只有未来增加有实际价值的去噪、分割等模型，或识别出足够大的矩阵/卷积瓶颈，才评估相应后端。设备上存在某个单元，不是必须使用它的理由。

Swift 负责 UI、生命周期、相机与系统框架；C ABI 负责稳定边界，显式规定尺寸、stride、格式、所有权和错误码。不要跨 ABI 传 STL 对象或抛出 C++ 异常。Apple 特定后端与标准 C++ 参考核心独立。

## 上线前的准确性、内存与热稳定门槛

- **准确性：**原 HNCS 核继续要求既有黄金向量、随机/负值/超白/量化边界测试下 UInt16 一致；显示 fast 路径独立维持已声明的最多 1 个 8 位码差。新增 SIMD/Metal 路径逐项验收，不只看肉眼效果。
- **颜色语义：**保持本仓库的原始二维 chroma LUT、输入域、插值、量化和截断规则，不能换成任意 RGB 3D LUT。HDR 负值/超白保留不是当前原核的承诺。未来改算法或高位深管线需单独定义契约，参见 [DESIGN.md](DESIGN.md)。
- **内存：**按 48,000,000 像素计算，RGBA16F 单缓冲约 384 MB（366 MiB），两张约 768 MB，尚未算 RAW、解码缓存和纹理。全图 RGBA32F 则约 768 MB/张。采用有限并发、分块、复用和预览降采样；有邻域操作时明确 halo，禁止分块接缝。
- **交互：**合并过时的滑杆请求，避免旧任务排队；交互预览与最终导出使用不同分辨率和缓存策略。Apple 对 RAW9 交互建议复用 CIContext、缓存中间结果并按显示尺寸处理，不能把该缓存策略无条件套到批量导出。
- **真机门槛：**记录端到端 p50/p95、峰值内存、帧丢失/交互延迟、持续负载表现与系统 thermalState。覆盖低电量、后台恢复、内存压力和导出取消。现有按热状态降低线程数的 Swift 策略尚未测得节能收益。

在 Apple 编译、真实样片、方向/色彩标签、真机内存和持续运行测试通过前，只能称为可核验的原型与性能实验，不能称为“极限优化完成”。
