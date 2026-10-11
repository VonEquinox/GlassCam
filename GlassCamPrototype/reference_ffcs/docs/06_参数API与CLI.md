# 参数、API 与 CLI

## 1. PipelineConfig 全部字段

| 字段 | 默认 | 作用 |
|---|---|---|
| simulation | PROVIA | 字符串别名或 FilmSimulation 对象 |
| camera | GENERIC | 字符串或 CameraProfile |
| output_space | sRGB | sRGB/AdobeRGB 输出像素转换 |
| output_bits | 16 | 保存和阶段导出默认位数 |
| seed | 0 | 颗粒 hash 种子 |
| filter_colour | None | ACROS/MONOCHROME 的 G/R/Ye 滤镜 |
| stage_dir | None | 非空则 apply 自动导出阶段 |
| sharpen_radius | 1.0 | 传入浮点锐化，当前未参与计算 |
| input_is_linear | False | True 绕过 sRGB 解码 |
| lut_path | None | 外部 cube，优先于内置数据 |
| lut_domain | None | cube 输入域，缺省使用 simulation 域 |
| sigma | None | 末端覆盖模型 sigma |
| use_reference_luts | True | 按 camera/look 查内置表 |

simulation 已经是 FilmSimulation 对象时 resolved_simulation 原样返回，因此 filter_colour 不会再自动改该对象。camera 是 CameraProfile 时原样返回。未知相机名称不抛错，而是构造该名称的默认 CameraProfile，使用单位矩阵及中性 RAW 参数。

## 2. FilmSimulation 与完整预设

字段顺序与默认值：name 必需；aliases=()，contrast=1，saturation=1，hue_shift=0，highlight_rolloff=0，shadow_lift=0，grain_strength=0，grain_size=1，grain_chroma=0.12，sharpness=0，sigma=1，matrix=单位矩阵，lut=None，lut_size=17，acros=False，sepia=False，lut_domain=linear，lut_scale=1，lut_source=None。

以下全部预设初始 matrix 都是单位矩阵、lut=None、lut_size=17、lut_domain=linear。内置加载成功后覆盖的字段按 LUT 文档执行。

| 名称 | contrast | saturation | hue_shift | shoulder | toe | grain | size | chroma | sharpness | sigma | acros | sepia |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| PROVIA | 1.03 | 1.02 | 0.0 | 0.1 | 0.0 | 0.015 | 1.0 | 0.1 | 0.22 | 1.0 | False | False |
| VELVIA | 1.14 | 1.34 | 0.012 | 0.18 | -0.01 | 0.025 | 0.9 | 0.13 | 0.12 | 1.0 | False | False |
| ASTIA | 1.0 | 1.08 | -0.008 | 0.08 | 0.005 | 0.015 | 1.0 | 0.09 | 0.18 | 1.0 | False | False |
| CLASSIC CHROME | 1.1 | 0.88 | -0.012 | 0.24 | 0.01 | 0.012 | 1.1 | 0.08 | 0.2 | 1.0 | False | False |
| CLASSIC NEG. | 1.06 | 1.05 | 0.018 | 0.2 | 0.015 | 0.02 | 1.2 | 0.11 | 0.16 | 1.0 | False | False |
| NOSTALGIC NEG. | 1.04 | 0.96 | 0.025 | 0.14 | 0.025 | 0.022 | 1.25 | 0.1 | 0.15 | 1.0 | False | False |
| ETERNA | 0.86 | 0.81 | -0.008 | 0.3 | 0.02 | 0.018 | 1.0 | 0.1 | 0.1 | 1.0 | False | False |
| ETERNA BLEACH BYPASS | 1.23 | 0.43 | -0.01 | 0.34 | 0.01 | 0.024 | 0.85 | 0.12 | 0.08 | 1.0 | False | False |
| ACROS | 1.15 | 0.0 | 0.0 | 0.28 | 0.02 | 0.035 | 1.15 | 0.12 | 0.25 | 1.0 | True | False |
| MONOCHROME | 1.08 | 0.0 | 0.0 | 0.18 | 0.01 | 0.022 | 1.1 | 0.1 | 0.2 | 1.0 | False | False |
| PRO NEG. HI | 1.1 | 0.93 | -0.008 | 0.12 | 0.005 | 0.012 | 1.0 | 0.08 | 0.18 | 1.0 | False | False |
| PRO NEG. STD | 0.96 | 0.92 | 0.0 | 0.06 | 0.008 | 0.012 | 1.0 | 0.08 | 0.18 | 1.0 | False | False |
| REALA ACE | 1.02 | 1.07 | -0.005 | 0.1 | 0.004 | 0.015 | 1.0 | 0.09 | 0.18 | 1.0 | False | False |
| SEPIA | 1.0 | 0.38 | 0.0 | 0.16 | 0.025 | 0.018 | 1.1 | 0.1 | 0.14 | 1.0 | False | True |

