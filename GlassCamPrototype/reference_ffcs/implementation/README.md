# FFCS 0.2.0

可检查、可导出中间阶段的 Fujifilm 风格颜色处理工具。支持 RGB 图像、可选 rawpy 传感器 RAF 解码、TIFF16 输出及 sRGB/AdobeRGB 色彩管理。

2026-10-13 修复了 RAW 重复 Gamma、CFA 跨颜色滤波、TIFF/ICC 精度和方向、色卡假通过、宽色域色差裁剪、LUT 重复预设调整、颗粒频谱和测试收集等问题。详见 [修复记录](FIXES_20261013.md)。

## 安装和使用

Python >=3.10。运行依赖为 Pillow >=9.1、NumPy、tifffile、imagecodecs；rawpy 为可选依赖。

```sh
python -m pip install '.[test]'
python -m pytest -q
ffcs apply input.tif --sim NC --camera XH2S --out output.tif --stages stages
ffcs apply input.tif --sim 'REALA ACE' --camera GFX100II --out reala.tif
ffcs develop input.raf --sim ACROS --filter Ye --camera XH2S --out acros.tif
ffcs compare candidate-stages reference-stages --out residuals.json
ffcs colorchecker candidate.tif reference.tif --boxes boxes.json
```

传感器解码另安装 `python -m pip install '.[raw]'`。无法解码传感器时使用面积最大的内嵌 JPEG，保存解码失败原因，并将传感器处理占位阶段标记为 `not_applicable`。预览不会再次做黑电平或白平衡校正。

## LUT 与工作域

包含 50 张原生映射采样 LUT：XH2S 19、XA3 11、GFX100 18、GFX100S NOSTALGIC Neg. 1、GFX100 II REALA ACE 1。专用表优先；GFX100S/GFX100II 其他可用外观使用 GFX100 公共表并明确记录机型替代。其他组合使用未经原生标定的解析预设。

已载入 LUT 默认关闭额外解析预设调整，保留映射原本输出。`--preset-adjustments` 可主动叠加预设；`--analytic` 强制解析路径。`--sigma` 的非默认值是便携 tanh 调整，原生实测只覆盖 sigma=1。

自定义 `.cube` 支持 `DOMAIN_MIN/MAX`、Resolve 输入范围及 1D shaper + 3D 组合，红轴最快。`--lut-domain encoded` 表示 sRGB 编码输入表，`linear` 表示线性工作表。自定义 API 的 `FilmSimulation(lut=...)` 不会被机型内置表覆盖。

RGB 文件先按方向与 ICC 转换为 sRGB 工作值；`--linear-input` 用于已在线性工作域的输入。传感器 RAW 自动保留线性域，无需手动指定。`FFCS.apply(image, input_pixels=...)` 接收已归一化的工作值；需文件 ICC 管理时使用 `apply_path()`。

`stage_pixels` 保存计算值，`stages` 是 8 位预览。阶段导出中，传感器原码/CFA/线性值使用无 ICC 的 float32 TIFF，编码阶段使用指定整数深度，最终阶段使用实际输出 ICC。JPEG/PNG 输出为 8 位，16 位输出使用 TIFF。

## 验证范围

50 张表共 100,000 个原生三线性映射样本全部满足平均 ΔE2000 <1；最高单表均值为 0.0540214251。证据保存在 [reference_validation.json](ffcs/data/reference_validation.json)，包含数据和原生库 SHA-256，并仅对 hash 匹配的表生效。完整图像、真实 RAF、原生 GUI 与 ColorChecker 的配对参考尚未提供，不能据此宣称全流程等价。

61 项回归测试通过。完整交付快照包含 10 篇技术文档、源码、测试、数值复现与资产校验，入口为 [交付说明](../README.md)。
