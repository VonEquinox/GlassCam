# FFCS 技术实现完整交付 0.2.0

2026-10-13 修复后的独立可安装交付：50 张 LUT、2 个 ICC、全部代码、61 项回归测试、10 篇技术文档、合成数值复现和 SHA-256 校验。补齐 GFX100S NOSTALGIC Neg. 与 GFX100 II REALA ACE。

修复说明见 [FIXES_20261013.md](FIXES_20261013.md)。原生核心 LUT 对照共 100,000 样本，最高单表平均 ΔE2000 0.0540214251；全部满足平均 <1。真实 RAF/原生 GUI/独立色卡配对尚缺，完整流程等价仍未验证。

## 从零运行

Python >=3.10，安装 Pillow>=9.1、NumPy、tifffile、imagecodecs。以下命令让 pip 按当前 Python 解析兼容依赖：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install './implementation[test]'
.venv/bin/python examples/verify_delivery.py
.venv/bin/python examples/reproduce.py
.venv/bin/python -m pytest implementation/tests -q
.venv/bin/python -m ffcs apply input.tif --sim NC --camera XH2S --out output.tif --stages stages
```

Windows 使用 `.venv\Scripts\python.exe`。本次 Python3.14.6 的实测环境记录在 `validation/requirements-verified.txt`；仅在兼容该锁定版本的环境中使用 `pip install -r ...`。传感器 RAF 另装 `'./implementation[raw]'`。

已载入 LUT 默认关闭额外解析调整，`--preset-adjustments` 可主动启用。传感器 RAW 自动保留线性；解码失败时预览保留已有显影、记录原因与不适用传感器阶段。TIFF16/方向/ICC 保持精度；编码阶段按实际空间标记，线性诊断保存无 ICC float32。

## 文档与目录

| 入口 | 内容 |
|---|---|
| [01 系统](docs/01_系统与完整Pipeline.md) | 全部分支、阶段域、默认处理 |
| [02 数学](docs/02_颜色变换数学与数值约定.md) | Gamma、矩阵、LUT、Lab/OKLab、tone与输出 |
| [03 数据](docs/03_LUT容器与全部数据资产.md) | 字节结构、全部50表与机型选择 |
| [04 RAW](docs/04_RAW双路径实现.md) | 同CFA运算、双绿、线性与预览 |
| [05 IO与效果](docs/05_颗粒锐化与图像IO.md) | 残差频谱、Gaussian半径、TIFF/ICC |
| [06 API](docs/06_参数API与CLI.md) | 完整参数与命令/退出码 |
| [07 验证](docs/07_验证指标与复现边界.md) | 测量、测试与未验证范围 |
| [08 文件](docs/08_文件清单与交付检查.md) | 清单/资产区分和独立校验 |
| [09 源码](docs/09_全部源码逐模块索引.md) | 当前所有模块/符号索引 |
| [10 重建](docs/10_独立重建实施规格.md) | 运算顺序、边界输入和验收 |
| `implementation/` | 全部源码、依赖、测试与原生诊断源码 |
| `examples/` | 从文本生成夹具并核对baseline；检查交付hash |
| `validation/` | 本次原生测量、环境、测试/复现/安装结果 |

`examples/generated/` 是运行时生成物，不包含在 ZIP。交付清单明确定义包内容；不包含安装器、vendor可执行文件、输入/输出图像、RAF和缓存。独立复现与原生匹配是不同证据，所有尚未定量标定的部分在元数据和验证文档里明确记录。
