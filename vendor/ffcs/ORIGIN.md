# FFCS 数据来源与权利

当前参考材料为用户提供的 **FFCS 0.2.0**，来自私有仓库 `VonEquinox/GlassCam` 的 `ffcs-technical-delivery-20261011`，固定源提交为 `c4b3383da838ea607bcc37d2776b90c8770795f6`。

| 材料 | 版本与校验记录 |
|---|---|
| [source.zip](source.zip) | 原始普通 Git 归档，88,509,373 字节 |
| 归档 Git blob | `4efa7a4e3eceaf3dae19939e90474a1b6fcc1820` |
| 归档 SHA-256 | `ebc7a783280aeeea73791cdd40fcccb30c2b9648061616c96d4a1f9b1decff6c` |
| [交付清单](validation/delivery_manifest.json) | 115 项原始交付文件，包含 50 张原生 LUT 与两个 ICC 文件 |
| 运行时 LUT | [SHA-256 清单](../../scripts/ffcs_native_SHA256SUMS) |
| 应用固定样本 | [tests/fixtures/ffcs](../../tests/fixtures/ffcs/README.md)，保留各版本的独立来源 |

最初接入参考提交为 `3c0a85eeb3893764ae92fc0fe52ebb62fd9f6ac5`。旧 0.1.0 归档可从提交 `d5145c5e8f59522ed6e3905c7d42a41d0e144994` 的 `GlassCamPrototype/reference_ffcs/source.zip` 恢复，其 Git blob 为 `ecc0ebc69b94d10f8b3f63cac5659d58886efeea`，SHA-256 为 `bc8c9b4d7691f3ecef03a79e3b1a7ddd8364647e97877ee02ceefa8e50e2ea02`。

保留的参考源码和上游文档使用原始内容。原厂二进制调查工具及二进制清单保存在 `GlassCam-research` 提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b` 的 `upstream/ffcs/`；提取与审计工具位于 `tools/reverse-engineering/`，调查证据位于 `evidence/`。

原厂数据与参考源码保留各自的权利与许可，统一分发说明见 [NOTICE](../../NOTICE.md)。
