# FFCS 技术实现完整交付

本文件夹是 2026-10-11 本地 FFCS 的独立交付快照。包含全部运行代码、48 个 LUT 文件、2 个 ICC 文件、配置、测试、逐阶段技术说明和确定性复现示例。复制整个文件夹后，无需原项目路径即可安装运行。

**复现对象是本文件夹内的 FFCS 实现及其颜色处理结果。** 给定相同输入、参数、数据和依赖环境，可以重建相同处理链并比较每个阶段的数值。现有材料尚不足以证明完整输出与所有机身 JPEG 或其他软件逐像素一致。此边界明确记录于验证说明，不能把阶段覆盖或历史 LUT 误差当成全链一致性证明。

## 目录和阅读顺序

| 路径 | 内容 |
|---|---|
| `docs/01_系统与完整Pipeline.md` | 总体结构、所有分支、阶段域、调用关系 |
| `docs/02_颜色变换数学与数值约定.md` | Gamma、矩阵、LUT、Lab、OKLab、色调曲线、输出空间 |
| `docs/03_LUT容器与全部数据资产.md` | 字节格式、轴顺序、数据选择、完整资产表 |
| `docs/04_RAW双路径实现.md` | 传感器路径、预览路径、每一阶段公式及实际限制 |
| `docs/05_颗粒锐化与图像IO.md` | 确定性噪声、空间算子、TIFF 与 ICC |
| `docs/06_参数API与CLI.md` | 完整参数表、所有模型参数、命令与退出码 |
| `docs/07_验证指标与复现边界.md` | 指标实现、证据、误差与复现范围 |
| `docs/08_文件清单与交付检查.md` | 本地文件分类、交付规则、校验方法 |
| `docs/09_全部源码逐模块索引.md` | 全部代码逐函数索引、行号与源码链接 |
| `docs/10_独立重建实施规格.md` | 其他语言重建顺序、运算顺序、分支与边界检查 |
| `implementation/` | 独立可安装工程及原有全部测试 |
| `examples/reproduce.py` | 运行时生成夹具的复现程序 |
| `examples/verify_delivery.py` | 全文件 SHA-256 与资产完整性检查 |
| `validation/` | 历史指标、本次测试、确定性像素和环境记录 |

## 从零运行

在本文件夹内执行：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r validation/requirements-verified.txt
.venv/bin/python -m pip install ./implementation --no-deps
.venv/bin/python examples/verify_delivery.py
.venv/bin/python examples/reproduce.py
.venv/bin/python -m pytest implementation/tests -q
```

Windows 使用 `.venv\Scripts\python.exe` 替代 `.venv/bin/python`。配置声明 Python >=3.9；本次实测版本及其范围见 `validation/run_report.json`。如果需要传感器 RAF 解码，另执行 `python -m pip install './implementation[raw]'` 并记录 rawpy、NumPy、LibRaw 版本。RAW 可选依赖未包含在 RGB 实测锁定环境里。

```sh
.venv/bin/python -m ffcs apply input.tif --sim NC --camera XH2S --seed 0 --bits 16 --space sRGB --out output.tif --stages stages
.venv/bin/python -m ffcs apply input.tif --sim CC --camera XA3 --out chrome.tif
.venv/bin/python -m ffcs develop input.raf --sim ACROS --filter Ye --camera XH2S --out acros.tif --stages raw_stages
```

示例输出写入 `examples/generated/`，可重复运行。复现程序会检查既有浮点阶段基准，而不是只生成一张看起来相似的图。校验程序忽略安装缓存和示例生成物，读取 `validation/delivery_manifest.json` 中明确列出的交付文件。

## 上传内容范围

压缩包仅包含技术文档、源码、测试、文本数值基准、校验记录与运行必需的 LUT/ICC 数据。安装包、输入/输出图片、RAF 文件、测试生成物和缓存均不随包上传。示例程序运行时会在本地生成测试图片，这些生成物不属于交付压缩包。
