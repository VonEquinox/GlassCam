# 测试与性能状态

更新：2026-10-11。以下严格区分已执行、源码实现与未执行。保存/分享合并运行 [43 项测试通过，26.105s](../validation/final-source-tests.txt)，随后精确 Float 并行集成 [43 项通过，19.088s](../validation/performance-integration-tests.txt)，包含保存/分享、显式跨队列取消 token、render 完成竞态 guard 与已解码源 Retry 的源码契约。Apple 代码仍只做静态验证。

## 已执行并通过

- 新增 Float display-linear 导出路径：884,736 个 RGB 通道对 double 参考，最大绝对误差 2.9801849987798334e-8（阈值 1e-7）。灰阶扫描保留 4,096 / 4,096 / 4,070 个不同通道值，排除先降 8 位再扩展的实现。
- Float 导出 tile 一致、alpha=1、范围 [0,1]、非法参数检查通过；原核黄金测试重新执行仍为 0 差。
- 既有 HEIF 静态契约覆盖专用 HEIF10 writer、RGBAf/extendedLinearSRGB 输入、快照与无 8 位导出回退。分享新增按需 JPEG 不属于 HEIF 保存回退；新交付静态契约已纳入上述 43 项运行。静态测试不等于 Swift 编译或真实 HEIF 检验。
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

## 历史预览基准与已实现优化

新增精确 Float 导出核与分段测量见 [当前颜色性能报告](COLOR_PERFORMANCE.md)。下面保留旧同轮基准用于解释优化来源，不以新旧不同负载互算加速比。

环境：Linux x86_64，Intel Xeon Platinum 8370C，g++ 14.2，`-O3 -fno-fast-math -ffp-contract=off -pthread`。以下为同一输入、同一次对比测试的中位耗时，预热后各 3 次。共享云 CPU 的短测会有噪声，不能当作稳定硬件极限。

| 尺寸 | 精确单线程 | 编码表单线程 | 编码表 2 线程 | 编码表 4 线程 | 4 线程加速比 |
|---|---:|---:|---:|---:|---:|
| 1024×1024 | 466.8 ms | 305.9 ms | 220.0 ms | 145.8 ms | 3.20× |
| 2048×1536 | 1308.8 ms | 968.1 ms | 750.2 ms | 400.4 ms | 3.27× |
| 4000×3000 | 5151.7 ms | 4105.6 ms | 2042.4 ms | 1139.0 ms | 4.52× |

计时包括源域桥、HNCS 与显示编码；**不包括解码、缩放、Swift 缓冲区、图像文件编码（当时为 PNG，当前为 HEIF）、界面与上下文初始化**。12MP 是独立 C++ 预览 benchmark；当前全源导出源码已不受 2048px 预览上限限制，但尚无 Apple 端到端导出测量。这不是 iPhone 测量，不能推算手机帧率。

本轮可归因优化：

1. 参数上下文预计算插值矩阵与 2D LUT，融合逐像素运算，避免全帧 double 中间图。
2. 原始 ICC 解码表按全部 65,536 个输入码精确预计算。
3. 精确输出路径保留。另加显式 fast API，只把最终 linear-sRGB→8bit OETF 的三个逐像素 pow 换成 65,536 项查表；该单项优化实测约 1.25–1.53×。
4. 加入最多 4 线程的连续块并行，原核不改，线程创建失败时安全串行补齐。
5. 当时 Swift 预览使用 fast 路径并按低电量/系统热状态将工作线程降至 2 或 1；当前 App 预览与导出已切至精确 Float 路径，继续采用有界工作线程策略；该 Apple 策略尚未真机测量，不能声称节电效果。

显示近似的边界：最近 16 位 linear 采样误差 ≤0.5/65535；sRGB 最大斜率约 12.92，连续字节尺度误差约 ≤0.0252，因此量化输出最多差 1 码。原始 HNCS UInt16 核仍需 bit-exact。精确 API 与 Swift `exactReference` 选项保留，便于比较或重新导出。该有界近似仅保留在旧8位诊断/预览API；当前App已改用精确Float高精度效果显示。HEIF 导出走独立 Float display-linear 路径，不通过 fast 字节编码；实际 HEIF10 编码器仍未在此环境执行，不能把已通过的 Float 测试称为已验证的 HEIF bitstream。当前 HNCS Float 导出已新增 1–4 线程精确并行，336 组对串行 oracle 逐位一致；真实8064×64条带及12MP计时见 [精确 Float 并行](EXACT_FLOAT_PARALLEL.md)。前表的旧8位预览速度仍不适用于端到端 HEIF 导出。

## 未执行 / 不能宣称通过

