# HNCS 颜色核查与保精度提速

2026-10-17，`codex/single-camera-hard-black`。本次保留颜色算法及参数，修改自动拍摄的执行流程与 CPU 工作调度。

后续已完成 [RAW 输入统一与成片对照](RAW_INPUT_STUDY_20261017.md)。下文源码摘要对应各次测量时的构建；后续入口整理通过了默认配方输出不变的回归，候选解码尚未改变相机默认外观。

随后[直接二进制核查](HNCS_BINARY_AUDIT_20261017.md)发现并修复了参考实现的无调整 gradation 旁路。当前 render revision 9 的 Standard 因补回原版处理，像素及耗时不再等同于下文历史构建；下文“参考一致”不能作为完整 Phocus 一致性的证据。

## 续接验收

上一次对话因请求错误中断。核对留存报告、RAW SHA-256 和源码摘要后，确认下文 Standard 的历史提速结果有对应证据；当时尚缺 Nature 的完整真机对照、真实自动处理服务的集成验证和正式 App 安装收尾。本次补齐这些项目，保留已经通过核对的颜色算法和优化实现。

同一台 iPhone、同一张 48MP RAW，使用设备现有的 L*RGB、EV -0.05 配置，分别检查 Standard 与 Nature。每个预设、每个输出尺寸、每条路径各三轮，交替路径与尺寸顺序。所有计时样本的热状态均为 nominal，低电量模式关闭。

| 预设 | 输出 | 含重复预览的路径 | 直接导出 | 耗时减少 |
|---|---|---:|---:|---:|
| Standard | 24MP | 3.562 秒 | 2.737 秒 | 23.14% |
| Standard | 48MP | 3.676 秒 | 2.853 秒 | 22.38% |
| Nature | 24MP | 6.558 秒 | 5.437 秒 | 17.09% |
| Nature | 48MP | 6.749 秒 | 5.684 秒 | 15.77% |

这是**同一构建内两种执行流程**的中位数比较，两边都使用优化后的 CPU 调度，用于单独验证省去预览的效果；不能与下文历史构建的约 23% 提速再次相乘。Nature 包含完整预设空间处理，不能用 Standard 的耗时代表它。计时仍不含相机拍摄、真实 Photos 事务，也没有并发运行取景。

- 四个预设/尺寸组内，各自六个 HEIF 文件逐字节一致；每组首对完整 Float32 RGBA 解码摘要也一致。测试样本因流程优化引入的 ΔE 为 0。
- 在手机上实际运行生产 `CaptureWorkflow` 和 `Services.live`，两种预设各验证磁盘保留与强制内存回退，共四例。所有成片均与相应直接导出文件一致；注入首次保存失败后，重试复用同一 HEIF 对象。这里只替换了相机输入回调和 Photos 事务，没有把替身测试称为真实拍摄/相册验收。
- 67 项相关便携检查通过，包含 576 组并行/串行逐位比较；重新运行 Apple Core Image/Metal/HEIF 回归，14 组直接/预览后导出解码像素差均为 0。
- Release 正式 App 构建、安装、启动成功，随后能查到对应进程。安装前后设置按值比较一致。两轮真机基准各记录的 22 个源码/资产摘要与当前文件一致。
- 重新核对参考 Python、工厂颜色 NPZ、原生预设 JSON 和后置曲线 NPZ，共六个文件与用户提供的 HNCS 目录一致。

结论仍是：未发现 HNCS 移植错误或 Standard/Nature 未生效的问题；iPhone 接入包含 Apple 显影与虚拟源域桥，尚不能把最终外观认定为经过相机配对标定的原生哈苏效果。GPU/ANE 的约束见下文，未把近似颜色替代作为本次提速。

证据：[真机续接报告](../validation/hncs-followup-iphone-20261017.json)、[Apple 回归日志](../validation/hncs-followup-apple-tests-20261017.txt)。样本仍限一张室内 RAW；不据此承诺多场景、p95、持续拍摄、功耗或屏幕观感。

## 颜色核查结论

软件内的 `reference/hncs_pipeline.py`、`phocus_presets.py`、`reference_color_core.py` 和工厂颜色 NPZ，与用户提供的 `/Users/vonequinox/Program/ProgramDev/HNCS/` 对应文件 SHA-256 一致，均为 render revision 8 / colour path revision 2。未发现把二维绝对色度 LUT 当残差、矩阵方向错误、预设未应用或资源版本错配的问题。

直接调用当前 C++ 实现的结果：

