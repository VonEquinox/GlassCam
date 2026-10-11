# 运行与全部 Pipeline

> 仓库交付范围：仅技术文档、代码和数值参数。文中涉及的照片、RAW、TIFF、DNG、预览和安装镜像均需在本地另行提供，未上传到此分支。历史照片核验结果为之前在本地执行的记录。


## 环境

在本交付文件夹根目录执行。Python3.12，固定依赖见 requirements：NumPy2.5.3、SciPy1.18.1、rawpy0.27.1、Pillow12.3.0、tifffile2026.9.20。rawpy捆绑 LibRaw 版本须从验证环境记录核对。uv首次安装会访问包源，缓存后可 --offline；也可用 Python venv + pip install -r requirements.txt。普通运行无需联网查询色彩模型。

先运行完整性和固定向量检查：

```bash
uv run --python 3.12 --with-requirements requirements.txt python tools/verify_delivery.py
uv run --python 3.12 --with-requirements requirements.txt python -m unittest -v test_hncs_pipeline test_dual_illuminant test_paired_illuminants test_phocus_presets
```

## 本交付专用回归工具

```bash
uv run --python 3.12 --with-requirements requirements.txt python tools/check_isolated_render.py
uv run --python 3.12 --with-requirements requirements.txt python tools/refit_delivery.py
```

第一项在临时目录只复制运行文件，用随包DSC07247生成完整照片，再与随包像素哈希基线、ICC及方向对照；不读取原工作区历史大图。第二项在临时模型目录重新拟合，使用交付色卡RAW、DCP和ROI，与保存模型比较。两项会把新验收结果写入validation。

## P01 单图与 P02 完整照片交付

```bash
uv run --python 3.12 hncs_pipeline.py render --input DSC07247.ARW --wb camera --illuminant-mode paired --output output/single/DSC07247_hncs.tif
uv run --python 3.12 --with-requirements requirements.txt python process_photo_batch.py --output-dir output/batch DSC07247.ARW DSC07426.ARW
```

单图命令产生工作RGB TIFF、sRGB TIFF、preview JPG及JSON；不会直接产生 full JPG 或DNG。批处理再调用 export_photo_original，产生HNCS全尺寸JPG、DNG、原色TIFF/JPG/preview、comparison及verification。批处理逐张串行，任一子进程失败会停止，日志在该张 processing.log；不是并发/失败重试队列。

两个同 stem 输入会写同一文件夹，建议不同输出根目录分开运行。render允许覆盖指定同名输出但禁止与输入RAW同路径。所有输出请使用单独目录，尤其重新拟合或历史回归时。

## P03 日光标定与 P04 两光源拟合

```bash
uv run --python 3.12 hncs_pipeline.py calibrate
uv run --python 3.12 --with-requirements requirements.txt python prepare_sony_source_profile.py
uv run --python 3.12 --with-requirements requirements.txt python fit_paired_illuminants.py
```

calibrate写基准模型与ROI；prepare校验DCP并写源白点模型；fit读取暖光训练、选择权重/正则化、建立两端并对不同曝光验证比较4模式。`fit_paired_illuminants.py --fit-only` 不打开验证RAW。新日光标定若只写 --profile custom.json，fit工具仍读取默认路径；要更换整套配置，必须调整脚本常量或把新基准设为默认再重拟合。

## P05 成对参考渲染

```bash
uv run --python 3.12 hncs_pipeline.py run
uv run --python 3.12 hncs_pipeline.py render --target-reference --input 7fbb1471e0cf4b22858cd9a161fb83a8.3fr --wb camera --output output/x2dii_hncs.tif
```

run重新标定并写日光Sony/哈苏参考、sRGB版本与comparison。它会更新默认模型。若基准数值改变，先执行P04再用paired渲染，避免指纹拒绝；目前保留默认参数时可得到相同基准。

## P06 光源历史模式、曲线与预设

```bash
uv run --python 3.12 hncs_pipeline.py render --input DSC05218.ARW --illuminant-mode adaptive --output output/adaptive.tif
uv run --python 3.12 hncs_pipeline.py render --input DSC05218.ARW --illuminant-mode calibration --output output/calibration.tif
uv run --python 3.12 hncs_pipeline.py render --input DSC05218.ARW --illuminant-mode dual --output output/dual.tif
uv run --python 3.12 hncs_pipeline.py render --input DSC07247.ARW --working-space lstar --intent reproduction --output output/reproduction.tif
uv run --python 3.12 hncs_pipeline.py render --input DSC07247.ARW --film-curve old-standard --output output/old-standard.tif
uv run --python 3.12 hncs_pipeline.py render --input DSC07247.ARW --preset nature --no-sharpness --output output/nature.tif
uv run --python 3.12 hncs_pipeline.py render --input DSC07247.ARW --preset film-grain-fine-texture --output output/grain.tif
```

