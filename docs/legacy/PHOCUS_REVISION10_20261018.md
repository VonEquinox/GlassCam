# HNCS revision 10：锐化与颜色链路验收

2026-10-18。本轮完成 Phocus 原版参数解析、锐化与后置颜色接入、逐张 RAW 配方绑定，以及本地回归和 iOS Release 编译。使用原始 Phocus 4.2.2 arm64 二进制直接调用作为数值依据，并以 analyze-it 指定的 radare2 / r2ghidra 生成可读 C 反编译。

本轮没有真机实测、签名或安装；24MP／48MP 检查在 Mac 上执行。历史报告中的手机计时和安装记录属于其当时版本，不能用于验收 revision 10。

统一证据见 [源码与结果摘要](../validation/phocus-revision10-20261018.json)，默认规则、语义伪代码和原生调用顺序见 [可读反编译分析](PHOCUS_READABLE_ANALYSIS_20261018.md)。

## 修复内容

`radius=None` 来自把只含某一工具的局部 XML 当成完整配置。沿用项目既有的无状态预设策略，局部工具预设叠加原厂 Standard；完整配置独立解码。原版配置解码时，缺失数值键返回 0，缺失 `ApplyUSM` 返回 true；这与 `SetDefaultSharpness` 初始化的 amount 0、radius 10、dark 10、noise 0 是两条不同路径。没有用统一常数填补缺失值。Standard 原厂 amount/radius 为 100/10，Nature 为 180/8，XML radius 在加入滤镜时除以 10。

生产内存和文件流水线接入原版整数亮度锐化，保留 RGB16 到 14 位工作码的转换、分离卷积各自截断、强度／噪声表、整数乘法行为以及边界像素复制。Standard 不再错误跳过自己的锐化。实际强度经过原版 `EffectiveSharpnessAmount` 计算；所测 RAW 的 `BaselineSharpness=1.5` 时，Standard 传入强度 270，Nature 为 334。缺失基线采用原版 getter 的零回退。

原生反编译和数值调用确认处理顺序为：颜色核／film curve → gradation → 锐化 → 颗粒 → 饱和度 → 灰度 → 输出转换。本轮纠正旧实现把饱和度放在 gradation 前、把灰度放在锐化前的问题，并还原原版 HSL 饱和度与灰度混合的浮点类型、FMA、截断和归一化边界。颗粒仍采用既有便携模型。

Swift 从每张 RAW 读取并冻结白平衡和 `BaselineSharpness`，HNCS 解码明确关闭 Apple 可控制的额外锐化。通用 RAW 转入 HNCS 时按需要重新解码，并保留已解析的源图策略；冻结的元数据不一致时拒绝处理。预览、直接导出和失败重试共用配方，最终成片预览读取实际 HEIF。设置版本 8／9 迁移至 10，保留预设、选项与效果开关，未知版本拒绝。FFCS 通用 RAW 默认行为保留。

关键实现：[参数解析](../tools/phocus_sharpness_settings.py)、[原版锐化](../core/hncs_phocus_sharpness.hpp)、[后置颜色](../core/hncs_phocus_post.hpp)、[空间流水线](../core/hncs_spatial.cpp)、[Apple 图像入口](../ios/GlassCam/ImagePipeline.swift)。

## 验证结果

