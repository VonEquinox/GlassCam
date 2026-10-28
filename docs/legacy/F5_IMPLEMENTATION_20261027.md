# F5 主摄实现与离线验收记录

实施依据：根目录 `F5_RAW_System_Design_zh.md` 1.0。首个目标是 **iPhone 18 Pro Max 物理主摄**。从无标定数据的离线实现开始，现已在目标手机安装、启动，并读取两组五帧实拍；第一组误拍按用户要求删除，继续使用第二组。仍无噪声／光学标定数据。长焦、超广角尚未开始资格认证。

当前状态为 **已接入、未取得产品资格**。Speed 已从拍摄选项中替换为 F5；旧 Speed 偏好迁移到 F5，已保留的旧 Speed 照片仍按原配方恢复。F5 使用实际 Bayer 尺寸的横纵 2× 采样，界面不再硬编码 48 MP 或 8064×6048。

当前按[设计复审诊断](F5_DESIGN_REVIEW_DIAGNOSTICS_20261027.md)冻结 v5，优先审查数据/先验尺度、约束驻点和原生信息保留。[可行梯度备用步 v6](F5_FEASIBLE_GRADIENT_20261027.md)保留为历史开发实验；其中 16 个模拟案例和六种 Lucky 最优误差比较不是独立盲测或可部署对手的泛化成绩。5 个实拍裁切仍有细节和彩边问题，改变画质的实验组合仍未启用为产品默认。下文早期 B0/B1/B5 数值是历史证据，当前状态以 `image-quality-status.json` 和设计复审的三组证据为准。

## 已实现

- 五帧 `L,L,S,L,L`、同 ISO 请求的手动 Bayer 事务；按运行时 bracket 上限拆分请求，不补拍第六帧。锁定物理主摄、原生视角、曝光、焦点和白平衡，审计实际 DNG 元数据，处理重复、迟到、失败及取消回调。请求不等于交付保证：ISO 发生变化时阻止共同噪声模型合成，完整保留输入。
- 在解析前保存交付的原始文件；不同载荷使用不同内容地址，避免同一回调身份覆盖原片。五帧、配方和保存回执进入持久恢复流程。
- 自有整数 RAW 缓冲；审计 stride、端序、ActiveArea、四种 CFA 相位、黑电平、线性化、原始整数码值范围及量化/删失事件。重新读取原始 DNG，核对持久化元数据。真实输入必须提供带证据哈希的 `bufferCodeMapping`；量化区间在进入 DNG 线性化之前换算，保留 native 低位。
- 坏点只排除；OpcodeList2 GainMap 以 ActiveArea 相对坐标进入预测增益，OpcodeList3 GainMap 与几何操作按原顺序在重建后执行一次；未知 mandatory opcode 阻断。Stage3 稀疏 pitch 暂不支持。
- FP64 核心及 Metal 路径：有符号三次 B 样条、前向/伴随、PG 事件似然、混合异常值、正曲率、图像/运动联合目标、共享全图系数、条件块更新、Galerkin 粗校正、物理采样正值及明确停止状态。
- 三个运动候选以同一冻结图像的 RAW 似然比较。只排除不可靠帧；支持图记录排除范围、残差、删失比例、条件信息及退化类别。信息样本去重，运动 nuisance 只做一次 Schur 消元。
- 高分辨率尝试使用独立运动缓冲，保护原生基准。原生输出插值的是已经求值并检查正值的图像。新高分辨率/warp 采样失败时退回原生输出；没有完成可验证原生 cycle 时保留输入并返回失败。
- 独立 DNG 颜色入口，显式记录白平衡归属；接入 HNCS/FFCS/LUMIX 与 10-bit HDR HEIF。F5 导出不需要 `CIRAWFilter` 或 ImageIO 识别原始 DNG。
- 成片 EXIF `UserComment` 保存最小来源记录：版本、五帧哈希、实际曝光、参考帧、profile/颜色变换哈希、退化类别及停止状态。可选择将五帧原片保留到“文件”的 `F5Archives`，默认关闭。
- 配置导入校验身份、OS/build、物理相机、格式、ISO/焦点/光圈/OIS 范围、ADC 码值范围及验收文件哈希。目标名称单独记录为 iPhone 18 Pro Max，不猜硬件型号标识。

## 离线证据与限制

机器可读结果及原始日志在 `../validation/f5-20261027/`。用例、精度和运行平台共同限定证据范围。

