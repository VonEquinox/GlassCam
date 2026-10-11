# FFCS 可安装实现

本目录包含完整 Python 包、LUT、ICC 和测试。技术说明从上一级 README.md 开始阅读。

```sh
python -m pip install .
python -m ffcs list simulations
python -m pytest tests -q
```

运行依赖是 Pillow；传感器 RAF 路径需要可选依赖 `pip install '.[raw]'`。数值处理、解析约定和现有实现限制详见上一级 docs/。