| 检查 | 覆盖与结果 | 证据 |
|---|---|---|
| 默认参数 | 56 个预设键（含别名）、8 组缺失字段／开关案例，与原生 getter 一致 | [settings](../validation/phocus-r10-settings.json) |
| 颜色核与 gradation | 两个随机种子，合计 203,709,420 个通道，最大 UInt16 差 0；WB 增益最大误差约 1.33e-15，CCT 选择相同 | [第一轮](../validation/phocus-r10-color-a.json)、[第二轮](../validation/phocus-r10-color-b.json) |
| 饱和度与灰度 | 56 个预设键、33,855,528 个通道，最大 UInt16 差 0 | [post stages](../validation/phocus-r10-post-stages.json) |
| 原版锐化 | O0／O3 使用不同种子；每轮 293 组参数、46 组图像模式及 9,601,024 个表项，全部一致 | [O0](../validation/phocus-r10-sharpness-o0.json)、[O3](../validation/phocus-r10-sharpness-o3.json) |
| 完整串联 | 712 组、4,949,196 个通道，最大 UInt16 差 0；工作浮点、内存／文件处理及最终显示入口逐位一致 | [chain](../validation/phocus-r10-chain.json) |
| 空间接入 | 112 组、1,200,096 个通道，最大 UInt16 差 0；另有 16 组便携颗粒组合检查 | [spatial](../validation/phocus-r10-spatial.json) |
| RAW 与曝光 | 3 个已有哈苏 RAW 的原生 getter；15 组曝光构造／滤镜参数检查，同一工作码输入的颜色核输出一致 | [RAW](../validation/phocus-r10-raw-contract.json)、[exposure](../validation/phocus-r10-exposure.json) |
| 便携回归 | 198 项通过；115 个原始参考文件哈希一致，缺失 FFCS 资源从已锁定原始 ZIP 恢复 | [日志](../validation/phocus-revision10-portable-20261018.txt) |
| Apple 运行 | 真实 Swift／Core Image／Metal，14 组 SDR／HDR HEIF 回读及取消、分享、配方迁移通过；已有 48MP DNG 读取基线 1.5、关闭解码锐化并导出 10-bit PQ | [日志](../validation/phocus-revision10-apple-20261018.txt) |
| Mac 全源导出 | Standard／Nature 各覆盖 24MP、48MP；每组直接导出与预览后导出的编码文件、完整 Float32 解码哈希均一致；服务内存回退及同文件重试通过 | [Standard](../validation/phocus-r10-mac-standard.json)、[Nature](../validation/phocus-r10-mac-nature.json) |
| 内存与边界 | ASan／UBSan 下 96 组比较通过，含非法尺寸、NaN／Inf、取消；未启用 LeakSanitizer | [日志](../validation/phocus-revision10-sanitizer-20261018.txt) |
| iOS 编译 | Release、通用 iOS 目标，`CODE_SIGNING_ALLOWED=NO`，构建成功 | [构建摘要与哈希](../validation/phocus-revision10-20261018.json) |

锐化图像模式覆盖 Standard／Nature、彩色边缘、暗部、亮部噪声、四角、单行／单列以及分块边界。串联检查覆盖八个预设、两种工作空间、曲线开关和多组曝光／CCT／基线。另保存了八组直接由原版生成的[回归向量清单](../validation/phocus-native-chain-goldens.json)与[数值文件](../validation/phocus-native-chain-vectors.npz)，便于不加载 Phocus 时运行持续回归。

## 曝光、白平衡和 HDR 的结论边界

反编译显示 `GetIsoGain` 有机型、数据来源与调试选项分支。在所测三个 RAW 对应的分支，原生结果满足 `65535 / (WhiteLevel - BlackLevel) × 2^(BaselineExposure + BaselineExposureOffset)`，误差为 0。该公式包含 RAW 码值归一化，不能整体再次乘到 Apple 已归一化的 RGB 上，也未据此增加 iPhone 曝光补偿。原厂预设 `EV=1` 是倍率 1，即额外 0 EV。

原版缩小预览有独立的锐化半径补偿，HDR 锐化使用独立工作域系数 `5.8829245141`。当前原版锐化等价声明限于全分辨率、非 HDR 工作码、无局部图层和镜头补偿。应用的源域转换、HDR 幅值分离与恢复由独立运行检查覆盖，不作为 Phocus 完整 RAW／HDR 引擎等价证明。

同一配方不保证不同采样网格上的空间处理逐像素相同：缩小 RAW 诊断预览与全源导出有此区别，最终拍摄回看使用完整导出的 HEIF。Mac 全源检查使用一张保留源图、每种输出一轮，自动处理服务的相机与 Photos 使用测试替身；这些结果不代表 iPhone 的速度、内存或热状态。