hue_shift 以圈为单位，Lab 调整中乘 2π，HSV 中直接加 H。滤镜变体保留原预设参数但 name 追加 +G/+R/+Ye，hue_shift 覆盖为 G=-0.025、R=0.032、Ye=0.052。滤镜仅对 ACROS/MONOCHROME 生效；对其他名称传 filter 不抛错，只返回原模型。自动从名称识别的后缀还包括 GREEN/RED/YELLOW。

所有名称查找去非字母数字并转大写；别名如下：

- PROVIA：`PROVIA/STANDARD`, `STANDARD`
- VELVIA：`VELVIA/VIVID`, `VIVID`
- ASTIA：`SOFT`
- CLASSIC CHROME：`CLASSIC_CHROME`, `CLASSICCHROME`, `CC`
- CLASSIC NEG.：`CLASSIC_NEG`, `CLASSIC NEG`, `CLASSICNEG`, `NC`
- NOSTALGIC NEG.：`NOSTALGIC_NEG`, `NOSTALGIC NEG`, `NOSTALGICNEG`
- ETERNA：`ETERNA/CINEMA`
- ETERNA BLEACH BYPASS：`ETERNA_BLEACH_BYPASS`, `BLEACH BYPASS`, `BLEACH_BYPASS`
- ACROS：`ACROS+`, `ACROS_STD`
- MONOCHROME：`MONO`
- PRO NEG. HI：`PRO_NEG_HI`, `PRONEGHI`
- PRO NEG. STD：`PRO_NEG_STD`, `PRONEGSTD`
- REALA ACE：`REALA_ACE`, `REALA`
- SEPIA：`SEPIA_TONE`

## 3. CameraProfile 全部常量

默认 name 必需，black_level=0，white_level=16383，wb=(1,1,1)，lens_shading=0，cfa=RGGB，cfa_period=(2,2)，matrix=单位矩阵，resize_factor=1。cfa/cfa_period 是机身描述；传感器 developer 使用解码的 pattern，而不是强制该描述。

| 名称 | 黑电平 | 白电平 | WB | shading | CFA | 周期 | resize |
|---|---|---|---|---|---|---|---|
| XH2S | 256 | 16383 | (2.04, 1.0, 1.49) | 0.16 | XTRANS | (6, 6) | 1.0 |
| X-T5 | 256 | 16383 | (2.0, 1.0, 1.48) | 0.14 | XTRANS | (6, 6) | 1.0 |
| X100V | 256 | 16383 | (1.95, 1.0, 1.52) | 0.12 | XTRANS | (6, 6) | 1.0 |
| GFX100S | 512 | 65535 | (1.9, 1.0, 1.45) | 0.1 | RGGB | (2, 2) | 1.0 |
| GFX100 | 512 | 65535 | (1.9, 1.0, 1.45) | 0.1 | RGGB | (2, 2) | 1.0 |
| XA3 | 256 | 16383 | (1.96, 1.0, 1.5) | 0.13 | RGGB | (2, 2) | 1.0 |
| GENERIC | 0.0 | 16383.0 | (1.0, 1.0, 1.0) | 0.0 | RGGB | (2, 2) | 1.0 |

全部行主序相机矩阵：

