# X2D II 原版 RAW 入口、颜色处理增益与 HDR 审计

2026-10-18，进行中。本报告随完整目标推进更新；目前不能据此宣称 GlassCam 已复现完整 Phocus RAW 到成片。开始状态和尚待验收的三个阶段见 [工作记录](COLOR_PIPELINE_WORK_20261018.md)。

## 已分析且已验证

### 实际机型和原生入口

对原有 `7fbb1471e0cf4b22858cd9a161fb83a8.3fr`，原始文件 SHA-256 为 `9ca1cce4a36fb559fdb500114397d55565cac7be09d5190f547dc73956faf5fd`。TIFF Model 为 X2D II 100C；原版 `CRaw3FRFile`/`sRawDescription` 返回 CCD 22、IR filter 6、back model 71、body model 99。原版 `CXMLLut` 构造器和延迟缓存将 `0x616` 解析到自身 `Colormaps/bohnjuhtuvuvtxyydb56.dat`。较早外部解码 plist 的摘要为 `c2b3d08e0d489eb852610c12a9b985e9d0340a4dd544f5b0b5b7a6a4f3427e95`；当前探针使用原生资源加载，不注入 GlassCam 矩阵。原生资源与旧 plist 的 incoming 矩阵零差，不能据此单独证明所有 LUT／曲线资产等价。

原生 getter 确认黑电平 4096、白电平 64763、ISO 码值增益 1.0653693159208844、SensitivityGain/AnalogGain 均为 1。`AsShotNeutral` 的原生增益规则是 `max(neutral)/neutral[channel]`，本例为 `[3.06964111328125, 1, 1.41644287109375]`，逐值一致。RAW 的非单位中性校准码为 `[16384,16570,16649]`，以 16384 为基准；它与捕获白平衡是不同的输入。

[身份探针](../tools/audit_x2d_identity.py)只接受观测到的 `X2D II 100C`／`Hasselblad X2D II 100C` 两种 Model 文本，并核验 CCD、back model 和 IR 分支。[原始结果](/Users/vonequinox/.codex/visualizations/2026/10/17/01a14afa-ebe0-7180-be23-7f59ec9cef36/color-research-20261018/x2d/identity-main/report.json)记录配置和四个原版框架摘要。其余两个原始 RAW 的独立身份检查也已通过；三张图均为相同机型分支、黑电平 4096、BaselineSharpness 1.5，白电平分别为 64763／64759／64757。ISO 200 的 `GetAnalogGain()` 为 4，而实际 `sRawDescription.analog_gain` 为 1，不能把 getter 值再乘到已归一化入口。

### 同一 RAW 的原版中间结果

[原生流水线探针](../tools/probe_x2d_native_pipeline.py)及[C++ ABI 适配器](../tools/native_x2d_pipeline_bridge.cpp)调用原版 `CSaveHandler::FromCorrection`、`ProcessCropGeneral`、`ProcessCropSpecific` 和 `OutputImage`。构造原版缓存、配方、滤镜对象，读取实际链中的指定节点。保留 `--parameter-builder viewer` 用于重现早期诊断；默认使用完整导出工厂。原始 RAW 只读打开，调用前后校验摘要；失败和超时保存为缺口，不作为通过。

实际 Standard 普通工作域的链包含：

```text
rawprovider → RepeatMargin → neutralisationBayer → Orientation
→ HotPix → NoiseReductionBayer → NoiseReductionBayerP2
→ BayerFastInterpolate → highlightsimple → Multi2Bayer → Aberration → demosaic
→ dust → ev → SceneCalibration → RGBLens → ev_1 → RGBLensD
→ colorCorrect → gradation → sharpness → resize → icc
```

这是对本例原生选路的观测，**不表示以上每个 RAW 算法均已独立移植**。原版还会根据文件、镜头、配方和 HDR 选择其他分支。

### 已修复：普通颜色核遗漏有效处理增益

此前大量核对的原生构造器使用单位增益。原版 `CRawColorCorrection::CalculateDesatValues`（HBRawCorrections arm64 `0x15304`）实际上使用颜色滤镜的有效处理增益 `g`：

