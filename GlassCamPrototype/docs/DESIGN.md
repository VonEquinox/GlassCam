# 第一原型架构与颜色域

## 分层

- SwiftUI：PhotosPicker / 文件导入、对比、曝光与工厂 CCT 参数、PNG 分享。
- Apple 图像适配层：Core Image 解码及颜色管理，输出有限尺寸的 linear-sRGB RGB 浮点数据。DNG/ProRAW 为实验性输入，需要 Apple SDK/真机核验。
- 标准 C++17：平台无关 HNCS 数值核、上下文参数预计算、逐像素处理和 C ABI。
- Python：读取保留的原始资产与固定向量，执行不改写算法的基准核验与可复现诊断。

Swift 不重写颜色算法；C++ 不依赖 UIKit、Core Image、Metal 或第三方 JSON 解析库。后续 Apple 加速后端独立存在。

## 真实 HNCS 核与实验输入桥分开

本仓库的 HNCS 交付实现要求黑位扣除、归一化、白平衡后的 X2D II native RGB，不能把 iPhone RGB/linear-sRGB 直接冒充该输入。

第一原型为“先跑效果”采用明确标记的色度学桥：

linear sRGB(D65) → XYZ → Bradford 白点适配 → inverse(interpolated camera_to_xyz) → virtual native RGB → 原有 HNCS 核 → Hasselblad 工作码 → 原有显示变换 → sRGB PNG。

桥使用已有矩阵，不拟合新色卡，也不声称已有 iPhone→X2D 标定。它只能让现有核在明确输入域上工作。输入 JPEG/HEIC 已有 tone mapping；简单线性化不能还原原始场景。ProRAW 的系统解码也不等同于未处理 CFA。图像效果好坏与跨设备匹配仍需真实样片判断。

工厂 CCT 是已有核的参数，不是拍摄光源的测量结果，也不是对解码图像再次叠加相机白平衡。曝光 EV 只在进入核前乘一次。原核入口保留 [0,1] 截断与 16 位就近偶数量化，因此没有额外宣称 HDR 负值/超白保留。

## 不改变的数值契约

- Double 核心运算；输入 `rint(clip(rgb,0,1)*65535)` 的 ties-to-even。
- Kelvin 节点线性插值，整体 2000–10000 K 限制后允许原表端点外推。
- 原始二维 chroma LUT，绝非凭感觉生成的 RGB 3D LUT。
- 原始暗部去饱和、灰度权重、工作域、截断索引和 65536 项曲线。
- 不重新平滑中性轴，不移除已验证的原始核特征。

## 第一轮性能策略

1. 每组参数预计算矩阵、插值 LUT 和输出转换，避免每像素重复工作。
2. 融合逐像素操作，使用连续缓冲区，限定预览尺寸，控制并发，避免 48MP 多个全尺寸 double 中间图。
3. 保留标准 C++ 参考实现和黄金向量，再用实际瓶颈决定 SIMD、线程池和 Metal。C++ 本身不等于自动使用 GPU/ANE。
4. 可移植 CPU benchmark 只说明本次云端 CPU 的该处理段性能，不能换算 iPhone 帧率。
5. 新增显式 fast 显示编码路径：65,536 项线性采样表，仅最终 8 位 sRGB 编码允许最多 1 码误差；原 HNCS 核不近似。精确路径保留。CPU 连续块并行最多 4 线程，已做同输入对比测量。
6. 未在手机上测量之前，不声称“极限优化完成”、实时 48MP、功耗或热稳定性目标达标。

本次的 8 位 PNG 是可查看效果的导出端点，不是建议长期把 RAW/宽色域处理降为 8 位。
