# 颜色处理性能：5 秒究竟测了什么

更新：2026-10-11。状态：Linux C++ 实测；Apple/iPhone/48MP/HEIF 端到端耗时未测。此文不声称“极限优化完成”。

**后续已落地：** Float 导出新增逐位一致的并行 API，详见 [精确 Float 导出改进](EXACT_FLOAT_PARALLEL.md)。下文表格与“单线程当前路径”是此次改动前的基线快照，不代表新增并行 API 的结果。

## 先纠正旧数字的含义

旧 `validation/optimization.json` 的 **5151.7 ms → 1139.0 ms** 是 **4000×3000，12,000,000 像素**：精确单线程 → 有界 8 位显示编码查表加四线程。不是 48MP，也不是手机上的 5 秒。

当时计时包括：linear-sRGB 输入域桥、HNCS 原核、显示域转换和 sRGB OETF/8 位量化。**OETF 是颜色传递函数数学，不是 HEIF 文件压缩编码。** 解码/RAW 去马赛克、Swift 缓冲区、Core Image、文件编码/落盘、Photos 保存、上下文初始化和 UI 都不在该数字里。

原测试已经是 `g++ -O3 -fno-fast-math -ffp-contract=off -pthread`，不能归因为 Debug 编译。iOS 的 Swift Debug/Release 设置是另一件事，Apple C++ 实际构建设置和运行尚未验证。

## 本次复测的范围

- Linux x86_64，Intel Xeon Platinum 8370C，g++ 14.2；严格浮点，不启用 fast-math。
- 可见逻辑 CPU affinity 为 0–8。cgroup CPU 配额、节流统计及内存限额接口不可读，不能推断有九个独占核心。
- 固定种子的合成 [0,1) linear-sRGB Float32 RGB；不是实际照片语料。HNCS：EV=0、5500K、legacy/standard。
- 每项先预热一次，再测五次；记录每次 wall time 与进程 CPU time（多线程 CPU time 含所有工作线程）。固定顺序采样，未随机交错；共享主机波动明显。
- 12MP 只测完整 C API；分阶段使用 1,048,576 像素，避免大量全图 double 中间缓冲。没有创建 48MP 测试图。
- 已分配输入输出和上下文不计入完整 C API；FFCS 基线在函数内部的 scratch 分配仍计入。

## HNCS 当前完整 CPU API：12MP

| API | 墙钟中位数 | 墙钟范围（五次） | CPU 时间中位数 |
|---|---:|---:|---:|
| exact 8-bit，1线程 | 5592.9 ms | 4686.8–6107.7 ms | 5566.9 ms |
| fast 8-bit，1线程 | 4980.9 ms | 3251.2–5861.5 ms | 4969.7 ms |
| fast 8-bit，2线程 | 2408.9 ms | 1642.9–3028.3 ms | 4112.5 ms |
| fast 8-bit，4线程 | 1412.0 ms | 1184.5–1544.0 ms | 4184.4 ms |
| 精确 display-linear Float RGBA，1线程 | 2998.6 ms | 2891.1–3171.5 ms | 2995.2 ms |

这组数字验证旧“数秒”量级能在同类云 CPU 的全算法上出现，但不证明稳定速度上限。1MP 的另一组短测里 fast 单线程甚至比 exact 慢，表明跨时间块的主机波动足以掩盖优化收益；不能只挑最好一次、声称固定加速倍数，或把五次样本当稳定 p95。

当前 HEIF 导出的 HNCS 路径使用 **display-linear Float 输出、单线程核**，绕开最后的 8 位 OETF/量化。四线程 fast 是预览路径，其耗时不能替代 Float 导出核，更不能替代 HEIF 导出总时长。上表 Float 也只到浮点像素，不含 Apple 编码器。

## 为什么不是一次小矩阵的耗时

诊断程序将相同算法拆成独立遍历，使用预分配 double 中间缓冲。以下为首次 1MP 样本中位数；原始样本见 JSONL。

