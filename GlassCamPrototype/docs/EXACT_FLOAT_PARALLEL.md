# 精确 Float 导出的实测并行改进

> 2026-10-17：Apple 平台现复用有界 libdispatch 工作线程，并并行空间预设前后的独立点处理；自动拍摄移除了重复 RAW 预览。新的 iPhone 实测见 [HNCS 颜色核查与提速](HNCS_AUDIT_AND_SPEED_20261017.md)。下文的线程启动和 Linux 数字保留为历史基线。

更新：2026-10-11。基于 [颜色性能基线](COLOR_PERFORMANCE.md) 的后续修改；基线中“当前单线程 Float 导出”描述的是修改前状态。

## 已实现

新增 `hncs_process_linear_rgba_parallel`，Swift 的 `exportLinearRGBA` 使用它。原串行 API 保留作为 oracle。

- 每个像素仍执行原始 double 输入桥、原始 UInt16 HNCS 核、相同顺序的显示转换，最后存为 Float。没有重排矩阵、降低中间精度、启用 fast-math 或使用 8 位预览编码表。
- 输入范围按连续像素分成不重叠的输出区域；共享不可变上下文。新增线程最多三个，调用线程负责其余区域，全部 join 后才返回。
- 1–4 workers；不足 65,536 像素走串行，减少小块启动开销。过大计数按 RGBA Float 字节数验证。
- 线程创建失败时，已启动的线程继续处理，剩余区域由调用线程完成，再 join；这是代码审查结果，未故障注入模拟线程创建失败。
- Swift 复用已有上下文缓存与预览的低电量/热状态并发策略。Apple 编译、真机节能和热稳态效果尚未验证。

## 正确性

`python tools/verify_parallel_linear.py`：336 个逐位一致 case，通过 legacy/L* × standard/reproduction、(-2EV,2000K)/(0EV,5500K)/(+2EV,10000K)、0/1/13/65535/65536/65539/516096 像素和1/2/3/4线程。

覆盖空指针、零长度、无效线程数、超大计数、后部 tile 中非有限输入；失败时输出仍按 C API 契约视为无效。每个计时样本的 Float RGBA SHA-256 与串行 oracle 相同。该测试验证精确输出，不以“肉眼差不多”替代。

ASan + UBSan 的非整除 tile、全部线程数、超大计数与非有限输入检查通过；关闭 LeakSanitizer，未声称通过泄漏检查。源码契约测试将 HEIF 路由更新为新 exact-parallel API，仍检查不经过 byte encoder。原始黄金核 52 组 / 6,656 像素、额外 892,080 通道比较均为 0 差；43 项集成/源码检查通过。

## 计时：包含每次调用的线程启动和 join

同一 Linux 云 CPU；`-O3 -fno-fast-math -ffp-contract=off -pthread`。已分配输入/输出与上下文；预热后五轮，轮换1/2/4线程测量顺序，避免总是先测某一种模式。

| 工作负载 | 1线程中位数 | 2线程中位数 | 4线程中位数 |
|---|---:|---:|---:|
| 8064×64，真实导出条带尺寸，516096像素 | 104.9 ms | 79.7 ms | 54.3 ms |
| 4000×3000，12MP C API | 2731.4 ms | 1950.8 ms | 1063.2 ms |

1→4线程的这组中位数约为1.93× / 2.57×墙钟加速。所有原始样本都保留：12MP串行有7.972秒离群值、四线程有1.708秒样本；64行四线程也有138.0ms样本，因此不承诺稳定延迟。

12MP进程CPU时间中位数为2730.3 / 3591.1 / 3962.5ms；四线程墙钟变短，但总CPU成本没有减少。不能据此声称省电或热表现改善。实际条带每次仍创建线程，复用工作队列是后续候选，不是已经实现的功能。

这些仅是 **精确 Float 像素核**。没有测解码、Swift/Core Image搬运、RGBAf暂存、HEIF压缩、文件写入、Photos保存、48MP或iPhone端到端时间；不将12MP时间乘四预测48MP。

## Apple 后端的精度要求

CPU SIMD/Accelerate 可以作为下一条独立优化路线，但必须用真实 Apple Release 构建证明收益与原有数值契约。矩阵求和顺序、乘加融合、舍入和查表边界都可能影响最终原核 UInt16；仅“仍用 double”不等于逐位一致。GPU 迁移同样不能先降为 Float32 再宣称原样保留。官方 API 精度边界及下一步详见 [Apple 精确加速路线](apple_precision_acceleration.md)。本次已落地的是不改变逐像素数学的标准 C++ 并行化。Xcode 工程中两个 C++ 源文件已有逐文件 `-O3 -fno-fast-math -ffp-contract=off` 设置；实际 Apple Release 编译命令与运行仍待验证。

## 复现及证据

- `python tools/verify_parallel_linear.py`
- `python -m unittest discover -s tests -v`
- `validation/parallel-linear-export.json`：336 case、全部计时、输出摘要和源码 SHA。
- `validation/parallel-linear-core-regression.json`：原始 golden 与随机/边界检查。
- `validation/performance-integration-tests.txt`：集成/静态源码检查。
- `validation/parallel-linear-sanitizer.txt` 与 `tests/hncs_parallel_sanitizer.cpp`。

Sanitizer 命令：

`g++ -std=c++17 -O1 -g -fno-fast-math -ffp-contract=off -pthread -fsanitize=address,undefined -fno-omit-frame-pointer core/hncs.cpp tests/hncs_parallel_sanitizer.cpp -o build/hncs_parallel_sanitizer`

`ASAN_OPTIONS=detect_leaks=0 build/hncs_parallel_sanitizer`