`--exposure`有限±20档；`--cct`2000…10000；`--chunk-rows`正整数；`--no-lut`仅诊断；raw-film-curve=0…7。所有预设值用 render --help 查看。`--profile/--assets/--paired-profile/--dual-profile`是单图入口参数，batch不透传所有这些参数；自定义模型批处理需修改/扩展包装脚本。

## P07 实验模型与全部审计工具

| 工具 | 输入和产物 | 前提 |
|---|---|---|
| hncs_dual_illuminant.py | 保存来源→model.json | 随包 public matrices/source reports |
| compare_dual_illuminant.py | 旧/dual照片对比 | 先生成对应历史模式照片 |
| audit_phocus_presets.py | 43预设数值探针→preset_effect_audit.json | 普通Python环境 |
| work/hncs-pipeline/verify_raw_normalisation.py | CFA/AHD尺度报告 | 原色卡RAW |
| work/hncs-phocus-audit/compare_phocus_export.py | 与实际导出TIFF的24块对照 | P05生成参考TIFF；随包实际导出 |
| verify_final_pipeline.py | 八张paired和adaptive文件对比 | 两套批量输出必须先生成 |
| audit_hncs_finalization.py | 汇总旧完整交付检查 | 同上，旧记录中绝对路径须重生成 |
| package_hncs_runtime.py | 运行ZIP + 可选隔离照片比较 | --verify需work/hncs-finalization/output中的DSC07247结果 |
| work/hncs-phocus-audit/update_audit_manifest.py | 旧审计哈希更新 | 指定审计输出存在 |

本目录保留所有这些代码；它们的历史输出前提不是核心渲染依赖。全部函数和历史版本入口见08索引。早期e2e脚本和before代码用于对照发展过程，不能替代revision6默认算法。

## P08 八张照片与版本比较

```bash
uv run --python 3.12 --with-requirements requirements.txt python process_photo_batch.py --illuminant-mode adaptive --output-dir work/hncs-adaptive-2026-10-03 DSC07247.ARW DSC07426.ARW DSC07294.ARW DSC07372.ARW DSC07240.ARW DSC04637.ARW DSC04945.ARW DSC05218.ARW
uv run --python 3.12 --with-requirements requirements.txt python process_photo_batch.py --output-dir work/hncs-finalization/output DSC07247.ARW DSC07426.ARW DSC07294.ARW DSC07372.ARW DSC07240.ARW DSC04637.ARW DSC04945.ARW DSC05218.ARW
uv run --python 3.12 --with-requirements requirements.txt python verify_final_pipeline.py
uv run --python 3.12 --with-requirements requirements.txt python package_hncs_runtime.py --verify
```

这会生成数十GB照片；交付目录没有重复收录这些可生成的大图。`verify_final_pipeline.py` 当前还检查两套 original_render，不只是颜色主图，因此必须完整 batch，两套都不能只跑render。

## P09 工厂资产准备与原生核验

随包Phocus_4.2.2_Mac.dmg可以只读挂载到/Volumes/Phocus；这些工具限定Apple Silicon及指定框架SHA。镜像当前没有挂载，本次没有重跑原生调用。普通开发者不需要这些步骤即可重建数值颜色核。

```bash
hdiutil attach -readonly Phocus_4.2.2_Mac.dmg
uv run --python 3.12 --with-requirements requirements.txt python prepare_hncs_assets.py
uv run --python 3.12 --with-requirements requirements.txt python extract_phocus_presets.py
```

prepare依赖随包原工厂plist与v1curve.py、镜像框架；检查3份框架SHA再提取矩阵、Robertson、曲线、LUT和ICC。extract后若要重新填充原生WB探针行，运行wb_preset_probe.py（它更新预设JSON）；不要只提取XML就删去已保存的Tint乘数。

指定DYLD_FRAMEWORK_PATH后可逐个执行native_config_probe.py、native_chain_probe.py、native_capture_probe.py、film_curve_probe.py、wb_preset_probe.py，它们位于work/hncs-phocus-audit，检查配置插值、颜色向量、RAW设置、曲线、WB增益。旧native_validation.py只是新版链路的包装。执行这些脚本会写新的验证资料，保留副本以便对照。

## 故障定位

资产哈希不符：恢复成套NPZ/ICC/provenance，不要修改校验值来绕过。paired fingerprint/source SHA不符：按P03/P04重拟合。非正虚拟中性或CCT不收敛：检查WB、模型方向和输入型号。ROI样本不足/裁剪：检查角点与曝光。颜色差异：先比较虚拟RGB和固定核向量，再看工作空间/曲线/ICC，最后看裁切与预设。DNG无法读回或CFA不一致应视为导出失败。
