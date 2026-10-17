# RAW 输入统一与成片对照

2026-10-17，`codex/single-camera-hard-black`。完成颜色计划第一轮：读取本机内嵌配置、统一 RAW 解码入口、生成同源对照并在 iPhone 上验证。当前默认显影的输出保持一致；候选配方尚未成为相机默认设置。本轮没有宣称完成 iPhone 与哈苏的色彩匹配。

后续已取得用户导出的 16 位 Adobe RGB Phocus 参考，并按用户要求转向[直接二进制核查](HNCS_BINARY_AUDIT_20261017.md)。该核查修正了无调整 gradation 旁路并升级至 render revision 9；本页“输出保持一致”和手机数字对应此前的输入实验构建。候选 RAW 显影仍未成为默认设置。

## 材料与可复现产物

使用此前保留的同一张 48MP ProRAW，`UniqueCameraModel = iPhone19,7 back camera`，SHA-256 为 `4bd1990df9893381b89797d1e761925973c0c840c3cd47dce758635c7502929e`。图中为室内高反差场景，没有实测色卡或同场景哈苏参考片。

完整图片、原始 DNG、15 张真机 HEIF、交互查看页和数值报告保存在聊天的 `raw-input-study` 可视化目录，未放入源码仓库。仓库保留[数值及验证证据](../validation/raw-input-study-20261017.json)和[Apple 图像回归日志](../validation/raw-input-apple-tests-20261017.txt)。图片来自 iPhone 全源处理后的 4242×5656、10-bit PQ HEIF；对照图使用同一 max-channel Reinhard → sRGB 变换，是 SDR 诊断视图。

## 本机内嵌配置

`tools/inspect_proraw_profile.py` 按 TIFF/IFD 和 Adobe DNG 1.7.1 定义提取数据，保留矩阵的原始有理数分子/分母；完整曲线和局部表写入指定结果目录。

- 两张 3×3 ColorMatrix，分别对应标准光源 A（17）与 D65（21）。它们表征此 DNG 的参考相机空间；不能再次直接乘到 CIRAWFilter 已转换的 sRGB 上。
- `ProfileToneCurve` 共 257 点。
- `ProfileGainTableMap` 为大端数据，12×16 个位置，每格 257 个 Float32 增益。表中增益范围约 0.1189–7.8028，实际取值取决于位置和输入；不是全图统一乘这个范围。
- DNG 规范要求该局部表在 BaselineExposure 之后的 RIMM 域使用。它不是 sRGB 纠色 LUT。
- `AsShotNeutral` 为 `[1,1,1]`，`AnalogBalance` 约为 `[2.5781,1,1.9485]`；Apple 解码器仍给出约 5119K、Tint +21.4、xy=(0.342874, 0.364168)。不能只看 AsShotNeutral 就判断光源或白平衡是否已处理。

第三方 Tony Kuyper 仓库的 `19,7 back camera` 条目已核验，DCP 本体尚未取得。本轮以原始 ProRAW 的 Apple Embedded Color Profile 为依据；没有提交领取文件所需的邮箱/条款流程。

## 统一解码入口

新增不可变 `RAWDecodeRecipe`，由 `ImagePipeline.configureRAW` 统一配置缩小解码、自动导出的元数据绑定和完整源解码。选定的 decoder version 随 ImportedImage 保留，预览后导出复用该配方；直接导出在读取白点后复用已选版本。不可用的 decoder version 被拒绝。

本张 RAW 实际选择 `8.dng`，支持列表也包含 `9.dng`；未切换到 RAW 9。相同捕获白点贯穿对照，HNCS 仍使用原算法与参数。额外曝光补偿为在线性工作空间施加的一个标量，不是自动白平衡或逐通道纠色。