颜色数值一致覆盖已测原版工作码、工厂参数及处理阶段，并未穷举所有 RGB16 三元组。没有受控 iPhone／X2D 对拍标定，不宣称所有真实场景色差为零。Apple RAW 内已完成的相机显影仍属于输入适配边界，没有额外拟合矩阵或凭观感修改颜色。

## 复现入口

在 `GlassCamPrototype/` 中使用已安装 `requirements.txt` 依赖的 Python。Apple 与原版调用需要本机 Xcode、原始 Phocus 4.2.2，以及同级 HNCS 参考目录；工具会核验原始库哈希。输出放在仓库外。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DYLD_FRAMEWORK_PATH=/Volumes/Phocus/Phocus.app/Contents/Frameworks
PHOCUS_REFERENCE=../../HNCS
PHOCUS_CHECKS="$(mktemp -d /tmp/glasscam-phocus-r10.XXXXXX)"

python -B tools/decompile_phocus.py --output-dir "$PHOCUS_CHECKS/readable-c"
python -B tools/audit_phocus_sharpness_settings.py --reference-root "$PHOCUS_REFERENCE" --output-dir "$PHOCUS_CHECKS/settings"
python -B tools/audit_phocus_binaries.py --reference-root "$PHOCUS_REFERENCE" --all-presets --seed 20261018 --random-pixels 65536 --output-dir "$PHOCUS_CHECKS/color-audit-a"
python -B tools/audit_phocus_binaries.py --reference-root "$PHOCUS_REFERENCE" --all-presets --seed 123456789 --random-pixels 196608 --output-dir "$PHOCUS_CHECKS/color-audit-b"
python -B tools/verify_phocus_sharpness.py --reference-root "$PHOCUS_REFERENCE" --optimization O3 --seed 20261018 --output-dir "$PHOCUS_CHECKS/sharpness-o3"
python -B tools/verify_phocus_sharpness.py --reference-root "$PHOCUS_REFERENCE" --optimization O0 --seed 987654321 --output-dir "$PHOCUS_CHECKS/sharpness-o0"
python -B tools/audit_phocus_post_stages.py --reference-root "$PHOCUS_REFERENCE" --output-dir "$PHOCUS_CHECKS/post-stages"
python -B tools/verify_phocus_chain.py --reference-root "$PHOCUS_REFERENCE" --output-dir "$PHOCUS_CHECKS/chain"
python -B tools/verify_phocus_spatial_integration.py --reference-root "$PHOCUS_REFERENCE" --seed 314159 --output-dir "$PHOCUS_CHECKS/integration-final"

python tools/materialize_ffcs_reference.py
python -m unittest discover -s tests -v
python -B tools/test_apple_images.py
xcodebuild -project ios/GlassCam.xcodeproj -scheme GlassCam -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$PHOCUS_CHECKS/ios-build" CODE_SIGNING_ALLOWED=NO build
```

`decompile_phocus.py` 生成 18 份真实 C 风格输出，保留复杂 C++ 类型推断警告；[已归档清单](../validation/phocus-r10-readable-c.json)包含工具版本、原始库与输出哈希、实际命令及二进制常量。反编译便于核对规则，数值结论由独立原版调用支持。

已有 RAW 可通过 `tools/test_apple_images.py --raw-source /absolute/path/to/photo.dng` 验证。完整 Mac 双路径检查使用 `tools/run_hncs_study.py --raw-source /absolute/path/to/photo.dng --output-dir /tmp/phocus-mac-standard --label revision10 --rounds 1 --preset standard --working-space lstar --exposure-ev -0.05 --compare-paths --verify-live-capture`，Nature 改预设并使用另一输出目录。所有命令的完整参数以对应工具 `--help` 为准。

[collect_phocus_validation.py](../tools/collect_phocus_validation.py)从本轮完整证据目录校验源码／结果哈希、导出一致性和构建日志后生成统一记录。记录中的 `base_commit` 为这次检查点之前的提交；当前生产文件由 `source_sha256` 锁定，不依赖把新提交哈希写入提交自身。
