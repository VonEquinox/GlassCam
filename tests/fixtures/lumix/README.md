# LUMIX 数值夹具

`native-vectors/*.rgb12` 是 SILKYPIX Developer Studio 8 SE 8.0.31.1 对 DC-S1M2 SDR Photo Style 的原生插值结果，对应 revision 1 单表路径。`native-full-vectors.zip` 冻结完整 RGB48 管线，包含双表混合、低 ISO、色温、饱和度、对比度和输出空间，归档清单使用 schema 2。框架及运行时归档的固定哈希见 [LUMIX 来源](../../../vendor/lumix/ORIGIN.md)。

原始生成工具保存在 `GlassCam-research` 提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b`。在其原始研究布局中，采集命令为：

```sh
python tools/reverse-engineering/extract_lumix_assets.py --analysis-root "$LUMIX_ANALYSIS"
python tools/reverse-engineering/verify_lumix_pipeline.py --analysis-root "$LUMIX_ANALYSIS" --work "$OUTPUT"
```

测试不运行原程序，也不重新生成这些结果。主仓库提交 `eb4e551` 保存了迁移前版本；从仓库根目录恢复完整管线归档的命令为：

```sh
git show eb4e551:GlassCamPrototype/validation/lumix-full-proraw-20261026/native-full-vectors.zip > tests/fixtures/lumix/native-full-vectors.zip
```

消费入口为 [LUT 参考测试](../../numeric/test_lumix_reference.py)和[完整原生管线测试](../../numeric/test_lumix_iphone.py)。
