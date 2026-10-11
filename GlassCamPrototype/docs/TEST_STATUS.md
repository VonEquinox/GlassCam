# 测试与性能状态

更新：2026-10-11（包括 HEIF-only 与 FFCS 跟进）。以下严格区分已执行、受限、未执行。

## 已执行并通过

- 新增 Float display-linear 导出路径：884,736 个 RGB 通道对 double 参考，最大绝对误差 2.9801849987798334e-8（阈值 1e-7）。灰阶扫描保留 4,096 / 4,096 / 4,070 个不同通道值，排除先降 8 位再扩展的实现。
- Float 导出 tile 一致、alpha=1、范围 [0,1]、非法参数检查通过；原核黄金测试重新执行仍为 0 差。
- 4 项 HEIF 源码契约静态测试通过：专用 HEIF10 writer、RGBAf/extendedLinearSRGB 输入、显示快照参数、无 PNG/JPEG/UInt8 回退。它们不能替代 Swift 编译或真实 HEIF 检验。
- 原始资产 SHA-256 对照 provenance.json 通过。
- 原始 Python 生产函数与独立参考实现：52 组黄金向量、6,656 像素，最大 UInt16 差 0。
- 标准 C++17 原核：同一 52 组/6,656 像素，最大 UInt16 差 0；覆盖 legacy/L* × standard/reproduction 四模式。
- 额外随机/负值/超白/量化边界/色温范围测试：892,080 个通道比较，最大 UInt16 差 0。
- 精确输入桥与显示输出对 Python：最大 8 位差 0；tile 切分不改变结果。
- 优化显示路径：2,700,027 个通道对精确输出，最大差 1/255；2,283 个通道发生变化（约 0.085%）。另以 2,196,606 个密集值/边界样本验证输出编码表，最大差 1。
- 1/2/3/4 工作线程的优化输出逐字节相同。
- C ABI 非有限值、空指针、零长度、过大长度、非法设置/线程数检查通过。
- ASan + UBSan C ABI smoke 测试通过。LeakSanitizer 因容器 ptrace 限制不能运行，已明确关闭；不宣称泄漏检查通过。
- Xcode 工程文件引用、scheme XML 静态检查通过；不是 Apple 编译。
- 诊断渐变/色块图跑通输入→HNCS→PNG，并人工查看生成图。它不是实拍照片，也不用于证明肤色/审美或设备匹配。

## 实测性能与已实现优化

环境：Linux x86_64，Intel Xeon Platinum 8370C，g++ 14.2，`-O3 -fno-fast-math -ffp-contract=off -pthread`。以下为同一输入、同一次对比测试的中位耗时，预热后各 3 次。共享云 CPU 的短测会有噪声，不能当作稳定硬件极限。

| 尺寸 | 精确单线程 | 编码表单线程 | 编码表 2 线程 | 编码表 4 线程 | 4 线程加速比 |
|---|---:|---:|---:|---:|---:|
| 1024×1024 | 466.8 ms | 305.9 ms | 220.0 ms | 145.8 ms | 3.20× |
| 2048×1536 | 1308.8 ms | 968.1 ms | 750.2 ms | 400.4 ms | 3.27× |
| 4000×3000 | 5151.7 ms | 4105.6 ms | 2042.4 ms | 1139.0 ms | 4.52× |

计时包括源域桥、HNCS 与显示编码；**不包括解码、缩放、Swift 缓冲区、图像文件编码（当时为 PNG，当前为 HEIF）、界面与上下文初始化**。12MP 是独立 C++ benchmark，不代表当前 2048px iOS 原型能导出 12MP。这不是 iPhone 测量，不能推算手机帧率。

本轮可归因优化：

1. 参数上下文预计算插值矩阵与 2D LUT，融合逐像素运算，避免全帧 double 中间图。
2. 原始 ICC 解码表按全部 65,536 个输入码精确预计算。
3. 精确输出路径保留。另加显式 fast API，只把最终 linear-sRGB→8bit OETF 的三个逐像素 pow 换成 65,536 项查表；该单项优化实测约 1.25–1.53×。
4. 加入最多 4 线程的连续块并行，原核不改，线程创建失败时安全串行补齐。
5. Swift 默认使用 fast 路径并按低电量/系统热状态将工作线程降至 2 或 1；该 Apple 策略尚未真机测量，不能声称节电效果。

显示近似的边界：最近 16 位 linear 采样误差 ≤0.5/65535；sRGB 最大斜率约 12.92，连续字节尺度误差约 ≤0.0252，因此量化输出最多差 1 码。原始 HNCS UInt16 核仍需 bit-exact。精确 API 与 Swift `exactReference` 选项保留，便于比较或重新导出。该有界近似现在仅用于屏幕预览。HEIF 导出走独立 Float display-linear 路径，不通过 fast 字节编码；实际 HEIF10 编码器仍未在此环境执行，不能把已通过的 Float 测试称为已验证的 HEIF bitstream。当前 float 导出核为单线程，前表的 4 线程预览速度不适用于端到端 HEIF 导出。

## 未执行 / 不能宣称通过

- Xcode/Swift/Apple SDK 编译、模拟器或 iPhone 安装。
- 实际 JPEG/HEIC/DNG/Apple ProRAW 导入、portrait 方向与 Core Image bitmap 行方向一致性。
- Apple HEIF10 编码实际执行、输出 HEVC/HEIF 位深与 SDR/sRGB 标签、无 HDR gain map 验证。
- 原生分享 sheet、微信/接收端可查看性、文件重开检查、Liquid Glass 真机外观。分享兼容转码尚未实现。
- 手机峰值内存、后台恢复、低电量与热稳态、持续运行 p50/p95、功耗。
- 完整旧 pipeline 的 RAW 解码、双光源拟合和空间滤镜；本轮只验证所使用的颜色核心。
- FFCS Apple 平台运行、实时拍摄、48MP/高位深全尺寸导出、RAW+配方管理。
- 真实照片的审美验收和 iPhone→Hasselblad 匹配；没有新标定，也没有把合成图当作实拍证据。

## 复现与证据

- `python -m unittest discover -s tests -v`
- `python tools/verify_cpp.py`
- `python tools/benchmark_optimized.py`
- `python tools/verify_linear_export.py`
- `validation/linear-export.json`：Float 导出精度与未执行的 Apple/微信验证边界。
- `validation/cpp-verification.json`：精确基线与运行环境。
- `validation/optimization.json`：最终优化准确性、各路径耗时及输出摘要。
- `validation/sanitizer-tests.txt`：检测结果与 LSan 限制。
- `ios/README.md`：Apple 环境逐项验收清单。

“极限优化”是持续目标，不是这次已经完成的标签。下一轮优先验证 Apple 编译与真实输入，再测 decode、核心、encode、内存峰值分段成本；根据瓶颈选择 SIMD/Metal，不盲目把小矩阵搬到 ANE。

## FFCS 独立验证

详见 [FFCS 实现和性能边界](FFCS.md)：原始 9 测试、14 案例/153 阶段；19 种移植模式/513 阶段图最大误差 2.51e-14；1,368 个分块组合逐值一致。三行缓冲明显降低暂存内存，但云端线程计时不稳定，不承诺加速。App 暂用单线程，保留 1–4 核心接口。

最终合并源码测试：13 项 unittest 全部通过。此云环境未安装 CMake，CMake configure/build/ctest 未执行；g++ 数值/回归构建已执行。