| 核查 | 结果 |
|---|---|
| 52 组原始黄金向量，6,656 像素 | UInt16 最大差 0 |
| 892,080 个额外随机/边界通道比较 | UInt16 最大差 0 |
| 43 个原始预设参数 | 与参考一致 |
| Nature/Lighten/Extra contrast 等有效原生后置曲线，278,528 像素 | 最大码值差 0 |
| 20,134,896 个预设通道比较 | 最大码值差 0 |
| 120 个 Film Curve 组合、86 个原生组合 | 最大码值差 0 |

详见 [原始核查结果](../validation/hncs-reference-audit-20261017.json)。这些结果验证指定数学及参数，不代表 iPhone 与哈苏之间已有色卡标定。

Standard 与 Nature 不是相同输出。Nature 的参考参数包含不同的曲线、5500K 对应的完整目标白平衡增益和锐化；Standard 按参考入口绕过后置空间预设。使用本机留存的同一张 48MP iPhone ProRAW，按设备当时的 L*RGB、EV -0.05、24MP 输出设置分别做完整导出，Nature 显得更暖、暗部更深。比较基于最终 HEIF 回读，见 [比较参数](../validation/hncs-color-comparison-20261017.json)。对照图片保存在本次聊天的本地可视化目录，不放入源码仓库。

但目前这条 iPhone 路径不等于参考文件夹中的完整 Sony→X2D 配对显影链：