```cpp
t = 15500.0 / g;
a = -0.123 / (t * t);
b = (t * a) * -2.0;
d = (t * t) * a + 1.0;
weight = Y <= t ? (a * Y) * Y + b * Y + d : 1.0;
```

本例真正进入颜色对象的 `g=4.643602306524954`，阈值为 `3337.925812083474`。该值包含原版上游处理的尺度，不能拿 RAW `GetIsoGain` 或用户 EV 单独替代，也不能再乘一遍 RGB。

共享生产[颜色核](../core/hncs.cpp)现保存可配置阈值并保留原生乘法顺序。[新增不可变上下文 API](../core/hncs_c.h) `hncs_clone_with_native_gain` 可与现有原生颜色、预设和后续流水线接口合用，保留配方及输出空间。原有构造器继续遵守其单位增益输入约定。此修改没有将 X2D RAW 校准套入 Apple 解码的 RGB，也没有新增拟合矩阵。

| 对比 | 范围 | 结果 |
|---|---|---|
| 原版 CPU 对当前颜色核 | 60 组：两种工作空间、Standard/Reproduction、三个 CCT、五种处理增益；14,155,380 通道 | 最大 UInt16 差 0 |
| 原版 RAW 中间输入到完整 CPU 颜色滤镜 | 同一 64×64 区域，12,288 通道；早期查看器诊断参数 | 修正前最大 68、11,150 通道不同；修正后全为 0 |
| 完整原版导出参数的 CPU 颜色滤镜 | 同一保存 RAW、Standard、64×64 区域；实际 SceneCalibration 强度 100 | 修正前最大 74、11,333 通道不同；修正后 12,288 通道全为 0 |
| 旧版与新版默认单位增益 | 12 组同输入 | 逐位一致 |
| 冻结原生向量与既有完整链回归 | 四项 unittest，含原生颜色/曲线/锐化/后置颜色、非法增益和上下文生命周期 | 通过 |

数值依据：[完整比较](../validation/x2d-native-gain-20261018.json)、[原生黄金清单](../validation/x2d-native-gain-goldens.json)、[测试](../tests/test_x2d_native_gain.py)。[复现工具](../tools/verify_x2d_color_gain.py)直接调用哈希锁定的原版函数；冻结预期值来自原版。真实 RAW 像素与大产物保留在仓库外，仓库只保存小型合成数值向量。

### CPU 与自动 GPU 必须分别记录

原版 `CImageFilter::OutputImage`（`0x4ba28`）在传入空 GPU cache 时仍会自动创建缓存并启用 GPU。因此“空 cache”不是 CPU 选择。`CGpuPipelineManager::IsGpuEnabled`（`0xe1d88`）检查原版 `disableGPU` 调试键；探针在自己的进程中设置该键，并检查返回值为 false，不保存用户偏好。

初期自动后端的中间截取出现最大 70 码差，增益修正后还余 8 码；这些截取会在 GPU 工作值与整数中间文件之间增加转换，不能作为严格 CPU 同输入比较。上述 68→0 采用明确 CPU 后端重新获取的输入和输出。自动后端的原始结果保留，不通过修改预期值消去差异。仍需单独量化完整 GPU/CPU 链的差异及最终色差。

### 原版导出参数与历史 TIFF

零初始化后只调用 `UpdateProcessParams` 不能复现导出默认值。原版 `CSaveHandler::FromCorrection`（HBImageProcessing `0x8e91c`）读取 `.phos` 中的 `ImageCorrection`、`ImageDescription` 和 `OutputPreset`，返回原生 `sProcessParams`（0x1c0 字节，随后是 optional 有效标志）。实际场景校准强度由 0 变为 100。