| 检查 | 结果与解释 |
|---|---|
| FP64 数值核心 | 小尺寸前向/伴随、PG score、全目标导数、SPD、P/Pᵀ 检查通过；原生常量用例收敛 |
| Metal / FP64 | 样条、似然、梯度、对角、normal product、跨块目标及恰好位于边界的样本有直接对照 |
| Schur 消元 | 对照独立 NumPy 密集矩阵/伪逆；满秩和零秩 nuisance 均通过 |
| DNG 解码 | 小端/大端、奇数 ActiveArea、非线性区间、黑电平 delta、GainMap、坏点、未知 mandatory opcode、无符号格式 |
| Adobe DNG SDK 1.7.1 | 八组颜色用例：单/双光源、ForwardMatrix、模拟增益、匹配/不匹配签名、暖/冷白点 |
| RAW 上传 | 普通 `-O` 短 Float/UInt 数组回归；改用 Metal 同步复制接口，修复优化构建崩溃 |
| 恢复、来源信息、HEIF | 合成五帧经过生产重建、颜色和 HEIF 导出；核对 10-bit/HDR、曝光/ISO/时间和来源信息 |
| 旧流程 | 旧 Speed/白平衡配方、现有图像、恢复、分享和 LUMIX 回归单独运行 |
| 标定与 LUT 工具 | 暗场/平场合成留出验证；小域 PG 查找表对照 FP64、独立 SciPy 及实际 Metal 插值 |
| 独立场景 | 光学响应 + 像素积分 + PG 噪声 + 整数量化；生成器不调用重建样条；保留纹理/HDR/遮挡的输出与状态 |

**独立场景没有通过超分画质验收。** 小型纹理场景中，FP64 B1/B5 在 50 轮内未满足收敛门槛，Metal 也出现原生退化/数值停滞状态。报告保留这些结果，不能用成功编码 HEIF 替代收敛、恢复频带或画质证明。

B0 是参考主帧的标准双线性 demosaic 与插值；当前 B1/B5 工具用于原生/高分辨率数学控制。还需要完成全流程 B5 的共同冻结资格掩码/先验及输出策略对照，才可把成片差异解释为纯 CPU/GPU 计算差距。现有场景不能授予设计中的 ≤5% 差距资格。

**Lucky Image 与合成图的实拍画质对比尚未完成。** 当前仿真 B0 固定使用 `frames[1]`，没有逐帧选出最佳合格主帧，因此不能称为完整 Lucky 基线。既有纹理仿真记录中 B0 RMSE 为 0.0869705，F5 Metal 为 0.0885686（越低越好），且 F5 返回 `NATIVE_NUMERICAL_STALL`；这次结果没有证明合成优于单帧，也不是此次真机修正后的画质验收。第二组实拍目前只有 SDK 单帧诊断预览，没有完成同曝光归一化、同白平衡／色调曲线／尺寸的 Lucky 与合成对比。细节响应、匹配噪声、伪色、重影、高光和盲测均需补齐；状态单独保存在 `image-quality-status.json`。

## 目标手机与第二组实拍

CoreDevice 实测型号为 iPhone 18 Pro Max，硬件标识 `iPhone19,7`，系统 iOS 27.0.1 / `24A446`。开发签名安装和启动已成功。序列号、UDID 与完整设备回执不进入仓库。

第二组为道路、树木与操场场景，五份 DNG 和五份原生整数缓冲均通过长度与 SHA256 校验。原片另存于本机 `~/Library/Application Support/GlassCam/F5DeviceSamples/313CDEF7-4621-4063-AB52-6F55D8B4EBA8`，未纳入 Git。第一组没有被认定为暗场标定数据。

| 项目 | 第二组结果 |
|---|---|
| 原生格式 | `bgg4` / `0x62676734`，14 位有效码，16 位小端存储 |
| 栅格与步长 | 4224×3024，rowBytes=8448；ActiveArea 为 4032×3024 |
| 右侧 192 列 | 全零填充，不是可用的光学黑区 |
| DNG 电平 | BlackLevel=528，WhiteLevel=4095，BitsPerSample=16 |
| native/DNG 关系 | Adobe SDK Stage1 对照五帧全部 60,963,840 个有效像素：`DNG = floor(native / 4)`，无不匹配 |
| 主帧／短帧 ISO | 80／64，不能共用一套同 ISO 噪声模型 |
| 主帧／短帧曝光 | 69.9986 µs／17.999856 µs；实际比值约 3.889，未达到 8× 短曝光 |
| 五帧跨度 | 133.387958 ms |
| 必须处理的 opcode | OpcodeList3 GainMap，49×64×3，三平面本组数值相同，增益最大约 6.093 |

