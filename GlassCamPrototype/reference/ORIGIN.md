# Selected HNCS reference source

This directory preserves selected original files from the user's private `VonEquinox/GlassCam` repository, `HNCS技术交付/`, pinned commit `34fa10f42bc32efea0ca5559f006ebe9a8bf6489` (colour revision 2, render revision 8). The original port used `c3595d776fe07ceda4c06793618bbe7456e02f04`; its core numerical assets and legacy golden vectors remain unchanged.

提取脚本和调查证据保存在本地 `GlassCam-research` 仓库的提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b`，分别位于 `tools/reverse-engineering/` 和 `evidence/`。

`README.md`, `validation/delivery_manifest.json`, `source_index.json`, and `tests.log` are original upstream documents/evidence. They describe the complete upstream delivery and are not a statement that every upstream file or RAW input is bundled here, or that all upstream tests were run in this environment. Current selected-file hashes are in `validation/revision8-selected-source-sha256.json`.

应用的 golden 数据保留在原型顶层的 `validation/`；调查记录位于上述研究仓库的 `evidence/`。

Runtime reproduction uses retained source assets without installing or running Phocus. No original photography or RAW image is added. Current cloud package versions may differ from upstream's locked requirements; each newly executed report must state its actual environment. No automatic dependency upgrade or new calibration is implied by this sync.

The original recovered factory data retain their existing rights boundary. See [NOTICE](../NOTICE.md). Private repository development does not establish commercial redistribution permission or complete Phocus equivalence.
