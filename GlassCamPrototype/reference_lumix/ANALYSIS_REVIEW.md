# `SILKYPIX_DS8SE_松下RAW处理管线_逆向分析.md` 审查与修订记录

审查基准：

```text
SILKYPIX8: 32,343,344 B
SHA-256:   63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b
```

使用 radare2/r2ghidra 对 `IslVEConnectISFilter::Connect`、`Modify2`、CMS 输出滤镜、3D LUT 滤镜和 VEParam 读取函数做了定点复核；结论已合入主报告。

## 结论

这份报告适合作为“模块、符号、资源和候选处理阶段”的逆向索引，但还不能声称已经把从 RW2 RAW 到最终图片的所有色彩变化完整分析完。报告自己列出的 B/C 未决项已经足以否定“像素级全链路已闭合”的说法；另外，VE 的 3D LUT 分支在报告的总图和一句话总结中被表达成了必经的串行阶段，这是一个需要修正的流程错误。

## 已修正或仍需补证的问题

### 1. `IslEISPanaRemoveBlack` 被误判为黑电平减法

报告 §6.3 和 §12.2 把 `IslEISPanaRemoveBlack` 解释成“去黑电平 pass”，证据只有类名和模板基类。这一结论与其像素函数的实际代码不符。`work/ev/review_20261023/R12_PanaRemoveBlack_DemosaicLine_pdg.c` 显示：它复制输入样本，遇到 0 值时调用 `CorrectPixel`；`R16_CorrectPixel_pdg.c` 的算法是对非零邻域做平均/距离加权插值。`StartDemosaic` 只是把两个边界设为 4，`EndDemosaic` 直接返回 0（见 `R15_PanaRemoveBlack_Start_pdg.c`、`R17_PanaRemoveBlack_End_pdg.c`）。代码中没有对 `OpticalBlackR/G/B` 做减法，也没有建立黑电平 LUT。

所以该类至少应标成“零值/坏点邻域修复，确切触发语义待证”，不能据此证明松下黑电平已经在这里完成。真正的黑电平算术仍应追 `IslEISDevelopOBSubtracter::MakeUpLUT`/`FilteringLine` 和 RAW 解码阶段。

另外，报告 §12.3 对 `CalcCorrectionLUT` 的“R/G/B 独立偏移与斜率 + 饱和点”只是签名推测。补充反编译在 `R23_OB_CalcCorrectionLUT_pdg.c` 中已经看到 `IslZMath::NormalDistribution`、向量/矩阵构造和 `Make_LUT`，所以这段推测应删除或降为“未知”；它不能作为黑电平公式的说明。

### 2. VE 3D LUT 不是 ToneCurve 到 MixYC 之后的必经步骤

报告 §9.4、§15 和 §19 把 VE 写成：

```text
ToneCurve → 2x3 → 12/16Axis → 4AxisLuminance → MixYC → 3DLUT
```

在 `work/ev/review_20261023/R1_VEConnect_pdg.c` 中，`Connect` 先计算 `min(Parameters+0x3b0, Parameters+0x3c4)`：

- 小于 1 时进入 ToneCurve、2x3、12Axis 或 16Axis、4AxisLuminance、MixYC 的建链路径；
- 大于等于 1 时直接进入 `IslVEISFilter3DLUT::SetRegs` 和 3DLUT 建链路径。

因此，同一次 `Connect` 调用中，3DLUT 路径会绕过前面那组 VE 滤镜。报告 §9.3 的“独立分支”描述接近事实，但 §9.4 的阶段列表、§15 的箭头和 §19 的一句话总结又把它写成串行，前后矛盾。应明确画成条件分支，而不是一条连续管线。

### 3. `Modify2` 中的通用色彩节点没有完整进入阶段清单

报告 §10.2 统计了 41 个装配函数/127 次调用，但 `Modify2` 还有直接构造和接入的条件节点，不能只按 `Connect*`/`ModifyIS*` 名称统计。`work/ev/review_20261023/R11_Modify2_color_setup_asm.txt` 显示：

```text
0x6f1f66  IslEISFilter3DCM::IslEISFilter3DCM
0x6f20e5  IslEISFilter3DCM::SetMatrix
0x6f210e  IslEISFilter3DCM::Set3DMapping
0x6f2160  IslEISFilter3DCM::SetColorLimit
0x6f2177  IslEISFilter3DCM::SetMustTransform
0x6f21a4  IslEISFilter3DCM::SetTransformMode
```

同一函数的调用序列还出现 `IslEISFilterLAB`、`IslEISFilterLABTransform`、`IslEISFilterUCS`、`IslEISFilterUCS2`、`IslEISFilterGrayAxis` 和 `IslZColorProfile`。`R28_3DCM_FilteringLine_pdg.c` 进一步显示 3DCM 的逐像素代码会做通道增益、3×3 矩阵乘法、色相保护/裁剪，并可调用 `IslZColor3DMapping::TransForm`。原报告只在 §9.6 顺带提到通用 `IslEISFilter3DCM`，没有把这些条件分支的输入、输出和接入位置纳入全流程图。因此对 Panasonic 路径能否触发、与 VE 的相对先后、以及它们是否改变 RGB 数值，仍然没有闭合证据。

### 4. 输出端只有“存在某个 ICC 滤镜”的证据，没有完成色彩转换分析

报告 §14 把输出归纳为“经 `IslEISFilterCmsTransform` 转到目标 ICC”，但定点反编译显示还至少需要说明：