保存的日光 RAW 与原始 RAW 的整个文件摘要不同，但压缩 RAW payload 相同，SHA-256 为 `d62bae1bc5154db7fe2d19300086ce694f94abd8af1da19e60f06ef985e19386`。使用该保存 RAW、原版 Standard 侧车和 TIFF 中提取的原始 Adobe RGB ICC，在原版自动后端重算 `(2000,2000,64,64)`：对历史 TIFF 最大差 **3/65535**，平均绝对差 **0.0423990885**，439/12,288 通道不同；此前错误参数构造为最大 794 码。实际处理增益为 4.643616364582644。

该结果只验证原版调用与保留导出在这个区域接近，不证明逐位一致，也不证明 GlassCam 全链一致。原生裁切坐标已对应 TIFF 坐标；手工添加 RAW margin 的探索使误差增大，没有采用。原始探针输出保存在 [auto-adobe-export-params](/Users/vonequinox/.codex/visualizations/2026/10/17/01a14afa-ebe0-7180-be23-7f59ec9cef36/color-research-20261018/x2d/auto-adobe-export-params/invocation.json)。

完整导出参数下的 CPU 核前／核后原生截取已经补测，增益修复同样达到零差；[比较工具](../tools/compare_x2d_crops.py)将生产颜色核比较与两次原版执行的 TIFF 比较分别记录。[首轮机器结果](../validation/x2d-export-first-20261018.json)保留修复前最大 74 码、修复后零差，以及独立的历史 TIFF 最大 3 码残差。

### 扩大的导出和颜色核检查

[批量采集工具](../tools/run_x2d_export_audit.py)完成 126 次原版调用，全部成功。30 组普通颜色核同输入比较涵盖 Standard／Nature、两张保存 RAW 与独立 ISO 200 RAW、±2 EV、2850／10000 K，以及色卡黑白、红蓝和两种印刷肤色区域。修复前最大 1172 码；修复后 **368,640 通道零差**。这是原版准备好的输入，不是独立 RAW 解码验证。

另外 24 个区域分别用原版 CPU 和自动后端重算最终 Adobe RGB 输出。自动后端相对历史 TIFF 的平均绝对差为 0.0152656 码、最大 50 码；CPU 为平均 47.0039 码、最大 1289 码。扩大样本后，最大差已经超过首个区域的 3 码，不能继续用首个区域代表全图。原版 CPU/GPU 的前处理及数值边界差异仍需逐节点定位。

探针现使用原始 RAW 的 `GetRawDescription`（`0x4f344`）取得原版共享描述；`GetCachedRawDescription` 只读取已有缓存，在未初始化时会返回空。先前构造描述与共享描述的所测字段相同，同一区域最终输出逐位相同，因而这项改动没有解释 TIFF 的剩余差异。失败的初次缓存调用和批量尝试保留在仓库外。

依据：[完整比较](../validation/x2d-export-matrix-20261018.json)。色卡位置复用既有几何，仅用于取样，不使用其跨相机拟合矩阵；印刷肤色不是实测真人肤色。

### 已还原并接入：原版 HDR 颜色核的 film curve

原版 HDR 曲线从普通 Standard film table 构造：先以原版 ICC 指数 `2.19921875f` 得到线性 Float32 表，按处理增益重新索引，在原始高光区计算切线和二次延伸，并在 `65535/gain` 之后接线性延伸。最后除以 Float32 `10000/203` 再乘 `65535`。线性延伸的截距和逐点计算使用原版的 double FMA；不能把它改成普通乘加，或把二次曲线无限延伸。

[独立实现](../core/hncs_phocus_hdr.hpp)与原版 `GradationApplyGain`、`GradationApplyHighlight`、`GetGradationCurveHDR` 分别比较。40 组增益、**7,864,320 个 Float32 表项逐位一致**；两种工作原色、三个 CCT、十种增益的 **60 组／14,155,380 个颜色通道零差**。另三个真实 HDR 区域涵盖 +2 EV 白色、Nature 红色和弱光黑色，36,864 通道零差。初版遗漏白点后的线性延伸，差异保留在外部诊断记录，未更改原版预期值。

