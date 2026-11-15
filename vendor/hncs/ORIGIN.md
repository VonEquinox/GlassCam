# HNCS 数据来源与权利

本目录选取用户私有仓库 `VonEquinox/GlassCam` 的 `HNCS技术交付/` 材料，固定源提交为 `34fa10f42bc32efea0ca5559f006ebe9a8bf6489`。参考颜色路径为 revision 2，渲染路径为 revision 8；最初移植基线为 `c3595d776fe07ceda4c06793618bbe7456e02f04`。

| 材料 | 来源与校验记录 |
|---|---|
| 参考实现 | [hncs_pipeline.py](hncs_pipeline.py)；独立参考入口为 [reference_color_core.py](tools/reference_color_core.py) |
| 所选源码与数据 | [逐文件 SHA-256 清单](validation/revision8-selected-source-sha256.json) |
| 工厂数值资产 | [provenance.json](work/hncs-pipeline/assets/provenance.json)，记录 Phocus 4.2.2 来源及矩阵、LUT、ICC 的哈希 |
| `x2dii_phocus_422.npz` | SHA-256：`3291628ef8787a20082eaebb7e50fccac0a89bbce14dc5619ecf1277d816c1b9` |
| 应用使用的固定数值样本 | [tests/fixtures/hncs](../../tests/fixtures/hncs/README.md)，各样本保留自身来源与版本 |

revision 13 的白点、矩阵运算与工作配置常量来自同版 Phocus 4.2.2 的独立调用和原始常量。原包 SHA-256 为 `09e09ee99bdabcbc097e2c132a1afe5cdbea1c73b0151eb1ea96ee4068648e78`；工作传递函数与原色保留原始 double 位型。对应原厂输入／输出及哈希保存于 [phocus-native-color.json](../../tests/fixtures/hncs/phocus-native-color.json)，采集和冻结工具位于 `GlassCam-research/tools/native-parity/`。

本目录保留数值测试和资产生成需要的固定参考源码、数据与向量，所选范围由逐文件 SHA-256 清单界定。[参考加载器](../../tests/numeric/support/reference_runtime.py)只载入原始颜色函数；Sony 跨相机标定、上游测试、说明和历史报告保存在 `GlassCam-research` 的 `tools/studies/product-tooling/`，来源为产品提交 `1eac23801da57b4b6b4fd13cff9037cc062c8afb`。

提取脚本和调查证据保存在本机 `GlassCam-research` 仓库提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b`，分别位于 `tools/reverse-engineering/` 和 `evidence/`。

原厂资产和第三方代码保留各自的权利与许可，统一分发说明见 [NOTICE](../../NOTICE.md)。