| 配方 | BaselineExposure | boost / local tone | gamut mapping | EDR | 额外线性曝光 |
|---|---:|---|---|---:|---:|
| current | 源默认约 3.1118 | 源默认 1 / 1 | 开 | 1 | 0 EV |
| scene | 0 | 0 / 0 | 关 | 0 | 0 EV |
| scene-baseline | 0 | 0 / 0 | 关 | 0 | +3.1118 EV |
| scene-hdr-baseline | 0 | 0 / 0 | 关 | 1 | +3.1118 EV |
| scene-hdr-aligned | 0 | 0 / 0 | 关 | 1 | +4.7031 EV（本张 iPhone 输入） |

去默认显影模式另将 shadowBias 设为 0；boostShadowAmount 保持原值，因为 boostAmount=0 时该参数无效。EDR 作为单独实验变量，不能因“去默认 look”就认为它不影响像素。曝光补偿值直接取 RAW 元数据，不是对中灰的物理标定。

`scene-hdr-aligned` 另外提供只调整整体曝光的诊断：在无 HNCS 的 2048px 输入上，筛选两侧所有通道都在 (0,1)、当前配方亮度 Y 在 [0.02,0.5]、候选 Y≥0.002 的像素，取 `log2(Y_current / Y_candidate)` 的中位数。iPhone 共 1,952,797 个像素，得到额外 +1.5913267 EV；这个标量在 HNCS 之前应用，并固定用于三个效果。它只对齐本张 RAW 的软件中间调，不是逐通道纠色、曲线拟合、物理曝光标定或自动拍照策略。

曝光对齐以当前 Apple 输出作为诊断基准，目的是减少亮度差异对颜色观察的干扰；最终风格目标仍需要由原版 Phocus 参考确定。该实验没有把“提亮暗部”定义成哈苏特征，也没有新增暗部专用提亮算法。

每个配方分别导出无 HNCS、Standard、Nature，共 15 个结果。所有 HNCS 结果使用 L*RGB、EV −0.05、原 Standard/As Shot film curve、原预设空间处理；完整 48MP 处理完成后才缩小到 24MP。无 HNCS 路径也从完整源解码，使用相同输出空间和相同 EV，仅绕过效果核。

## 观察结果

以下是 iPhone 最终 HEIF 回读到 2048px 长边的诊断图的平均线性亮度，用于描述变化，不是全分辨率统计、色差或感知亮度评分：

| 配方 | 无 HNCS | Standard | Nature |
|---|---:|---:|---:|
| current | 0.33249 | 0.40135 | 0.42110 |
| scene | 0.02029 | 0.02066 | 0.01969 |
| scene-baseline | 0.17564 | 0.19581 | 0.19639 |
| scene-hdr-baseline | 0.23794 | 0.25960 | 0.26053 |
| scene-hdr-aligned | 0.68006 | 0.74875 | 0.76373 |

1. 单纯归零会大幅改变曝光尺度。即使补偿 +3.1118 EV 并保留 EDR，候选的室内暗部仍明显比当前配方暗，不能认定它自动更接近哈苏。Apple 默认局部提亮与全局曝光不是同一件事。
2. 去默认显影、EDR=0 的解码，在输入通道值 0.001–0.4 的样本上，−1/+1 EV 分别精确得到 0.5/2 倍。iPhone 覆盖 7,140,945 个通道，最大绝对误差为 0。这个有限区间的软件响应检查不证明完整动态范围或真实拍摄的绝对辐射线性。
3. EDR=0 与 1 在去默认显影后仍有差别。iPhone 的缩小输入最大通道从 1 变为约 1.75，平均线性亮度从约 0.02162 变为 0.02716；部分变化也落在原值小于 0.9 的通道。这些值不单独证明裁剪位置，说明 EDR 必须单独控制与验证。
4. 在五种配方的 2048px 输入样本上，按生产高光归一化、EV 和虚拟矩阵计算，Standard/Nature 的虚拟 native RGB 越界比例均为 0。没有在这张图上发现矩阵输入越界造成的大范围裁剪；该结论不是全分辨率、全部场景或色彩准确性的证明。
5. Standard 与 Nature 始终输出不同文件和观感。候选仍需解决曝光/曲线的目标定义，再对照原版 Phocus；本轮没有引入经验纠色矩阵或新的风格 LUT。
6. 中间调对齐的额外系数通过独立 NumPy 计算复核，与 Swift 结果一致；应用后原筛选像素的中位亮度差为约 −4.6×10⁻⁸ EV。单像素原本需要的额外补偿第 10/90 百分位仍相差约 0.81 EV（1.1790/1.9900 EV），所以一个标量无法同时复原局部明暗关系。对齐后无 HNCS 的回读平均亮度约为当前配方的 2.05 倍；六路图中高光和暗部关系仍不同，不能把中间调接近当成整幅颜色或哈苏风格已匹配。