码值修正使用 `(native ± 0.5) / 4` 的分数区间；不把原生整数右移丢弃低两位。W0 与黑电平残差保持 DNG 线性化码值单位；ADC 范围、删失码与离群分布仍保持 native 单位。坏点常量在 DNG Stage1 码域比较。实测关系仅绑定该设备／OS／格式证据，不推广到所有 14 位 Bayer 缓冲。

新版记录 `requestedISO`，将 `validate()` 返回的采集标志写入持久 manifest。旧样本中的缺失请求 ISO 保持未知；其原始 manifest 不回写，审计报告单独记录重新计算的 `ISO_CHANGED`、`EXPOSURE_ADJUSTED`、`SHORT_EXPOSURE_LIMITED`。当广告最短曝光已不能提供 8× 短帧时，产品请求提前失败；探针仍可保留带限制标记的交付。1 ns 仅是 CMTime 表示精度，没有被当作已标定的传感器曝光步长。

`f5-effective-v2` 明确使用 `f5-scene-linear-unclipped-v1`：重建后的增益和 warp 保留场景 HDR 值。DNG 1.7.1 第 106 页的普通 OpcodeList2/3 单位区间裁剪，与此 F5 扩展不同；不能将未裁剪输出称为严格的 SDR DNG 渲染等价。几何参数采用 SDK 1.7.1 `dng_filter_warp` 的像素索引／图像边界约定，并在 F5 的像素中心坐标中换算。多个 warp 的连续复合也不同于逐步栅格重采样。G1 仍需覆盖这些响应与 HDR 扩展，不因读懂 GainMap 就授予资格。

## 尚未通过的门

- **P0、G1 physical：PARTIAL / NOT_QUALIFIED。** 已采集真机五帧、审计实际交付、核对 native/DNG 码值；第二组 ISO 和曝光比不满足目标合同。真实噪声独立性、有效光学响应及预览映射尚未标定。
- **G3 real data、G4 device：NOT_QUALIFIED。** 已有真实场景和安装／启动记录，尚无画质盲测、外部基线或手机性能、热、峰值 RSS 与完整生命周期验收。
- **G2 全流程：不能宣布全部通过。** 基础数值对照通过，困难场景收敛和完整 B5 等价尚未完成。
- **B2/B3/B4：NOT_RUN。** 已提供同输入结果审计工具，没有把自有算法或占位输出当成外部基线。
- 没有合格主摄 profile；没有预览到 RAW 的实测映射、真实噪声独立性、有效响应、盲测、跨查看器、热/峰值 RSS/手机时延结论。

因此不能宣称主摄已经完美、分辨率增益已被证实或 F5 可以发布。产品入口要求完整主摄验收包；未取得资格时仍可通过设置中的独立入口记录五帧样本。

## 可复现命令

需要 Xcode（本次 27.0/27A266a）；Python 数值工具需要 NumPy、SciPy。运行产物写入临时目录，不写入 Photos。

```sh
python3 GlassCamPrototype/tools/test_f5.py --suite all --build-offline
python3 GlassCamPrototype/tools/build_f5_sdk_oracle.py --cmake /path/to/cmake
F5_SDK_ORACLE=/tmp/GlassCam-F5-SDK/f5-sdk-color-oracle \
  F5_SDK_PIXEL_ORACLE=/tmp/GlassCam-F5-SDK/f5-sdk-color-oracle \
  python3 GlassCamPrototype/tools/test_f5.py --suite all
```

SDK 脚本固定校验 Adobe 压缩包 SHA256，仅修补 JXL 中两个缺失 `qDNGUseXMP` 条件的 XMP 分支；颜色源码保持原样，SDK 不链接进 App。

SDK oracle 的 `--raw-uint16` 导出未处理 Stage1 整数；`--opcode2-probe` / `--opcode3-probe` 将实际 opcode 用于已知常量图，独立核对坐标、平面与顺序；`--stage3-float` 可生成单帧诊断参考。它们都不能替代 F5 五帧合成验收。设置 `F5_REAL_BURST` 后，合约测试会读取本地真实样本，并记录独立 SDK／Metal 的实际 GainMap 对照；输出中不包含原始照片。