- iPhone 输入首先经过 Apple ProRAW 解码。实测样张的默认 `boostAmount=1`、`boostShadowAmount=0.9`、`localToneMapAmount=1`、`baselineExposure≈3.1118`，因此颜色核接收的是已经进行全局/局部色调处理的线性编码 RGB。线性编码不等于未经显影处理的场景线性数据。[Apple boostAmount](https://developer.apple.com/documentation/coreimage/cirawfilter/boostamount)、[localToneMapAmount](https://developer.apple.com/documentation/coreimage/cirawfilter/localtonemapamount)。
- HNCS 使用虚拟源域映射和每张 RAW 的白点，不是此 iPhone 传感器的实测配对标定。Sony 的配对矩阵不能直接移用到 iPhone。
- 现有 HDR 外层会单独保存、恢复超过参考白的幅值。这是 App 的 HDR 适配，不是已验证的 Phocus 非 HDR 核心本身。本次样张约 2.52% 的预览像素进入该分支。

所以可以确认核心和预设在运行，但不能据此断言用户不满意的外观就是原生哈苏 HNCS 的风格。本次没有擅自关闭 Apple 显影参数、修改预设或重新拟合颜色；进一步改色应以明确的参考成片/同场景测量为依据。

## iPhone 上的实际处理基线与结果

设备：iPhone 18 Pro Max（`iPhone19,7`），iOS 27.0.1（24A446），6 个逻辑 CPU，Release 严格浮点构建。读取现有 RAW，不拍摄新照片、不写入 Photos。前后均使用同一份 49,513,537 字节的 RAW；默认 Standard、legacy 工作空间、EV 0，先完整处理 8064×6048，再按选项缩小。每个输出尺寸测 3 轮，顺序交替；系统 thermalState 开始/结束均为 nominal，低电量模式关闭。

计时覆盖源文件保留、旧路径的 RAW 预览及效果计算、全源 HEIF 输出、成片预览解码。相机拍摄、相册事务不在计时内。独立基准 App 没有同时运行取景，因此实际相机 App 延迟可能有所不同。

| 输出 | 优化前中位数 | 优化后中位数 | 耗时减少 | 加速比 |
|---|---:|---:|---:|---:|
| 24MP | 3.632 秒 | 2.772 秒 | 23.69% | 1.310× |
| 48MP | 3.746 秒 | 2.875 秒 | 23.25% | 1.303× |

旧路径约 0.75 秒用于 RAW 预览解码、0.085 秒用于这张不会展示的效果预览。改成直接全源导出后省去了这段工作，最终仍从已编码 HEIF 生成成片预览。

作为独立核实验，8064×64 像素的 Standard 四 worker 调用中位数从 4.977ms 到 4.661ms；Nature 点处理从 15.217ms 到 14.005ms。这不是完整 Nature 导出耗时。调度收益较小，端到端主要收益来自避免重复预览。

所有原始计时、温度状态、源码摘要、文件摘要与范围说明见 [真机数据](../validation/hncs-iphone-20261017.json)。只有一张室内 RAW 和每档三轮，不能当作 p95、持续连拍、功耗或全部场景保证。

## 已落地的实现

1. `ImagePipeline.writeHEIF(sourceFile:recipe:...)` 只读取本张 RAW 白平衡元数据，绑定不可变配方，直接进入既有全源导出。`CaptureWorkflow` 使用此入口，保留 DNG/内存回退、保存失败重试和最终 HEIF 所有权。原预览入口继续作为编辑/诊断与回归 oracle。
2. Apple 平台的精确 Float 点处理复用 libdispatch 工作线程。最多仍是调用者请求的 1–4 worker，保留低电量/热状态限制；每次领取 32,768 像素，让性能不同的核心分担不同数量的任务。其他平台保留标准线程实现。
3. Nature 等空间预设之前/之后的两个独立点处理阶段也使用同一并行调度。全图颗粒统计、随机顺序、USM、裁切和 64 行导出粒度保持原算法。

不合并矩阵、不改变表达式顺序、不启用 fast-math、不降低 double/UInt16 中间精度。每个像素仍调用原串行数学函数。

## 精度及运行验证

- 真机同一 RAW 的 24MP 与 48MP：前后六个同尺寸 HEIF 文件分别逐字节一致；首轮完整解码的 Float32 RGBA SHA-256 也一致。因此对本组样本，在同一色彩转换下优化引入的 ΔE 为 0。此处不是跨相机色准指标。
- 新增 576 个并行/串行比较组合，覆盖三个 Float 边界、八类预设/模式、1–4 worker、阈值及非整除尾部，逐位一致；空指针、非法 worker、溢出和末尾 NaN/Inf 按原契约拒绝。
- Apple 真实 Core Image/Metal/HEIF 回归通过；14 组 SDR/HDR 来源、空间效果、方裁切与缩小，直接导出和旧预览后导出的解码像素最大差 0。
- ASan/UBSan 并行边界检查通过；Release iPhone 构建通过。未把静态源码检查当作图像精度证据。

## GPU 与 Neural Engine 的判断

Core Image/Metal 继续负责 Apple 图像处理、缩放与显示，HEIF 由 Apple 框架编码。本次没有把这些阶段换成 CPU 仿制算法。

在这台 iPhone 上用 Metal 运行时编译含 `double` 的 compute kernel，得到 `'double' is not supported in Metal`。当前 HNCS 的有序双精度运算、精确 UInt16 舍入、二维 LUT 边界不能通过直接改成 float/half 就宣称等价。GPU 原始 LUT 查找可并行，但整个颜色核的逐位等价需要额外研究；未把已有近似实时 cube 用于最终成片。

Neural Engine 通过 Core ML 模型调度，不是可以直接运行现有 C++ double 函数的处理器。Core ML 的图划分和执行类型也不能给出该流水线的 FP64/舍入等价保证。[Apple typed execution 说明](https://apple.github.io/coremltools/docs-guides/source/typed-execution.html)。本次未部署 ANE 模型，没有声称测得其吞吐或加速效果。

在本次“颜色不变”的约束下，优先删除重复工作和做跨像素 CPU 并行有可核验收益。GPU/ANE 的近似颜色替代不能作为此优化的默认实现。

## 复现

从 `GlassCamPrototype/` 运行，结果目录应在源码仓库之外：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B tools/run_hncs_study.py \
  --raw-source /absolute/path/photo.dng --output-dir /tmp/hncs-study \
  --label direct --rounds 3 --direct
```

不带 `--direct` 可测同一构建中的预览后导出路线；这会包含新线程调度，不能冒充完整旧版本的性能。`--preset nature --working-space lstar` 可检查对应配置。`--prepare-ios --team TEAM_ID` 生成独立 Xcode 工程，随后按 `HNCSStudy` scheme 为手机构建、安装、运行；结果在该基准 App 的 `Documents/<label>/report.json`。该工具只处理显式输入 RAW，不调用相机或 Photos 保存 API。

自动完成本次真机对照及服务验证：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B tools/run_hncs_study.py \
  --raw-source /absolute/path/photo.dng --output-dir /tmp/hncs-nature-study \
  --label nature-lstar --rounds 3 --preset nature --working-space lstar --exposure-ev -0.05 \
  --compare-paths --verify-live-capture --run-ios DEVICE_UDID --team TEAM_ID
```

`--run-ios` 构建并安装独立 HNCS Study App，收集与本次 `run_id` 匹配的完成报告；默认 600 秒截止，可用 `--timeout` 调整。完成依据报告状态，GUI App 可以保持打开。结果保存为输出目录下的 `<label>/report.json`，同时保存运行配置、源码摘要及构建日志。`--compare-paths` 交替比较两条路径并强制校验文件/像素摘要；`--verify-live-capture` 增加真实自动处理服务、内存回退和保存重试验证。去掉 `--run-ios` 与 `--team` 可在 Mac 上运行同样的检查。
