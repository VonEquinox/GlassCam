# 06 参数、API 与 CLI（0.2.0）

| PipelineConfig 参数 | 默认 | 作用 |
|---|---|---|
| simulation | `'PROVIA'` | 外观名称或明确 FilmSimulation |
| camera | `'GENERIC'` | 机型名称或 CameraProfile |
| output_space | `'sRGB'` | sRGB/AdobeRGB |
| output_bits | `16` | 8/16；16位RGB使用TIFF |
| seed | `0` | 整数噪声seed |
| filter_colour | `None` | ACROS/MONO G/R/Ye |
| stage_dir | `None` | 自动导出阶段 |
| sharpen_radius | `1.0` | 有限正Gaussian半径 |
| input_is_linear | `False` | 普通RGB已在线性域；sensor自动识别 |
| lut_path | `None` | 自定义cube路径 |
| lut_domain | `None` | linear/encoded |
| sigma | `None` | [0.05,8]有限值；默认按外观 |
| use_reference_luts | `True` | 允许自动选择参考表 |
| apply_reference_adjustments | `False` | 主动开启LUT之后的解析预设调整 |

FilmSimulation 所有字段、别名与 3×3 矩阵、CameraProfile 的 matrix/resize_factor 均以 [model_parameters.json](../validation/model_parameters.json) 和 [models.py](../implementation/ffcs/models.py) 为完整机器可读定义。下表是解析默认值；加载 LUT 后默认将额外调整置中性，不是原生测量参数。

| 外观 | contrast | saturation | hue | shoulder | toe | grain | size | chroma | sharp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| PROVIA | 1.03 | 1.02 | 0.0 | 0.1 | 0.0 | 0.015 | 1.0 | 0.1 | 0.22 |
| VELVIA | 1.14 | 1.34 | 0.012 | 0.18 | -0.01 | 0.025 | 0.9 | 0.13 | 0.12 |
| ASTIA | 1.0 | 1.08 | -0.008 | 0.08 | 0.005 | 0.015 | 1.0 | 0.09 | 0.18 |
| CLASSIC CHROME | 1.1 | 0.88 | -0.012 | 0.24 | 0.01 | 0.012 | 1.1 | 0.08 | 0.2 |
| CLASSIC NEG. | 1.06 | 1.05 | 0.018 | 0.2 | 0.015 | 0.02 | 1.2 | 0.11 | 0.16 |
| NOSTALGIC NEG. | 1.04 | 0.96 | 0.025 | 0.14 | 0.025 | 0.022 | 1.25 | 0.1 | 0.15 |
| ETERNA | 0.86 | 0.81 | -0.008 | 0.3 | 0.02 | 0.018 | 1.0 | 0.1 | 0.1 |
| ETERNA BLEACH BYPASS | 1.23 | 0.43 | -0.01 | 0.34 | 0.01 | 0.024 | 0.85 | 0.12 | 0.08 |
| ACROS | 1.15 | 0.0 | 0.0 | 0.28 | 0.02 | 0.035 | 1.15 | 0.12 | 0.25 |
| MONOCHROME | 1.08 | 0.0 | 0.0 | 0.18 | 0.01 | 0.022 | 1.1 | 0.1 | 0.2 |
| PRO NEG. HI | 1.1 | 0.93 | -0.008 | 0.12 | 0.005 | 0.012 | 1.0 | 0.08 | 0.18 |
| PRO NEG. STD | 0.96 | 0.92 | 0.0 | 0.06 | 0.008 | 0.012 | 1.0 | 0.08 | 0.18 |
| REALA ACE | 1.02 | 1.07 | -0.005 | 0.1 | 0.004 | 0.015 | 1.0 | 0.09 | 0.18 |
| SEPIA | 1.0 | 0.38 | 0.0 | 0.16 | 0.025 | 0.018 | 1.1 | 0.1 | 0.14 |

全部内置 sigma=1，默认外观矩阵恒等，lut=None（运行时解析）；ACROS acros=True，SEPIA sepia=True。NC→CLASSIC Neg.，CC→CLASSIC CHROME。黑白过滤名称可在名字中写 +G/+R/+Ye 或用 filter_colour。

| 机型 | black | white | WB | shading | CFA |
|---|---:|---:|---|---:|---|
| XH2S | 256 | 16383 | (2.04, 1.0, 1.49) | 0.16 | XTRANS |
| X-T5 | 256 | 16383 | (2.0, 1.0, 1.48) | 0.14 | XTRANS |
| X100V | 256 | 16383 | (1.95, 1.0, 1.52) | 0.12 | XTRANS |
| GFX100S | 512 | 65535 | (1.9, 1.0, 1.45) | 0.1 | RGGB |
| GFX100 | 512 | 65535 | (1.9, 1.0, 1.45) | 0.1 | RGGB |
| GFX100II | 512 | 65535 | (1.9, 1.0, 1.45) | 0.1 | RGGB |
| XA3 | 256 | 16383 | (1.96, 1.0, 1.5) | 0.13 | RGGB |
| GENERIC | 0.0 | 16383.0 | (1.0, 1.0, 1.0) | 0.0 | RGGB |

机型标量与矩阵是未标定的起点，真实传感器黑电平/WB/CFA 优先元数据。未知机型产生同名中性 profile；GFX100II 公共 RAW 起点不构成该机标定证据。

```python
from ffcs import FFCS, PipelineConfig, FilmSimulation
result = FFCS(PipelineConfig(camera='GFX100S', simulation='NOSTALGIC NEG.')).apply_path('input.tif')
result.save('out.tif')
result.save_stages('stages')
# 显式自定义控制不会被自动中性化：
custom = FilmSimulation('CUSTOM', contrast=1.1, lut=my_lut, lut_size=17, lut_domain='encoded')
result = FFCS(PipelineConfig(simulation=custom)).apply(image, input_pixels=working_pixels)
```

```sh
ffcs list simulations
ffcs list cameras
ffcs apply input.tif --sim NC --camera XH2S --out result.tif --stages stages --json
ffcs apply input.tif --sim PROVIA --camera XH2S --preset-adjustments --sharpen-radius 1.5 --out result.tif
ffcs apply input.tif --lut look.cube --lut-domain encoded --out result.tif
ffcs develop raw.raf --sim ACROS --filter R --camera XH2S --out result.tif
ffcs compare candidate reference --stride 1 --out comparison.json
ffcs colorchecker candidate.tif reference.tif --boxes boxes.json --out chart.json
```

CLI --analytic 关闭内置 LUT；--linear-input 表示普通图像已在线性工作域；--bits 默认16，仅 TIFF 16位，JPEG/PNG 8位；--space 只允许 sRGB/AdobeRGB；--seed 默认为0。

比较退出码 0=全部适用门槛通过，1=失败，2=无效输入，3=需要证据。ColorChecker 返回 0/1/2，boxes 为 24 个不重叠的整数 `[x0,y0,x1,y1]`，右/下边界排除且全部在图内。不是一个有效框加若干空框也能平均通过。

JSON 为严格标准格式，正/负无穷写字符串，NaN 写 null；测试和比较输入中的 NaN 会直接拒绝。保存元数据记录实际文件 ICC 是否嵌入，而非只根据希望的配置断言成功。

[CLI源码](../implementation/ffcs/cli.py) · [管线源码](../implementation/ffcs/pipeline.py)
