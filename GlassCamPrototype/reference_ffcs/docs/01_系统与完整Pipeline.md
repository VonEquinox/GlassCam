# 01 系统与完整 Pipeline（0.2.0）

入口 `FFCS.apply_path()` 区分普通文件与 RAF。RGB 文件由 `io.load_pixels()` 在原始位深读取，应用方向，再由输入 ICC 转成 sRGB 工作值。无 ICC 默认 sRGB。`input_is_linear=True` 表示调用者已提供线性工作 RGB，绕过 ICC 与 sRGB 解码；传感器 RAW 自动选择线性分支。直接 `apply()` 的数组由调用者负责归一化与色彩空间。

```text
RGB文件 → 方向/ICC → 编码或显式线性工作RGB ─┐
RAF → rawpy可见传感器 → RAW前置链（线性） ├→ 颜色链
RAF → 面积最大内嵌JPEG → 保留显影像素 ─────┘
```

| 颜色阶段 | 数值域和实际动作 |
|---|---|
| input_normalized | 编码 sRGB，或传感器/显式线性 RGB |
| gamma_pre | 编码输入做一次 sRGB 解码；线性输入原样通过 |
| matrix_3x3 | 线性表/解析路径：先机型矩阵、后外观矩阵；编码表只施加外观矩阵 |
| lut_3d | 编码表：矩阵结果先编码，再三线性插值；线性表在工作线性值插值 |
| lab_ucs | 在线性 LUT 后先编码；解析黑白滤镜先按彩色通道加权，其余可选 Lab → OKLab |
| tone_curve | 编码 RGB 中逐通道对比、toe、shoulder |
| film_grain | 固定 seed 的亮度/色度噪声；另计算 grain−tone 残差统计 |
| sharpen | 浮点 Gaussian unsharp，半径实际参与邻域计算 |
| output_icc | sRGB 或经矩阵/Gamma 转换的 AdobeRGB；保存时嵌入对应 ICC |

原生封装表包含矩阵的最终映射，外观矩阵为恒等，不重复应用原生矩阵。加载任何 LUT 且 `simulation` 为名称字符串时，默认将 contrast/saturation/hue/toe/shoulder/grain/sharpen 调整置中性。`apply_reference_adjustments=True` 或显式 `FilmSimulation` 才使用调用者指定的调整。所有阶段仍可导出，空操作阶段不意味着原生软件包含相同步骤。

RAW 前置阶段依次为 `raw_input`、`black_level`、`bad_pixel_repair`、`lens_shading`、`band_preprocess`、`white_balance`、`demosaic`、`shadow_cleanup`、`resize_lanczos`。原码域为 sensor-code，前去马赛克归一化域为 cfa-linear，去马赛克后为 linear；预览回退各阶段为 encoded，传感器处理标记不适用。

`PipelineResult.stage_pixels` 保存计算数组，`stages` 保存 8 位查看图，数值验证应使用前者。`save_stages()` 将实际域写入 `pipeline.json`：线性/原码/CFA 为无 ICC float32 TIFF，编码阶段为整数 TIFF，最终输出使用实际输出空间。Float32 导出有该位深的舍入误差，JSON 浮点基准保留计算精度。

元数据包括版本、解析参数、LUT 来源/机型替代、数据 hash 对应原生证据、阶段域、实际导出格式、颗粒统计及各近似状态。`stage_coverage` 与 `validate_contract()` 的通过仅代表阶段名齐全。参考全链状态独立记录为 `unverified`。

[下一篇：颜色数学](02_颜色变换数学与数值约定.md) · [源码](../implementation/ffcs/pipeline.py)