- `ModifyISCmsTransform` 根据像素格式和全局 `m_bUse16BitICME` 选择 CMS 对象；
- `IslEISFilterCmsTransform::GetLine` 在 32→32 路径调用虚表转换，在 48→32 路径调用 `IslZcmsTransform::TranslateVia48`；
- `IslZcmsTransform::TranslateVia48` 的色域映射、裁剪、抖动和舍入尚未解出；
- `SetCmsTransformFromTargetICCColor` 先调用 `IslBRawReadParam::GetColorSpace`，再根据返回枚举值选择不同的 `GetCmsTransform` 参数；这更像条件选择的工作空间/目标变换，不能仅凭 `Parameters::Set` 的 `_COLORSPACE` 形参断言“内部固定在某一个工作空间”；
- JPEG 路径还调用 `MakeUpJpegData`、`DupForJPEG`、`SetICCProfile`、`StoreJpeg2`，但报告没有分析 RGB→JPEG 编码空间、范围、采样和量化；
- TIFF/DNG 的 bits-per-sample、通道顺序、ICC 写入和 DNG 特有输出参数也没有逐字段确认。

相关证据保存在 `R3_ModifyISCmsTransform_pdg.c`、`R5_CmsGetLine_pdg.c`、`R7_CalcBitsPerSample_pdg.c`、`R8_JpegDoOutput_pdg.c` 和 `R26_SetCmsTransformFromTargetICCColor_pdg.c`。

### 5. RAW 到线性 RGB 的像素级变换仍未完成

报告给出了 `DecodeStrip`、`Decode1Line`、CF2 标签和若干反马赛克类名。补充复核已确认 `OpenInternal` 实际读取 CF2 Gamma/Huffman/strip 字段，
`DecodeStrip` 走 `DecRead → DecHuff → Gamma`，`Decode1Line` 分成 8/12-bit 与 10/14-bit 变长字段分支；但仍没有完成以下闭环：

- CF2 解码字段与真实传感器数值的物理含义，以及 Bayer 平面排列、边界和 `ErrRangeCheck` 全部规则；
- BayerPattern/ColorFilter 如何决定平面顺序；
- DigitalGainR/G/B、GainG、SamplingMax 和白电平如何进入像素算术；
- `GetOpticalBlack`、`GetSamplingMaxValue`、`GetDigitalGain`、`GetWhiteBalanceGain2` 和 4/12 轴读取函数已经证明对应字段会被解析；仍需把 `OpenInternal`/`MakeUpVEParam` 的字段写入和后续像素消费者逐一对上；
- `IslEISPanaRemoveBlack::DemosaicLine` 的零值/坏点修复公式及其与黑电平的关系；
- 12 种以上 demosaic 实现的选择条件及每种输出位深；
- 非线性、饱和、色差、Shading、SpatialGain 之间的实际数值顺序。

补充的 `GetWhiteBalance2` 反编译还确认：WB2 会读取第二套 R/G/B 增益、按版本合并 DigitalGain，并按相机/ISO 分支应用修正系数；因此 WB 的两个输出增益并不等于简单的两个标签乘法。证据为 `R48_GetWhiteBalance2_pdg.c`。

这些内容不是仅凭方法名就能升级为 A 级。

### 6. 仍有明确的 B/C 项，却在总结中使用了“完整参数清单/完整色彩链”的口径

报告 §16 已承认以下项目未解决：通用链全局执行顺序、`u16×6` 语义、`CAMERA_ID` 到机型映射、黑电平 LUT 公式、preLUT 数值和部分滤镜语义。补充复核已经确认 `Pana_LUT::GetValue` 是 8 点三线性插值，但 `CalcCorrectionLUT`、`MakeUpLUT`、`IslZcmsTransform::TranslateVia48` 的完整数值语义和所有分支仍未闭合，因此不能把“参数结构齐全”表述为“色彩变化已全部分析”。

## 证据中可以新增的一个重要事实

3DLUT 自身并不是单纯“查表后输出”。`R9_VE3DLUTFilteringLine_pdg.c` 显示它还包含：输入通道归一化、可选的通道预处理、`Pana_LUT::GetValue`、低 ISO/对比度相关处理、增益换算、多个线性组合、`floor`、0/65535 裁剪和按比例写回 16-bit 通道。进一步反编译 `R21_PanaLUT_GetValue_pdg.c` 可见，`GetValue` 对三个输入轴各取相邻网格点，按 8 个角点权重做三线性插值，然后逐通道向下取整并裁剪到 0…65535。报告目前只列出 3DLUT 的资源格式和寄存器参数，没有把这些运行时色彩操作列出来。

CMS 输出也有可量化的遗漏：`R24_CmsTranslateVia48_pdg.c` 显示 32-bit 输入先左移 8 位变成 16-bit 中间值，非特殊参数时加入 4×4 抖动表，再调用 CMS 变换并复制 alpha/附加通道。报告没有描述这个位深扩展、抖动和舍入路径。

## 建议的修订口径

1. 把 VE 图改成两个互斥分支：`ToneCurve→矩阵/轴校正→MixYC`，或 `3DLUT(Pana_LUT/preLUT/LUTContrast/LowISO)`。
2. 在通用链表之外增加“直接构造的条件色彩节点”一节，至少列出 3DCM、LAB/LABTransform、UCS/UCS2、GrayAxis 及其 `ReleaseAndSet` 位置。
3. 把 §14 的等级从“输出侧 A 级”改成“输出类和入口 A 级，像素转换 B/C 级”，补上 `Translate`/`TranslateVia48` 与 JPEG/TIFF/DNG 的分支。
4. 用一张真实 S1M2 RW2 做运行时记录，分别保存 RAW 解码后、去黑、反马赛克、VE 前后、CMS 前后和编码器输入的中间缓冲；没有这一步，无法证明某一条具体输入路径实际经过了哪些条件节点。