## 验证

- Mac 和 iPhone 各生成 15 个 24MP HDR 成片；每个平台 10 组 HNCS 配方的直接导出与预览后导出文件逐字节一致。
- 本次入口整理前后，Mac 的 Standard/Nature、24/48MP 四组文件及完整 Float32 解码摘要一致。iPhone 当前配方的 Standard/Nature 24MP 文件也与此前真机报告一致。
- 从手机取回的 15 个 HEIF SHA-256 均与手机报告一致。
- 65 项相关便携检查通过；Apple 图像回归通过，包含 14 组 SDR/HDR 导出、白平衡、保存重试、真实 48MP RAW 等检查。
- 正式 App 的 iPhone Release 构建、签名验证、安装、启动及进程检查通过；拍摄设置按解析后的值保留，临时诊断 App 已移除。
- 交互页面通过独立 Chrome 检查：五种配方、三个效果的图片加载与 HEIF 链接、滑块位置均正常；只传入一个配方时也不会引用不存在的六路图。报告工具检查平台、解码版本、白点、RAW 配置及成片摘要的一致性。
- 原始报告保留各自的源码摘要。输入轮次之后诊断工具增加了 EDR 分析和中间调对齐；所有正式流水线源码仍与这些轮次的摘要一致。
- C++ 颜色核和空间核在本轮未改动。候选相对旧图的差异是显影配方变化，不能计为“提速误差”；原有颜色数值合同继续适用。

## 复现

从 `GlassCamPrototype/` 运行。检查器只需 Python 3.11+；绘图工具需要 NumPy、Pillow、Matplotlib。Apple 处理需要本机 Xcode、Core Image 和 Metal。

```sh
python3 -B tools/inspect_proraw_profile.py /absolute/path/source.dng --output-dir /tmp/raw-input/profile

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B tools/run_hncs_study.py \
  --raw-source /absolute/path/source.dng --output-dir /tmp/raw-input/study \
  --label input --input-study --exposure-ev -0.05

python3 -B tools/report_raw_input_study.py /tmp/raw-input/study/input \
  --profile-dir /tmp/raw-input/profile --output-dir /absolute/path/output
```

`--input-study` 固定检查 L*RGB 下的无 HNCS/Standard/Nature 与 24MP 全源导出；普通性能模式的预设、工作空间、轮数选择不用于该模式。`--input-variants` 可选择补充实验，报告工具可接收多个结果目录。

默认生成前四种配方。需要中间调对齐时，另运行 `--input-variants scene-hdr-aligned --label aligned`，将其结果目录作为绘图命令的第二个位置参数传入；也可在一次运行中显式列出全部五种配方。不同平台的数据分别生成报告。

加 `--run-ios DEVICE_UDID --team TEAM_ID` 可运行同样的 iPhone 诊断，完成报告按 run_id 收集。手机的图片与浮点数据在诊断 App 的 `Documents/<label>/`，绘图前用 devicectl 取回整个目录。工具不拍照、不写入 Photos；原始照片和派生图片应保存在源码仓库外。

下一轮应使用已有哈苏 RAW 建立固定 Phocus 参考，确定统一曝光和曲线目标，再决定是否推广候选配方。已定位到本地 HNCS 目录中的 `Phocus_4.2.2_Mac.dmg`；当前尚未进行该轮参考导出。本轮结果不足以支持直接替换相机默认外观。
