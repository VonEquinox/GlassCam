# 实验性仅色彩取景

更新2026-10-13（FFCS0.2）。源码提供默认关闭的 “Experimental live color (approx.)” 开关。它只影响中心取景，不改变照片配方、ProRAW、完整 HNCS/FFCS 处理、HEIF 保存或分享。外围仍显示真实宽镜头的系统色彩。

## 实现边界

- 65³ sRGB 整形格点，Float32 RGBA 数据，R最快/G其次/B最慢；节点由本项目真实 CPU 核计算，输出为 display-linear sRGB。
- HNCS 保留原核心量化；FFCS 新增独立逐点 C ABI，保留矩阵、原始 LUT、Lab/UCS、tone 与输出解码，只省略颗粒和锐化。原交付没有独立模糊阶段。
- CI 读取带实际颜色附件的 NV12，转换到线性工作域，显式限制到 [0,1]，用 `CILinearToSRGBToneCurve` 生成查表坐标，再应用 cube。之后不再做逆 shaper；输出已经是线性显示值。
- 常驻 Metal-backed CIContext，Float 工作域、RGBA16Float drawable、SDR/EDR关闭。当前相机输入仍是8位 NV12，高精度处理不会恢复源位数。P3越域分量被显式裁剪，不能声称保留其完整色域或高光。
- Cube 只在配方变化时由后台任务生成，按蓝色切片检查取消；最多一个生成任务和一个最新请求，缓存最多两个cube。每个65³ Float32 RGBA cube约4.19MiB。
- 预览只放行EV0：HNCS原始Standard完整配方、虚拟capture 5500K或6500K，以及重新测量的FFCS0.2 XH2S中性PROVIA/ACROS（解析叠加关闭、半径1、有效原生资产）。revision8预设/film curve/目标WB/工厂覆盖等颜色身份进入准入检查；三个独立效果开关进入完整缓存身份，但不改变只含颜色的cube数值，也不扩大已测颜色范围。没有颜色误差证据的配方直接系统取景回退。其他模式/参数继续显示系统取景并给出说明。完整照片按研究表族显示全部实际支持的FFCS模式，不受此预览门控限制。

## 精度不是位深

高精度存储不会消除插值误差。历史0.1与HNCS原始5500K研究中，65³整形格点的HNCS ΔE76最大0.795、p99 0.137；PROVIA最大2.48、p99 0.612；ACROS最大0.968、p99 0.156。数据来自合成/随机/边界样本，不能当作任意场景、镜头或实际视频的准确度保证。

编辑器默认6500K已单独补测：相同168,193个holdout，Float32 cube的ΔE76最大0.79777、p99 0.13801；274,625个节点及布局/alpha检查通过。见 `validation/lut-proxy-default-kelvin.json`。

详见 [原始误差研究](lut-proxy-preview.md)、[FFCS热点](FFCS_STAGE_PROFILE.md) 和 [GPU设计](gpu-preview-design.md)。CPU查表速度不等于iPhone GPU帧率；显示调度目标不是实测交付帧率。

## 生命周期与回退

原始系统取景始终在下层。效果层只有当前配方、当前相机会话的GPU任务成功完成后才显示。关闭、准备中、未支持参数、失效会话/源、离开窗口、GPU失败或没有可用drawable时，应退回原始取景并更新状态。仅一个GPU任务在途，再保留一帧最新输入；CVPixelBuffer和cube持有到GPU完成，不排队积压历史相机帧。

## 已验证与待验证

当前FFCS0.2：每look452,780个holdout；65³ Float32cube与最终RGBA16F存储后PROVIA ΔE76 p99 0.61116/max2.53272、ACROS p99 0.189495/max1.10197。独立Python/native核对最大线性误差2.98e-8、274,625节点逐位一致。新合同v4使旧cube失效；窄配方重新放行是基于实测的实验性工程选择，不是通用视觉保证。见[新研究](FFCS_V020_LIVE.md)。

以下为0.1历史，不验证0.2默认：

新增FFCS逐点接口：19模式×13,229颜色，分别对原始stage、空间系数置零完整路线和独立研究oracle逐位一致；304非法调用不改输出；原完整图像与分块回归通过，见 `validation/ffcs-color-only.json`。

Apple SDK编译、CI shaper实际公式与插值、颜色附件处理、行方向/裁切、画面接缝、低电量/热稳态、实际帧时间、GPU占用和功耗均未在本环境执行。源代码契约和云数值测试不能代替这些设备验收。