- Xcode/Swift/Apple SDK 编译、模拟器或 iPhone 安装。
- 实际 JPEG/HEIC/DNG/Apple ProRAW 导入、portrait 方向与 Core Image bitmap 行方向一致性。
- Apple HEIF10 编码实际执行、输出 HEVC/HEIF 位深与 SDR/sRGB 标签、无 HDR gain map 验证。
- 原生分享 sheet、微信/接收端可查看性、文件重开检查、Liquid Glass 真机外观。HEIC-first/按需 JPEG 兼容转码已实现源码，但接收方类型选择与兼容性未验证。
- 手机峰值内存、后台恢复、低电量与热稳态、持续运行 p50/p95、功耗。
- 完整 HNCS 旧 pipeline 的 RAW 解码、双光源拟合和全部空间阶段；FFCS 则已另行验证所移植的颜色、颗粒与锐化阶段，仍不等于完整相机 pipeline。
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

早期 13 项测试的记录已由后续 43 项合并运行替代，不能作为当前总数。此云环境未安装 CMake，CMake configure/build/ctest 未执行；g++ 数值/回归构建已执行。


## 当前原生拍摄 / 全源导出证据

[拍摄/导出阶段记录](../validation/final-source-tests.txt)：43 项合并 Python/source-contract 测试通过（其中 Apple 代码仅静态契约，非编译）。新增 FFCS strip 数值回归：399 全图、6,326 分块、653,904 像素与完整路线逐值一致；21 个非法调用无输出修改。项目新 Swift 文件引用/标识符检查通过。完整原始源临时保留、64 行输出块、FFCS halo/global grain、磁盘 RGBAf、颜色后 Lanczos 与十位写入已实现源码。

这些新增源码未在 Apple 平台编译运行；相机硬件、48MP/双路共存、实际条带行方向、HEIF 位流、磁盘/RSS/热状态、微信仍须设备测试。2048px 只限制默认导入预览，不限制全源输出。性能表仍是旧 HNCS 预览基准，不适用于完整新拍摄/导出链。

FFCS strip ASan+UBSan：19模式/760调用通过，见 `validation/ffcs_strip_sanitizer.txt`；LSan关闭。新增 `tests/apple_ci_strip_roundtrip.swift` 为未执行的 Apple 行方向诊断。


## 新交付与生命周期：源码已实现，运行待验收

- Photos add-only 原始 HEIF 保存、Files 原始 HEIF 复制；普通分享排除 Save to Camera Roll。
- 一个 NSItemProvider 的 HEIC-first / lazy JPEG file/data 表示。JPEG 仅从最终 HEIF 生成，不经预览；真正接收方选择、回调取消、sheet/file 生命周期尚待 Apple 实测。
- 保留导出 worker，显式 NSLock 取消 token 跨 decodeQueue 传递，条带与 codec 边界取消，不可中断调用结束前保持 busy。Photos 提交后不可取消。
- 导入效果失败保留 decoded source 可 Retry；未渲染配方禁止 Save/share；相机取消/失败解除 pending capture。
- 近似 FOV 外围映射、真实宽镜头覆盖门控、独立缩放的中心/外围视频输出不构成光学对齐或任意设备组合可用的证明。

设备验收：见 [iOS 清单](../ios/README.md)。43 项合并通过仅覆盖报告列出的 portable/source-contract 范围，不意味着这些新增交互已在 Apple 运行时通过。

## 精确 Float 并行回归

52 组/6656 像素、额外892080通道原核仍为0差；336并行case逐位一致；ASan/UBSan通过。真实64行条带1→4线程104.9→54.3ms，12MP2.731→1.063s（同轮云CPU中位数，含启动/join，不含Apple解码编码）。总CPU时间增加，不宣称省电。详见 [实现与原始样本](EXACT_FLOAT_PARALLEL.md)。

## 高精度效果预览追加

Float32原图/效果图→CoreImage/Metal RGBA16Float SDR源码已加入；软件binary16灰阶4096样本保留3073级，线性及sRGB编码域误差低于声明样本预算。此检查不等于Apple编译、GPU或面板实测；详见 [高精度预览](HIGH_PRECISION_PREVIEW.md)。

高精度预览合并 [52项测试通过，20.372s](../validation/high-precision-integration-tests.txt)。其中九项新增为源码/软件存储检查，Apple显示未执行；实时HNCS/FFCS视频处理未接入，用户已明确后置，不属于本轮待实施功能。

## 未来低分辨率色彩成本诊断

实时处理已由用户后置，本轮只估计成本。45 配置、225 计时样本与45预热输出全部与串行 oracle 的 hash 一致；覆盖 HNCS、完整 PROVIA / ACROS、128×72 至1080p及1/2/4 workers。记录墙钟与进程 CPU 时间，不能将多线程墙钟直接换算成低功耗。具体样本、画质代价和限制见 [低分辨率报告](LOWRES_COLOR_PERFORMANCE.md)。这些是共享云 CPU 数据，不是 iPhone 帧率或整机占用。
