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

`phocus-422-independent.json` 与 `phocus-422-independent-vectors.npz` 保存独立输入在 Phocus 4.2.2 arm64 上的颜色、增益、HDR、预设曲线、后置颜色和完整尺寸锐化输出，由 [独立原厂阶段回归](../../numeric/test_hncs_original_binary.py)读取。清单固定整库与 arm64 切片哈希、原始数组哈希、输入种子和取样位置；空间样本保留完整邻域。原厂 helper 使用 `CXMLLut(profile, 0)` 自行加载包内资源，原厂与产品分别运行于独立进程。

采集和选取工具位于 `GlassCam-research/tools/native-parity/hncs/`，`EVIDENCE` 指向研究仓库中的独立实验目录：

```sh
python tools/native-parity/hncs/audit.py --evidence "$EVIDENCE"
python tools/native-parity/hncs/freeze_fixtures.py --evidence "$EVIDENCE" --output "$FIXTURE_OUTPUT"
```

选取工具拒绝覆盖现存夹具。完整资源、原厂颗粒、源域适配与成片层的比较记录保存在研究仓库。

## 当前白点与工作配置

`phocus-native-color.json` 和 `phocus-native-color-vectors.npz` 对应 render revision 13。NPZ 的 SHA-256 为 `7830e4e6b5d84b094e43e36b76da42856e925967a8f2dc3bac18c821d6b987d5`。白点数据来自原厂 `CColorTempConversion` 与颜色上下文，包含捕获／目标增益、工厂 CCT 与相同原生输入的颜色；输出数据来自原厂 `CCustomCMM` 的工作配置 0/1/8/9 到扩展线性 sRGB 配置 10。

清单记录选用的白点、预设、策略、工作空间、原始数组哈希与尺度。结束阶段期望值直接取原厂 Float32 输出；原厂未插观察和插观察的整数结果一致。旧 CPU 夹具保持原样。

在 `GlassCam-research` 中，从已经保留的原厂调用数据冻结：

```sh
python tools/native-parity/freeze_production_color.py \
  --evidence "$EVIDENCE" --product "$GLASSCAM"
```

消费入口是 [当前 HNCS 颜色测试](../../numeric/test_hncs_native_color.py)。
