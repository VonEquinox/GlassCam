# Handheld Multi-Frame Super-Resolution 来源

- 上游：[Jamy-L/Handheld-Multi-Frame-Super-Resolution](https://github.com/Jamy-L/Handheld-Multi-Frame-Super-Resolution)。
- 固定提交：`27c4655ae4752898e0ae6e9737697c4d89c95226`。
- 许可：[MIT](LICENSE)，Copyright (c) 2023 Jamy Lafenetre。
- 使用范围：GPU Bayer 低频灰度、金字塔配准与光度可靠度流程，见 [C++ 配准](../../Packages/GlassCamKit/Sources/CMetalF5/f5_curvature_registration.mm) 和 [Metal 内核](../../Packages/GlassCamKit/Sources/F5/F5Kernels.metal)。

GlassCam 将这些流程改写为 C++／Metal，并使用 Gaussian 积分噪声矩、细层零位移候选及独立曲率重建。上游源码与研究执行器保存在研究仓库，产品仓库保留许可和来源身份。
