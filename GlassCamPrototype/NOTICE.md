# Provenance and distribution boundary

HNCS reference source and numerical assets originate from the historical `HNCS技术交付/` tree in the user's private repository `VonEquinox/GlassCam`, pinned source commit `34fa10f42bc32efea0ca5559f006ebe9a8bf6489` (original port baseline `c3595d776fe07ceda4c06793618bbe7456e02f04`). The selected sources and assets used by GlassCam are preserved in `reference/`.

Original color implementation: `hncs_pipeline.py` (colour path revision 2, render path revision 8). Independent original implementation: `tools/reference_color_core.py`. Asset provenance: `work/hncs-pipeline/assets/provenance.json`. NPZ SHA256: `3291628ef8787a20082eaebb7e50fccac0a89bbce14dc5619ecf1277d816c1b9`.

The portable C++ implementation is derived from these sources and uses a lossless generated representation of supplied numeric tables. Source order, quantization and domain semantics are retained deliberately. The bundled reference files retain their original provenance and hashes; the separate technical-delivery branch and top-level directory are not build dependencies.

The supplied provenance identifies recovered Phocus 4.2.2 data. No blanket license or proof of commercial redistribution rights for these factory data was supplied. Permission to work in the private repository is not a finding that App Store distribution is cleared. Do not publish the factory data in a public repository or commercial application without rights review. No licensing statement in this prototype grants rights to Hasselblad/Phocus materials. The unrelated license elsewhere in the technical delivery must not be treated as licensing these tables.

Only user-authorized private repository development is performed here. This prototype is not affiliated with or endorsed by Hasselblad or Apple.

## FFCS

FFCS derives from the user-supplied private technical delivery, source commit `3c0a85eeb3893764ae92fc0fe52ebb62fd9f6ac5`. Exact archive provenance and preserved materials are documented in [reference_ffcs/ORIGIN.md](reference_ffcs/ORIGIN.md). Original code, documents, validation and recovered LUT/ICC bytes are retained. Factory SilkyPix/Fujifilm data do not acquire public redistribution rights through this port. No proof of commercial redistribution clearance has been established. Private development authorization does not authorize public release of these assets. This prototype is not endorsed by Fujifilm or SilkyPix.

Revision 8 preset source/catalog and the six UInt16 post-curve tables retain the same private provenance boundary. Native post-curve vectors validate recovered color controls, not proprietary Phocus spatial kernels. Legacy numerical reports remain historical evidence. See [revision 8 contract](docs/HNCS_REVISION8.md).

## NumPy / SciPy compatibility components

The revision-8 portable spatial port retains the applicable NumPy/SciPy BSD and PCG/random-generator license notices and source URLs directly in `core/hncs_numpy_rng.cpp` and `core/hncs_spatial.cpp`. These notices must accompany redistributions, including compiled distributions where the licenses require it. This is distinct from the unresolved rights to recovered Phocus/Fujifilm factory data.