- XH2S：`((1.22, -0.15, -0.07), (-0.06, 1.13, -0.07), (-0.04, -0.14, 1.18))`
- X-T5：`((1.2, -0.14, -0.06), (-0.05, 1.12, -0.07), (-0.04, -0.13, 1.17))`
- X100V：`((1.18, -0.13, -0.05), (-0.05, 1.11, -0.06), (-0.03, -0.12, 1.16))`
- GFX100S：`((1.16, -0.11, -0.05), (-0.04, 1.09, -0.05), (-0.03, -0.1, 1.13))`
- GFX100：`((1.16, -0.11, -0.05), (-0.04, 1.09, -0.05), (-0.03, -0.1, 1.13))`
- XA3：`((1.18, -0.13, -0.05), (-0.05, 1.11, -0.06), (-0.03, -0.12, 1.16))`
- GENERIC：`((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))`

完整机器可读字段在 validation/model_parameters.json。机身默认参数是现有实现的起始值，当前材料没有每个值的机身实测校准证明。

## 4. Python API 示例

```python
from pathlib import Path
from PIL import Image
from ffcs import FFCS, PipelineConfig, FilmSimulation, apply_image

result = FFCS(PipelineConfig(
    simulation='NC', camera='XH2S', seed=0,
    output_space='sRGB', output_bits=16,
)).apply(Image.new('RGB', (4,4), (128,96,64)))
result.save('output.tif')
result.save_stages('stages')
print(result.stage_pixels['lut_3d'][0][0])
print(result.validate_contract())

# 线性像素直入：显示图只用来承载尺寸，数值由 input_pixels 提供。
linear = [[(0.2,0.3,0.4)]]
linear_result = FFCS(PipelineConfig(
    simulation='PROVIA', input_is_linear=True,
    use_reference_luts=False,
)).apply(Image.new('RGB',(1,1)), input_pixels=linear)

# 保存时不重新做空间变换；空间必须在配置中先确定。
adobe = apply_image('input.tif','adobe.tif',PipelineConfig(output_space='AdobeRGB'))
```

`FilmSimulation` 可定制所有字段及嵌套/平坦 LUT；`CameraProfile` 可定制矩阵与 resize 等。二者为 frozen dataclass，变更宜用 dataclasses.replace。`PipelineResult.compare(reference,stride)` 使用内存浮点阶段；`compare_stage_directories` 比较量化后的 TIFF 阶段。RawSensor/RawDevelopment、demosaic_*、develop_raf、颜色指标等公共导出见 __init__.py。

## 5. CLI 全部命令

```sh
python -m ffcs list simulations
python -m ffcs list cameras
python -m ffcs apply image.tif --sim 'CLASSIC NEG.' --camera XH2S --out out.tif --stages stages
python -m ffcs develop raw.raf --sim ACROS --filter G --camera XH2S --out raw.tif
python -m ffcs apply image.tif --sim PROVIA --analytic --out analytic.png
python -m ffcs apply image.tif --sim PROVIA --lut look.cube --lut-domain encoded --sigma 1 --out custom.tif
python -m ffcs compare candidate-stages reference-stages --stride 1 --out residuals.json
python -m ffcs colorchecker candidate.tif reference.tif --boxes boxes.json --out chart.json
```

apply/develop 的公共选项：--sim 默认 PROVIA，--camera 默认 GENERIC，--filter G/R/Ye，--out 必需，--bits 8/16 默认16，--space sRGB/AdobeRGB 默认sRGB，--seed 整数默认0，--lut、--lut-domain linear/encoded、--sigma 浮点、--analytic、--stages、--json。CLI 没有 input_is_linear/sharpen_radius 控制，需要 Python API。

list 的 what 默认 simulations。boxes.json 必须是 24 个 [x0,y0,x1,y1]，x1/y1 为不包含的右下边界。框与图必须事先对齐，不做图表检测、透视校正或配准。

apply/develop 成功返回0，处理捕获错误返回2；argparse 非法参数一般返回2。compare 即使指标 fail 也返回0，**自动验收需读取 JSON status**。colorchecker 通过返回0、指标失败返回1、输入或解析错误返回2。比较报告可能含 Infinity/NaN，Python json.dumps 默认会写这些非严格 JSON 值，其他语言读取需兼容或先规范化。
