# HNCS 数值夹具

这些文件冻结了 Phocus 4.2.2 原程序的输出，来源与框架哈希见各 JSON 和 [HNCS 来源](../../../vendor/hncs/ORIGIN.md)。`phocus-native-chain-*` 对应 HNCS render revision 10；`x2d-hdr-*` 覆盖 HDR 色彩、色调、后处理与锐化；`x2d-native-gain-*` 覆盖普通工作域的原生增益。没有独立版本字段的夹具以 JSON 中的向量 SHA-256 为版本标识。

原始生成工具保存在 `GlassCam-research` 的提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b`，位于 `tools/reverse-engineering/`。采集入口如下，参数指向对应研究环境的原始参考目录、RAW 和裁剪清单；生成的向量及清单经过选取、重命名后冻结于本目录。

```sh
python tools/reverse-engineering/verify_phocus_chain.py --reference-root "$REFERENCE" --output-dir "$OUTPUT/chain"
python tools/reverse-engineering/verify_x2d_hdr.py --reference-root "$REFERENCE" --raw-source "$RAW" --output-dir "$OUTPUT/hdr"
python tools/reverse-engineering/audit_x2d_hdr_gradation.py --reference-root "$REFERENCE" --crop-manifest "$CROPS" --output-dir "$OUTPUT/gradation"
python tools/reverse-engineering/verify_x2d_hdr_post.py --reference-root "$REFERENCE" --output-dir "$OUTPUT/post"
python tools/reverse-engineering/verify_phocus_sharpness.py --reference-root "$REFERENCE" --hdr-scale 5.8829245141 --output-dir "$OUTPUT/sharpness"
python tools/reverse-engineering/verify_x2d_color_gain.py --reference-root "$REFERENCE" --output-dir "$OUTPUT/gain"
```

测试只读取冻结值，不重新采集。主仓库迁移前的完整版本为 `eb4e551`；例如可从仓库根目录恢复原始向量：

```sh
git show eb4e551:GlassCamPrototype/validation/phocus-native-chain-vectors.npz > tests/fixtures/hncs/phocus-native-chain-vectors.npz
```

消费入口为 [Phocus 原生链](../../numeric/test_phocus_native_chain.py)、[HDR 色彩](../../numeric/test_x2d_hdr.py)、[HDR 后处理](../../numeric/test_x2d_hdr_post.py)和[原生增益](../../numeric/test_x2d_native_gain.py)。