新增共享生产 API `hncs_render_x2d_hdr_color`，支持普通颜色模型、Standard film curve 和处理增益 `[0.25,32]`，显式拒绝超范围、非有限值及不支持的模型。输入必须是准备好的 X2D 原生 HDR 数据；输出是该颜色阶段的线性 HDR 工作码，不能按 SDR ICC 曲线解码。API 不会额外施加一次曝光，也不改变 App 的 Apple 输入策略。

[数值报告](../validation/x2d-hdr-20261018.json)、[原版回归向量](../validation/x2d-hdr-goldens.json)、[复现探针](../tools/verify_x2d_hdr.py)和[无原版依赖的回归](../tests/test_x2d_hdr.py)已保存。HDR、增益与既有普通完整链合计六项 unittest 通过。

### 已还原并接入：HDR 高光、gamma、gradation 与锐化

新增 [HDR 后置实现](../core/hncs_phocus_hdr_post.hpp)与 `hncs_render_x2d_hdr_post`，按原版顺序执行 HighlightStrength 和 gamma。实际三个 RAW 配方均使用高光强度／去饱和参数 50／50，gamma 选择 legacy；原生数值验证还覆盖 L*。原探针里的 `gamma_inverse` 已更名为 `gamma_lstar`，因为该位选择 L* 或 legacy，并不表示逆 gamma。

原版高光权重为 `fma(amount*4.5e-5, amount, amount*.01)`；分段二次曲线保留原版 double FMA。HSL 的中间值和亮度混合使用 Float32，饱和度混合保留 double FMA。输出先 `FRINTA`（半值远离零取整），再限幅与转整数。初版直接截断产生大量 1 码误差，随后遗漏 Float32／FMA 边界仍有少量 1 码误差；两轮失败的源码、输出和报告均保留，未改变原版预期值。

gamma 将 HDR 工作码先除以 65535、乘 `49.26108374384236`，执行原版 legacy 幂函数或 L*，再除以 `5.8829245141` 并编码。该流程不能使用普通 SDR 的显示解码函数代替。

串联检查另外发现 **HDR 不能复用 SDR gradation 表**。原版 `CalculateCurve(CCurve*, bool)`（`0x12d5a0`）在 HDR／ExpToolVersion 4 下使用 `5.8829245141` 的曲线工作范围。复用 SDR 表时，Nature 真实区域的 gradation 最大差为 2118 码，锐化后为 2240 码。

[生成工具](../tools/audit_x2d_hdr_gradation.py)从哈希锁定的原版构造器取得 Standard／Nature 的五路完整 UInt16 表，去重为[三张精确表](../core/hncs_x2d_hdr_gradation.inc)，共 393,216 字节数值数据。它们是原版有限数值域的精确结果，不是重新采样的近似，也不是独立重写任意用户曲线的解析器。实际侧车的三组 HDR 表与对应原厂 HDR 表全部一致。新增 `hncs_apply_x2d_hdr_gradation` 保留已验证的 RecoverHue 和逐步取整，只支持已列的现代 HDR 原厂配置；既有 SDR 表和 API 保留。

原版 HDR 锐化把工作域系数先转 Float32，再用于 amount／noise 表的索引数值；它不会再次乘到像素曝光。新增 `hncs_render_x2d_hdr_sharpness` 使用 Standard／Nature 原厂控制、每张 RAW 的 BaselineSharpness、全分辨率像素尺度和复制边缘。实际 RAW 的 Standard／Nature 有效 amount 为 270／334，半径为 1／0.8，noise 0、dark 10，HDR 系数均为 `5.8829245141`。普通锐化继续使用系数 1。

| 对照 | 已验证范围 | 结果 |
|---|---|---|
| HighlightStrength／gamma／二者串联 | 33 组合成输入，含全部 65536 中性码、17³ 网格、随机 RGB、16 组非整数控制；另 9 个真实阶段对照 | 合计 8,707,059 通道，最大差 0 |
| HDR gradation | 两种原厂配置，全部中性码、网格和随机输入；原版 RecoverHue 开启 | 471,846 通道，最大差 0；原版关闭该位的结果另存 |
| HDR 锐化 | 293 组参数、46 组图像模式 | 9,601,024 表项及 1,668,417 像素通道，全部一致 |
| 真实 HDR 串联 | 三个原始 HDR 区域：颜色核 → 高光 → gamma → gradation → 锐化 | 前三边界每区 12,288 通道零差；最终锐化内部区域合计 28,224 通道零差 |