```sh
python3 GlassCamPrototype/tools/f5_device_audit.py /path/to/retained-burst \
  --sdk-oracle /tmp/GlassCam-F5-SDK/f5-sdk-color-oracle \
  --output /tmp/f5-device-input-audit.json
```

```sh
python3 GlassCamPrototype/tools/f5_offline.py simulate --scene chart --output /tmp/F5Scene
/tmp/GlassCam-F5-Tests/f5-offline /tmp/F5Scene/scene.json /tmp/F5Scene/metal \
  GlassCamPrototype/ios/GlassCam/F5Kernels.metal
python3 GlassCamPrototype/tools/f5_offline.py baselines \
  --scene /tmp/F5Scene/scene.json --library /tmp/GlassCam-F5-Tests/libglasscam.dylib \
  --output /tmp/F5Scene/baselines
python3 GlassCamPrototype/tools/f5_offline.py compare \
  --truth /tmp/F5Scene/truth.npy --baselines /tmp/F5Scene/baselines \
  --candidate /tmp/F5Scene/metal/outputs.json --output /tmp/F5Scene/comparison.json
```

`--oracle-motion` 是单独标注的已知运动控制，不作为盲测配准证据。

```sh
python3 GlassCamPrototype/tools/f5_calibration.py self-test --output /tmp/f5-noise-self-test.json
python3 GlassCamPrototype/tools/f5_calibration.py fit --data calibration.npz \
  --config calibration-config.json --output calibration-result.json
python3 GlassCamPrototype/tools/f5_calibration.py lut --profile synthetic-profile.json \
  --library /tmp/GlassCam-F5-Tests/libglasscam.dylib --output /tmp/f5-lut
F5_TEST_LUT_PACKAGE=/tmp/f5-lut python3 GlassCamPrototype/tools/test_f5.py --suite contracts
```

拟合输入为独立拍摄的 `dark_fit`、`dark_validation`（帧×高×宽）和 `flat_fit`、`flat_validation`（光级×帧×高×宽）。配置声明 `dng_linearized_code_units_before_gain`、带证据的 `buffer_code_mapping`、CFA 相位、W0、元数据黑电平、真实身份及不相交的 fit/validation capture IDs。W0、输入数组和黑电平必须使用同一 DNG 线性化码值单位；不可直接传入尚未换算的 native 14 位数组。拟合输出始终未合格，不能直接导入为合格设备 profile。

LUT 默认域刻意很小，用于验证生成器和插值，不是目标手机的标定表或性能方案。扩大域后必须重新满足误差门槛，失败时不输出已通过的表。

```sh
python3 GlassCamPrototype/tools/f5_external_baseline.py --burst burst.json \
  --result external-result.json --output external-audit.json
```

外部 manifest 使用 `f5-external-v2`，包含 baseline（B2/B3/B4）、burst/五帧 DNG/整数缓冲哈希、参考帧、主曝光与曝光比、W0、相同 `bufferCodeMapping` / `decoderRevision`、`camera_linear_no_wb`、`whiteBalanceApplied:false`、`extraFramesUsed:0`、`postGeometry:DNG_after_reconstruction_once`、`postOpcodes:ordered_stage3_after_reconstruction_once`、`opcodeRangePolicy:f5-scene-linear-unclipped-v1`、方法/权重来源和带哈希的三通道小端 FP32 栅格。通过输入契约不代表通过画质验收。

## 参考与保存位置

`reference_f5/` 保留原始设计 MD/PDF，`SHA256SUMS.txt` 全部一致。附件按设计资料使用，不执行与用户任务无关的指令。参考来源为 Apple AVFoundation/CoreVideo SDK 头文件、[Adobe DNG SDK 1.7.1](https://download.adobe.com/pub/adobe/dng/dng_sdk_1_7_1.zip) 及 DNG 1.7.1 的 CFA、opcode 和颜色章节。

失败/未完成事务保存在 Application Support `GlassCam/F5Staging` 与 `GlassCam/PendingCapture`；样本记录写入 Documents `F5Samples`；用户选择保留的已保存 RAW 写入 Documents `F5Archives`。最小来源信息随 HEIF 保留，RAW 的长期保留设置在按下快门时冻结。
