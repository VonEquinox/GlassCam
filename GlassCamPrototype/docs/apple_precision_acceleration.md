# Apple 精度保持加速路线

核查日期：2026-10-11。范围：当前 C++ double HNCS / FFCS；只研究方案，不修改生产算法。结论中的“可保持”是设计条件，不是已经完成的 Apple 真机证明。

## 结论

默认继续保留 exact CPU 路线。优先跨像素并行、减少临时内存和 double SIMD；不要为了 GPU 吞吐默默把核心改成 float/half。Accelerate 支持 double，不代表其复合函数与现有 C++ 算式逐位相同。Metal precise 也不等于 CPU double。

## 官方契约与工程影响

- [Apple Accelerate 概览](https://developer.apple.com/accelerate/)：CPU 向量计算；SIMD 支持 double 向量。因此 CPU SIMD 不需要降成 Float32。向量的多个 lane 应表示不同像素，不能把同一像素的求和随意横向归约。
- [vDSP 向量算术](https://developer.apple.com/documentation/accelerate/vector-vector-real-arithmetic-functions)：vDSP_vaddD、vDSP_vmulD、vDSP_vdivD 是 double 逐元素 API。它们可作独立候选；需逐步核查舍入、NaN/零、步长、别名和调用成本。不要由 API 中的 D 推导完整流水线逐位等价。
- [vDSP_vmaD](https://developer.apple.com/documentation/accelerate/vdsp_vmad) 给出乘加语义，但当前文档没有为我们的 oracle 保证“乘法先舍入、再加法舍入”。因此先保留显式分开的乘法/加法，不直接替换成乘加、dot、矩阵库或跨通道 reduction。
- [vForce](https://developer.apple.com/documentation/accelerate/vforce-library) 提供 double 的 vvpow、vvsqrt、vvsin 等向量超越函数。[vvpow](https://developer.apple.com/documentation/accelerate/vvpow(_:_:_:_:)) 的 C 参数顺序是 output、exponents、bases、count。查阅的官方概览/API 未承诺与 std::pow/libm 逐位一致，也未给可直接证明本流水线的统一误差界；不能宣称“无精度损失替换”。
- [Xcode 14.3 Release Notes](https://developer.apple.com/documentation/Xcode-Release-Notes/xcode-14_3-release-notes) 明确提示默认浮点 contraction 可融合乘加并影响数值敏感应用。当前 -O3 -fno-fast-math -ffp-contract=off 必须在实际 iOS Release 核心编译命令中继续生效，不能只检查 CMake 文件。
- [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)，本次读取 2026-06-04 版：§2.1 不支持 double；§1.6.3 safe 仍允许语句内 contraction；须另设 -ffp-contract=off 或 #pragma METAL fp contract(off)。§8.4 的 precise pow 允许最多 16 FP32 ULP，§8.1 允许非正规数冲零，§8.2 允许相应舍入模式差异。这些都不能建立 CPU double 逐位等价。
- [MTLCompileOptions.mathMode](https://developer.apple.com/documentation/metal/mtlcompileoptions/mathmode)：旧 fastMathEnabled=false 对应 safe + precise。明确设定二者适用于 GPU 实验；它并不会增加到 FP64。

## 具体实施顺序

1. **当前 exact 主线**：保留每像素函数、double 常量、查表值、round_even、截断和相同括号。上下文不可变；每个 worker 输出互不重叠。FFCS 锐化必须保持原邻域累加顺序、全图坐标和 halo；不能改用滑窗求和或不同分组。先测现有 1–4 workers，报告整条 strip/export 延迟和热态表现。
2. **CPU SIMD 小步实验**：先把 exposure、矩阵的各个独立乘法/有序加法、tone curve 拆成跨像素 double2 或编译器可向量化循环。SIMD lane 是像素，单像素表达式树完全不变；LUT gather 和分支可以继续标量。避免为了向量化引入近似 reciprocal、FMA、矩阵预合并。比较标量尾部与整向量批次，使用优化报告/反汇编确认实际产生 double 向量指令且没有 FMA。仍须通过 Apple 同机 oracle 回归才能启用。
3. **Accelerate 分支**：按热点逐个测 vDSP 的单一步骤；把 vForce pow/trig 作为显式实验后端，测阶段 ULP 和整数码差。HNCS 已有完整 65536 项 gamma_decode 表，应复用精确索引查表，不把该已消除的 per-pixel pow 再做一遍。若表值由新实现生成，完整比较所有表项；不要只比较图片观感。
4. **Metal 分支只在另行接受精度契约后**：先用 UInt16 原始 LUT buffer + 显式加载/插值，保持索引、通道排列、边界和算式；不要直接使用 normalized/sRGB texture 或硬件线性采样替换当前插值。显式插值可控制流程，但 FP32 仍不是 double。输出已定整数码后的搬运、打包或显示工作可另行评估，不推导整个 GPU 色彩核心 exact。

## 验收门槛

- 固定 oracle 版本、资产 hash、参数、seed、输入字节；记录设备/SoC、OS、Xcode、编译 flags。先做同机 oracle 对比，再看跨平台差异。Linux 测速不能标成 iPhone 测速。
- 分阶段比较原始 double 位模式，记录首次分歧的像素、通道、操作和 ULP；再分别比较 HNCS 原生 UInt16、Float32 linear export 和最终 8/10/16-bit 码值。输出文件编码器自身的变化另算。
- 边界样本包含 input×65535 的 k+0.5 及 nextafter 两侧；HNCS curve 索引使用截断，须另外测试整数边界；LUT cell 边界、0/1 clamp、y=0、shadow/gray 阈值、sRGB 分段、极暗/饱和色、负值/非法输入契约。FFCS 加灰阶、色相、seed、边缘和 strip 接缝。所有支持的模式、曝光、白平衡、worker 数与奇数尾长都纳入。
- “误差小于半个 16-bit 码”不足以证明输出相同：真值可任意接近舍入边界；跨过阈值就差一码。half 在 [0.5,1) 的间距约为 32 个 16-bit 码，Float32 间距虽小得多，也会跨边界。这是格式/量化推导，不是实测错误统计。
- 默认要求阶段/输出零差异。若未来用户只要求最终整数码相同，可单独提出该契约；应采用经过证明的误差区间与临界像素 double fallback，或明示有限测试覆盖。随机样本零差异不能宣称全输入保证。当前没有用户授权放宽为视觉相似或允许少量码差。

## 当前未建立的事实

本研究未运行 Accelerate/Metal 真机后端；没有 Apple GPU 精度或速度测试结果。不存在从这些官方文档直接推导的 vvpow=std::pow 或 Metal FP32=当前 C++ double 保证。下一有效交付是同机 A/B 逐阶段证据与端到端性能，而不是替换整个核心后只看 PSNR/肉眼。

## 补充：10-bit 精度 SDR 预览（显示端，独立于核心加速）

目标是移除处理结果的 UInt8 CGImage 瓶颈，不要求启用 HDR，不推断面板物理位深。

- 推荐接线：现有 CPU double 核心 → linear Float32 RGBA（alpha=1）→ CIImage 的 RGBAf bitmap → Metal-backed CIContext → MTKView/CAMetalLayer rgba16Float。CIImage 源色空间、render 目的色空间与 layer.colorspace 都明确使用 linear sRGB。half 仅为最终显示存储，不作为 HNCS/FFCS 运算类型。
- [CIImage bitmap 初始化](https://developer.apple.com/documentation/coreimage/ciimage/init(bitmapdata:bytesperrow:size:format:colorspace:)) 要求预乘 alpha；现有 alpha=1 满足要求，rowBytes 应为 width×4×sizeof(Float)。持有数据直到渲染提交使用结束。
- [CAMetalLayer.pixelFormat](https://developer.apple.com/documentation/quartzcore/cametallayer/pixelformat) 明确允许 rgba16Float 与 rgb10a2Unorm；默认是 bgra8Unorm。使用 [CIContext.render](https://developer.apple.com/documentation/coreimage/cicontext/render(_:to:commandbuffer:bounds:colorSpace:)) 时创建 Metal context，目标为 2D、sampleCount=1；同一个 commandBuffer 完成渲染和 present。CI 写 drawable 路线设置 [framebufferOnly=false](https://developer.apple.com/documentation/metalkit/mtkview/framebufferonly)，接受其性能成本。
- 若明确选 rgb10a2Unorm，推荐渲染目的与 layer 都设 sRGB，让 CI 从源 linear sRGB 编码一次再写入 10-bit RGB。该格式没有自动 sRGB 变换后缀，不能把 linear 数据直接写进去却声明 sRGB，也不能先编码再让 CI 重复编码。
- [wantsExtendedDynamicRangeContent](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent) 控制超出 SDR 的数值；默认 false。保留 false、输出0…1即可支持高精度 SDR 路线，无须 PQ/HLG/EDR 标志。
- 验证：浮点输入至 drawable 之间不再出现 UInt8/RGBA8 中转；灰阶渐变检查>256级输入的区别是否保留；核对一次色彩转换、黑白点、方向/裁切、alpha及缩放。设备合成后的物理输出仍需真机验证，不能由纹理格式宣称面板全链路保证。
- 若 live capture 仍为8-bit，其既有采样损失无法由高精度显示恢复；新路线防止处理结果再被8-bit量化。10-bit capture 是独立工作，应按设备/activeFormat/availableVideoPixelFormatTypes 检查，不以“设置10bit display”等同“源10bit”。