真实区域未保存框外邻域，因此最终锐化比较明确排除四像素边界，不能把这个结果表述成完整 64×64 或全图的零差。独立的合成图像验证由原版 `CRepeatMarginFilter` 提供复制边缘，覆盖单像素、单行／列和不规则尺寸。

依据：[后置阶段](../validation/x2d-hdr-post-20261018.json)、[曲线来源](../validation/x2d-hdr-gradation-20261018.json)、[HDR 锐化](../validation/x2d-hdr-sharpness-20261018.json)、[真实串联](../validation/x2d-hdr-chain-20261018.json)。[回归](../tests/test_x2d_hdr_post.py)读取冻结的原版向量，检查各阶段、组合 API、原地处理、参数边界与内存重叠；没有把当前实现输出写成预期值。

### 输出 ICC 的明确边界

三组真实 HDR 配方已补取原版最终 Adobe RGB 输出；原版选择的输入配置是 **Hasselblad HDR RGB，special profile enum 8**，并经 `AddOutputFiltersExport` 加入 ICC 滤镜。[原生参数与输出记录](../validation/x2d-hdr-output-20261018.json)保存 50／50 高光、gamma 类型、实际锐化参数、源文件和输出 ICC 哈希。

这验证了 HDR 工作码应交给独立 HDR 配置处理，不能交给 SDR 显示解码；最终原版 ICC 已可调用，但没有独立移植该 ICC／HDR limit 的全部行为，也没有历史 HDR 成片作为全图 oracle。此处的原版最终输出不冒充 GlassCam 独立 RAW 到成片一致。现有 Swift 的 Apple HDR 幅值分离／恢复仍遵守其既有输入契约，没有凭这次分析删除 sRGB 接口的限幅。

## 已发现但尚未完整实现或验证

- 上述默认 HDR 颜色、高光强度、gamma、原厂 gradation 和全分辨率锐化已验证。非零 RAW 高光重建、任意自定义曲线／局部图层、缩小预览的半径补偿及完整 HDR limit／ICC 行为不在这些等价声明内。三个保存配方的 HighlightRecovery／HighlightRecoveryHDR 均为 0；上游仍有原版 `highlightsimple`，没有将它误记为独立移植。
- 原版 RAW 的校准、噪声处理、去马赛克和场景/镜头校准已获得可调用入口及实际滤镜序列；尚未完成独立算法逐阶段比较或移动端移植。
- 新增有效增益已进入生产 C++ 核；App 的 Apple 输入适配不属于本轮跨相机研究范围，不能把该增益接口当成已经接通 X2D 专用 RAW 解码。
- 同 RAW、同原厂 Standard/Nature 设置及原版 Adobe RGB ICC 已完成上述区域比较，尚未证明全图逐位一致。ICC 从既有 16 位原版 TIFF 提取，摘要为 `304f569a83c1e5eddaddac54e99ed03339333db013738bb499ab64f049887e28`。

## 已知差异与未完成范围

尚不能证明完整 X2D RAW 到成片等价。已建立上述有限配置的 HDR 工作域与阶段接口；RAW 前处理的独立移植、最终 ICC/几何一致性、完整图像和更多真实 HDR 肤色／白平衡／曝光组合仍有缺口。现有便携颗粒模型保持原范围，本轮不做新的颗粒逆向。当前数据也不能证明 iPhone/哈苏跨相机匹配。

本轮 206 项 Python 回归、实际 Apple 预览／14 组 SDR/HDR HEIF／真实 48MP DNG／设置迁移检查、ASan/UBSan 及 iOS Release 通用目标编译已通过。未执行手机安装或实测。新 X2D 接口明确要求原生准备输入，不改变 App 的 Apple 源域策略；性能数据另见[受控加速报告](COLOR_PERFORMANCE_20261018.md)。
