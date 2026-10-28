# FFCS reference provenance

Current reference: user-supplied **FFCS 0.2.0**, private `VonEquinox/GlassCam`,
`ffcs-technical-delivery-20261011`, pinned commit
`c4b3383da838ea607bcc37d2776b90c8770795f6`.

- Original ZIP Git blob: `4efa7a4e3eceaf3dae19939e90474a1b6fcc1820`
- ZIP size: 88,509,373 bytes
- ZIP SHA256: `ebc7a783280aeeea73791cdd40fcccb30c2b9648061616c96d4a1f9b1decff6c`
- All 115 manifest files, 50 native LUTs, and two ICC profiles verified.

`source.zip` is the original ordinary Git ZIP, reused by Git object identity;
it is not an LFS pointer or a reconstructed archive. The source research branch
is unchanged.

保留的运行时与参考源码、测试、示例和文档保持原样。加载原厂二进制的工具与二进制清单保存在本地 `GlassCam-research` 仓库的提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b`，位于 `upstream/ffcs/` 下的原有相对路径；提取与审计工具位于 `tools/reverse-engineering/`，调查记录位于 `evidence/`。

原始归档和交付清单的哈希保持不变。校验过程从固定哈希归档直接读取四项迁出材料，其他文件读取工作区内容。

在仓库根目录运行 `python scripts/materialize_ffcs_reference.py` 可恢复保留的参考文件，并准备全部 50 张原厂表；已迁出的工具和二进制清单不再解压。

The offline Xcode build phase verifies the archive and every table's SHA256, extracting only exact paths
from the checked-in checksum list. No Python, package install, or network is
required by that build phase. Generated binary resources are ignored by Git.

The previous 0.1.0 archive remains recoverable from development commit
`d5145c5e8f59522ed6e3905c7d42a41d0e144994` at this same path (Git blob
`ecc0ebc69b94d10f8b3f63cac5659d58886efeea`, SHA256
`bc8c9b4d7691f3ecef03a79e3b1a7ddd8364647e97877ee02ceefa8e50e2ea02`).
Historical app reports retain their original version scope; old goldens do not
serve as acceptance targets for the intentionally corrected 0.2.0 defaults.

Apple imports enter as profile-managed, already-developed linear sRGB. The app
uses Core Image RAW decoding, not this Python sensor-CFA/RAF decoder. Python RAW,
ICC, custom-Cube and analytical-only utilities are preserved as reference; their
presence does not claim those separate paths are exposed in the app. Native
asset-family selection describes research table provenance, not the physical
Apple camera. Missing native tables fail explicitly rather than selecting an
analytical substitute. GFX100S/II common GFX100-table fallback is identified as
such, according to the supplied resolver.

The supplied native table measurements do not prove full camera JPEG/SilkyPix
or Apple sensor equivalence. Real RAF/GUI/ColorChecker paired validation remains
absent. Factory/vendor data rights require review before public/App Store
redistribution; this private development copy grants no new rights.