| 独立阶段 | 墙钟中位数 |
|---|---:|
| 对照：仅一次 3×3，Float 输入 / double 输出 | 24.0 ms |
| 输入桥（曝光、有限数检查、3×3） | 14.1 ms |
| 三通道 UInt16 ties-to-even 量化 | 80.9 ms |
| 原核 incoming 3×3 | 18.9 ms |
| chroma 坐标、除法与二维 LUT 双线性插值 | 42.2 ms |
| 灰轴/阴影权重 | 12.5 ms |
| outgoing 运算与原始 tone LUT | 11.7 ms |
| ICC 解码查表、三个显示矩阵、裁剪 | 42.8 ms |
| 精确 sRGB OETF（pow）及 8 位量化 | 262.5 ms |
| fast sRGB 查表及 8 位量化 | 65.0 ms |

**这些独立阶段不可相加为融合 API 耗时，不可直接换算为占比。** 内存流量、缓存、编译器内联/向量化和测量时段不同；输入桥比纯矩阵对照快也提醒了这一限制。能支持的结论是：精确显示传递函数和整数边界处理是值得优化的实际工作，单次 3×3 不是整个 pipeline。它不是“12MP × 一个3×3却用了5秒”。

正确性：分阶段重组的 exact/fast 字节输出与生产 C API 一致；1MP/12MP fast 相对 exact 最大差均为 1 个 8 位码，2/4 线程与 fast 单线程摘要一致。原核 UInt16 没有被近似 RGB 3D LUT 替换。此次只增加诊断程序，没有修改生产算法。

## FFCS 不能与 HNCS 混为一谈

FFCS PROVIA，1,048,576 像素，原 reference-order 阶段的五次中位数：3×3 9.9 ms；OETF+3D LUT 317.2 ms；Lab/UCS 1484.0 ms；tone 15.8 ms；grain 66.3 ms；sharpen 73.4 ms；输出转 Float linear 141.3 ms。这里 Lab/UCS 明显比矩阵贵，包含多次传递函数、非线性色彩坐标和三角运算。

完整 Float 输出 API：基线 2048.9 ms；精确 row-ring 优化单线程 3393.1 ms；四线程 712.0 ms。输出 Float 与可选预览逐位等于基线。单线程 row-ring 这组更慢，不能把降低 scratch 内存称为无条件提速；四线程减少墙钟也不等于降低总 CPU 成本/功耗。合并预览输出的另一组短测出现不单调耗时，进一步说明共享主机噪声。raw JSON 保留所有样本。没有把这些 FFCS 数字用于解释旧 HNCS 5.152 秒。

## 实现与下一步状态

已实现、这次直接测量：精确原核、精确 ICC 解码表、独立有界显示编码表、最多四线程预览、Float 输出绕开 8 位编码。

已在代码中、但不是本次 Apple 运行证据：不可变配方上下文复用、全源分块、FFCS halo/全局 grain 坐标。上下文复用的旧独立构造实验见 `validation/hncs_context_cache.json`；不能当作本次像素耗时的一部分。

下一步优化优先级：先在 Apple Release 真机测分段 signpost（解码、域转换/拷贝、原核、文件编码、保存），再基于实际热路径优化量化/SIMD和 Float 核并行。线程池/持久工作队列、Metal 融合都还是候选，需要结果一致性、总耗时、内存与热状态验收；不把小矩阵直接搬到 ANE 就称为优化。

未执行：Apple 编译/安装、48MP CPU 或 iPhone 测量、HEIF 压缩/写盘耗时、真机峰值内存、功耗与热稳态。**不做 12→48MP 或云 CPU→iPhone 线性推算。**

## 复现与证据

`python tools/benchmark_current_pipeline.py`

- `tools/profile_hncs.cpp`：直接包含生产实现；独立分段与生产输出交叉校验。
- `tools/profile_ffcs.cpp`：原始 reference-order 阶段回调；优化 API 与基线输出比较。
- `validation/profile_hncs_1mp.jsonl` / `profile_hncs_12mp.jsonl` / `profile_ffcs_1mp.jsonl`：原始墙钟与 CPU 样本。
- `validation/current-color-performance.json`：编译命令、源码 SHA-256、环境、汇总和测量边界。

旧证据未覆盖写入。新实验不替代既有 golden/reference、sanitizer、Apple验收。
