# 来源与分发说明

GlassCam 使用用户提供的参考源码、数值资产与固定样本。各来源的版本、提交和哈希分别记录在对应的 ORIGIN 文档中。

| 组成 | 来源与校验记录 |
|---|---|
| HNCS 源码、预设、矩阵、LUT 与曲线 | [HNCS ORIGIN](vendor/hncs/ORIGIN.md)，来源资料包含 Phocus 4.2.2 数据 |
| FFCS 源码、相机表族 LUT 与 ICC | [FFCS ORIGIN](vendor/ffcs/ORIGIN.md)，当前参考交付为 FFCS 0.2.0 |
| LUMIX Photo Style 双表与参数 | [LUMIX ORIGIN](vendor/lumix/ORIGIN.md)，来源为 SILKYPIX Developer Studio 8 SE 8.0.31.1 |

## 原厂数据的权利

原厂数据及其衍生数值表保留原权利人的所有权；随资料未提供覆盖公开或商业再分发的完整许可证明。私有仓库开发授权不包含公开仓库、App Store 或其他商业分发授权，分发前须完成相应的权利核对。本仓库及技术交付中其他组件的许可均不为这些数据授予额外权利。

GlassCam 与 Hasselblad、Phocus、Fujifilm、SILKYPIX 或 Apple 没有关联或背书关系。

## 第三方兼容代码

便携空间处理和随机数兼容组件保留适用的 NumPy／SciPy BSD、PCG 及随机数实现许可声明和来源链接，详见 [hncs_numpy_rng.cpp](Packages/GlassCamKit/Sources/CHNCS/hncs_numpy_rng.cpp) 与 [hncs_spatial.cpp](Packages/GlassCamKit/Sources/CHNCS/hncs_spatial.cpp)。分发这些组件时，应按各许可要求随源码或二进制提供相应声明。
