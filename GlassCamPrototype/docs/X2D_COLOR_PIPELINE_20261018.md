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

## 已发现但尚未完整实现或验证

- 原版 HDR 实际链在 `colorCorrect` 后加入 `HighlightStrength` 和 `gamma`；三个实际区域的六个节点已截取。上述 HDR 颜色核和 film curve 已验证，之后的 HighlightStrength、高光恢复、gamma、空间系数和最终输出仍分开分析。
- 原版 RAW 的校准、噪声处理、去马赛克和场景/镜头校准已获得可调用入口及实际滤镜序列；尚未完成独立算法逐阶段比较或移动端移植。
- 新增有效增益已进入生产 C++ 核；App 的 Apple 输入适配不属于本轮跨相机研究范围，不能把该增益接口当成已经接通 X2D 专用 RAW 解码。
- 同 RAW、同原厂 Standard/Nature 设置及原版 Adobe RGB ICC 已完成上述区域比较，尚未证明全图逐位一致。ICC 从既有 16 位原版 TIFF 提取，摘要为 `304f569a83c1e5eddaddac54e99ed03339333db013738bb499ab64f049887e28`。

## 已知差异与未完成范围

尚不能证明完整 X2D RAW 到成片等价。HDR 独立工作域、最终 ICC/几何一致性、更多曝光/白平衡以及肤色/暗部/高光/高饱和区域，仍需后续原生比较。现有便携颗粒模型保持原范围，本轮不做新的颗粒逆向。当前数据也不能证明 iPhone/哈苏跨相机匹配。

本阶段后续仍须补充必要的 Apple 运行时、设置迁移和 iOS 编译验收；本报告没有新增真机性能、安装或实拍结论。阶段三性能基线必须明确使用已验证的配置和数值域。
