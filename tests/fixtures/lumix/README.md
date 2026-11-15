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

## 原程序分派夹具

`native-dispatch-vectors.zip` 来自重新解包的同版原厂框架，在完成原应用 `IslInterface` 初始化后调用 `Set3DLUT`、`SetRegs`、`Pana_LUT::GetValue` 和 `FilteringLine`。框架 SHA-256 为 `63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b`；夹具归档 SHA-256 为 `c4c441ba73e227940b3aef4b6e5767e9ce7984eed2ed6480645ae3d9ac149e34`。归档内 schema 1 清单记录每例设置、原始样本索引、输入和独立期望的哈希，以及采集程序和完整比较记录的身份。

夹具包含 456 例、57,912 个 RGB 像素，其中 96 例为 RGB12，360 例为 RGB48，112 例选自独立留出输入。范围覆盖全部 16 个风格、3000/5000 K 端点、双表混合、色温量化边界、全部 21 档对比度和饱和度、ISO 50/64/80/100、白值 4095/16383/65535、EV −0.5/0/+0.5 和两种整数输出空间。相机上下文固定为 DC-S1M2，原始 Photo Style 固定为 0。每例从完整原厂输出抽取 127 个样本，期望值不由产品实现生成。

对应研究工具位于 `GlassCam-research/tools/native-parity/lumix`，完整运行记录位于该仓库的 `evidence/native-parity/513e277-oracle-audit/lumix`。先按研究仓库的复现说明生成独立进程矩阵，再执行以下命令；`FRAMEWORK` 指向原解包框架，`EVIDENCE` 指向该 LUMIX 证据目录，`OUTPUT` 必须是不存在的新文件。

```sh
python3 tools/native-parity/lumix/initialized_audit.py \
  --source-run "$EVIDENCE/python-host" --framework "$FRAMEWORK" \
  --symbols "$EVIDENCE/symbols.tsv" --output "$EVIDENCE/initialized/matrix"
python3 tools/native-parity/lumix/export_fixtures.py \
  --evidence "$EVIDENCE/initialized/matrix" --output "$OUTPUT"
```

[原程序分派测试](../../numeric/test_lumix_native_dispatch.py)只消费固定输入和期望，调用产品 C ABI 并逐整数比较。夹具验证上述离散阶段，不代表 RAW 解码、相机标定、最终 ICC 输出或 revision 4 浮点适配已与原程序等价。

## 当前生产颜色

`native-color-vectors.zip` 对应 render revision 5，SHA-256 为 `4abe94fa48111b6674c1ed08125614818e37a93f4390d844f2892093539e550b`。原厂框架身份与上节相同；原应用初始化后，以工作白值 `16380` 对灰阶、RGB 轴向扫描和独立随机输入运行全部风格的低 ISO 与控制端点组合。

归档包含原厂整数输出及标准 sRGB EOTF 转换后的浮点期望，记录完整原始输入／输出哈希和抽样位置；原函数重复调用的结果逐字节相同。浮点转换只改变输出单位，颜色、饱和度和对比度期望来自原厂，旧参考夹具保持不变。

在 `GlassCam-research` 中采集，`OUTPUT` 为不存在的新证据目录：

```sh
python tools/native-parity/lumix/capture_production_color.py \
  --prior "$LUMIX_EVIDENCE" --output "$OUTPUT" --product "$GLASSCAM"
```

消费入口为 [当前整数颜色与浮点输入域桥测试](../../numeric/test_lumix_native_color.py)。
